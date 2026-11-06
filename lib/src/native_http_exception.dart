/// Why a native request failed, in the terms a caller has to act on.
enum NativeHttpFailure {
  /// The request provably never left the device: no connection was established, so no byte of the request body
  /// was sent. Re-sending it cannot make the server act twice.
  notSent,

  /// The platform rejected the server's certificate. The request was not sent.
  untrusted,

  /// Anything else, including failures after the request may have reached the server.
  other,
}

/// A failure reported by the platform HTTP stack. connect-dart callers see it as the `cause` of a
/// `ConnectException` with code `unavailable`.
final class NativeHttpException implements Exception {
  const NativeHttpException(this.failure, this.message, {this.platformCode});

  final NativeHttpFailure failure;
  final String message;

  /// The platform's own code: an `NSURLErrorDomain` code on iOS, a Cronet internal (`net::`) error code on Android.
  final int? platformCode;

  /// Whether re-sending the request is safe, because the server cannot have seen it.
  bool get requestNeverSent => failure == NativeHttpFailure.notSent || failure == NativeHttpFailure.untrusted;

  @override
  String toString() => 'NativeHttpException(${failure.name}, code $platformCode): $message';
}
