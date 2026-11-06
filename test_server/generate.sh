#!/usr/bin/env bash
# Regenerates the eliza Go server stubs (gen/) and Dart client (../example/lib/gen/) from proto/.
# Needs buf, protoc-gen-go, and the Dart plugins:
#   dart pub global activate protoc_plugin 25.0.0 && dart pub global activate connectrpc 2.0.0
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
rm -rf gen ../example/lib/gen
buf generate
# protoc-gen-dart writes server stubs the example app never uses.
rm -f ../example/lib/gen/connectrpc/eliza/v1/*.pbserver.dart
dart format -l 120 ../example/lib/gen
