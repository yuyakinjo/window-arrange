import { join } from "node:path";
import { ROOT } from "./common";
import { acquireLock, createRebuilder, rebuild, watchInputs } from "./dev-support";
import { setupSigning } from "./signing";

const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log("bun run dev [--setup | --once [--no-open]]\n保存時の自動ビルド・署名・再起動。終了: Ctrl+C");
  process.exit(0);
}
if (args.some(arg => !["--setup", "--once", "--no-open"].includes(arg)) ||
    (args.includes("--no-open") && !args.includes("--once")) ||
    (args.includes("--setup") && args.includes("--once"))) {
  console.error("Usage: bun run dev [--setup | --once [--no-open]]");
  process.exit(64);
}

let release: (() => void) | undefined;
let child: ReturnType<typeof Bun.spawn> | undefined;
let closeInputs: (() => void) | undefined;
const queue = createRebuilder((signal, publishing) => rebuild({ signal, publishing }), error => {
  console.error(`更新できませんでした: ${error}\n次の保存時に再試行します。`);
});
let stopping = false;
async function shutdown() {
  if (stopping) return;
  stopping = true;
  closeInputs?.();
  if (child) { child.kill("SIGTERM"); await child.exited; }
  await queue.stop();
  release?.();
  console.log("\n開発モードを終了しました。起動中のアプリは引き続き利用できます。");
  process.exit(0);
}

try {
  release = acquireLock();
  // Set up before --watch starts so a save cannot interrupt identity creation.
  await setupSigning();
  if (args.includes("--setup")) {
    release();
  } else if (args.includes("--once")) {
    await rebuild({ launch: !args.includes("--no-open") });
    release();
  } else {
    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
    // Bun handles file edits; refresh its import list only when files are added/deleted/renamed.
    closeInputs = watchInputs();
    child = Bun.spawn([process.execPath, "--watch", "--no-clear-screen", join(ROOT, "scripts/dev-worker.ts")],
      { cwd: ROOT, stdin: "inherit", stdout: "pipe", stderr: "inherit" });
    console.log("変更を監視中です。保存すると自動で更新します。終了: Ctrl+C");
    let pending = "";
    const decoder = new TextDecoder();
    for await (const chunk of child.stdout as ReadableStream<Uint8Array>) {
      pending += decoder.decode(chunk, { stream: true });
      const lines = pending.split("\n");
      pending = lines.pop()!;
      for (const line of lines) if (line.trim() === "inputs-changed") queue.request();
    }
    process.exitCode = await child.exited;
    await queue.stop();
    closeInputs();
    release();
  }
} catch (error) {
  closeInputs?.();
  await queue.stop();
  release?.();
  console.error(`開発モードでエラーが発生しました: ${error}`);
  process.exitCode = 1;
}
