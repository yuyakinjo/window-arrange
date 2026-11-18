import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { calver, sourceFingerprint, stampPlist } from "../source";

describe("CalVer", () => {
  test("uses the local build date and a sortable build number", () => {
    expect(calver(new Date(2026, 10, 8, 9, 5))).toEqual({ short: "2026.11.8", build: "202611080905" });
    expect(Number(calver(new Date(2026, 11, 31, 23, 59)).build))
      .toBeLessThan(Number(calver(new Date(2027, 0, 1, 0, 0)).build));
  });
});

test("Info.plist values are replaced or appended and escaped", () => {
  const plist = `<plist version="1.0"><dict>
    <key>CFBundleVersion</key><string>0</string>
</dict></plist>`;
  const stamped = stampPlist(plist, { CFBundleVersion: "202611180930", WindowArrangeSourceRoot: "/a&b" });
  expect(stamped).toContain("<key>CFBundleVersion</key><string>202611180930</string>");
  expect(stamped).not.toContain("<string>0</string>");
  expect(stamped).toContain("<key>WindowArrangeSourceRoot</key><string>/a&amp;b</string>\n</dict>");
});

test("source fingerprint follows edits, additions and deletions but ignores build output", () => {
  const root = mkdtempSync(join(tmpdir(), "window-arrange-fingerprint-"));
  try {
    mkdirSync(join(root, "Sources"));
    mkdirSync(join(root, ".build"));
    writeFileSync(join(root, "Sources/View.swift"), "struct View {}");
    const initial = sourceFingerprint(root);
    writeFileSync(join(root, ".build/Generated.swift"), "ignored");
    expect(sourceFingerprint(root)).toBe(initial);
    writeFileSync(join(root, "Sources/View.swift"), "struct Changed {}");
    const edited = sourceFingerprint(root);
    expect(edited).not.toBe(initial);
    writeFileSync(join(root, "Sources/View.swift"), "struct View {}");
    expect(sourceFingerprint(root)).toBe(initial);
    writeFileSync(join(root, "Sources/shim.c"), "int x;");
    expect(sourceFingerprint(root)).not.toBe(initial);
    rmSync(join(root, "Sources/shim.c"));
    expect(sourceFingerprint(root)).toBe(initial);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
