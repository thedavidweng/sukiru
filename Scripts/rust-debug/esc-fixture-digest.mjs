#!/usr/bin/env node
// Independent golden-digest computation for the `esc` fixture in
// HashingVectorTests.symlinkTargetEscapingMatchesRustDebug.
//
// Usage: esc-fixture-digest.mjs <symlink-output-hex>
//   <symlink-output-hex> is the `quote-backslash-squote` row's output bytes
//   (hex) from `main.rs battery` — produced BY rustc, never hand-computed.
//
// The composition (ICU `localeCompare` ordering with a bytewise tiebreak,
// SHA-256 over utf8(relativePath) + bytes, no separators) is pinned
// independently by the real-CLI sortcase vector in the same suite; this
// script only re-composes those verified primitives around the rustc-quoted
// symlink bytes.

import { createHash } from "node:crypto";

const symlinkHex = process.argv[2];
if (!symlinkHex || !/^[0-9a-f]+$/.test(symlinkHex)) {
    console.error("usage: esc-fixture-digest.mjs <symlink-output-hex>");
    process.exit(2);
}

const entries = [
    ["SKILL.md", Buffer.from("---\nname: esc\ndescription: Escape quoting.\n---\n", "utf8")],
    ["esc.txt", Buffer.from(symlinkHex, "hex")],
    // Backslash inside the file NAME normalizes to "/" in the hash key
    // (upstream's split("\\").join("/") quirk).
    ["we\"ird/it's.md", Buffer.from("x\n", "utf8")],
];

entries.sort((a, b) =>
    a[0].localeCompare(b[0]) || Buffer.compare(Buffer.from(a[0], "utf8"), Buffer.from(b[0], "utf8"))
);

const hasher = createHash("sha256");
for (const [relativePath, bytes] of entries) {
    hasher.update(Buffer.from(relativePath, "utf8"));
    hasher.update(bytes);
}
console.error("order: " + entries.map((e) => e[0]).join(" | "));
console.log(hasher.digest("hex"));
