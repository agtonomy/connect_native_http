import 'package:connect_native_http/connect_native_http.dart';
import 'package:connect_native_http/src/cronet/cronet_http_client.dart';
import 'package:connect_native_http/src/nio_http3/nio_http3_client.dart';
import 'package:connectrpc/connect.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the iOS plugin (HTTP3Bridge): records method calls and lets a test emit the plugin's events.
class FakeHttp3Plugin {
  FakeHttp3Plugin() {
    _messenger.setMockMethodCallHandler(nioHttp3MethodChannel, (call) async {
      calls.add(call);
      if (refusing.contains(call.method)) {
        throw PlatformException(code: 'datagramFailed', message: '${call.method} refused');
      }
      return call.method == 'createEngine' ? 3 : null;
    });
    _messenger.setMockMethodCallHandler(MethodChannel(nioHttp3EventChannel.name), (call) async => null);
  }

  final calls = <MethodCall>[];
  final refusing = <String>{};

  TestDefaultBinaryMessenger get _messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<MethodCall> callsTo(String method) => calls.where((c) => c.method == method).toList();

  int get lastSessionId => callsTo('openDatagrams').last.arguments['callId'] as int;

  Future<void> emit(Map<String, Object?> event) async {
    await _messenger.handlePlatformMessage(
      nioHttp3EventChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  Future<void> headers(int callId, {int status = 200}) => emit({
    'callId': callId,
    'type': 'headers',
    'status': status,
    'protocol': 'h3',
    'headers': [
      ['x-session', 'yes'],
    ],
  });

  Future<void> datagram(int callId, List<int> bytes) =>
      emit({'callId': callId, 'type': 'datagram', 'data': Uint8List.fromList(bytes)});
}

/// Lets queued microtasks and platform-channel replies run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeHttp3Plugin plugin;
  late NioHttp3Client client;
  final url = Uri.parse('https://example.test/datagrams/echo');

  setUp(() async {
    plugin = FakeHttp3Plugin();
    client = await NioHttp3Client.create(const NativeHttpConfig(quicIdleTimeout: Duration(milliseconds: 1500)));
  });

  /// Opens a session and lets the fake server accept it with [status].
  Future<DatagramSession> open({int status = 200}) async {
    final session = client.openDatagramSession(url, protocol: 'datagram-echo', headers: {'authorization': 'x'});
    await settle();
    await plugin.headers(plugin.lastSessionId, status: status);
    return session;
  }

  test('passes the QUIC idle timeout in milliseconds', () {
    expect(plugin.callsTo('createEngine').single.arguments['quicIdleTimeoutMs'], 1500);
  });

  test('opens an Extended CONNECT with the protocol and headers, and completes once the server accepts it', () async {
    final session = await open();
    final args = plugin.callsTo('openDatagrams').single.arguments as Map;
    expect(args['engineId'], 3);
    expect(args['url'], url.toString());
    expect(args['protocol'], 'datagram-echo');
    expect(args['headers'], [
      ['authorization', 'x'],
    ]);
    expect(session.status, 200);
    expect(session.headers['x-session'], 'yes');
  });

  test('delivers datagrams from the server in order, and sends datagrams to the plugin', () async {
    final session = await open();
    final received = <List<int>>[];
    session.datagrams.listen(received.add);
    await plugin.datagram(plugin.lastSessionId, [1]);
    await plugin.datagram(plugin.lastSessionId, [2, 3]);
    await settle();
    expect(received, [
      [1],
      [2, 3],
    ]);

    await session.send(Uint8List.fromList([9]));
    final sent = plugin.callsTo('sendDatagram').single.arguments as Map;
    expect(sent['callId'], plugin.lastSessionId);
    expect(sent['data'], [9]);
  });

  test('close finishes the request stream, and the session ends with the server', () async {
    final session = await open();
    final datagramsDone = session.datagrams.toList();
    await session.close();
    expect(plugin.callsTo('end').single.arguments['callId'], plugin.lastSessionId);

    await plugin.emit({'callId': plugin.lastSessionId, 'type': 'done'});
    await session.done;
    expect(await datagramsDone, isEmpty);
    await expectLater(session.send(Uint8List(1)), throwsA(isA<NativeHttpException>()));
  });

  test('a failed session fails done and the datagram stream', () async {
    final session = await open();
    final datagramsDone = session.datagrams.toList();
    await plugin.emit({
      'callId': plugin.lastSessionId,
      'type': 'failed',
      'domain': 'NSURLErrorDomain',
      'code': -1005,
      'message': 'connection lost',
    });
    await expectLater(session.done, throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.unavailable)));
    await expectLater(datagramsDone, throwsA(isA<ConnectException>()));
  });

  test('a session the server rejects throws DatagramSessionRejected and is canceled', () async {
    await expectLater(
      open(status: 404),
      throwsA(isA<DatagramSessionRejected>().having((e) => e.status, 'status', 404)),
    );
    expect(plugin.callsTo('cancel').single.arguments['callId'], plugin.lastSessionId);
  });

  test('a session that never gets an answer fails with the connection failure', () async {
    final session = client.openDatagramSession(url, protocol: 'datagram-echo');
    await settle();
    await plugin.emit({
      'callId': plugin.lastSessionId,
      'type': 'failed',
      'domain': 'ConnectNativeHttp',
      'code': -2,
      'message': 'the server does not support HTTP datagrams',
    });
    await expectLater(
      session,
      throwsA(isA<ConnectException>().having((e) => e.cause, 'cause', isA<NativeHttpException>())),
    );
  });

  test('a datagram the plugin refuses throws a NativeHttpException', () async {
    final session = await open();
    plugin.refusing.add('sendDatagram');
    await expectLater(session.send(Uint8List(70000)), throwsA(isA<NativeHttpException>()));
  });

  test('Cronet has no datagram sessions', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      cronetMethodChannel,
      (call) async => 1,
    );
    final cronet = await CronetHttpClient.create(const NativeHttpConfig());
    expect(() => cronet.openDatagramSession(url, protocol: 'datagram-echo'), throwsUnsupportedError);
  });
}
