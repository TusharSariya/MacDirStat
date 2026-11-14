#!/bin/zsh
set -eu
cd "${0:A:h:h}"
test_dir=$(mktemp -d /tmp/MacDirStat-integration.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  MacDirStat/Core/*.swift MacDirStat/Privileged/*.swift MacDirStat/ScanViewModel.swift \
  PrivilegedHelper/ScanSession.swift Tests/Integration/ScanViewModelChecks.swift \
  -o "$test_dir/checks"
if [[ $# -eq 1 ]]; then
  codesign --force --sign "$1" --identifier tushar.MacDirStat.ProtocolChecks --timestamp=none "$test_dir/checks"
  MACDIRSTAT_REQUIRE_SIGNED_TESTS=1 "$test_dir/checks"
else
  "$test_dir/checks"
fi
