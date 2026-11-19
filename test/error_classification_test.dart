import 'package:connect_native_http/connect_native_http.dart';
import 'package:connect_native_http/src/cronet/cronet_error.dart';
import 'package:connect_native_http/src/url_session/ns_url_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyNsUrlError', () {
    test('connect-phase failures are notSent', () {
      for (final code in [-1003, -1004, -1006, -1009, -1200]) {
        expect(classifyNsUrlError(nsUrlErrorDomain, code), NativeHttpFailure.notSent, reason: 'code $code');
      }
    });

    test('certificate failures are untrusted', () {
      for (final code in [-1201, -1202, -1203, -1204]) {
        expect(classifyNsUrlError(nsUrlErrorDomain, code), NativeHttpFailure.untrusted, reason: 'code $code');
      }
    });

    test('timeouts and dropped connections may have reached the server', () {
      for (final code in [-1001, -1005, -1011, -999]) {
        expect(classifyNsUrlError(nsUrlErrorDomain, code), NativeHttpFailure.other, reason: 'code $code');
      }
    });

    test('codes from another domain are not interpreted', () {
      expect(classifyNsUrlError('kCFErrorDomainCFNetwork', -1004), NativeHttpFailure.other);
    });
  });

  group('classifyCronetFailure', () {
    test('a failure before the stream was ready is notSent', () {
      expect(classifyCronetFailure(streamReady: false, internalErrorCode: -102), NativeHttpFailure.notSent);
      expect(classifyCronetFailure(streamReady: false, internalErrorCode: null), NativeHttpFailure.notSent);
    });

    test('certificate errors before the stream was ready are untrusted', () {
      for (final code in [-150, -200, -202, -299]) {
        expect(
          classifyCronetFailure(streamReady: false, internalErrorCode: code),
          NativeHttpFailure.untrusted,
          reason: 'code $code',
        );
      }
    });

    test('any failure once the stream was ready may have reached the server', () {
      expect(classifyCronetFailure(streamReady: true, internalErrorCode: -102), NativeHttpFailure.other);
      expect(classifyCronetFailure(streamReady: true, internalErrorCode: -202), NativeHttpFailure.other);
    });
  });

  test('requestNeverSent holds only for notSent and untrusted', () {
    expect(const NativeHttpException(NativeHttpFailure.notSent, '').requestNeverSent, isTrue);
    expect(const NativeHttpException(NativeHttpFailure.untrusted, '').requestNeverSent, isTrue);
    expect(const NativeHttpException(NativeHttpFailure.other, '').requestNeverSent, isFalse);
  });
}
