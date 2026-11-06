import '../native_http_exception.dart';

/// Chromium's `net::ERR_SSL_PINNED_KEY_NOT_IN_CERT_CHAIN`.
const _errPinnedKeyNotInChain = -150;

/// Classifies a failed Cronet bidirectional stream.
///
/// [streamReady] is whether Cronet called `onStreamReady`. The bridge writes no request body before that callback,
/// so a stream that failed without it never sent a byte of the body: [NativeHttpFailure.notSent], or
/// [NativeHttpFailure.untrusted] when [internalErrorCode] is a certificate error. `net::` certificate errors are
/// -200 to -299 (`net/base/net_error_list.h`).
NativeHttpFailure classifyCronetFailure({required bool streamReady, required int? internalErrorCode}) {
  if (streamReady) {
    return NativeHttpFailure.other;
  }
  final code = internalErrorCode;
  if (code != null && (code == _errPinnedKeyNotInChain || (code <= -200 && code >= -299))) {
    return NativeHttpFailure.untrusted;
  }
  return NativeHttpFailure.notSent;
}
