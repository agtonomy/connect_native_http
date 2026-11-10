import 'dart:async';
import 'dart:math' as math;

import 'package:connectrpc/connect.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../native_http_client.dart';
import '../native_http_config.dart';
import '../native_http_exception.dart';
import 'connect_end_stream.dart';

/// A platform plugin that speaks this file's channel protocol: `createEngine`, `shutdownEngine`, `open`, `write`,
/// `end` and `cancel` method calls, and `headers`, `data`, `trailers`, `responseComplete`, `done`, `failed` and
/// `canceled` events.
final class PlatformBridge {
  const PlatformBridge({
    required this.name,
    required this.methods,
    required this.events,
    required this.failure,
    this.responseHeaders = plainHeaders,
    this.endsStreamsItself = true,
  });

  /// Prefixes the plugin's error messages, such as `cronet`.
  final String name;
  final MethodChannel methods;
  final EventChannel events;

  /// The cause a `failed` event's call fails with.
  final NativeHttpException Function(Map<String, Object?> event) failure;

  /// Builds the response headers connect-dart sees from a `headers` event's name and value pairs.
  final Headers Function(List<(String, String)> pairs) responseHeaders;

  /// Whether the plugin ends a call once the server has sent the whole response, even while the request body is
  /// still open. When it does not, the client watches Connect streaming responses for their end-stream message and
  /// cancels the call itself once that arrives (see [ConnectEndStreamDetector]).
  final bool endsStreamsItself;
}

Headers plainHeaders(List<(String, String)> pairs) {
  final headers = Headers();
  for (final (name, value) in pairs) {
    headers.add(name, value);
  }
  return headers;
}

final class _Call {
  _Call(this.url) {
    // A failure event can arrive before the `open` reply, so before `_send` has handed this future to its caller.
    // The caller still gets the error; this keeps it from also being reported as unhandled in the meantime.
    response.future.ignore();
  }

  final Uri url;
  final response = Completer<HttpResponse>();
  final body = StreamController<Uint8List>();
  final trailer = Headers();
  bool finished = false;
  ConnectEndStreamDetector? endStream;

  /// Set when the call's signal fired, so the outcome reports the signal's error rather than the cancellation.
  Object? abortError;

  /// Time since the call last received anything from the server, or started.
  final sinceReceived = Stopwatch()..start();

  void fail(Object error) {
    finished = true;
    if (!response.isCompleted) {
      response.completeError(error);
    }
    // A failure after the whole response arrived, such as a cancel while the request side was closing, changes
    // nothing the caller has already read.
    if (!body.isClosed) {
      body
        ..addError(error)
        ..close();
    }
  }

  /// The server sent the whole response, so nothing more is sent.
  void completeResponse(String bridgeName) {
    finished = true;
    if (!response.isCompleted) {
      response.completeError(ConnectException(Code.internal, '$bridgeName: response ended without headers'));
    }
    if (!body.isClosed) {
      body.close();
    }
  }
}

/// Reports an error that has no caller to go to, such as one thrown by `onResponse`, through [FlutterError.reportError]:
/// logged in debug builds, and passed to [FlutterError.onError] (an app's crash reporter, typically) in all builds.
/// Nothing in this package lets such an error escape into a zone or a native thread, where it could crash the app.
void reportError(Object error, StackTrace stack, String context) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'connect_native_http',
      context: ErrorDescription(context),
    ),
  );
}

