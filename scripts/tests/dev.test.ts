import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { acquireLock, appPIDs, createRebuilder, inputFiles, rebuild, refreshInputs } from "../dev-support";
import { run } from "../common";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "window-arrange-bun-"));
  const app = join(root, "dist/Window Arrange.app");
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "old"), "old app");
  return { root, app, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

describe("build scheduling survives Bun worker restarts", () => {
  test("rapid saves are coalesced", async () => {
    let builds = 0;
    const queue = createRebuilder(async () => { builds++; }, () => {}, 5);
    queue.request(); queue.request(); queue.request();
    await Bun.sleep(30);
    await queue.stop();
    expect(builds).toBe(1);
  });

  test("a new save cancels a build and waits for its cleanup", async () => {
    let builds = 0;
    let cancelled = false;
    let finish!: () => void;
    const gate = new Promise<void>(resolve => { finish = resolve; });
    const queue = createRebuilder(async signal => {
      builds++;
      if (builds === 1) {
        signal.addEventListener("abort", () => { cancelled = true; });
        await gate;
      }
    }, () => {}, 5);
    queue.request();
    await Bun.sleep(20);
    queue.request();
    await Bun.sleep(20);
    expect(cancelled).toBe(true);
    expect(builds).toBe(1);
    finish();
    await Bun.sleep(20);
    await queue.stop();
    expect(builds).toBe(2);
  });

  test("publishing finishes before a queued rebuild or shutdown", async () => {
    let aborted = false;
    let finish!: () => void;
    const gate = new Promise<void>(resolve => { finish = resolve; });
    const queue = createRebuilder(async (signal, publishing) => {
      publishing(true);
      signal.addEventListener("abort", () => { aborted = true; });
      await gate;
    }, () => {}, 5);
    queue.request();
    await Bun.sleep(20);
    queue.request();
    let stopped = false;
    const stop = queue.stop().then(() => { stopped = true; });
    await Bun.sleep(20);
    expect(aborted).toBe(false);
    expect(stopped).toBe(false);
    finish();
    await stop;
  });

  test("failure retries only after another save", async () => {
    let builds = 0;
    let errors = 0;
    const queue = createRebuilder(async () => {
      if (++builds === 1) throw new Error("compiler error");
    }, () => { errors++; }, 5);
    queue.request();
    await Bun.sleep(30);
    expect(builds).toBe(1);
    queue.request();
    await Bun.sleep(30);
    await queue.stop();
    expect(builds).toBe(2);
    expect(errors).toBe(1);
  });
});

describe("safe app updates", () => {
  test("failed builds leave the running app untouched", async () => {
    const f = fixture();
    let stopped = false;
    try {
      await expect(rebuild({ ...f,
        build: async () => { throw new Error("compiler error"); },
        stop: async () => { stopped = true; },
      })).rejects.toThrow("compiler error");
      expect(stopped).toBe(false);
      expect(readFileSync(join(f.app, "old"), "utf8")).toBe("old app");
    } finally { f.cleanup(); }
  });

  test("signature verification precedes shutdown and publishing", async () => {
    const f = fixture();
    const events: string[] = [];
    try {
      await rebuild({ ...f,
        build: async (_, staged) => {
          mkdirSync(staged!, { recursive: true });
          writeFileSync(join(staged!, "new"), "new app");
          events.push("build");
        },
        execute: async args => {
          if (args[0].endsWith("codesign")) {
            events.push("signature");
            return 'designated => identifier "test" and certificate leaf = H"abc"';
          }
          expect(existsSync(join(f.app, "new"))).toBe(true);
          events.push("open");
          return "";
        },
        stop: async () => { expect(existsSync(join(f.app, "old"))).toBe(true); events.push("stop"); },
      });
      expect(events).toEqual(["build", "signature", "signature", "stop", "open"]);
      expect(existsSync(join(f.app, "old"))).toBe(false);
    } finally { f.cleanup(); }
  });

  test("ad-hoc signatures are never published", async () => {
    const f = fixture();
    let stopped = false;
    try {
      await expect(rebuild({ ...f,
        build: async (_, staged) => { mkdirSync(staged!, { recursive: true }); },
        execute: async () => '# designated => cdhash H"abc"',
        stop: async () => { stopped = true; },
      })).rejects.toThrow("署名");
      expect(stopped).toBe(false);
      expect(existsSync(join(f.app, "old"))).toBe(true);
    } finally { f.cleanup(); }
  });

  test("cancellation during a build preserves the old app", async () => {
    const f = fixture();
    const controller = new AbortController();
    let stopped = false;
    try {
      await expect(rebuild({ ...f, signal: controller.signal,
        build: async () => { controller.abort(); controller.signal.throwIfAborted(); },
        stop: async () => { stopped = true; },
      })).rejects.toThrow();
      expect(stopped).toBe(false);
      expect(existsSync(join(f.app, "old"))).toBe(true);
    } finally { f.cleanup(); }
  });

  test("only the executable at the exact app path is selected", () => {
    const app = "/tmp/Window Arrange.app";
    expect(appPIDs(`123 /tmp/Window Arrange.app/Contents/MacOS/WindowArrange\n124 /Applications/Window Arrange.app/Contents/MacOS/WindowArrange\n125 /tmp/Window Arrange.app.backup/Contents/MacOS/WindowArrange`, app)).toEqual([123]);
  });

  test("command errors do not include password arguments", async () => {
    await expect(run([process.execPath, "-e", "process.exit(1)", "secret-password"], { quiet: true }))
      .rejects.not.toThrow("secret-password");
  });
});

test("one supervisor holds the lock across worker restarts", () => {
  const f = fixture();
  try {
    const release = acquireLock(f.root);
    expect(() => acquireLock(f.root)).toThrow("実行中");
    release();
    acquireLock(f.root)();
  } finally { f.cleanup(); }
});

test("input manifest includes additions and deletions, and ignores build output", () => {
  const f = fixture();
  try {
    mkdirSync(join(f.root, "Sources"));
    writeFileSync(join(f.root, "Sources/View.swift"), "struct View {}");
    refreshInputs(f.root);
    expect(inputFiles(f.root)).toEqual(["Sources/View.swift"]);
    writeFileSync(join(f.root, ".build/Generated.swift"), "ignored");
    expect(inputFiles(f.root)).toEqual(["Sources/View.swift"]);
    rmSync(join(f.root, "Sources/View.swift"));
    refreshInputs(f.root);
    expect(JSON.parse(readFileSync(join(f.root, ".build/dev-inputs.json"), "utf8"))).toEqual([]);
  } finally { f.cleanup(); }
});

test("Bun --watch reloads Swift text imports, including newly added files", async () => {
  const f = fixture();
  let child: ReturnType<typeof Bun.spawn> | undefined;
  try {
    mkdirSync(join(f.root, "Sources"));
    const source = join(f.root, "Sources/View.swift");
    writeFileSync(source, "struct View {}");
    const entry = join(f.root, "watch.ts");
    const support = resolve(import.meta.dir, "../dev-support.ts");
    writeFileSync(entry, `import { watchInputs, registerInputs } from ${JSON.stringify(support)};
watchInputs(${JSON.stringify(f.root)});
await registerInputs(${JSON.stringify(f.root)});
console.log("ready");
setInterval(() => {}, 60000);`);
    child = Bun.spawn([process.execPath, "--watch", "--no-clear-screen", entry], { stdout: "pipe", stderr: "inherit" });
    const reader = child.stdout.getReader();
    async function ready(stage: string) {
      const result = await Promise.race([
        reader.read(),
        Bun.sleep(4000).then(() => { throw new Error(`Bun watch did not restart: ${stage}`); }),
      ]);
      expect(new TextDecoder().decode(result.value)).toContain("ready");
    }
    await ready("initial");
    writeFileSync(source, "struct Changed {}");
    await ready("edit");
    const added = join(f.root, "Sources/New.swift");
    writeFileSync(added, "struct New {}");
    await ready("addition");
    writeFileSync(added, "struct NewChanged {}");
    await ready("edit new file");
    rmSync(added);
    await ready("deletion");
  } finally {
    child?.kill();
    await child?.exited;
    f.cleanup();
  }
}, 15000);
