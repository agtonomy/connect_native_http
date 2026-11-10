/// What a [NativeHttpClient] learned about one response.
final class NativeHttpResponseInfo {
  const NativeHttpResponseInfo({required this.url, required this.protocol});

  final Uri url;

  /// The protocol the platform negotiated, as the platform names it: Cronet reports `h2`, `quic/1+spdy/3` (HTTP/3)
  /// or `http/1.1`. `null` when the platform does not expose it, as with URLSession.
  final String? protocol;
}

/// Application-level keepalive: while a client has calls open to an origin, it sends a `grpc.health.v1.Health/Check`
/// request (Connect protocol, an empty `HealthCheckRequest`) every [interval] over the same platform stack, so the
/// connection carries traffic even while its calls are quiet. Register that service on every server the client
/// calls; in connect-go that is `grpchealth.Register`.
///
/// URLSession has no way to send HTTP/2 PING frames, and this plugin doesn't turn on Cronet's (an experimental
/// option), so a quiet HTTP/2 connection is otherwise silent, and anything on the path that closes idle connections
/// can close it: a load balancer's idle timeout (an AWS ALB's is 60 s by default), a NAT mapping, or the server's own.
/// A load balancer that ends HTTP/2 also answers PINGs itself, while these requests reach the server. Over HTTP/3 the
/// server's QUIC pings already keep the path busy.
///
/// It only keeps the connection busy: it doesn't fail calls or notice a dead connection, and a request on another
/// stream doesn't count as data on a call's own stream. Whatever the outcome, the next request waits [interval]. One
/// that hasn't ended within [timeout] is canceled. A response other than HTTP 200 is reported once per origin
/// through `FlutterError.onError`, since it usually means the server doesn't serve the health service.
///
/// Each request is small, but on a phone a short interval keeps the radio awake while calls are open.
final class NativeKeepAlive {
  const NativeKeepAlive({this.interval = const Duration(seconds: 15), this.timeout = const Duration(seconds: 10)});

  /// The wait before each request, starting when a call opens to an origin with none open, and after each request
  /// ends. Keep it well under the shortest idle timeout on the path.
  final Duration interval;

  /// How long a request may take before it is canceled.
  final Duration timeout;
}

/// Configuration shared by both platform clients. Server certificates are checked against the platform's trust
/// store.
final class NativeHttpConfig {
  const NativeHttpConfig({this.http3Origins = const {}, this.quicIdleTimeout, this.onResponse, this.keepAlive});

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

  /// Called with each response's headers, before its body is read. An exception it throws goes to
  /// `FlutterError.onError`, and the call goes on.
  final void Function(NativeHttpResponseInfo info)? onResponse;

  /// Application-level keepalive requests while this client has calls open. `null`, the default, sends none.
  final NativeKeepAlive? keepAlive;
}
