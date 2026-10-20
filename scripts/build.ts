import { copyFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { APP, ROOT, run, signingArguments, swiftEnvironment, swiftFlags, type Runner } from "./common";

export async function buildApp(configuration = "release", app = APP, requireStable = false,
  execute: Runner = run, signal?: AbortSignal) {
  if (!["debug", "release"].includes(configuration)) throw new Error("Usage: bun run build [release|debug]");
  const flags = swiftFlags();
  if (configuration === "release") flags.push("-debug-info-format", "none");
  const env = swiftEnvironment();
  const signing = await signingArguments(requireStable, (args, options) => execute(args, { ...options, signal }));
  await execute(["swift", "build", "-c", configuration, ...flags], { env, signal });
  const bin = (await execute(["swift", "build", "-c", configuration, ...flags, "--show-bin-path"],
    { capture: true, env, signal })).trim();
  mkdirSync(join(app, "Contents/MacOS"), { recursive: true });
  mkdirSync(join(app, "Contents/Resources"), { recursive: true });
  copyFileSync(join(bin, "WindowArrange"), join(app, "Contents/MacOS/WindowArrange"));
  copyFileSync(join(ROOT, "Resources/Info.plist"), join(app, "Contents/Info.plist"));
  await execute(["/usr/bin/codesign", "--force", ...signing, "--identifier", "local.windowarrange.app",
    "--timestamp=none", app], { signal });
  await execute(["/usr/bin/codesign", "--verify", "--strict", app], { signal });
  console.log(`Built: ${app}`);
}

if (import.meta.main) {
  try { await buildApp(process.argv[2]); }
  catch (error) { console.error(String(error)); process.exitCode = 1; }
}
