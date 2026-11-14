import 'package:flutter/services.dart';

import '../channel/channel_http_client.dart';
import '../native_http_config.dart';
import '../native_http_exception.dart';
import 'ns_url_error.dart';

/// Must match `ios/.../ConnectNativeHttpPlugin.swift`.
const nioHttp3MethodChannel = MethodChannel('connect_native_http/http3');
const nioHttp3EventChannel = EventChannel('connect_native_http/http3/events');

const nioHttp3Bridge = PlatformBridge(
  name: 'http3',
  methods: nioHttp3MethodChannel,
  events: nioHttp3EventChannel,
  failure: _nioHttp3Failure,
  supportsDatagrams: true,
);

NativeHttpException _nioHttp3Failure(Map<String, Object?> event) {
  final domain = event['domain']! as String;
  final code = event['code']! as int;
  return NativeHttpException(
    classifyNsUrlError(domain, code),
    '${event['message']} ($domain $code)',
    platformCode: code,
  );
}

/// A connect-dart [HttpClient] on swift-nio-http3, driven by the Swift plugin in `ios/`. Every call goes over HTTP/3.
final class NioHttp3Client extends ChannelHttpClient {
  NioHttp3Client._(int engineId, NativeHttpConfig config) : super(nioHttp3Bridge, engineId, config);

  static Future<NioHttp3Client> create(NativeHttpConfig config) async {
    final idle = config.quicIdleTimeout;
    if (idle != null && idle <= Duration.zero) {
      throw ArgumentError.value(idle, 'quicIdleTimeout', 'must be positive');
    }
    final connect = config.connectTimeout;
    if (connect != null && connect <= Duration.zero) {
      throw ArgumentError.value(connect, 'connectTimeout', 'must be positive');
    }
    final engineId = await ChannelHttpClient.createEngine(nioHttp3Bridge, config, {
      'http3Origins': [
        for (final origin in config.http3Origins) [origin.host, origin.port],
      ],
      'quicIdleTimeoutMs': idle == null ? null : (idle.inMicroseconds / 1000).ceil(),
      'connectTimeoutMs': connect == null ? null : (connect.inMicroseconds / 1000).ceil(),
    });
    return NioHttp3Client._(engineId, config);
  }
}
