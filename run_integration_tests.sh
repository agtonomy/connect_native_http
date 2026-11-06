#!/usr/bin/env bash
# Runs example/integration_test, then the native bridge tests (ios/connect_native_http/Tests, android/src/
# androidTest), on a booted iOS simulator or Android emulator against a fresh test_server.
#
#   ./run_integration_tests.sh ios <simulator udid>
#   ./run_integration_tests.sh android <adb serial, e.g. emulator-5554>
#   ./run_integration_tests.sh ios <udid> --plain-name 'bidi'   # extra arguments go to `flutter test`
#   SUITES=native ./run_integration_tests.sh ios <udid>         # only the native tests; SUITES=dart for only Dart
#   FLUTTER=flutter ./run_integration_tests.sh ios <udid>       # use the flutter on PATH instead of `fvm flutter`#
# iOS: the server's CA goes into the simulator's keychain, and calls should go over HTTP/3.
# Android: the CA is bundled into the example app. Cronet only uses QUIC with public roots, so this checks HTTP/2;
# HTTP/3 on Android needs a server with a publicly trusted certificate.
#
# Output goes to the terminal and to build/integration_test_<platform>_<suites>.log.
set -euo pipefail

PLATFORM="${1:?usage: $0 ios|android <device id> [flutter test args]}"
DEVICE="${2:?usage: $0 ios|android <device id> [flutter test args]}"
# Expanded as ${EXTRA_ARGS[@]+...} below: macOS's bash 3.2 treats an empty array as unbound under `set -u`.
EXTRA_ARGS=("${@:3}")
SUITES="${SUITES:-dart native}"
# Split on spaces, so the default runs as `fvm flutter`.
read -ra FLUTTER <<< "${FLUTTER:-fvm flutter}"
PORT=8443
ADMIN_PORT=8081
# Short QUIC settings so the idle-timeout tests take seconds, not the server's 30 s default.
MAX_IDLE_SECONDS=3
KEEPALIVE=1s

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run() {
case "$PLATFORM" in
  ios)
    # The certificate covers only localhost, so 127.0.0.1 reaches the same server under a name it does not cover.
    HOSTS="localhost"
    SERVER_URL="https://localhost:$PORT"
    UNTRUSTED_URL="https://127.0.0.1:$PORT"
    UNREACHABLE_URL="https://localhost:9"
    ADMIN_URL="http://localhost:$ADMIN_PORT"
    EXPECT_PROTOCOL="HTTP/3.0"
    ;;
  android)
    # 10.0.2.2 is the emulator's address for the host. nip.io resolves 10.0.2.2.nip.io to it, which gives the
    # certificate a name to cover; the bare IP is then a name it does not.
    HOSTS="10.0.2.2.nip.io"
    SERVER_URL="https://10.0.2.2.nip.io:$PORT"
    UNTRUSTED_URL="https://10.0.2.2:$PORT"
    UNREACHABLE_URL="https://10.0.2.2.nip.io:9"
    ADMIN_URL="http://10.0.2.2:$ADMIN_PORT"
    EXPECT_PROTOCOL="HTTP/2.0"
    ;;
  *)
    echo "unknown platform $PLATFORM" >&2
    exit 2
    ;;
esac

echo "Building the test server"
(cd "$ROOT/test_server" && go build -o connect-native-http-test-server .)

# A server left over from an earlier run would hold the ports, make this one exit, and answer in its place.
if curl -s -o /dev/null "http://localhost:$ADMIN_PORT/"; then
  echo "something already serves on port $ADMIN_PORT; stop the old test server first" >&2
  exit 1
fi
"$ROOT/test_server/connect-native-http-test-server" -addr ":$PORT" -hosts "$HOSTS" \
  -certdir "$ROOT/test_server/certs" -admin-addr ":$ADMIN_PORT" -max-idle "${MAX_IDLE_SECONDS}s" -keepalive "$KEEPALIVE" &
