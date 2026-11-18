import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { APP, ROOT, run, signingArguments, swiftEnvironment, swiftFlags, type Runner } from "./common";
import { calver, sourceFingerprint, stampPlist } from "./source";

/** Build metadata read by the app: CalVer and what the in-app update check compares against. */
export function buildInfo(configuration: string, date = new Date(), root = ROOT) {
  const version = calver(date);
  return {
    CFBundleShortVersionString: version.short,
    CFBundleVersion: version.build,
    WindowArrangeBuildConfiguration: configuration,
    WindowArrangeSourceRoot: root,
    WindowArrangeSourceFingerprint: sourceFingerprint(root),
    // Prefer the PATH entry (e.g. /opt/homebrew/bin/bun) so a Homebrew upgrade keeps it valid.
    WindowArrangeBunPath: Bun.which("bun") ?? process.execPath,
  };
}

export async function buildApp(configuration = "release", app = APP, requireStable = false,
  execute: Runner = run, signal?: AbortSignal) {
  if (!["debug", "release"].includes(configuration)) throw new Error("Usage: bun run build [release|debug]");
  // Fingerprint the sources before compiling so edits during the build still count as changes.
  const info = buildInfo(configuration);
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
  writeFileSync(join(app, "Contents/Info.plist"), stampPlist(readFileSync(join(ROOT, "Resources/Info.plist"), "utf8"), info));
  await execute(["/usr/bin/codesign", "--force", ...signing, "--identifier", "local.windowarrange.app",
    "--timestamp=none", app], { signal });
  await execute(["/usr/bin/codesign", "--verify", "--strict", app], { signal });
  console.log(`Built: ${app} (${info.CFBundleShortVersionString} build ${info.CFBundleVersion})`);
}

if (import.meta.main) {
  try { await buildApp(process.argv[2]); }
  catch (error) { console.error(String(error)); process.exitCode = 1; }
}