/// Routes one plugin's event stream to the call each event belongs to. Every client on that plugin shares it, so call
/// ids are unique across clients.
final class _Dispatcher {
  _Dispatcher(this.bridge) {
    bridge.events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error, StackTrace stack) => reportError(error, stack, 'while receiving ${bridge.name} events'),
    );
  }

  static final _instances = <String, _Dispatcher>{};

  static _Dispatcher of(PlatformBridge bridge) => _instances.putIfAbsent(bridge.events.name, () => _Dispatcher(bridge));

  final PlatformBridge bridge;
  final calls = <int, _Call>{};
  final _onResponse = <int, void Function(NativeHttpResponseInfo)?>{};

  /// Starts at a random id rather than 1. A hot restart starts Dart afresh while the plugin's calls live on, and
  /// would otherwise hand a new call the id of an old one, whose events it would then receive. Under 2^30, so ids stay
  /// within the 32 bits the plugins read them as.
  int _nextCallId = 1 + math.Random().nextInt(1 << 30);

  int register(_Call call, void Function(NativeHttpResponseInfo)? onResponse) {
    final id = _nextCallId++;
    calls[id] = call;
    _onResponse[id] = onResponse;
    return id;
  }

  _Call? remove(int id) {
    _onResponse.remove(id);
    return calls.remove(id);
  }

  /// Asks the plugin to cancel call [id]; its `canceled` event then ends the call. Should the plugin fail to take the
  /// request, no event will come, so the call ends here instead.
  ///
  /// With [evictConnection], the call hit its deadline (see [NativeHttpConfig.evictOnDeadline]). The plugin then moves
  /// new calls off the call's connection, unless something from the call's origin has arrived since the call last
  /// received anything.
  Future<void> cancel(int id, {bool evictConnection = false}) async {
    try {
      await bridge.methods.invokeMethod<void>('cancel', {
        'callId': id,
        if (evictConnection) 'evictConnection': true,
      });
    } catch (error, stack) {
      final call = remove(id);
      call?.fail(call.abortError ?? ConnectException(Code.canceled, '${bridge.name}: cancel failed: $error'));
      reportError(error, stack, 'while canceling a ${bridge.name} call');
    }
  }

  void _onEvent(Object? event) {
    final int id;
    final _Call? call;
    try {
      id = (event! as Map)['callId']! as int;
      call = calls[id];
    } catch (error, stack) {
      reportError(error, stack, 'while reading a ${bridge.name} event (${event.runtimeType})');
      return;
    }
    if (call == null) {
      return;
    }
    try {
      _onCallEvent(id, call, (event as Map).cast<String, Object?>());
    } catch (error, stack) {
      // A malformed event: the call can't go on, but nothing else is affected.
      remove(id);
      call.fail(ConnectException(Code.internal, '${bridge.name}: bad event: $error', cause: error));
      unawaited(cancel(id));
      // The event's type only: its body bytes and headers can be large, and private.
      reportError(error, stack, "while handling a ${bridge.name} '${(event as Map)['type']}' event for call $id");
    }
  }

  void _onCallEvent(int id, _Call call, Map<String, Object?> e) {
    if (const {'headers', 'data', 'trailers'}.contains(e['type'])) {
      call.sinceReceived.reset();
    }
    switch (e['type']) {
      case 'headers':
        final headers = bridge.responseHeaders([
          for (final pair in (e['headers']! as List).cast<List<Object?>>()) (pair[0]! as String, pair[1]! as String),
        ]);
        final status = e['status']! as int;
        if (!bridge.endsStreamsItself && isConnectStreamingContentType(headers.get('content-type')?.firstOrNull)) {
          call.endStream = ConnectEndStreamDetector();
        }
        final onResponse = _onResponse[id];
        if (onResponse != null) {
          // The caller's own callback: its failure is reported, and doesn't fail the call or leave it hanging.
          try {
            onResponse(NativeHttpResponseInfo(url: call.url, protocol: e['protocol'] as String?));
          } catch (error, stack) {
            reportError(error, stack, 'in NativeHttpConfig.onResponse');
          }
        }
        if (!call.response.isCompleted) {
          call.response.complete(HttpResponse(status, headers, call.body.stream, call.trailer));
        }
      case 'data':
        _onData(id, call, e['data']! as Uint8List);
      case 'trailers':
        for (final pair in (e['headers']! as List).cast<List<Object?>>()) {
          call.trailer.add(pair[0]! as String, pair[1]! as String);
        }
      case 'responseComplete':
        call.completeResponse(bridge.name);
      case 'done':
        remove(id);
        call.completeResponse(bridge.name);
      case 'failed':
        remove(id);
        final cause = bridge.failure(e);
        call.fail(call.abortError ?? ConnectException(Code.unavailable, cause.message, cause: cause));
      case 'canceled':
        remove(id);
        call.fail(call.abortError ?? ConnectException(Code.canceled, '${bridge.name}: stream canceled'));
    }
  }

  void _onData(int id, _Call call, Uint8List data) {
    if (call.finished) {
      return;
    }
    final detector = call.endStream;
    if (detector == null) {
      call.body.add(data);
      return;
    }
    final used = detector.add(data);
    if (used > 0) {
      call.body.add(used == data.length ? data : Uint8List.sublistView(data, 0, used));
    }
    if (detector.done) {
      call.completeResponse(bridge.name);
      unawaited(cancel(id));
    }
  }
}

/// The `connect-timeout-ms` to send for a call whose deadline is [ms] away: [step] less, or half of [ms] when that is
/// less, so the server never gets zero. See [NativeHttpConfig.deadlineStep].
int serverTimeoutMs(int ms, Duration step) => ms - math.min(step.inMilliseconds, ms ~/ 2);

/// connect-dart's deadline header, which it sets from the call's signal.
const _connectTimeoutHeader = 'connect-timeout-ms';

