// Runs connect_native_http's platform client against ../test_server on a device or simulator. Start it through
// ../run_integration_tests.sh, which starts the server, trusts its CA on the device and passes these defines.
import 'dart:async';
import 'dart:io' as io;

import 'package:connect_native_http/connect_native_http.dart';
import 'package:connect_native_http_example/gen/connectrpc/eliza/v1/eliza.connect.client.dart';
import 'package:connect_native_http_example/gen/connectrpc/eliza/v1/eliza.pb.dart';
import 'package:connectrpc/connect.dart';
import 'package:connectrpc/protobuf.dart';
import 'package:connectrpc/protocol/connect.dart' as connect_protocol;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The test server, as the device reaches it.
const serverUrl = String.fromEnvironment('SERVER_URL');

/// `X-Proto` the server must report once the client has had a chance to switch protocols, such as `HTTP/3.0`.
/// Empty skips the check.
const expectedProtocol = String.fromEnvironment('EXPECT_PROTOCOL');

/// A port nothing listens on, so the connection is refused.
const unreachableUrl = String.fromEnvironment('UNREACHABLE_URL');

/// The test server under a name its certificate does not cover.
const untrustedUrl = String.fromEnvironment('UNTRUSTED_URL');

/// The test server's plain-HTTP admin endpoint, which can freeze its HTTP/3 path (test_server/freeze.go).
const adminUrl = String.fromEnvironment('ADMIN_URL');

/// The QUIC idle timeout the test server advertises (its -max-idle).
const serverMaxIdle = Duration(seconds: int.fromEnvironment('SERVER_MAX_IDLE_SECONDS'));

/// The gap the server leaves between Introduce sentences (introduceInterval in test_server/eliza.go).
const introduceInterval = Duration(milliseconds: 100);

final class Harness {
  Harness._(this.native, this.eliza);

  static Future<Harness> create(String baseUrl, {Set<Uri> http3Origins = const {}}) async {
    late final Harness harness;
    final native = await NativeHttpClient.create(
      NativeHttpConfig(http3Origins: http3Origins, onResponse: (info) => harness.platformProtocols.add(info.protocol)),
    );
    if (native == null) {
      throw StateError('no native client on this platform');
    }
    final transport = connect_protocol.Transport(
      baseUrl: baseUrl,
      codec: const ProtoCodec(),
      httpClient: native.httpClient,
    );
    return harness = Harness._(native, ElizaServiceClient(transport));
  }

  final NativeHttpClient native;
  final ElizaServiceClient eliza;

  /// What the platform reported for each response, where it reports anything.
  final platformProtocols = <String?>[];

  /// `X-Proto` of each response: the protocol the server saw.
  final serverProtocols = <String>[];

  void recordHeaders(Headers headers) => serverProtocols.add(headers.get('x-proto')?.join(',') ?? '');
}

/// Every case finishes in a few seconds against a local server (most well under one); a hang should fail fast.
void testCase(String description, WidgetTesterCallback body, {Duration timeout = const Duration(seconds: 10)}) =>
    testWidgets(description, body, timeout: Timeout(timeout));

Future<void> admin(String path) async {
  final client = io.HttpClient();
  try {
    final response = await (await client.postUrl(Uri.parse('$adminUrl$path'))).close();
    expect(response.statusCode, 200, reason: 'POST $adminUrl$path');
    await response.drain<void>();
  } finally {
    client.close();
  }
}

/// Opens Converse and reads the server's greeting. Nothing flows afterwards until the caller sends.
Future<(StreamController<ConverseRequest>, StreamIterator<ConverseResponse>)> openQuietConverse(Harness harness) async {
  final requests = StreamController<ConverseRequest>();
  final responses = StreamIterator(harness.eliza.converse(requests.stream, onHeader: harness.recordHeaders));
  expect(await responses.moveNext(), isTrue);
  expect(responses.current.sentence, 'hello');
  return (requests, responses);
}

/// A client whose pooled connection to the server negotiated [protocol], such as `HTTP/3.0`.
///
/// URLSession races QUIC against TCP for each new connection and keeps whichever connects first, so on a loaded
/// device a connection sometimes lands on HTTP/2 even for an HTTP/3 origin. A client keeps reusing the connection it
/// has, so each attempt uses a fresh client, closing the ones that got another protocol. Each attempt is that
/// client's first call, before any Alt-Svc: reaching HTTP/3 shows the client tried QUIC because of http3Origins.
Future<Harness> harnessNegotiating(String protocol) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  final protocols = <String>[];
  while (true) {
    final harness = await Harness.create(serverUrl, http3Origins: {Uri.parse(serverUrl)});
    await harness.eliza.say(SayRequest(sentence: 'which protocol'), onHeader: harness.recordHeaders);
    final negotiated = harness.serverProtocols.last;
    if (negotiated == protocol) {
      if (protocols.isNotEmpty) {
        // Not a failure, but worth seeing in CI's log: how often a local HTTP/3 connection lost the race to TCP.
        debugPrint('negotiated $protocol after ${protocols.length} other connections: $protocols');
      }
      addTearDown(harness.native.close);
      return harness;
    }
    protocols.add(negotiated);
    await harness.native.close();
    if (DateTime.now().isAfter(deadline)) {
      fail('no connection negotiated $protocol in ${protocols.length} attempts: $protocols');
    }
  }
}

