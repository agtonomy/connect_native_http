import 'dart:io';

import 'package:connectrpc/connect.dart';

import 'cronet/cronet_http_client.dart';
import 'datagram_session.dart';
import 'native_http_config.dart';
import 'nio_http3/nio_http3_client.dart';

/// A connect-dart [HttpClient] for full-duplex streams over HTTP/3: swift-nio-http3 on iOS, which speaks HTTP/3 only,
/// and Cronet on Android, which negotiates HTTP/3 or HTTP/2 itself. Use it with the Connect protocol
/// (`package:connectrpc/protocol/connect.dart`): Cronet does not expose HTTP trailers, which the gRPC protocol needs.
///
/// Requests fail with a `ConnectException` of code `unavailable` whose `cause` is a [NativeHttpException].
abstract interface class NativeHttpClient {
  /// The client for this platform, or `null` where there is none (anything but iOS 27+ and Android).
  ///
  /// Throws a `PlatformException` if the platform can't create one, such as when Android fails to load Cronet's native
  /// library. An app can fall back to another `HttpClient` then.
  static Future<NativeHttpClient?> create([NativeHttpConfig config = const NativeHttpConfig()]) async {
    if (Platform.isIOS) {
      return NioHttp3Client.create(config);
    }
    if (Platform.isAndroid) {
      return CronetHttpClient.create(config);
    }
    return null;
  }

  HttpClient get httpClient;

  /// Opens an HTTP/3 datagram session: an Extended CONNECT request (RFC 9220) to [url] with `:protocol` [protocol],
  /// on which both sides may then send HTTP datagrams (RFC 9297). Completes once the server has accepted it with a 2xx
  /// status.
  ///
  /// Throws a `ConnectException` with code `unavailable` and a [NativeHttpException] cause if the session can't be set
  /// up, including when the server's HTTP/3 SETTINGS don't offer datagrams and Extended CONNECT, and
  /// [DatagramSessionRejected] if the server answers with another status.
  ///
  /// iOS only: throws [UnsupportedError] on Android, where Cronet has no HTTP datagrams.
  Future<DatagramSession> openDatagramSession(
    Uri url, {
    required String protocol,
    Map<String, String> headers = const {},
  });

  /// Lets requests in flight finish and releases the platform resources. Do not send requests after this.
  Future<void> close();
}
