import 'dart:io';

import 'package:connectrpc/connect.dart';

import 'cronet/cronet_http_client.dart';
import 'native_http_config.dart';
import 'url_session/url_session_http_client.dart';

/// A connect-dart [HttpClient] on the platform's own HTTP stack, which negotiates HTTP/3 or HTTP/2 itself and
/// carries full-duplex streams. Use it with the Connect protocol (`package:connectrpc/protocol/connect.dart`): the
/// platform stacks do not expose HTTP trailers, which the gRPC protocol needs.
///
/// Requests fail with a `ConnectException` of code `unavailable` whose `cause` is a [NativeHttpException].
abstract interface class NativeHttpClient {
  /// The client for this platform, or `null` where there is none (anything but iOS and Android).
  static Future<NativeHttpClient?> create([NativeHttpConfig config = const NativeHttpConfig()]) async {
    if (Platform.isIOS) {
      return UrlSessionHttpClient.create(config);
    }
    if (Platform.isAndroid) {
      return CronetHttpClient.create(config);
    }
    return null;
  }

  HttpClient get httpClient;

  /// Lets requests in flight finish and releases the platform resources. Do not send requests after this.
  Future<void> close();
}
