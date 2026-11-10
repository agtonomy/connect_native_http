import 'dart:async';

import 'package:connectrpc/connect.dart';

import '../native_http_config.dart';

/// The procedure each keepalive calls: gRPC's standard health service, which connect-go serves through
/// `grpchealth.Register`.
const healthCheckPath = '/grpc.health.v1.Health/Check';

/// A Connect unary request for [healthCheckPath]. Its body is an empty `HealthCheckRequest`, which asks about the
/// server as a whole and encodes to no bytes at all.
Headers healthCheckHeaders(Duration timeout) => Headers()
  ..add('content-type', 'application/proto')
  ..add('connect-protocol-version', '1')
  ..add('connect-timeout-ms', '${timeout.inMilliseconds}');

/// Throws an [ArgumentError] unless [keepAlive] is `null` or has positive durations.
void validateKeepAlive(NativeKeepAlive? keepAlive) {
  if (keepAlive == null) {
    return;
  }
  if (keepAlive.interval <= Duration.zero) {
    throw ArgumentError.value(keepAlive.interval, 'keepAlive.interval', 'must be positive');
  }
  if (keepAlive.timeout <= Duration.zero) {
    throw ArgumentError.value(keepAlive.timeout, 'keepAlive.timeout', 'must be positive');
  }
}

/// `scheme://host:port` of [url]: the calls that share a connection.
Uri originOf(Uri url) => Uri(scheme: url.scheme, host: url.host, port: url.port);

/// Runs one client's [NativeKeepAlive]: a loop per origin that has calls open, which ends once none are.
final class KeepAliveMonitor {
  KeepAliveMonitor(this.config, {required this.ping});

  final NativeKeepAlive config;

  /// Sends one keepalive request to [origin], and completes once it has ended, however it ended.
  final Future<void> Function(Uri origin) ping;

  final _origins = <Uri, _Origin>{};
  bool _closed = false;

  /// Keeps the connection to [url]'s origin busy until the returned function is called, which the caller does once
  /// the call has finished.
  void Function() track(Uri url) {
    final origin = originOf(url);
    final state = _origins.putIfAbsent(origin, _Origin.new);
    final call = Object();
    state.calls.add(call);
    if (!state.running && !_closed) {
      state.running = true;
      unawaited(_run(origin, state));
    }
    return () => state.calls.remove(call);
  }

  /// Stops sending. A keepalive in flight is left to finish.
  void close() => _closed = true;

  Future<void> _run(Uri origin, _Origin state) async {
    try {
      while (true) {
        await Future<void>.delayed(config.interval);
        if (_closed || state.calls.isEmpty) {
          return;
        }
        await ping(origin);
      }
    } finally {
      state.running = false;
      if (state.calls.isEmpty && identical(_origins[origin], state)) {
        _origins.remove(origin);
      }
    }
  }
}

final class _Origin {
  /// One token per open call.
  final calls = <Object>{};
  bool running = false;
}
