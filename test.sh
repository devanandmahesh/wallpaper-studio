#!/bin/bash
# Runs all tests. The explicit plugin path is needed because the Command Line Tools' swift-build
# does not pass the Swift Testing macro plugin to the compiler by itself.
set -euo pipefail
cd "$(dirname "$0")"
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
