import 'package:flutter/services.dart';

import '../channel/channel_http_client.dart';
import '../native_http_config.dart';
import '../native_http_exception.dart';
import 'cronet_error.dart';

/// Must match `ConnectNativeHttpPlugin.kt`.
const cronetMethodChannel = MethodChannel('connect_native_http/cronet');
const cronetEventChannel = EventChannel('connect_native_http/cronet/events');

const cronetBridge = PlatformBridge(
  name: 'cronet',
  methods: cronetMethodChannel,
  events: cronetEventChannel,
  failure: _cronetFailure,
);

NativeHttpException _cronetFailure(Map<String, Object?> event) {
  final internalErrorCode = event['internalErrorCode'] as int?;
  return NativeHttpException(
    classifyCronetFailure(streamReady: event['streamReady']! as bool, internalErrorCode: internalErrorCode),
    'cronet: ${event['message']}',
    platformCode: internalErrorCode,
  );
}

/// A connect-dart [HttpClient] on one Cronet engine, through Cronet's `BidirectionalStream` (the plugin in
/// `android/`). `package:cronet_http` cannot serve here: it uses `UrlRequest`, which reads the whole request body
/// before sending it.
final class CronetHttpClient extends ChannelHttpClient {
  CronetHttpClient._(int engineId, NativeHttpConfig config) : super(cronetBridge, engineId, config);

  static Future<CronetHttpClient> create(NativeHttpConfig config) async {
    final idle = config.quicIdleTimeout;
    if (idle != null && idle < const Duration(seconds: 1)) {
      throw ArgumentError.value(idle, 'quicIdleTimeout', 'Cronet takes whole seconds; use at least 1 s');
    }
    final engineId = await ChannelHttpClient.createEngine(cronetBridge, config, {
      'quicHints': [
        for (final origin in config.http3Origins) [origin.host, origin.port],
      ],
      'quicIdleTimeoutSeconds': idle?.inSeconds,
    });
    return CronetHttpClient._(engineId, config);
  }
}
