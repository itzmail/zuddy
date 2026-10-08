#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zuddy-pill-colors.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    Zuddy/Sources/ZuddyKit/PillColors.swift \
    tests/PillColorsTests.swift -o "$TEST_DIR/pill-colors-tests"
"$TEST_DIR/pill-colors-tests"
