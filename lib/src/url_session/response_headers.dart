import 'package:connectrpc/connect.dart';

/// Content codings URLSession decodes itself. It advertises them on every request and decodes the response body
/// before handing it over, but leaves `Content-Encoding` in place, which connect-dart would try to decode again.
const _decodedEncodings = {'gzip', 'deflate', 'br'};

/// The response headers connect-dart should see, without the encoding headers of a body URLSession already decoded.
Headers responseHeaders(Map<String, String> allHeaderFields) {
  String? field(String name) =>
      allHeaderFields.entries.where((e) => e.key.toLowerCase() == name).map((e) => e.value).firstOrNull;
  final decoded = _decodedEncodings.contains(field('content-encoding')?.trim().toLowerCase());
  final headers = Headers();
  allHeaderFields.forEach((name, value) {
    final lower = name.toLowerCase();
    if (decoded && (lower == 'content-encoding' || lower == 'content-length')) {
      return;
    }
    headers.add(lower, value);
  });
  return headers;
}
