#!/bin/zsh
# Runs the unit tests with the active Xcode toolchain.
set -euo pipefail
cd "${0:A:h}/.."
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  # Command Line Tools only: swift-testing lives outside the default search paths.
  CLT=/Library/Developer/CommandLineTools/Library/Developer
  exec swift test \
    -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
    -Xlinker -F -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
