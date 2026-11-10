/// What a [NativeHttpClient] learned about one response.
final class NativeHttpResponseInfo {
  const NativeHttpResponseInfo({required this.url, required this.protocol});

  final Uri url;

  /// The protocol the platform negotiated, as the platform names it: Cronet reports `h2`, `quic/1+spdy/3` (HTTP/3)
  /// or `http/1.1`. `null` when the platform does not expose it, as with URLSession.
  final String? protocol;
}

/// Configuration shared by both platform clients. Server certificates are checked against the platform's trust
/// store.
final class NativeHttpConfig {
  const NativeHttpConfig({this.http3Origins = const {}, this.quicIdleTimeout, this.readIdleTimeout, this.onResponse});

  /// `https://host:port` origins to try HTTP/3 with from the first request, before an `Alt-Svc` response header has
  /// advertised it. Both platforms fall back to HTTP/2 over TCP on their own when QUIC fails.
  ///
  /// Set this for origins that serve HTTP/3. Without it, URLSession learns HTTP/3 from `Alt-Svc` but uses it only for
  /// a new connection, and a busy session keeps reusing its first HTTP/2 connection indefinitely.
  final Set<Uri> http3Origins;

  /// The QUIC idle timeout this client advertises, in whole seconds: how long an HTTP/3 connection may go without
  /// receiving a packet before it is closed and its calls fail. QUIC uses the smaller of the two endpoints' values,
  /// so this bounds how long a dead network path goes unnoticed, as long as the server pings more often than this.
  /// `null` keeps the platform default.
  ///
  /// Android only. URLSession exposes no QUIC settings, so on iOS only the server's advertised idle timeout applies.
  final Duration? quicIdleTimeout;

  /// Fails each of this client's calls once it has received nothing from the server for this long. `null` or
  /// [Duration.zero] means none. Each call has its own timer in the platform client, so it also works on the HTTP/2
  /// fallback, where nothing else notices a dead connection.
  ///
  /// It applies to every call, so leave it off on a client that carries streams which go quiet for long, or use a
  /// second client for them. A call's own deadline (connect-dart's `TimeoutSignal` or `DeadlineSignal`) also moves new
  /// calls off a dead connection; see "Calls that run out of time" in the README.
  ///
  /// - **What resets it:** anything the call receives. It runs from when the call starts, so it also bounds the wait
  ///   for the response headers, and a unary call the server holds longer than this fails. A server stream that may go
  ///   quiet needs a longer timeout, or periodic messages.
  /// - **iOS:** `URLRequest.timeoutInterval`. URLSession fails the task with `NSURLErrorTimedOut` (-1001).
  /// - **Android:** a timer in the bridge, which fails the call with `net::ERR_TIMED_OUT` (-7).
  /// - **The failure:** a `ConnectException` with code `unavailable`, whose cause is a [NativeHttpException] with
  ///   that `platformCode`.
  /// - **The connection:** if nothing has arrived from the call's origin, on any call, since the call last received
  ///   anything, the connection is taken to be dead. The client moves new calls to a fresh `URLSession` or Cronet
  ///   engine, so they dial a new connection, and lets the calls already on the old one finish there. A call that hits
  ///   its deadline is checked the same way: the server is sent a deadline a step shorter, so on a live connection its
  ///   `deadline_exceeded` arrives first.
  final Duration? readIdleTimeout;

  /// Called with each response's headers, before its body is read. An exception it throws goes to
  /// `FlutterError.onError`, and the call goes on.
  final void Function(NativeHttpResponseInfo info)? onResponse;
}
