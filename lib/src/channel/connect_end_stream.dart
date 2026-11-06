import 'dart:math';
import 'dart:typed_data';

/// Whether a response with [contentType] is a Connect streaming response, whose body is a sequence of envelopes
/// ending in an end-stream message.
bool isConnectStreamingContentType(String? contentType) =>
    contentType?.trim().toLowerCase().startsWith('application/connect+') ?? false;

/// Finds the end of a Connect streaming response body: the envelope with the end-stream flag (`0x02`).
///
/// Each envelope is a flags byte, a 4-byte big-endian length, then that many bytes. URLSession over HTTP/3 does not
/// complete a task while its request body is still open, even after the server has finished the response, so the
/// end of a bidi call the server ends first is only visible here.
final class ConnectEndStreamDetector {
  static const _headerLength = 5;
  static const _endStreamFlag = 0x02;

  final _header = Uint8List(_headerLength);
  int _headerFilled = 0;
  int _payloadRemaining = 0;
  bool _inEndStream = false;
  bool _done = false;

  /// Whether the end-stream message has been read in full.
  bool get done => _done;

  /// Consumes [chunk] and returns how many of its bytes belong to the response, which is all of them unless the
  /// end-stream message completes inside [chunk]. Bytes after the end-stream message are not part of any message.
  int add(Uint8List chunk) {
    var offset = 0;
    while (offset < chunk.length && !_done) {
      if (_payloadRemaining > 0) {
        final take = min(chunk.length - offset, _payloadRemaining);
        _payloadRemaining -= take;
        offset += take;
        if (_payloadRemaining == 0 && _inEndStream) {
          _done = true;
        }
        continue;
      }
      _header[_headerFilled++] = chunk[offset++];
      if (_headerFilled < _headerLength) {
        continue;
      }
      _headerFilled = 0;
      _inEndStream = _header[0] & _endStreamFlag != 0;
      _payloadRemaining = ByteData.sublistView(_header).getUint32(1);
      if (_payloadRemaining == 0 && _inEndStream) {
        _done = true;
      }
    }
    return offset;
  }
}
