#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="cmux.xcodeproj"
SCHEME="cmux-unit"
CONFIGURATION="${CMUX_TEST_CONFIGURATION:-Debug}"
DESTINATION="${CMUX_TEST_DESTINATION:-platform=macOS}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  ENABLE_APP_INTENTS_METADATA_EXTRACTION=NO \
  SWIFT_EMIT_APP_INTENTS_METADATA=NO \
  "$@"
