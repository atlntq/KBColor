#!/bin/bash
# Builds KBColor.kext, KBColor.app and "KBColor Kurulum.app" (which carries the
# other two plus iasl and acpiexec from ACPICA).
#   MACKERNELSDK=~/MacKernelSDK ./build.sh
set -euo pipefail
R="$(cd "$(dirname "$0")" && pwd)"
SDK="${MACKERNELSDK:?set MACKERNELSDK to a MacKernelSDK checkout}"
B="$R/build"; rm -rf "${B:?}"; mkdir -p "$B"

# kext
K="$B/KBColor.kext"; mkdir -p "$K/Contents/MacOS"
CF=(-arch x86_64 -mkernel -nostdinc -mmacosx-version-min=10.15
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -I"$SDK/Headers" -Os -Wall -Wno-macro-redefined)
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$R/kext/Info.plist")"
xcrun clang++ "${CF[@]}" -DKBCOLOR_VERSION="\"$VER\"" -fapple-kext -std=gnu++17 -fno-rtti -fno-exceptions -c "$R/kext/KBColor.cpp" -o "$B/KBColor.o"
xcrun clang "${CF[@]}" -c "$R/kext/kmod_info.c" -o "$B/kmod_info.o"
xcrun clang++ -arch x86_64 -mmacosx-version-min=10.15 -nostdlib -Xlinker -kext -Xlinker -export_dynamic \
    "$B/KBColor.o" "$B/kmod_info.o" "$SDK/Library/x86_64/libkmod.a" -o "$K/Contents/MacOS/KBColor"
cp "$R/kext/Info.plist" "$K/Contents/Info.plist"
rm "$B"/*.o

# menu bar app
A="$B/KBColor.app"; mkdir -p "$A/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 "$R/app/main.swift" "$R/shared/Diagnostics.swift" -o "$A/Contents/MacOS/KBColor"
cp "$R/app/Info.plist" "$A/Contents/Info.plist"
codesign --force --sign - "$A"

# setup assistant
S="$B/KBColor Kurulum.app"; mkdir -p "$S/Contents/MacOS" "$S/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 "$R"/setup/Sources/*.swift "$R/shared/Diagnostics.swift" -o "$S/Contents/MacOS/KBColorKurulum"
cp "$R/setup/Info.plist" "$S/Contents/Info.plist"
cp -R "$K" "$A" "$S/Contents/Resources/"
for t in iasl acpiexec; do cp "${ACPICA_BIN:-/usr/local/bin}/$t" "$S/Contents/Resources/$t"; done
cp "$R/tools/ACPICA-LICENSE.txt" "$S/Contents/Resources/"
codesign --force --deep --sign - "$S"
echo "built: $B"
