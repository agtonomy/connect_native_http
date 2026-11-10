import 'package:connectrpc/connect.dart';

/// The request header that carries one call's read-idle timeout, in whole milliseconds. `0` means none.
///
/// The client reads it and removes it, so it never reaches the server. Set it with [setReadIdleTimeout], in a call's
/// `headers` or from an interceptor.
const readIdleTimeoutHeader = 'native-http-read-idle-timeout-ms';

/// Gives the call that sends [headers] a read-idle timeout: the call fails if it receives nothing from the server for
/// [timeout]. [Duration.zero] turns the timeout off for this call, overriding `NativeHttpConfig.readIdleTimeout`.
///
/// ```dart
/// final res = await eliza.say(
///   SayRequest(sentence: 'hi'),
///   headers: Headers()..setReadIdleTimeout(const Duration(seconds: 10)),
/// );
/// ```
///
/// See `NativeHttpConfig.readIdleTimeout` for what counts as receiving, and what happens on a timeout.
extension ReadIdleTimeoutHeaders on Headers {
  void setReadIdleTimeout(Duration timeout) {
    if (timeout.isNegative) {
      throw ArgumentError.value(timeout, 'timeout', 'must not be negative');
    }
    // At least 1 ms, so a sub-millisecond timeout doesn't turn into "none".
    final ms = timeout == Duration.zero ? 0 : (timeout.inMicroseconds / 1000).ceil();
    this[readIdleTimeoutHeader] = '$ms';
  }
}

/// The read-idle timeout for a request with [headers], in whole milliseconds, or `null` for none: the request's
/// [readIdleTimeoutHeader] if it has one, else [fallback]. Throws a [FormatException] on a malformed header.
int? readIdleTimeoutMs(Headers headers, Duration? fallback) {
  final values = headers.get(readIdleTimeoutHeader);
  if (values == null || values.isEmpty) {
    if (fallback == null || fallback == Duration.zero) {
      return null;
    }
    return (fallback.inMicroseconds / 1000).ceil();
  }
  // Repeated headers: the last one set wins, as with [Headers.operator []=].
  final value = values.last.trim();
  // Digits only: int.parse would also take a sign or a 0x prefix.
  final ms = _digits.hasMatch(value) ? int.tryParse(value) : null;
  if (ms == null) {
    throw FormatException('$readIdleTimeoutHeader must be a whole number of milliseconds', value);
  }
  return ms == 0 ? null : ms;
}

final _digits = RegExp(r'^[0-9]{1,15}$');
