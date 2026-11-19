import 'package:connect_native_http/src/url_session/response_headers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('responseHeaders', () {
    test('drops the encoding headers of a body URLSession already decoded', () {
      final headers = responseHeaders({
        'Content-Type': 'application/proto',
        'Content-Encoding': 'gzip',
        'Content-Length': '42',
        'X-Proto': 'HTTP/3.0',
      });
      expect(headers.get('content-encoding'), isNull);
      expect(headers.get('content-length'), isNull);
      expect(headers.get('content-type'), ['application/proto']);
      expect(headers.get('x-proto'), ['HTTP/3.0']);
    });

    test('keeps an encoding URLSession does not decode, for connect-dart to handle or reject', () {
      final headers = responseHeaders({'Content-Encoding': 'zstd', 'Content-Length': '42'});
      expect(headers.get('content-encoding'), ['zstd']);
      expect(headers.get('content-length'), ['42']);
    });

    test('keeps Content-Length of an unencoded body', () {
      expect(responseHeaders({'Content-Length': '7'}).get('content-length'), ['7']);
    });
  });
}
