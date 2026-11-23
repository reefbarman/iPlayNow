#!/bin/sh
# Extracts the static OpenSSL and usrsctp XCFrameworks that OpenNOW iOS ships
# prebuilt (Vendor/OpenNOW-iOS-128-native-libraries.zip) into Frameworks/.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
archive="$root/Vendor/OpenNOW-iOS-128-native-libraries.zip"
# Same pin as OpenNOW's BuildScripts/prepare-native-libraries.py
expected=700e218ace883213de500707095ff322d8ec179235b231ceb61d0007a353ea56
actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
if [ "$expected" != "$actual" ]; then
  echo "error: $archive checksum mismatch" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
unzip -q "$archive" 'ios/OpenNOWiOS/Frameworks/*' -d "$stage"
mkdir -p "$root/Frameworks"
for fw in OpenSSL usrsctp; do
  rm -rf "$root/Frameworks/$fw.xcframework"
  mv "$stage/ios/OpenNOWiOS/Frameworks/$fw.xcframework" "$root/Frameworks/"
done
echo "Frameworks ready in $root/Frameworks"
