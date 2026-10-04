#!/bin/zsh
# Build or test through xcodebuild the same way everywhere (agents, CI, humans).
#   Scripts/xc.sh build                 # app + c4bench, Debug
#   Scripts/xc.sh test                  # all test targets
#   Scripts/xc.sh test -only-testing:C4CoreTests
#   CONFIG=Release Scripts/xc.sh build
# Extra arguments are passed to xcodebuild. Output is filtered to errors, warnings in our
# code, test results and the final status; the full log is in build/last-xcodebuild.log.
set -euo pipefail
cd "${0:A:h}/.."
action="${1:-build}"; shift || true
xcodegen generate --quiet
mkdir -p build
set +e
xcodebuild -project LLMConnectFour.xcodeproj -scheme "${SCHEME:-LLMConnectFour}" \
  -configuration "${CONFIG:-Debug}" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA:-build/DerivedData}" \
  -skipMacroValidation -skipPackagePluginValidation \
  "$action" "$@" > build/last-xcodebuild.log 2>&1
code=$?
set -e
grep -E "error:|warning: .*/(App|Packages/C4|Tools|Tests)/|✘|Test run with|Executed [0-9]+ test|\*\* (BUILD|TEST) " build/last-xcodebuild.log \
  | grep -v -e "/checkouts/" -e "\[Connection\]" | sort -u | head -80
exit $code
