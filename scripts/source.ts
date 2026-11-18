import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { ROOT } from "./common";

/** Files that affect the built app. Shared by watch mode, version stamping and the in-app update check. */
export function inputFiles(root = ROOT): string[] {
  const files = ["Package.swift", "package.json"].filter(name => existsSync(join(root, name)));
  for (const directory of ["Sources", "Resources", "scripts"]) {
    if (!existsSync(join(root, directory))) continue;
    for (const entry of readdirSync(join(root, directory), { recursive: true, withFileTypes: true })) {
      if (entry.isFile() && (directory === "Resources" || /\.(swift|ts|c|h)$/.test(entry.name))) {
        files.push(relative(root, join(entry.parentPath, entry.name)));
      }
    }
  }
  return files.sort();
}

/** Content hash of the inputs: unchanged after a no-op checkout, changed by any edit, addition or deletion. */
export function sourceFingerprint(root = ROOT) {
  const hash = createHash("sha256");
  for (const file of inputFiles(root)) {
    hash.update(file).update("\0");
    hash.update(readFileSync(join(root, file))).update("\0");
  }
  return hash.digest("hex");
}

/** CalVer from the build time (local time): YYYY.M.D for display, YYYYMMDDHHmm as a monotonic build number. */
export function calver(date = new Date()) {
  const pad = (value: number) => String(value).padStart(2, "0");
  const [year, month, day] = [date.getFullYear(), date.getMonth() + 1, date.getDate()];
  return {
    short: `${year}.${month}.${day}`,
    build: `${year}${pad(month)}${pad(day)}${pad(date.getHours())}${pad(date.getMinutes())}`,
  };
}

function escapeXML(value: string) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

/** Replace or add string values in a flat XML property list. */
export function stampPlist(contents: string, values: Record<string, string>) {
  let result = contents;
  for (const [key, value] of Object.entries(values)) {
    const entry = `<key>${key}</key><string>${escapeXML(value)}</string>`;
    const pattern = new RegExp(`<key>${key}</key>\\s*<string>[^<]*</string>`);
    if (pattern.test(result)) result = result.replace(pattern, () => entry);
    else {
      const end = result.lastIndexOf("</dict>");
      if (end < 0) throw new Error("Info.plist に <dict> が見つかりません。");
      result = `${result.slice(0, end)}    ${entry}\n${result.slice(end)}`;
    }
  }
  return result;
}
