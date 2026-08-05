#!/bin/bash
set -euo pipefail

# Bare `swift test` silently runs ZERO tests on this machine: there is no Xcode, and the `xctest`
# runner tool ships only with Xcode. SwiftPM builds the .xctest bundle, finds no runner, and exits 0
# with no output. Pointing swiftc at the Command Line Tools framework directory makes SwiftPM use the
# swift-testing entry point instead. Verified 2026-08-05: without -F, 0 tests run and exit is 0.
exec swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks "$@"
