import 'package:connect_native_http/src/cronet/cronet_http_client.dart';
import 'package:connectrpc/connect.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for ConnectNativeHttpPlugin.kt: records method calls and lets a test emit the plugin's events.
class FakePlugin {
  FakePlugin() {
    _messenger.setMockMethodCallHandler(cronetMethodChannel, (call) async {
      calls.add(call);
      if (refusing.contains(call.method)) {
        throw PlatformException(code: 'badArguments', message: '${call.method} refused');
      }
      return call.method == 'createEngine' ? 7 : null;
    });
    _messenger.setMockMethodCallHandler(MethodChannel(cronetEventChannel.name), (call) async => null);
  }

  final calls = <MethodCall>[];

  /// Methods the plugin answers with an error.
  final refusing = <String>{};

  TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<MethodCall> callsTo(String method) => calls.where((c) => c.method == method).toList();

  int get lastCallId => callsTo('open').last.arguments['callId'] as int;

  Future<void> emit(Map<String, Object?> event) async {
    await _messenger.handlePlatformMessage(
      cronetEventChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  Future<void> headers(int callId, {String protocol = 'quic/1+spdy/3'}) => emit({
    'callId': callId,
    'type': 'headers',
    'status': 200,
    'protocol': protocol,
    'headers': [
      ['content-type', 'application/connect+proto'],
    ],
  });

  Future<void> data(int callId, List<int> bytes) =>
      emit({'callId': callId, 'type': 'data', 'data': Uint8List.fromList(bytes)});

  Future<void> failed(int callId, {required bool streamReady, int? internalErrorCode}) => emit({
    'callId': callId,
    'type': 'failed',
    'streamReady': streamReady,
    'message': 'net::ERR',
    'internalErrorCode': internalErrorCode,
  });
}

/// Lets queued microtasks and platform-channel replies run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

HttpRequest request(Stream<Uint8List>? body, {AbortSignal? signal, String url = 'https://example.test/svc/Method'}) =>
    HttpRequest(
      url,
      'POST',
      Headers()..add('content-type', 'application/proto'),
      body,
      signal,
    );
