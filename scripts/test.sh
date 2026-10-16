#!/bin/sh
# Generates the Xcode project, runs the unit tests and prints a one-line summary.
# Extra arguments are passed to xcodebuild, e.g. -only-testing:MetricsKitTests/CPUCalculatorTests
set -u
cd "$(dirname "$0")/.."
# xcodebuild forwards only TEST_RUNNER_-prefixed variables to the test process (prefix
# stripped), so a plain CI=1 never reaches the `.enabled(if: CI == nil)` check in
# LiveSamplerTests. Exported only when set: an empty CI would still count as "on CI".
if [ -n "${CI:-}" ]; then export TEST_RUNNER_CI="$CI"; fi
xcodegen generate --quiet || exit 1
RESULT="build/TestResults-$$.xcresult"
rm -rf "$RESULT"
xcodebuild test -project SystemMetrics.xcodeproj -scheme SystemMetrics \
  -destination 'platform=macOS,arch=arm64' -resultBundlePath "$RESULT" -quiet "$@" 2>&1 \
  | grep -vE 'DVTAssertions|IDELaunchSession|IDETestOperationsObserverDebug|^Details:|^Object:|^Method:|^Thread:|feedbackassistant|^Testing started$'
if [ -d "$RESULT" ]; then
  xcrun xcresulttool get test-results summary --path "$RESULT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("TESTS: {result} total={totalTestCount} passed={passedTests} failed={failedTests} skipped={skippedTests}".format(**d))
for f in d.get("testFailures", []):
    print("FAIL:", f.get("testIdentifierString"), "-", f.get("failureText"))
sys.exit(0 if d["result"] == "Passed" else 1)'
  STATUS=$?
  rm -rf "$RESULT"
else
  echo "TESTS: build failed, no result bundle"
fi
exit $STATUS
