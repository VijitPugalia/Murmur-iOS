#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/configure.py
xcodegen generate --spec project.json
mkdir -p build dist
swiftc -parse-as-library Shared/*.swift App/GroqTranscriber.swift Tests/CoreTests.swift -o build/core-tests
build/core-tests
for scheme in Murmur; do
  xcodebuild -project Murmur.xcodeproj -scheme "$scheme" -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "build/$scheme" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
  package="build/package-$scheme"
  mkdir -p "$package/Payload"
  cp -R "build/$scheme/Build/Products/Release-iphoneos/$scheme.app" "$package/Payload/"
    codesign --force --sign - --entitlements Config/Shared.entitlements "$package/Payload/$scheme.app/PlugIns/MurmurKeyboard.appex"
    codesign --force --sign - --entitlements Config/Shared.entitlements "$package/Payload/$scheme.app"
    name="Murmur-0.2.0.ipa"
  # Ad-hoc signatures are for packaging. SideStore must re-sign for device installation.
  codesign --verify --deep --strict "$package/Payload/$scheme.app"
  (cd "$package" && /usr/bin/zip -qry "../../dist/$name" Payload)
done
python3 scripts/validate.py --ipas dist
