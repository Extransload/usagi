#!/bin/zsh
# Compiles Sources/Logic.swift and Sources/Glyphs.swift with the plain-assertion test main and runs it; exits non-zero on failure.
set -euo pipefail
tests=${0:A:h}
root=${tests:h:h}
out=$(mktemp -d "${TMPDIR:-/tmp}/usagi-swift-tests.XXXXXX")
trap 'rm -rf "$out"' EXIT
/usr/bin/swiftc -swift-version 5 -module-name UsagiTests "$root/Sources/Logic.swift" "$root/Sources/Glyphs.swift" "$tests/main.swift" -o "$out/tests"
"$out/tests"
