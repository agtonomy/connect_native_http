#!/usr/bin/env bash
# Builds the Flutter-free core's package tests (ConnectNativeHttpCoreTests.xctest) for the iOS simulator, into the
# derived data directory given. It needs no booted simulator, so CI builds it while the rest of the setup runs, and
# run_integration_tests.sh, which calls this too, then finds it up to date.
#
#   ios/connect_native_http/build_core_tests.sh build/ios_core_tests
set -euo pipefail

# Its parent may not exist yet: on a fresh CI checkout nothing has created build/. Resolved on a line of its own, so
# set -e stops on a failed cd; within a longer assignment, the last substitution's status hides it.
mkdir -p "$(dirname "${1:?usage: $0 <derived data directory>}")"
parent="$(cd "$(dirname "$1")" && pwd)"
DERIVED_DATA="$parent/$(basename "$1")"
cd "$(dirname "${BASH_SOURCE[0]}")"

# A generic destination, so the build doesn't depend on which simulator, or whether one is booted, runs it. Xcode evaluates package manifests in a sandbox of its own, which can't start inside another sandbox; this manifest
# is ours and, core only, has no dependencies, so it runs without one.
CONNECT_NATIVE_HTTP_CORE_ONLY=1 xcodebuild build-for-testing -quiet \
  -IDEPackageSupportDisableManifestSandbox=YES -scheme connect_native_http-Package \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA"
