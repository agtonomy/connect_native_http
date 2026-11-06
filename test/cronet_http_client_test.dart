import 'dart:async';

import 'package:connect_native_http/connect_native_http.dart';
import 'package:connect_native_http/src/cronet/cronet_http_client.dart';
import 'package:connectrpc/connect.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for ConnectNativeHttpPlugin.kt: records method calls and lets a test emit the plugin's events.
class FakePlugin {
  FakePlugin() {
    _messenger.setMockMethodCallHandler(cronetMethodChannel, (call) async {
      calls.add(call);
      return call.method == 'createEngine' ? 7 : null;
    });
    _messenger.setMockMethodCallHandler(MethodChannel(cronetEventChannel.name), (call) async => null);
  }

  final calls = <MethodCall>[];

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

HttpRequest request(Stream<Uint8List>? body, {AbortSignal? signal}) => HttpRequest(
  'https://example.test/svc/Method',
  'POST',
  Headers()..add('content-type', 'application/proto'),
  body,
  signal,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePlugin plugin;
  late CronetHttpClient client;
  final responses = <NativeHttpResponseInfo>[];

  setUp(() async {
    plugin = FakePlugin();
    responses.clear();
    client = await CronetHttpClient.create(
      NativeHttpConfig(http3Origins: {Uri.parse('https://example.test:443')}, onResponse: responses.add),
    );
  });

  test('creates the engine with a QUIC hint per HTTP/3 origin and the default idle timeout', () {
    final args = plugin.callsTo('createEngine').single.arguments as Map;
    expect(args['quicHints'], [
      ['example.test', 443],
    ]);
    expect(args['quicIdleTimeoutSeconds'], isNull);
  });

  test('passes the QUIC idle timeout in whole seconds', () async {
    await CronetHttpClient.create(const NativeHttpConfig(quicIdleTimeout: Duration(seconds: 4)));
    expect(plugin.callsTo('createEngine').last.arguments['quicIdleTimeoutSeconds'], 4);
  });

  test('rejects an idle timeout Cronet cannot express', () async {
    await expectLater(
      CronetHttpClient.create(const NativeHttpConfig(quicIdleTimeout: Duration(milliseconds: 500))),
      throwsArgumentError,
    );
  });

  test('opens the stream, then sends each body chunk and the end, in order', () async {
    final response = client.httpClient(
      request(
        Stream.fromIterable([
          Uint8List.fromList([1]),
          Uint8List.fromList([2]),
        ]),
      ),
    );
    await settle();
    await settle();
    final id = plugin.lastCallId;
    final open = plugin.callsTo('open').single.arguments as Map;
    expect(open['engineId'], 7);
    expect(open['url'], 'https://example.test/svc/Method');
    expect(open['headers'], [
      ['content-type', 'application/proto'],
    ]);
    expect(plugin.calls.map((c) => c.method).skip(1), ['open', 'write', 'write', 'end']);
    expect(plugin.callsTo('write').map((c) => (c.arguments as Map)['data']), [
      [1],
      [2],
    ]);
    await plugin.headers(id);
    await response;
  });

  test('response headers and body arrive while the request body is still open', () async {
    final requestBody = StreamController<Uint8List>();
    final responseFuture = client.httpClient(request(requestBody.stream));
    await settle();
    final id = plugin.lastCallId;

    await plugin.headers(id);
    final response = await responseFuture;
    expect(response.status, 200);
    expect(response.header.get('content-type'), ['application/connect+proto']);

    final received = <List<int>>[];
    response.body.listen(received.add);
    await plugin.data(id, [9, 9]);
    await settle();
    expect(received, [
      [9, 9],
    ]);
    expect(plugin.callsTo('end'), isEmpty, reason: 'the request side is still open');

    requestBody.add(Uint8List.fromList([5]));
    await requestBody.close();
    await settle();
    await settle();
    expect(plugin.callsTo('write').single.arguments['data'], [5]);
    expect(plugin.callsTo('end'), hasLength(1));
  });

  test('reports the negotiated protocol for each response', () async {
    final responseFuture = client.httpClient(request(null));
    await settle();
    await plugin.headers(plugin.lastCallId, protocol: 'h2');
    await responseFuture;
    expect(responses.single.protocol, 'h2');
    expect(responses.single.url, Uri.parse('https://example.test/svc/Method'));
  });

  test('trailers are filled in before the body completes', () async {
    final responseFuture = client.httpClient(request(null));
    await settle();
    final id = plugin.lastCallId;
    await plugin.headers(id);
    final response = await responseFuture;
    final done = response.body.toList();
    await plugin.emit({
      'callId': id,
      'type': 'trailers',
      'headers': [
        ['grpc-status', '0'],
      ],
    });
    await plugin.emit({'callId': id, 'type': 'done'});
    await done;
    expect(response.trailer.get('grpc-status'), ['0']);
  });

  Future<NativeHttpException> failureCause(Future<HttpResponse> response) async {
    try {
      await response;
    } on ConnectException catch (e) {
      expect(e.code, Code.unavailable);
      return e.cause! as NativeHttpException;
    }
    fail('expected the call to fail');
  }

  test('a failure before the stream was ready is notSent', () async {
    final response = client.httpClient(request(null));
    await settle();
    await plugin.failed(plugin.lastCallId, streamReady: false, internalErrorCode: -102);
    final cause = await failureCause(response);
    expect(cause.failure, NativeHttpFailure.notSent);
    expect(cause.requestNeverSent, isTrue);
    expect(cause.platformCode, -102);
  });

  test('a certificate error is untrusted', () async {
    final response = client.httpClient(request(null));
    await settle();
    await plugin.failed(plugin.lastCallId, streamReady: false, internalErrorCode: -202);
    expect((await failureCause(response)).failure, NativeHttpFailure.untrusted);
  });

  test('a failure after the stream was ready may have reached the server', () async {
    final response = client.httpClient(request(null));
    await settle();
    await plugin.failed(plugin.lastCallId, streamReady: true, internalErrorCode: -101);
    final cause = await failureCause(response);
    expect(cause.failure, NativeHttpFailure.other);
    expect(cause.requestNeverSent, isFalse);
  });

  test('a failure after the headers errors the response body', () async {
    final responseFuture = client.httpClient(request(null));
    await settle();
    final id = plugin.lastCallId;
    await plugin.headers(id);
    final response = await responseFuture;
    final body = response.body.toList();
    await plugin.failed(id, streamReady: true, internalErrorCode: -101);
    await expectLater(body, throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.unavailable)));
  });

  test("the signal cancels the native stream and the call fails with the signal's error", () async {
    final signal = CancelableSignal();
    final response = client.httpClient(request(StreamController<Uint8List>().stream, signal: signal));
    await settle();
    final id = plugin.lastCallId;
    signal.cancel('stop');
    await settle();
    expect(plugin.callsTo('cancel').single.arguments['callId'], id);
    await plugin.emit({'callId': id, 'type': 'canceled'});
    await expectLater(response, throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.canceled)));
  });

  test('cancelling the response body cancels the native stream', () async {
    final responseFuture = client.httpClient(request(null));
    await settle();
    final id = plugin.lastCallId;
    await plugin.headers(id);
    final response = await responseFuture;
    final subscription = response.body.listen((_) {});
    await subscription.cancel();
    await settle();
    expect(plugin.callsTo('cancel').single.arguments['callId'], id);
  });

  test('stops sending the request body once the server has finished the call', () async {
    final requestBody = StreamController<Uint8List>();
    final responseFuture = client.httpClient(request(requestBody.stream));
    await settle();
    final id = plugin.lastCallId;
    await plugin.headers(id);
    (await responseFuture).body.listen((_) {});
    await plugin.emit({'callId': id, 'type': 'done'});
    requestBody.add(Uint8List.fromList([1]));
    await requestBody.close();
    await settle();
    await settle();
    expect(plugin.callsTo('write'), isEmpty);
    expect(plugin.callsTo('end'), isEmpty);
  });

  test('the response ends when the server finishes, while the request side is still open', () async {
    final requestBody = StreamController<Uint8List>();
    final responseFuture = client.httpClient(request(requestBody.stream));
    await settle();
    final id = plugin.lastCallId;
    await plugin.headers(id);
    final body = (await responseFuture).body.toList();
    await plugin.data(id, [1]);
    await plugin.emit({'callId': id, 'type': 'responseComplete'});
    expect(await body.timeout(const Duration(seconds: 1)), [
      [1],
    ]);

    // The plugin ended the request side itself, so later request messages go nowhere.
    requestBody.add(Uint8List.fromList([2]));
    await requestBody.close();
    await settle();
    await settle();
    expect(plugin.callsTo('write'), isEmpty);
    expect(plugin.callsTo('end'), isEmpty);
    expect(plugin.callsTo('cancel'), isEmpty);

    // Cronet's own success arrives once both sides are closed, and changes nothing.
    await plugin.emit({'callId': id, 'type': 'done'});
  });

  test('close shuts the engine down', () async {
    await client.close();
    expect(plugin.callsTo('shutdownEngine').single.arguments['engineId'], 7);
  });
}
