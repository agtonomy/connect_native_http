// HTTP/3 against a server with a publicly trusted certificate, which Cronet requires before it will use QUIC. Opt-in
// because it needs the internet and a third-party server:
//   fvm flutter test integration_test/public_server_test.dart -d <device> \
//     --dart-define=PUBLIC_ELIZA_URL=https://demo.connectrpc.com
import 'dart:async';
import 'dart:io';

import 'package:connect_native_http/connect_native_http.dart';
import 'package:connect_native_http_example/gen/connectrpc/eliza/v1/eliza.connect.client.dart';
import 'package:connect_native_http_example/gen/connectrpc/eliza/v1/eliza.pb.dart';
import 'package:connectrpc/connect.dart';
import 'package:connectrpc/protobuf.dart';
import 'package:connectrpc/protocol/connect.dart' as connect_protocol;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// A real ELIZA, such as Connect's demo server.
const publicElizaUrl = String.fromEnvironment('PUBLIC_ELIZA_URL');

/// What Cronet reports for HTTP/3. URLSession reports nothing, so the check only applies on Android.
const cronetHttp3 = 'quic/1+spdy/3';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late NativeHttpClient native;
  late ElizaServiceClient eliza;
  final protocols = <String?>[];

  setUp(() async {
    if (publicElizaUrl.isEmpty) {
      return;
    }
    protocols.clear();
    native = (await NativeHttpClient.create(
      NativeHttpConfig(http3Origins: {Uri.parse(publicElizaUrl)}, onResponse: (info) => protocols.add(info.protocol)),
    ))!;
    eliza = ElizaServiceClient(
      connect_protocol.Transport(baseUrl: publicElizaUrl, codec: const ProtoCodec(), httpClient: native.httpClient),
    );
  });

  void expectHttp3() {
    if (Platform.isAndroid) {
      expect(protocols, isNotEmpty);
      expect(protocols, everyElement(cronetHttp3));
    }
  }

  testWidgets('unary over HTTP/3', (_) async {
    if (publicElizaUrl.isEmpty) {
      markTestSkipped('PUBLIC_ELIZA_URL not set');
      return;
    }
    final res = await eliza.say(SayRequest(sentence: 'hello'));
    expect(res.sentence, isNotEmpty);
    expectHttp3();
    await native.close();
  }, timeout: const Timeout(Duration(seconds: 20)));

  testWidgets('full-duplex bidi over HTTP/3', (_) async {
    if (publicElizaUrl.isEmpty) {
      markTestSkipped('PUBLIC_ELIZA_URL not set');
      return;
    }
    final requests = StreamController<ConverseRequest>();
    final responses = StreamIterator(eliza.converse(requests.stream));
    for (final sentence in ['I feel happy', 'I am testing QUIC']) {
      requests.add(ConverseRequest(sentence: sentence));
      // Each reply arrives before the next request is sent.
      expect(await responses.moveNext(), isTrue);
      expect(responses.current.sentence, isNotEmpty);
    }
    await requests.close();
    while (await responses.moveNext()) {}
    expectHttp3();
    await native.close();
  }, timeout: const Timeout(Duration(seconds: 20)));

  const quicIdle = Duration(seconds: 3);

  /// Opens Converse on a client with [quicIdleTimeout] and reads the reply to one sentence, after which the server
  /// sends nothing until the client does.
  Future<(NativeHttpClient, StreamController<ConverseRequest>, StreamIterator<ConverseResponse>)> quietConverse(
    Duration? quicIdleTimeout,
  ) async {
    final client = (await NativeHttpClient.create(
      NativeHttpConfig(
        http3Origins: {Uri.parse(publicElizaUrl)},
        quicIdleTimeout: quicIdleTimeout,
        onResponse: (info) => protocols.add(info.protocol),
      ),
    ))!;
    final eliza = ElizaServiceClient(
      connect_protocol.Transport(baseUrl: publicElizaUrl, codec: const ProtoCodec(), httpClient: client.httpClient),
    );
    final requests = StreamController<ConverseRequest>();
    final responses = StreamIterator(eliza.converse(requests.stream));
    requests.add(ConverseRequest(sentence: 'hello'));
    expect(await responses.moveNext(), isTrue);
    expectHttp3();
    return (client, requests, responses);
  }

  bool skipUnlessAndroid() {
    if (publicElizaUrl.isEmpty || !Platform.isAndroid) {
      markTestSkipped('PUBLIC_ELIZA_URL not set, or not Android: URLSession has no idle timeout setting');
      return true;
    }
    return false;
  }

  testWidgets('the client QUIC idle timeout ends a quiet connection', (_) async {
    if (skipUnlessAndroid()) {
      return;
    }
    final (client, requests, responses) = await quietConverse(quicIdle);
    final stopwatch = Stopwatch()..start();
    await expectLater(responses.moveNext(), throwsA(isA<ConnectException>()));
    expect(stopwatch.elapsed, lessThan(quicIdle + const Duration(seconds: 3)));
    await requests.close();
    await client.close();
  }, timeout: const Timeout(Duration(seconds: 20)));

  testWidgets('without the setting the same quiet connection survives', (_) async {
    // The control for the previous case: the server keeps a quiet stream open, so the setting is what closed it.
    if (skipUnlessAndroid()) {
      return;
    }
    final (client, requests, responses) = await quietConverse(null);
    await Future<void>.delayed(quicIdle * 2 + const Duration(seconds: 2));
    requests.add(ConverseRequest(sentence: 'still there'));
    expect(await responses.moveNext(), isTrue);
    await requests.close();
    await client.close();
  }, timeout: const Timeout(Duration(seconds: 20)));
}
