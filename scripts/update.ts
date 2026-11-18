import { APP } from "./common";
import { acquireLock, rebuild } from "./dev-support";
import { setupSigning } from "./signing";
import { sourceFingerprint } from "./source";

// Called by the app's update button. `--check` prints the current source fingerprint;
// otherwise build, replace the running app bundle and relaunch it.
const usage = "Usage: bun scripts/update.ts --check | [--app <path>] [--configuration release|debug]";
const args = process.argv.slice(2);

function option(name: string) {
  const index = args.indexOf(name);
  if (index < 0) return undefined;
  const value = args[index + 1];
  if (!value || value.startsWith("--")) { console.error(usage); process.exit(64); }
  return value;
}

if (args.includes("--check")) {
  console.log(sourceFingerprint());
} else {
  const app = option("--app") ?? APP;
  const configuration = option("--configuration") ?? "release";
  if (configuration !== "release" && configuration !== "debug") { console.error(usage); process.exit(64); }
  let release: (() => void) | undefined;
  try {
    console.log(`[${new Date().toLocaleString()}] 更新を開始します: ${app} (${configuration})`);
    release = acquireLock();
    await setupSigning();
    await rebuild({ app, configuration, launchArguments: [] });
  } catch (error) {
    console.error(`更新できませんでした: ${error}`);
    process.exitCode = 1;
  } finally {
    release?.();
  }
}
