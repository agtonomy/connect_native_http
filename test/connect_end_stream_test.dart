import 'dart:typed_data';

import 'package:connect_native_http/src/channel/connect_end_stream.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List envelope(int flags, List<int> payload) {
  final header = ByteData(5)
    ..setUint8(0, flags)
    ..setUint32(1, payload.length);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...payload]);
}

void main() {
  test('recognizes Connect streaming content types only', () {
    expect(isConnectStreamingContentType('application/connect+proto'), isTrue);
    expect(isConnectStreamingContentType('Application/Connect+JSON; charset=utf-8'), isTrue);
    expect(isConnectStreamingContentType('application/proto'), isFalse);
    expect(isConnectStreamingContentType('application/grpc'), isFalse);
    expect(isConnectStreamingContentType(null), isFalse);
  });

  test('data messages do not end the stream', () {
    final detector = ConnectEndStreamDetector();
    final chunk = Uint8List.fromList([
      ...envelope(0, [1, 2, 3]),
      ...envelope(0x01, [4]),
    ]);
    expect(detector.add(chunk), chunk.length);
    expect(detector.done, isFalse);
  });

  test('finds the end-stream message split across chunks', () {
    final detector = ConnectEndStreamDetector();
    final bytes = [
      ...envelope(0, [9, 9]),
      ...envelope(0x02, '{}'.codeUnits),
    ];
    for (final b in bytes.take(bytes.length - 1)) {
      expect(detector.add(Uint8List.fromList([b])), 1);
      expect(detector.done, isFalse);
    }
    expect(detector.add(Uint8List.fromList([bytes.last])), 1);
    expect(detector.done, isTrue);
  });

  test('a compressed end-stream message ends the stream', () {
    final detector = ConnectEndStreamDetector()..add(envelope(0x03, [7, 7, 7]));
    expect(detector.done, isTrue);
  });

  test('an empty end-stream message ends the stream', () {
    final detector = ConnectEndStreamDetector()..add(envelope(0x02, []));
    expect(detector.done, isTrue);
  });

  test('reports only the bytes up to the end of the end-stream message', () {
    final detector = ConnectEndStreamDetector();
    final end = envelope(0x02, '{}'.codeUnits);
    final chunk = Uint8List.fromList([
      ...envelope(0, [1]),
      ...end,
      0xff,
      0xff,
    ]);
    expect(detector.add(chunk), chunk.length - 2);
    expect(detector.done, isTrue);
  });

  test('payload bytes that look like an end-stream header do not end the stream', () {
    final detector = ConnectEndStreamDetector();
    final payload = envelope(0x02, []);
    expect(detector.add(envelope(0, payload)), 5 + payload.length);
    expect(detector.done, isFalse);
  });
}
