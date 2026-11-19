/// connect-dart HttpClients on the platform HTTP stacks: URLSession on iOS, Cronet on Android. On iOS 27 and later,
/// `NativeHttpConfig.enableDatagrams` switches to swift-nio-http3, which adds HTTP/3 datagram sessions.
library;

export 'src/datagram_session.dart' show DatagramSession, DatagramSessionRejected;
export 'src/native_http_client.dart' show NativeHttpClient;
export 'src/native_http_config.dart' show NativeHttpConfig, NativeHttpResponseInfo;
export 'src/native_http_exception.dart' show NativeHttpException, NativeHttpFailure;
