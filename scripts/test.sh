#!/usr/bin/env bash
#
# Regenerate the Xcode project and run the full test suite.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
xcodegen generate
xcodebuild -project Runbar.xcodeproj -scheme Runbar \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  test
