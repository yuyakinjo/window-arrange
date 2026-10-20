import { existsSync } from "node:fs";
import { basename, join, resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "..");
export const APP = join(ROOT, "dist/Window Arrange.app");
export const SIGNING = join(ROOT, ".local/signing");

export type Runner = (command: string[], options?: {
  capture?: boolean;
  quiet?: boolean;
  env?: Record<string, string>;
  signal?: AbortSignal;
}) => Promise<string>;

export const run: Runner = async (command, options = {}) => {
  const child = Bun.spawn(command, {
    cwd: ROOT,
    env: { ...process.env, ...options.env },
    stdout: options.capture ? "pipe" : options.quiet ? "ignore" : "inherit",
    stderr: options.quiet ? "ignore" : "inherit",
    signal: options.signal,
  });
  const output = options.capture ? new Response(child.stdout).text() : Promise.resolve("");
  const [code, text] = await Promise.all([child.exited, output]);
  // Do not expose arguments: security commands include the dedicated keychain password.
  if (code !== 0) throw new Error(`${basename(command[0])} failed (exit ${code}).`);
  return text;
};

export function swiftEnvironment() {
  return {
    CLANG_MODULE_CACHE_PATH: join(ROOT, ".build/clang-cache"),
    SWIFTPM_MODULECACHE_OVERRIDE: join(ROOT, ".build/module-cache"),
  };
}

export function swiftFlags() {
  const flags = ["--cache-path", join(ROOT, ".build/cache"),
    "--config-path", join(ROOT, ".build/config"), "--security-path", join(ROOT, ".build/security")];
  if (process.env.WINDOW_ARRANGE_NESTED_SANDBOX === "1") flags.push("--disable-sandbox");
  return flags;
}

export async function signingArguments(requireStable = false, execute: Runner = run) {
  let identity = process.env.WINDOW_ARRANGE_SIGNING_IDENTITY;
  const flags: string[] = [];
  if (!identity && existsSync(join(SIGNING, "identity"))) {
    identity = (await Bun.file(join(SIGNING, "identity")).text()).trim();
    if (!/^[a-f\d]{40}$/i.test(identity)) throw new Error("Invalid local signing identity.");
    const keychain = join(SIGNING, "development.keychain-db");
    const password = await Bun.file(join(SIGNING, "password")).text();
    await execute(["/usr/bin/security", "unlock-keychain", "-p", password, keychain]);
    flags.push("--keychain", keychain);
  } else if (process.env.WINDOW_ARRANGE_SIGNING_KEYCHAIN) {
    flags.push("--keychain", process.env.WINDOW_ARRANGE_SIGNING_KEYCHAIN);
  }
  identity ||= "-";
  if (requireStable && identity === "-") {
    throw new Error("開発モードには証明書が必要です。bun run dev:setup を実行してください。");
  }
  return ["--sign", identity, ...flags];
}
