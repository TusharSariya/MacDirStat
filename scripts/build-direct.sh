#!/bin/zsh
# Builds an explicitly unsandboxed, signed app with an optional read-only root helper.
# Does not install, register, or launch the helper.
set -eu
cd "${0:A:h:h}"
if [[ $# -ne 1 ]]; then
  print -u2 'Usage: scripts/build-direct.sh "Apple Development: …" (or signing identity hash)'
  exit 2
fi
signing_identity=$1
if [[ "$signing_identity" == '-' ]]; then
  print -u2 'Use an Apple Development or Developer ID identity, not an ad-hoc signature.'
  exit 2
fi
derived="$PWD/.build/direct-derived"
xcodebuild -project MacDirStat.xcodeproj -scheme MacDirStat \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO ENABLE_APP_SANDBOX=NO build \
  > /tmp/MacDirStat-direct-build.log 2>&1 || { tail -40 /tmp/MacDirStat-direct-build.log; exit 1; }
app="$derived/Build/Products/Release/MacDirStat.app"
helper="$app/Contents/Library/LaunchServices/MacDirStatScanner"
mkdir -p "${helper:h}" "$app/Contents/Library/LaunchDaemons"
xcrun swiftc -swift-version 6 -O -target "$(uname -m)-apple-macos14.0" \
  MacDirStat/Core/{ScanSnapshot,FileIdentity,DiskScanner,NativeDiskScanner,ParallelDiskScanner}.swift \
  MacDirStat/Privileged/{ElevatedProtocol,ScanAuthorization,PeerSigning}.swift \
  PrivilegedHelper/*.swift -o "$helper"
cp PrivilegedHelper/tushar.MacDirStat.Scanner.plist "$app/Contents/Library/LaunchDaemons/"
plutil -replace MacDirStatElevatedBuild -bool true "$app/Contents/Info.plist"
codesign --force --sign "$signing_identity" --identifier tushar.MacDirStat.Scanner \
  --options runtime --timestamp=none "$helper"
codesign --force --sign "$signing_identity" --options runtime --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$helper"
codesign --verify --strict --verbose=2 "$app"
print "Built: $app"
print 'No helper has been installed or registered. Use Scan Access in the app to explicitly enable it.'