/// A connect-dart [HttpClient] on one engine of a [PlatformBridge] plugin.
base class ChannelHttpClient implements NativeHttpClient {
  ChannelHttpClient(this._bridge, this._engineId, this._config);

  /// Starts the bridge's event routing and creates an engine with [arguments], returning its id.
  static Future<int> createEngine(
    PlatformBridge bridge,
    NativeHttpConfig config,
    Map<String, Object?> arguments,
  ) async {
    final readIdle = config.readIdleTimeout;
    if (readIdle != null && readIdle.isNegative) {
      throw ArgumentError.value(readIdle, 'readIdleTimeout', 'must not be negative');
    }
    final step = config.deadlineStep;
    if (step != null && step.isNegative) {
      throw ArgumentError.value(step, 'deadlineStep', 'must not be negative');
    }
    _Dispatcher.of(bridge);
    return (await bridge.methods.invokeMethod<int>('createEngine', arguments))!;
  }

  final PlatformBridge _bridge;
  final int _engineId;
  final NativeHttpConfig _config;

  /// [NativeHttpConfig.deadlineStep], or `null` for none.
  late final Duration? _deadlineStep = _config.deadlineStep == Duration.zero ? null : _config.deadlineStep;

  /// [NativeHttpConfig.readIdleTimeout] in whole milliseconds, rounded up so a sub-millisecond timeout isn't none.
  late final int? _readIdleTimeoutMs = switch (_config.readIdleTimeout) {
    null || Duration.zero => null,
    final timeout => (timeout.inMicroseconds / 1000).ceil(),
  };

  @override
  HttpClient get httpClient => _send;

  Future<HttpResponse> _send(HttpRequest req) async {
    final dispatcher = _Dispatcher.of(_bridge);
    final methods = _bridge.methods;
    final step = _deadlineStep;
    final call = _Call(Uri.parse(req.url));
    // How much earlier than the client the server times the call out.
    var serverLead = Duration.zero;
    final headers = <List<String>>[];
    for (final (:name, :value) in req.header.entries) {
      final ms = step != null && name == _connectTimeoutHeader ? int.tryParse(value) : null;
      if (ms != null && ms > 0) {
        final serverMs = serverTimeoutMs(ms, step!);
        serverLead = Duration(milliseconds: ms - serverMs);
        headers.add([name, '$serverMs']);
      } else {
        headers.add([name, value]);
      }
    }
    final id = dispatcher.register(call, _config.onResponse);
    call.body.onCancel = () {
      if (!call.finished) {
        unawaited(dispatcher.cancel(id));
      }
    };
    req.signal?.future.then((error) {
      if (call.finished) {
        return;
      }
      call.abortError = error;
      // A call that received something since the server's deadline was still hearing from the server, whatever the
      // server made of the deadline, so its connection is alive.
      final evict =
          _config.evictOnDeadline && error.code == Code.deadlineExceeded && call.sinceReceived.elapsed >= serverLead;
      unawaited(dispatcher.cancel(id, evictConnection: evict));
    });
    try {
      await methods.invokeMethod<void>('open', {
        'engineId': _engineId,
        'callId': id,
        'url': req.url,
        'method': req.method,
        'headers': headers,
        'hasBody': req.body != null,
        'readIdleTimeoutMs': _readIdleTimeoutMs,
      });
    } catch (error) {
      // The plugin refused the call, or isn't there (a background isolate, say): nothing was sent.
      dispatcher.remove(id);
      call.finished = true;
      final cause = NativeHttpException(NativeHttpFailure.notSent, '${_bridge.name}: open failed: $error');
      throw ConnectException(Code.unavailable, cause.message, cause: cause);
    }
    unawaited(_sendBody(id, call, req.body, dispatcher));
    return call.response.future;
  }

  /// Streams the request body to the plugin, one chunk per method call.
  Future<void> _sendBody(int id, _Call call, Stream<Uint8List>? body, _Dispatcher dispatcher) async {
    final methods = _bridge.methods;
    try {
      if (body != null) {
        await for (final chunk in body) {
          if (call.finished) {
            return;
          }
          await methods.invokeMethod<void>('write', {'callId': id, 'data': chunk});
        }
      }
      if (!call.finished) {
        await methods.invokeMethod<void>('end', {'callId': id});
      }
    } catch (error) {
      // The request stream failed, or the plugin refused a chunk: the call fails with that error.
      if (!call.finished) {
        call.abortError ??= error is PlatformException
            ? ConnectException(Code.internal, '${_bridge.name}: request body refused: $error', cause: error)
            : error;
        await dispatcher.cancel(id);
      }
    }
  }

  @override
  Future<void> close() => _bridge.methods.invokeMethod<void>('shutdownEngine', {'engineId': _engineId});
}
