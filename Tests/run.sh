#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d)
trap 'rm -rf "$TEST_BUILD"' EXIT
xcrun swiftc -parse-as-library Paperdesk/LibraryStore.swift Tests/SmokeTests.swift -o "$TEST_BUILD/SmokeTests"
"$TEST_BUILD/SmokeTests"
