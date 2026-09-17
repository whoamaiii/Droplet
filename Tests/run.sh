#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/droplet-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
clang -std=c11 -Wall -Wextra -Werror -c "$ROOT/ProcessSupport.c" -o "$WORK/process.o"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
    -import-objc-header "$ROOT/ProcessSupport.h" \
    "$ROOT/ProcessRuntime.swift" "$ROOT/DownloadCore.swift" \
    "$ROOT/Tests/CoreTests.swift" "$WORK/process.o" -o "$WORK/core-tests"
"$WORK/core-tests"
bash -n "$ROOT/build.sh"
if [[ "$(uname -s)" == Darwin ]]; then
    swiftc -swift-version 5 -warnings-as-errors -parse-as-library -D DROPLET_TESTING \
        -target "$(uname -m)-apple-macos14.0" \
        -import-objc-header "$ROOT/ProcessSupport.h" \
        "$ROOT/main.swift" "$ROOT/ProcessRuntime.swift" "$ROOT/DownloadCore.swift" \
        "$ROOT/Tests/ManagerTests.swift" "$WORK/process.o" -o "$WORK/manager-tests"
    "$WORK/manager-tests"
else
    echo 'SKIP: AppKit manager integration tests require macOS.'
fi
