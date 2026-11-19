import 'dart:async';

import 'package:connect_native_http/connect_native_http.dart';
import 'package:connect_native_http/src/cronet/cronet_http_client.dart';
import 'package:connect_native_http/src/nio_http3/nio_http3_client.dart';
import 'package:connect_native_http/src/url_session/url_session_http_client.dart';
import 'package:connectrpc/connect.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for one of the platform plugins: records its method calls and lets a test emit its events.
class FakeChannel {
  FakeChannel(this.methods, this.events, {this.createError}) {
    _messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'createEngine') {
        if (createError != null) {
          throw createError!;
        }
        return 5;
      }
      return null;
    });
    _messenger.setMockMethodCallHandler(MethodChannel(events.name), (call) async => null);
  }

  final MethodChannel methods;
  final EventChannel events;
  final PlatformException? createError;
  final calls = <MethodCall>[];

  TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<MethodCall> callsTo(String method) => calls.where((c) => c.method == method).toList();

  Future<void> emit(Map<String, Object?> event) async {
    await _messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }
}

/// Lets queued microtasks and platform-channel replies run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// A Connect streaming envelope: flags, big-endian length, payload.
List<int> envelope(int flags, List<int> payload) => [
  flags,
  payload.length >> 24 & 0xFF,
  payload.length >> 16 & 0xFF,
  payload.length >> 8 & 0xFF,
  payload.length & 0xFF,
  ...payload,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final url = Uri.parse('https://example.test/datagrams/echo');
  late FakeChannel urlSession;
  late FakeChannel http3;
  late FakeChannel cronet;

  setUp(() {
    urlSession = FakeChannel(urlSessionMethodChannel, urlSessionEventChannel);
    http3 = FakeChannel(nioHttp3MethodChannel, nioHttp3EventChannel);
    cronet = FakeChannel(cronetMethodChannel, cronetEventChannel);
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('on iOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('uses URLSession by default, which opens no datagram sessions', () async {
      final client = (await NativeHttpClient.create())!;
      expect(urlSession.callsTo('createEngine'), hasLength(1));
      expect(http3.calls, isEmpty);
      expect(() => client.openDatagramSession(url, protocol: 'datagram-echo'), throwsUnsupportedError);
    });

    test('with enableDatagrams, uses swift-nio-http3 and asks it to advertise datagram support', () async {
      final client = (await NativeHttpClient.create(const NativeHttpConfig(enableDatagrams: true)))!;
      expect(urlSession.calls, isEmpty);
      expect(http3.callsTo('createEngine').single.arguments['datagrams'], isTrue);

      unawaited(client.openDatagramSession(url, protocol: 'datagram-echo').then((_) {}, onError: (_) {}));
      await settle();
      expect(http3.callsTo('openDatagrams').single.arguments['engineId'], 5);
    });

    test('with enableDatagrams, a plugin that refuses (before iOS 27) fails create', () async {
      FakeChannel(
        nioHttp3MethodChannel,
        nioHttp3EventChannel,
        createError: PlatformException(code: 'unsupported', message: 'HTTP datagrams need iOS 27 or later'),
      );
      await expectLater(
        NativeHttpClient.create(const NativeHttpConfig(enableDatagrams: true)),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'unsupported')),
      );
    });

    // URLSession over HTTP/3 doesn't end a call while its request body is open, so the client ends a Connect stream
    // at its end-stream message. swift-nio-http3 and Cronet end such calls themselves.
    test('URLSession: a Connect stream ends at its end-stream message while the request is still open', () async {
      final client = (await NativeHttpClient.create())!;
      final requestBody = StreamController<Uint8List>();
      addTearDown(requestBody.close);
      final pending = client.httpClient(
        HttpRequest(
          'https://example.test/svc/Method',
          'POST',
          Headers()..add('content-type', 'application/connect+proto'),
          requestBody.stream,
          null,
        ),
      );
      await settle();
      final id = urlSession.callsTo('open').single.arguments['callId'] as int;
      await urlSession.emit({
        'callId': id,
        'type': 'headers',
        'status': 200,
        'headers': [
          ['content-type', 'application/connect+proto'],
        ],
      });
      final response = await pending;
      final message = envelope(0, [1, 2]);
      final endStream = envelope(2, '{}'.codeUnits);
      await urlSession.emit({
        'callId': id,
        'type': 'data',
        'data': Uint8List.fromList([...message, ...endStream, 0xFF]),
      });

      final body = await response.body.expand((chunk) => chunk).toList();
      expect(body, [...message, ...endStream], reason: 'bytes after the end-stream message are dropped');
      expect(urlSession.callsTo('cancel').single.arguments['callId'], id);
    });
  });

  group('on Android', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('uses Cronet, with or without enableDatagrams, and opens no datagram sessions', () async {
      final client = (await NativeHttpClient.create(const NativeHttpConfig(enableDatagrams: true)))!;
      expect(cronet.callsTo('createEngine'), hasLength(1));
      expect(urlSession.calls, isEmpty);
      expect(http3.calls, isEmpty);
      expect(() => client.openDatagramSession(url, protocol: 'datagram-echo'), throwsUnsupportedError);
    });
  });

  test('has no client elsewhere', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await NativeHttpClient.create(), isNull);
  });
}
