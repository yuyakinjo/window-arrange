import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { run, SIGNING } from "./common";

async function proveIdentity() {
  const fingerprint = await run(["/usr/bin/openssl", "x509", "-in", join(SIGNING, "certificate.pem"),
    "-noout", "-fingerprint", "-sha1"], { capture: true });
  const identity = fingerprint.trim().split("=").at(-1)!.replaceAll(":", "");
  if (!/^[a-f\d]{40}$/i.test(identity)) throw new Error("証明書の識別子を取得できませんでした。");
  const temporary = mkdtempSync(join(SIGNING, "probe-"));
  try {
    const probe = join(temporary, "signing-probe");
    copyFileSync("/usr/bin/true", probe);
    chmodSync(probe, 0o755);
    await run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain",
      join(SIGNING, "development.keychain-db"), "--timestamp=none", probe]);
    await run(["/usr/bin/codesign", "--verify", "--strict", probe]);
    writeFileSync(join(SIGNING, "identity"), `${identity}\n`);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}

export async function setupSigning() {
  const external = process.env.WINDOW_ARRANGE_SIGNING_IDENTITY;
  if (external) {
    if (external === "-") throw new Error("開発モードではad-hoc署名を使用できません。");
    console.log("指定された署名用証明書を使用します。");
    return;
  }
  if (existsSync(join(SIGNING, "identity"))) {
    console.log("既存の開発用証明書を再利用します。");
    return;
  }
  const keychain = join(SIGNING, "development.keychain-db");
  if (["certificate.pem", "password", "development.keychain-db"].every(name => existsSync(join(SIGNING, name)))) {
    const password = await Bun.file(join(SIGNING, "password")).text();
    await run(["/usr/bin/security", "unlock-keychain", "-p", password, keychain]);
    await run(["/usr/bin/security", "set-key-partition-list", "-S", "apple:", "-s", "-k", password, keychain], { quiet: true });
    await proveIdentity();
    return;
  }
  if (existsSync(SIGNING)) {
    throw new Error("署名の初期設定が途中で停止しています。.local/signing を確認してください。既存の証明書は自動で作り直しません。");
  }
  mkdirSync(SIGNING, { recursive: true, mode: 0o700 });
  chmodSync(SIGNING, 0o700);
  const password = randomBytes(32).toString("hex");
  writeFileSync(join(SIGNING, "password"), password, { mode: 0o600 });
  const temporary = mkdtempSync(join(SIGNING, "identity-"));
  try {
    const config = join(temporary, "openssl.cnf");
    writeFileSync(config, `[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Window Arrange Local Development
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
`);
    const key = join(temporary, "key.pem");
    const certificate = join(SIGNING, "certificate.pem");
    const archive = join(temporary, "identity.p12");
    console.log("このプロジェクト専用の開発用証明書を作成します。");
    await run(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
      "-days", "3650", "-config", config, "-keyout", key, "-out", certificate], { quiet: true });
    await run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", key, "-in", certificate, "-name",
      "Window Arrange Local Development", "-out", archive, "-passout", "env:WINDOW_ARRANGE_P12_PASSWORD"],
    { env: { WINDOW_ARRANGE_P12_PASSWORD: password } });
    await run(["/usr/bin/security", "create-keychain", "-p", password, keychain]);
    await run(["/usr/bin/security", "unlock-keychain", "-p", password, keychain]);
    await run(["/usr/bin/security", "import", archive, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign"], { quiet: true });
    await run(["/usr/bin/security", "set-key-partition-list", "-S", "apple:", "-s", "-k", password, keychain], { quiet: true });
  } finally { rmSync(temporary, { recursive: true, force: true }); }
  await proveIdentity();
  console.log("署名の初期設定が完了しました。通常ビルドでも同じ証明書を使用します。");
}
