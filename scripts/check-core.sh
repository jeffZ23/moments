#!/usr/bin/env bash
# Compiles MomentCore and runs its scenario checks with plain swiftc.
# Works with only the Command Line Tools installed (no Xcode, no SwiftPM test support).
# With Xcode, `swift test` in ios/MomentCore runs the same checks through XCTest.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ios/MomentCore/Sources"
OUT="${TMPDIR:-/tmp}/momentcore-check"
rm -rf "$OUT" && mkdir -p "$OUT"

swiftc -parse-as-library -emit-library -static -emit-module -module-name MomentCore \
  -emit-module-path "$OUT/MomentCore.swiftmodule" -o "$OUT/libMomentCore.a" "$SRC"/MomentCore/*.swift
swiftc -parse-as-library -emit-library -static -emit-module -module-name MomentCoreScenarios -I "$OUT" \
  -emit-module-path "$OUT/MomentCoreScenarios.swiftmodule" -o "$OUT/libMomentCoreScenarios.a" "$SRC"/MomentCoreScenarios/*.swift
swiftc -I "$OUT" -L "$OUT" -lMomentCore -lMomentCoreScenarios -o "$OUT/momentcore-check" "$SRC"/momentcore-check/main.swift
"$OUT/momentcore-check"
