import 'dart:async';

import 'package:connect_native_http/connect_native_http.dart';
import 'package:connect_native_http/src/cronet/cronet_http_client.dart';
import 'package:connectrpc/connect.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_cronet_plugin.dart';

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

  group('errors end the call they concern, and nothing else', () {
    final reported = <FlutterErrorDetails>[];
    late FlutterExceptionHandler? previousOnError;

    setUp(() {
      reported.clear();
      previousOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
    });

    tearDown(() => FlutterError.onError = previousOnError);

    Future<void> expectSayWorks() async {
      final response = client.httpClient(request(null));
      await settle();
      await plugin.headers(plugin.lastCallId);
      expect((await response).status, 200);
    }

    test('an onResponse callback that throws is reported, and the call goes on', () async {
      final throwing = await CronetHttpClient.create(NativeHttpConfig(onResponse: (_) => throw StateError('oops')));
      final responseFuture = throwing.httpClient(request(null));
      await settle();
      await plugin.headers(plugin.lastCallId);
      final response = await responseFuture.timeout(const Duration(seconds: 1));
      expect(response.status, 200);
      expect(reported.single.exception, isA<StateError>());
    });

    test('a plugin that refuses to open the call fails it as never sent', () async {
      plugin.refusing.add('open');
      final cause = await failureCause(client.httpClient(request(Stream.value(Uint8List.fromList([1])))));
      expect(cause.failure, NativeHttpFailure.notSent);
      expect(cause.message, contains('open refused'));
      await settle();
      expect(plugin.callsTo('write'), isEmpty);
      plugin.refusing.clear();
      await expectSayWorks();
    });

    test('a plugin that refuses a chunk cancels the call', () async {
      plugin.refusing.add('write');
      final response = client.httpClient(request(Stream.value(Uint8List.fromList([1]))));
      await settle();
      await settle();
      final id = plugin.lastCallId;
      expect(plugin.callsTo('cancel').single.arguments['callId'], id);
      await plugin.emit({'callId': id, 'type': 'canceled'});
      await expectLater(response, throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.internal)));
    });

    test('a cancel the plugin refuses still ends the call', () async {
      plugin.refusing.add('cancel');
      final signal = CancelableSignal();
      final response = client.httpClient(request(StreamController<Uint8List>().stream, signal: signal));
      await settle();
      signal.cancel('stop');
      await expectLater(
        response.timeout(const Duration(seconds: 1)),
        throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.canceled)),
      );
      expect(reported.single.exception, isA<PlatformException>());
    });

    test('a malformed event fails its own call, and other calls carry on', () async {
      final other = client.httpClient(request(null));
      await settle();
      final otherId = plugin.lastCallId;

      final broken = client.httpClient(request(null));
      await settle();
      final brokenId = plugin.lastCallId;
      await plugin.emit({'callId': brokenId, 'type': 'headers', 'status': 'two hundred', 'headers': <Object>[]});
      await expectLater(broken, throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.internal)));
      await settle();
      expect(plugin.callsTo('cancel').single.arguments['callId'], brokenId);
      expect(reported, hasLength(1));

      await plugin.headers(otherId);
      expect((await other).status, 200);
    });

    test('an event that names no call is reported and ignored', () async {
      await plugin.emit({'type': 'data'});
      expect(reported, hasLength(1));
      await expectSayWorks();
    });
  });
}
