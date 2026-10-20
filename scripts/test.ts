import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { run, swiftEnvironment, swiftFlags } from "./common";

try {
  await run([process.execPath, "test", "scripts/tests"]);
  const compiler = (await run(["xcrun", "--find", "swiftc"], { capture: true })).trim();
  const macros = join(dirname(dirname(compiler)), "lib/swift/host/plugins/testing/libTestingMacros.dylib");
  const flags = swiftFlags();
  if (existsSync(macros)) flags.push("-Xswiftc", "-load-plugin-library", "-Xswiftc", macros);
  await run(["swift", "test", "--disable-xctest", ...flags], { env: swiftEnvironment() });
} catch (error) {
  console.error(String(error));
  process.exitCode = 1;
}
