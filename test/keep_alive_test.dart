import 'dart:async';

import 'package:connect_native_http/connect_native_http.dart';
import 'package:connect_native_http/src/cronet/cronet_http_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_cronet_plugin.dart';

const interval = Duration(milliseconds: 30);
const timeout = Duration(milliseconds: 60);
const keepAlive = NativeKeepAlive(interval: interval, timeout: timeout);
const healthCheck = 'https://example.test/grpc.health.v1.Health/Check';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePlugin plugin;
  final clients = <CronetHttpClient>[];

  setUp(() => plugin = FakePlugin());

  // A client's keepalive loop would otherwise go on into the next test, against that test's fake plugin.
  tearDown(() async {
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
  });

  Future<CronetHttpClient> create(NativeHttpConfig config) async {
    final client = await CronetHttpClient.create(config);
    clients.add(client);
    return client;
  }

  /// The `open` arguments of each request to [url] so far.
  List<Map<Object?, Object?>> opensTo(String url) => [
    for (final call in plugin.callsTo('open'))
      if ((call.arguments as Map)['url'] == url) call.arguments as Map,
  ];

  List<int> callIds(List<Map<Object?, Object?>> opens) => [for (final open in opens) open['callId']! as int];

  Future<void> until(String what, bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting until $what; calls: ${plugin.calls}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Answers call [id] with [status] and ends it.
  Future<void> answer(int id, {int status = 200}) async {
    await plugin.emit({
      'callId': id,
      'type': 'headers',
      'status': status,
      'protocol': 'h2',
      'headers': [
        ['content-type', 'application/proto'],
      ],
    });
    await plugin.emit({'callId': id, 'type': 'done'});
  }

  /// Opens a call to [url] whose request side stays open, and returns its id. The call must not fail: an error on
  /// its response would surface as an uncaught error and fail the test.
  Future<int> openCall(CronetHttpClient client, {String url = 'https://example.test/svc/Method'}) async {
    unawaited(client.httpClient(request(StreamController<Uint8List>().stream, url: url)));
    await settle();
    return callIds(opensTo(url)).last;
  }

  test('sends no keepalives unless configured', () async {
    final client = await create(const NativeHttpConfig());
    await openCall(client);
    await Future<void>.delayed(interval * 4);
    expect(opensTo(healthCheck), isEmpty);
  });

  test('sends a Connect health check to the origin of an open call, after the interval', () async {
    final client = await create(const NativeHttpConfig(keepAlive: keepAlive));
    await openCall(client);
    expect(opensTo(healthCheck), isEmpty, reason: 'nothing before the first interval');
    await until('a keepalive was sent', () => opensTo(healthCheck).isNotEmpty);
    final open = opensTo(healthCheck).single;
    expect(open['engineId'], 7);
    expect(open['method'], 'POST');
    expect(open['hasBody'], isFalse, reason: 'an empty HealthCheckRequest encodes to no bytes');
    expect(open['headers'], [
      ['content-type', 'application/proto'],
      ['connect-protocol-version', '1'],
      ['connect-timeout-ms', '60'],
    ]);
  });

  test('keeps sending while a call is open, and stops once none is', () async {
    final responses = <NativeHttpResponseInfo>[];
    final client = await create(NativeHttpConfig(keepAlive: keepAlive, onResponse: responses.add));
    final call = await openCall(client);
    for (var n = 1; n <= 3; n++) {
      await until('keepalive $n was sent', () => opensTo(healthCheck).length == n);
      await answer(callIds(opensTo(healthCheck)).last);
    }
    expect(responses, isEmpty, reason: 'onResponse sees the app\'s calls only');

    // The call ends. A keepalive already waiting for its interval may still go out, but nothing after it.
    await answer(call);
    await Future<void>.delayed(interval * 2);
    for (final id in callIds(opensTo(healthCheck)).skip(3)) {
      await answer(id);
    }
    final sent = opensTo(healthCheck).length;
    await Future<void>.delayed(interval * 4);
    expect(opensTo(healthCheck), hasLength(sent));
    expect(responses, hasLength(1));
  });

  test('a keepalive with no answer is canceled after the timeout, the call carries on, and the next follows', () async {
    final client = await create(const NativeHttpConfig(keepAlive: keepAlive));
    final call = await openCall(client);
    await until('a keepalive was sent', () => opensTo(healthCheck).isNotEmpty);
    final first = callIds(opensTo(healthCheck)).single;

    await until('the keepalive was canceled', () => plugin.callsTo('cancel').isNotEmpty);
    expect(plugin.callsTo('cancel').single.arguments['callId'], first);
    await plugin.emit({'callId': first, 'type': 'canceled'});

    await until('the next keepalive was sent', () => opensTo(healthCheck).length == 2);
    expect(plugin.callsTo('cancel').map((c) => c.arguments['callId']), isNot(contains(call)));
  });

  test('a failed keepalive fails no call, and the next follows', () async {
    final client = await create(const NativeHttpConfig(keepAlive: keepAlive));
    final call = await openCall(client);
    await until('a keepalive was sent', () => opensTo(healthCheck).isNotEmpty);
    await plugin.failed(callIds(opensTo(healthCheck)).single, streamReady: true, internalErrorCode: -101);
    await until('the next keepalive was sent', () => opensTo(healthCheck).length == 2);
    expect(plugin.callsTo('cancel').map((c) => c.arguments['callId']), isNot(contains(call)));
  });

  test('one keepalive at a time per origin, however many calls are open to it', () async {
    final client = await create(const NativeHttpConfig(keepAlive: keepAlive));
    await openCall(client);
    await openCall(client, url: 'https://example.test/svc/Other');
    await openCall(client, url: 'https://other.test:8443/svc/Method');
    await until('each origin got a keepalive', () {
      return opensTo(healthCheck).isNotEmpty &&
          opensTo('https://other.test:8443/grpc.health.v1.Health/Check').isNotEmpty;
    });
    // The first is still waiting for an answer, so no second one has gone out to the same origin.
    await Future<void>.delayed(interval * 2 ~/ 3);
    expect(opensTo(healthCheck), hasLength(1));
  });

  test('close stops keepalives', () async {
    final client = await create(const NativeHttpConfig(keepAlive: keepAlive));
    await openCall(client);
    await client.close();
    await Future<void>.delayed(interval * 4);
    expect(opensTo(healthCheck), isEmpty);
  });

  test('rejects intervals and timeouts that are not positive', () async {
    await expectLater(
      CronetHttpClient.create(const NativeHttpConfig(keepAlive: NativeKeepAlive(interval: Duration.zero))),
      throwsArgumentError,
    );
    await expectLater(
      CronetHttpClient.create(const NativeHttpConfig(keepAlive: NativeKeepAlive(timeout: Duration(seconds: -1)))),
      throwsArgumentError,
    );
    expect(plugin.callsTo('createEngine'), isEmpty);
  });

  group('reporting', () {
    final reported = <FlutterErrorDetails>[];
    late FlutterExceptionHandler? previousOnError;

    setUp(() {
      reported.clear();
      previousOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
    });

    tearDown(() => FlutterError.onError = previousOnError);

    test('a response other than HTTP 200 is reported once per origin, and keepalives go on', () async {
      final client = await create(const NativeHttpConfig(keepAlive: keepAlive));
      await openCall(client);
      for (var n = 1; n <= 2; n++) {
        await until('keepalive $n was sent', () => opensTo(healthCheck).length == n);
        await answer(callIds(opensTo(healthCheck)).last, status: 404);
      }
      await until('the next keepalive was sent', () => opensTo(healthCheck).length == 3);
      expect(reported, hasLength(1));
      expect('${reported.single.exception}', allOf(contains('HTTP 404'), contains('grpc.health.v1.Health')));
    });
  });
}
