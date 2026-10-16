#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"

if ! xcodebuild -version >/dev/null 2>&1; then
  print -u2 "完全版のXcodeが必要です。App StoreからXcodeをインストールし、xcode-selectで選択してください。"
  exit 1
fi

xcodebuild \
  -project "$project_dir/GitOperation.xcodeproj" \
  -scheme GitOperation \
  -configuration Release \
  -derivedDataPath "$project_dir/build" \
  CODE_SIGNING_ALLOWED=NO \
  build

print "ビルド完了: $project_dir/build/Build/Products/Release/GitOperation.app"
