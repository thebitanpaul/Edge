#!/bin/bash
#
# Runs the unit tests.
#
# The -plugin-path is not optional. swift-testing's macro plugin ships at
#   <toolchain>/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
# but the default plugin search path is the `plugins` directory itself and does not descend
# into `testing/`. Without this flag `swift test` fails with
#   "plugin for module 'TestingMacros' not found"
# on a clean tree — and, confusingly, sometimes succeeds on a dirty one because the expanded
# macros are still cached from an earlier run.

set -euo pipefail
cd "$(dirname "$0")/.."

PLUGIN_DIR="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing"

if [ -d "$PLUGIN_DIR" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
else
  echo "note: swift-testing macro plugin not found at $PLUGIN_DIR; trying without it" >&2
  exec swift test "$@"
fi
