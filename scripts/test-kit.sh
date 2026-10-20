#!/bin/zsh
# Build and run one package test target in isolation: scripts/test-kit.sh ClaudeKit [scratch-dir]
set -uo pipefail
kit=$1
scratch=${2:-/tmp/openaccs-build-$kit}
cd "${0:A:h}/../Packages/OpenAccsKit"
log=$(swift build --scratch-path "$scratch" --target "${kit}Tests" 2>&1)
if (( $? != 0 )); then
  print -r -- "$log" | grep -E "error|warning: " | sort -u
  echo "build failed"
  exit 1
fi
print -r -- "$log" | grep -E "warning: " | sort -u
bundle="$scratch/out/Products/Debug/${kit}Tests.xctest/Contents/MacOS/${kit}Tests"
helper=$(xcrun --find swift | xargs dirname)/../libexec/swift/pm/swiftpm-testing-helper
platform=$(xcode-select -p)/Platforms/MacOSX.platform/Developer
DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib" "$helper" --test-bundle-path "$bundle" "$bundle" --testing-library swift-testing 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -vE "^◇|started\.$"
