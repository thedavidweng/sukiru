#!/usr/bin/env bash
# Regenerate the Rust-Debug escaping table and print the ground-truth battery
# for ContentHasher.rustDebugQuotedSymlink.
#
#   Scripts/rust-debug/generate.sh
#
# 1. Compiles main.rs with the system rustc (no crates) and sweeps every
#    Unicode scalar through `format!("{:?}", PathBuf::from(...))`, writing the
#    `\u{...}` escape ranges to Sources/SukiruCore/Hashing/RustDebugEscapes.swift.
#    The generated header records the `rustc --version` string so a newer
#    toolchain cannot silently shift the table (Unicode-version drift).
# 2. Prints the adversarial-target battery as TSV (name, target hex, expected
#    `symlink:...` output hex, Rust literal) — paste the hex columns into
#    HashingVectorTests.rustDebugQuotingMatchesRustcBattery.
# 3. Prints the regenerated golden digest for the `esc` fixture
#    (esc-fixture-digest.mjs, Node ICU ordering + SHA-256 around the
#    rustc-quoted symlink bytes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
BIN="$OUT_DIR/rust-debug"

RUSTC_VERSION="$(rustc --version)"
rustc -O "$ROOT/Scripts/rust-debug/main.rs" -o "$BIN"
"$BIN" table "$RUSTC_VERSION" > "$ROOT/Sources/SukiruCore/Hashing/RustDebugEscapes.swift"
echo "wrote Sources/SukiruCore/Hashing/RustDebugEscapes.swift (toolchain: $RUSTC_VERSION)" >&2

echo "--- battery (name, target hex, expected output hex, rust literal) ---" >&2
"$BIN" battery

SYMLINK_HEX="$("$BIN" battery | awk -F '\t' '$1 == "quote-backslash-squote" { print $3 }')"
echo "--- esc fixture golden digest ---" >&2
node "$ROOT/Scripts/rust-debug/esc-fixture-digest.mjs" "$SYMLINK_HEX"
