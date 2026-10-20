import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, watch, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { APP, ROOT, run, type Runner } from "./common";
import { buildApp } from "./build";

export function inputFiles(root = ROOT): string[] {
  const files = ["Package.swift", "package.json"].filter(name => existsSync(join(root, name)));
  for (const directory of ["Sources", "Resources", "scripts"]) {
    if (!existsSync(join(root, directory))) continue;
    for (const entry of readdirSync(join(root, directory), { recursive: true, withFileTypes: true })) {
      if (entry.isFile() && (directory === "Resources" || /\.(swift|ts)$/.test(entry.name))) {
        files.push(relative(root, join(entry.parentPath, entry.name)));
      }
    }
  }
  return files.sort();
}

export function refreshInputs(root = ROOT) {
  mkdirSync(join(root, ".build"), { recursive: true });
  const path = join(root, ".build/dev-inputs.json");
  const contents = JSON.stringify(inputFiles(root));
  if (!existsSync(path) || readFileSync(path, "utf8") !== contents) writeFileSync(path, contents);
}

export async function registerInputs(root = ROOT) {
  const { default: manifest } = await import(join(root, ".build/dev-inputs.json"), { with: { type: "text" } });
  for (const file of JSON.parse(manifest) as string[]) {
    const path = join(root, file);
    if (!existsSync(path)) continue;
    try { await import(path, { with: { type: "text" } }); }
    catch (error) { if (existsSync(path)) throw error; }
  }
}

export function createRebuilder(task: (signal: AbortSignal, publishing: (value: boolean) => void) => Promise<void>,
  onError: (error: unknown) => void, delay = 700) {
  let generation = 0;
  let stopped = false;
  let publishing = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let controller: AbortController | undefined;
  let active: Promise<void> | undefined;
  function drain() {
    if (active || stopped) return;
    const attempted = generation;
    controller = new AbortController();
    const signal = controller.signal;
    active = task(signal, value => { publishing = value; }).catch(error => {
      if (!signal.aborted) onError(error);
    }).finally(() => {
      active = undefined;
      controller = undefined;
      publishing = false;
      if (generation !== attempted && !timer) drain();
    });
  }
  return {
    request() {
      if (stopped) return;
      generation++;
      if (!publishing) controller?.abort();
      clearTimeout(timer);
      timer = setTimeout(() => { timer = undefined; drain(); }, delay);
    },
    async stop() {
      stopped = true;
      clearTimeout(timer);
      if (!publishing) controller?.abort();
      await active;
    },
  };
}

export function watchInputs(root = ROOT) {
  refreshInputs(root);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const watchers = ["Sources", "Resources", "scripts", "."].filter(directory => existsSync(join(root, directory))).map(directory =>
    watch(join(root, directory), { recursive: directory !== "." }, event => {
      if (event !== "rename") return;
      clearTimeout(timer);
      timer = setTimeout(() => refreshInputs(root), 100);
    }));
  return () => { for (const watcher of watchers) watcher.close(); clearTimeout(timer); };
}

export function acquireLock(root = ROOT) {
  const lock = join(root, ".local/dev.lock");
  mkdirSync(join(root, ".local"), { recursive: true });
  for (let attempt = 0; attempt < 2; attempt++) {
    try { writeFileSync(lock, String(process.pid), { flag: "wx" }); }
    catch (error: any) {
      if (error.code !== "EEXIST") throw error;
      const pid = Number(readFileSync(lock, "utf8"));
      if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error("開発モードのロックを確認してください: .local/dev.lock");
      try { process.kill(pid, 0); }
      catch (error: any) {
        if (error.code === "ESRCH") { rmSync(lock); continue; }
        throw error;
      }
      throw new Error("別の開発モードが実行中です。先にそちらを終了してください。");
    }
    return () => rmSync(lock, { force: true });
  }
  throw new Error("開発モードのロックを取得できませんでした。");
}

export function appPIDs(output: string, app = APP) {
  const executable = join(app, "Contents/MacOS/WindowArrange");
  return output.split("\n").flatMap(line => {
    const match = line.match(/^\s*(\d+)\s+(.+)$/);
    return match && match[2] === executable ? [Number(match[1])] : [];
  });
}

export async function stopApp(app = APP) {
  const pids = appPIDs(await run(["/bin/ps", "-axo", "pid=,comm="], { capture: true }), app);
  for (const pid of pids) {
    try { process.kill(pid, "SIGTERM"); }
    catch (error: any) { if (error.code !== "ESRCH") throw error; }
  }
  for (let attempt = 0; attempt < 100; attempt++) {
    const alive = pids.some(pid => {
      try { process.kill(pid, 0); return true; }
      catch (error: any) { if (error.code === "ESRCH") return false; throw error; }
    });
    if (!alive) return;
    await Bun.sleep(100);
  }
  throw new Error("アプリが終了しませんでした。処理が終わってから再試行してください。");
}

function requirement(output: string) {
  return output.split("\n").find(line => line.includes("designated =>")) ?? "";
}

export async function rebuild(options: {
  app?: string;
  root?: string;
  launch?: boolean;
  signal?: AbortSignal;
  execute?: Runner;
  build?: typeof buildApp;
  stop?: typeof stopApp;
  publishing?: (value: boolean) => void;
} = {}) {
  const { app = APP, root = ROOT, launch = true, signal, execute = run, build = buildApp, stop = stopApp } = options;
  mkdirSync(join(root, ".build"), { recursive: true });
  const temporary = mkdtempSync(join(root, ".build/dev-app-"));
  const staged = join(temporary, "Window Arrange.app");
  try {
    await build("debug", staged, true, execute, signal);
    let previous = "";
    if (existsSync(app)) {
      try { previous = requirement(await execute(["/usr/bin/codesign", "-d", "-r-", app], { capture: true, signal })); }
      catch { /* A previous unsigned app can be replaced after validating the new one. */ }
    }
    const current = requirement(await execute(["/usr/bin/codesign", "-d", "-r-", staged], { capture: true, signal }));
    if (!current || current.includes("cdhash")) throw new Error("証明書による安定した署名を確認できませんでした。");
    if (previous !== current) console.log("署名が切り替わります。初回はアクセシビリティの許可を更新してください。");
    signal?.throwIfAborted();
    // Finish publishing before responding to a watch restart signal.
    options.publishing?.(true);
    await stop(app);
    mkdirSync(join(app, ".."), { recursive: true });
    const backup = join(temporary, "previous.app");
    if (existsSync(app)) renameSync(app, backup);
    try { renameSync(staged, app); }
    catch (error) {
      if (existsSync(backup)) renameSync(backup, app);
      throw error;
    }
    if (launch) await execute(["/usr/bin/open", "-n", "-a", app, "--args", "--development"]);
    console.log("更新しました。" + (launch ? "アプリを再起動しました。" : ""));
  } finally {
    options.publishing?.(false);
    rmSync(temporary, { recursive: true, force: true });
  }
}