SERVER_PID=$!
# Wait for the server's graceful shutdown, so a run started right after this one can bind the same ports.
trap 'kill $SERVER_PID 2>/dev/null && wait $SERVER_PID 2>/dev/null || true' EXIT
# The admin endpoint comes up after the certificates and both listeners, so it doubles as a readiness check.
ready=0
for _ in $(seq 50); do
  if curl -sf -X POST "http://localhost:$ADMIN_PORT/unfreeze" >/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ $ready -eq 0 ]]; then
  echo "test server did not come up on port $ADMIN_PORT within 5 s" >&2
  exit 1
fi

case "$PLATFORM" in
  ios)
    xcrun simctl keychain "$DEVICE" add-root-cert "$ROOT/test_server/certs/ca.pem"
    ;;
  android)
    mkdir -p "$ROOT/example/android/app/src/main/res/raw"
    cp "$ROOT/test_server/certs/ca.pem" "$ROOT/example/android/app/src/main/res/raw/test_server_ca.pem"
    ;;
esac

cd "$ROOT/example"
if [[ " $SUITES " == *" dart "* ]]; then
  echo "Dart integration tests"
  "${FLUTTER[@]}" test integration_test -d "$DEVICE" \
    --dart-define=SERVER_URL="$SERVER_URL" \
    --dart-define=UNTRUSTED_URL="$UNTRUSTED_URL" \
    --dart-define=UNREACHABLE_URL="$UNREACHABLE_URL" \
    --dart-define=EXPECT_PROTOCOL="$EXPECT_PROTOCOL" \
    --dart-define=ADMIN_URL="$ADMIN_URL" \
    --dart-define=SERVER_MAX_IDLE_SECONDS="$MAX_IDLE_SECONDS" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
fi
if [[ " $SUITES " == *" native "* ]]; then
  echo "Native plugin tests"
  case "$PLATFORM" in
    ios)
      # The Flutter-free core's package tests, built by xcodebuild and run on the simulator by xctest directly,
      # which skips xcodebuild's test session and result bundle. SIMCTL_CHILD_ variables reach the tests without
      # the prefix. Xcode evaluates package manifests in a sandbox of its own, which can't start inside another
      # sandbox; this manifest is ours and, core only, has no dependencies, so it runs without one.
      (cd "$ROOT/ios/connect_native_http" && CONNECT_NATIVE_HTTP_CORE_ONLY=1 xcodebuild build-for-testing -quiet \
        -IDEPackageSupportDisableManifestSandbox=YES -scheme connect_native_http-Package -destination "id=$DEVICE" \
        -derivedDataPath "$ROOT/build/ios_core_tests")
      SIMCTL_CHILD_SERVER_URL="$SERVER_URL" SIMCTL_CHILD_SERVER_CA="$ROOT/test_server/certs/ca.der" \
        xcrun simctl spawn "$DEVICE" \
        "$(xcrun --sdk iphonesimulator --show-sdk-platform-path)/Developer/Library/Xcode/Agents/xctest" \
        "$ROOT/build/ios_core_tests/Build/Products/Debug-iphonesimulator/ConnectNativeHttpCoreTests.xctest"
      ;;
    android)
      # The plugin module's own instrumented tests, built through the example's Gradle project, which includes the
      # plugin. Flutter writes example/android/gradlew.
      mkdir -p "$ROOT/android/src/androidTest/res/raw"
      cp "$ROOT/test_server/certs/ca.pem" "$ROOT/android/src/androidTest/res/raw/test_server_ca.pem"
      "${FLUTTER[@]}" build apk --debug --config-only
      (cd android && ANDROID_SERIAL="$DEVICE" ./gradlew :connect_native_http:connectedDebugAndroidTest \
        -Pandroid.testInstrumentationRunnerArguments.serverUrl="$SERVER_URL")
      ;;
  esac
fi
}

mkdir -p "$ROOT/build"
run 2>&1 | tee "$ROOT/build/integration_test_${PLATFORM}_${SUITES// /_}.log"
