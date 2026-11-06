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
  const NativeHttpConfig({this.http3Origins = const {}, this.quicIdleTimeout, this.onResponse});

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

  /// Called with each response's headers, before its body is read.
  final void Function(NativeHttpResponseInfo info)? onResponse;
}
