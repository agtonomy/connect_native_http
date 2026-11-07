#!/usr/bin/env bash
# Builds the Flutter-free core's package tests (ConnectNativeHttpCoreTests.xctest) for the iOS simulator, into the
# derived data directory given. It needs no booted simulator, so CI builds it while the rest of the setup runs, and
# run_integration_tests.sh, which calls this too, then finds it up to date.
#
#   ios/connect_native_http/build_core_tests.sh build/ios_core_tests
set -euo pipefail

DERIVED_DATA="$(cd "$(dirname "${1:?usage: $0 <derived data directory>}")" && pwd)/$(basename "$1")"
cd "$(dirname "${BASH_SOURCE[0]}")"

# A generic destination, so the build doesn't depend on which simulator, or whether one is booted, runs it. Xcode evaluates package manifests in a sandbox of its own, which can't start inside another sandbox; this manifest
# is ours and, core only, has no dependencies, so it runs without one.
CONNECT_NATIVE_HTTP_CORE_ONLY=1 xcodebuild build-for-testing -quiet \
  -IDEPackageSupportDisableManifestSandbox=YES -scheme connect_native_http-Package \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA"
