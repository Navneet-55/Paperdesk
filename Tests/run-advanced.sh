#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d)
trap 'rm -rf "$TEST_BUILD"' EXIT
xcrun swiftc -parse-as-library Paperdesk/LibraryStore.swift Paperdesk/PDFEditing.swift Paperdesk/PaperdeskStyle.swift Paperdesk/PDFWriteService.swift Tests/EditingTests.swift -o "$TEST_BUILD/EditingTests"
"$TEST_BUILD/EditingTests"
xcrun swiftc -parse-as-library Paperdesk/DocumentTextService.swift Tests/TextServiceTests.swift -o "$TEST_BUILD/TextServiceTests"
"$TEST_BUILD/TextServiceTests"
