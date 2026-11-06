import 'dart:async';

import 'package:connectrpc/connect.dart';
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
  _Call(this.url);

  final Uri url;
  final response = Completer<HttpResponse>();
  final body = StreamController<Uint8List>();
  final trailer = Headers();
  bool finished = false;
  ConnectEndStreamDetector? endStream;

  /// Set when the call's signal fired, so the outcome reports the signal's error rather than the cancellation.
  Object? abortError;

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

/// Routes one plugin's event stream to the call each event belongs to. Every client on that plugin shares it, so call
/// ids are unique across clients.
final class _Dispatcher {
  _Dispatcher(this.bridge) {
    bridge.events.receiveBroadcastStream().listen(_onEvent);
  }

  static final _instances = <String, _Dispatcher>{};

  static _Dispatcher of(PlatformBridge bridge) => _instances.putIfAbsent(bridge.events.name, () => _Dispatcher(bridge));

  final PlatformBridge bridge;
  final calls = <int, _Call>{};
  final _onResponse = <int, void Function(NativeHttpResponseInfo)?>{};
  int _nextCallId = 1;

  int register(_Call call, void Function(NativeHttpResponseInfo)? onResponse) {
    final id = _nextCallId++;
    calls[id] = call;
    _onResponse[id] = onResponse;
    return id;
  }

  void _remove(int id) {
    calls.remove(id);
    _onResponse.remove(id);
  }

  void _onEvent(Object? event) {
    final e = (event! as Map).cast<String, Object?>();
    final id = e['callId']! as int;
    final call = calls[id];
    if (call == null) {
      return;
    }
    switch (e['type']) {
      case 'headers':
        final headers = bridge.responseHeaders([
          for (final pair in (e['headers']! as List).cast<List<Object?>>()) (pair[0]! as String, pair[1]! as String),
        ]);
        if (!bridge.endsStreamsItself && isConnectStreamingContentType(headers.get('content-type')?.firstOrNull)) {
          call.endStream = ConnectEndStreamDetector();
        }
        _onResponse[id]?.call(NativeHttpResponseInfo(url: call.url, protocol: e['protocol'] as String?));
        call.response.complete(HttpResponse(e['status']! as int, headers, call.body.stream, call.trailer));
      case 'data':
        _onData(id, call, e['data']! as Uint8List);
      case 'trailers':
        for (final pair in (e['headers']! as List).cast<List<Object?>>()) {
          call.trailer.add(pair[0]! as String, pair[1]! as String);
        }
      case 'responseComplete':
        call.completeResponse(bridge.name);
      case 'done':
        _remove(id);
        call.completeResponse(bridge.name);
      case 'failed':
        _remove(id);
        final cause = bridge.failure(e);
        call.fail(call.abortError ?? ConnectException(Code.unavailable, cause.message, cause: cause));
      case 'canceled':
        _remove(id);
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
      unawaited(bridge.methods.invokeMethod<void>('cancel', {'callId': id}));
    }
  }
}

/// A connect-dart [HttpClient] on one engine of a [PlatformBridge] plugin.
base class ChannelHttpClient implements NativeHttpClient {
  ChannelHttpClient(this._bridge, this._engineId, this._config);

  /// Starts the bridge's event routing and creates an engine with [arguments], returning its id.
  static Future<int> createEngine(PlatformBridge bridge, Map<String, Object?> arguments) async {
    _Dispatcher.of(bridge);
    return (await bridge.methods.invokeMethod<int>('createEngine', arguments))!;
  }

  final PlatformBridge _bridge;
  final int _engineId;
  final NativeHttpConfig _config;

  @override
  HttpClient get httpClient => _send;

  Future<HttpResponse> _send(HttpRequest req) async {
    final dispatcher = _Dispatcher.of(_bridge);
    final methods = _bridge.methods;
    final call = _Call(Uri.parse(req.url));
    final id = dispatcher.register(call, _config.onResponse);
    call.body.onCancel = () {
      if (!call.finished) {
        unawaited(methods.invokeMethod<void>('cancel', {'callId': id}));
      }
    };
    req.signal?.future.then((error) {
      if (!call.finished) {
        call.abortError = error;
        unawaited(methods.invokeMethod<void>('cancel', {'callId': id}));
      }
    });
    await methods.invokeMethod<void>('open', {
      'engineId': _engineId,
      'callId': id,
      'url': req.url,
      'method': req.method,
      'headers': [
        for (final (:name, :value) in req.header.entries) [name, value],
      ],
      'hasBody': req.body != null,
    });
    unawaited(_sendBody(id, call, req.body));
    return call.response.future;
  }

  /// Streams the request body to the plugin, one chunk per method call.
  Future<void> _sendBody(int id, _Call call, Stream<Uint8List>? body) async {
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
      if (!call.finished) {
        call.abortError ??= error;
        await methods.invokeMethod<void>('cancel', {'callId': id});
      }
    }
  }

  @override
  Future<void> close() => _bridge.methods.invokeMethod<void>('shutdownEngine', {'engineId': _engineId});
}
