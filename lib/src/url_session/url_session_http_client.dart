import 'package:connectrpc/connect.dart';
import 'package:flutter/services.dart';

import '../channel/channel_http_client.dart';
import '../native_http_config.dart';
import '../native_http_exception.dart';
import 'ns_url_error.dart';
import 'response_headers.dart';

/// Must match `ios/.../ConnectNativeHttpPlugin.swift`.
const urlSessionMethodChannel = MethodChannel('connect_native_http/urlsession');
const urlSessionEventChannel = EventChannel('connect_native_http/urlsession/events');

const urlSessionBridge = PlatformBridge(
  name: 'urlsession',
  methods: urlSessionMethodChannel,
  events: urlSessionEventChannel,
  failure: _urlSessionFailure,
  responseHeaders: _responseHeaders,
  // Over HTTP/3, URLSession does not complete a task while its request body is open, even after the server has
  // finished the response and stopped reading.
  endsStreamsItself: false,
);

NativeHttpException _urlSessionFailure(Map<String, Object?> event) {
  final domain = event['domain']! as String;
  final code = event['code']! as int;
  return NativeHttpException(
    classifyNsUrlError(domain, code),
    '${event['message']} ($domain $code)',
    platformCode: code,
  );
}

Headers _responseHeaders(List<(String, String)> pairs) =>
    responseHeaders({for (final (name, value) in pairs) name: value});

/// A connect-dart [HttpClient] on one URLSession, driven by the Swift plugin in `ios/`.
final class UrlSessionHttpClient extends ChannelHttpClient {
  UrlSessionHttpClient._(int engineId, NativeHttpConfig config) : super(urlSessionBridge, engineId, config);

  static Future<UrlSessionHttpClient> create(NativeHttpConfig config) async {
    final engineId = await ChannelHttpClient.createEngine(urlSessionBridge, {
      'http3Origins': [
        for (final origin in config.http3Origins) [origin.host, origin.port],
      ],
    });
    return UrlSessionHttpClient._(engineId, config);
  }
}