Future<NativeHttpException> nativeCause(Future<Object?> call) async {
  try {
    await call;
  } on ConnectException catch (e) {
    expect(e.code, Code.unavailable, reason: '$e');
    final cause = e.cause;
    if (cause is NativeHttpException) {
      return cause;
    }
    fail('cause is ${cause.runtimeType}, not NativeHttpException: $e');
  }
  fail('the call succeeded');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Harness harness;

  // One call on a throwaway client before any case. Right after the app launches, the simulator and the test server
  // on the same CI runner are both slow (a QUIC connection took 66 ms to set up, and the server answered its first
  // packet 130 ms after it was sent), so the first call's QUIC attempt loses URLSession's race to TCP. The cases then
  // start on a warm app and server. The protocol it got is logged, not checked.
  //
  // A few attempts, each on a fresh client whose call a deadline cancels: on a freshly booted simulator, trustd can
  // stall every certificate check for a while (once while it updated its pinning database from a trust data update).
  // Three 8 s attempts stay inside the test framework's 30 s default timeout.
  setUpAll(() async {
    if (serverUrl.isEmpty) {
      return; // setUp reports it.
    }
    const attempts = 3;
    final errors = <Object>[];
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final warmup = await Harness.create(serverUrl, http3Origins: {Uri.parse(serverUrl)});
      try {
        await warmup.eliza.say(
          SayRequest(sentence: 'warm up'),
          signal: TimeoutSignal(const Duration(seconds: 8)),
          onHeader: warmup.recordHeaders,
        );
        debugPrint('warm-up call $attempt went over ${warmup.serverProtocols.single}');
        return;
      } on ConnectException catch (e) {
        debugPrint('warm-up call $attempt failed: $e');
        errors.add(e);
      } finally {
        await warmup.native.close();
      }
    }
    fail('no warm-up call succeeded in $attempts attempts: $errors');
  });

  setUp(() async {
    expect(serverUrl, isNotEmpty, reason: 'run with --dart-define=SERVER_URL=...');
    final origin = Uri.parse(serverUrl);
    harness = await Harness.create(serverUrl, http3Origins: {origin});
  });

  tearDown(() => harness.native.close());

  testCase('unary call', (_) async {
    final res = await harness.eliza.say(SayRequest(sentence: 'hi'), onHeader: harness.recordHeaders);
    expect(res.sentence, 'say: hi');
    expect(harness.serverProtocols.single, startsWith('HTTP/'));
  });

  testCase('unary error code comes through', (_) async {
    await expectLater(
      harness.eliza.say(SayRequest(sentence: 'error:failed_precondition')),
      throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.failedPrecondition)),
    );
  });

  testCase('a deadline ends a call the server holds', (_) async {
    final stopwatch = Stopwatch()..start();
    await expectLater(
      harness.eliza.say(SayRequest(sentence: 'sleep:5000'), signal: TimeoutSignal(const Duration(milliseconds: 300))),
      throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.deadlineExceeded)),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  testCase('server stream delivers each message as it is sent', (_) async {
    final arrivals = <DateTime>[];
    final sentences = <String>[];
    await for (final res in harness.eliza.introduce(IntroduceRequest(name: 'ann'))) {
      arrivals.add(DateTime.now());
      sentences.add(res.sentence);
    }
    expect(sentences, ['ann 0', 'ann 1', 'ann 2', 'ann 3', 'ann 4']);
    // A client that buffered the response would deliver all five within a few milliseconds.
    expect(arrivals.last.difference(arrivals.first), greaterThanOrEqualTo(introduceInterval * 3));
  });

  testCase('server stream error after messages', (_) async {
    final sentences = <String>[];
    await expectLater(
      harness.eliza.introduce(IntroduceRequest(name: 'error')).forEach((res) => sentences.add(res.sentence)),
      throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.failedPrecondition)),
    );
    expect(sentences, ['error 0', 'error 1']);
  });

  testCase('bidi stream is full duplex, and the server can finish first', (_) async {
    final requests = StreamController<ConverseRequest>();
    final responses = StreamIterator(harness.eliza.converse(requests.stream, onHeader: harness.recordHeaders));

    // The server speaks before the client sends anything.
    expect(await responses.moveNext(), isTrue);
    expect(responses.current.sentence, 'hello');

    // Each reply arrives while the request side is still open.
    for (final sentence in ['one', 'two']) {
      requests.add(ConverseRequest(sentence: sentence));
      expect(await responses.moveNext(), isTrue);
      expect(responses.current.sentence, 'echo: $sentence');
    }

    // The server ends the call after "bye" while the request side is still open.
    requests.add(ConverseRequest(sentence: 'bye'));
    expect(await responses.moveNext(), isTrue);
    expect(responses.current.sentence, 'echo: bye');
    expect(await responses.moveNext(), isFalse);
    await requests.close();
  });

  testCase('a refused connection is reported as never sent', (_) async {
    expect(unreachableUrl, isNotEmpty, reason: 'run with --dart-define=UNREACHABLE_URL=...');
    final unreachable = await Harness.create(unreachableUrl);
    addTearDown(unreachable.native.close);
    final cause = await nativeCause(unreachable.eliza.say(SayRequest(sentence: 'hi')));
    expect(cause.failure, NativeHttpFailure.notSent, reason: '$cause');
    expect(cause.requestNeverSent, isTrue);
  });

  testCase('a certificate for another name is rejected as untrusted', (_) async {
    expect(untrustedUrl, isNotEmpty, reason: 'run with --dart-define=UNTRUSTED_URL=...');
    final untrusted = await Harness.create(untrustedUrl);
    addTearDown(untrusted.native.close);
    final cause = await nativeCause(untrusted.eliza.say(SayRequest(sentence: 'hi')));
    expect(cause.failure, NativeHttpFailure.untrusted, reason: '$cause');
  });

  testCase('negotiates the expected protocol', (_) async {
    if (expectedProtocol.isEmpty) {
      markTestSkipped('EXPECT_PROTOCOL not set');
      return;
    }
    // Fresh clients, since one that connected over HTTP/2 keeps that connection. A loaded simulator sometimes lets
    // TCP win the race even on this local path (a QUIC handshake held 150 ms in certificate verification while TCP
    // started 100 ms in and finished first), so one fallback isn't a failure; never reaching HTTP/3 is.
    await harnessNegotiating(expectedProtocol);
  });

  // The idle-timeout cases freeze the server's UDP path, so they only apply where calls go over HTTP/3.
  bool skipUnlessHttp3() {
    if (expectedProtocol != 'HTTP/3.0' || adminUrl.isEmpty || serverMaxIdle == Duration.zero) {
      markTestSkipped('needs EXPECT_PROTOCOL=HTTP/3.0, ADMIN_URL and SERVER_MAX_IDLE_SECONDS');
      return true;
    }
    return false;
  }

  // Up to 5 s of harnessNegotiating on top of the case itself, which waits up to 7 s for the idle timeout.
  const http3CaseTimeout = Duration(seconds: 20);

  testCase('a quiet HTTP/3 stream outlives the idle timeout while the server pings', (_) async {
    if (skipUnlessHttp3()) {
      return;
    }
    final h3 = await harnessNegotiating('HTTP/3.0');
    final (requests, responses) = await openQuietConverse(h3);
    expect(h3.serverProtocols.last, 'HTTP/3.0');
    await Future<void>.delayed(serverMaxIdle * 2);
    requests.add(ConverseRequest(sentence: 'still there'));
    expect(await responses.moveNext(), isTrue);
    expect(responses.current.sentence, 'echo: still there');
    await requests.close();
  }, timeout: http3CaseTimeout);

  testCase('a unary call the server holds longer than the idle timeout completes', (_) async {
    // A long-running unary call: nothing flows until the reply, so only the server's pings keep the connection from
    // going idle.
    if (skipUnlessHttp3()) {
      return;
    }
    final h3 = await harnessNegotiating('HTTP/3.0');
    final hold = serverMaxIdle * 2 + const Duration(seconds: 1);
    final res = await h3.eliza.say(
      SayRequest(sentence: 'sleep:${hold.inMilliseconds}'),
      signal: TimeoutSignal(const Duration(seconds: 10)),
      onHeader: h3.recordHeaders,
    );
    expect(res.sentence, 'say: sleep:${hold.inMilliseconds}');
    expect(h3.serverProtocols.last, 'HTTP/3.0');
  }, timeout: http3CaseTimeout);

  testCase('a dead HTTP/3 path fails an open stream', (_) async {
    if (skipUnlessHttp3()) {
      return;
    }
    final h3 = await harnessNegotiating('HTTP/3.0');
    final (requests, responses) = await openQuietConverse(h3);
    expect(h3.serverProtocols.last, 'HTTP/3.0');
    addTearDown(() => admin('/unfreeze'));
    await admin('/freeze?for=60s');

    final stopwatch = Stopwatch()..start();
    await expectLater(
      responses.moveNext(),
      throwsA(isA<ConnectException>().having((e) => e.code, 'code', Code.unavailable)),
    );
    // QUIC uses the smaller of the two endpoints' idle timeouts, so the server's bounds the client's. On the iOS 18.4
    // simulator a 3 s server value was detected in 2.98 s.
    expect(stopwatch.elapsed, lessThan(serverMaxIdle + const Duration(seconds: 2)));
    await requests.close();
  }, timeout: http3CaseTimeout);
}
