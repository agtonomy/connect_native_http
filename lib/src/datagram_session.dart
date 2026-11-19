import 'dart:typed_data';

import 'package:connectrpc/connect.dart';

/// An HTTP/3 Extended CONNECT (RFC 9220) session that carries HTTP datagrams (RFC 9297) to and from the server. Open
/// one with [NativeHttpClient.openDatagramSession].
///
/// Datagrams are unreliable and unordered: either side may drop or reorder them, and each must fit in one QUIC
/// packet. The session itself is the request stream that opened it, which ends when either side closes it or the
/// connection fails. It shares its connection with the client's other calls and sessions to the same origin.
abstract interface class DatagramSession {
  /// The server's answer to the CONNECT request: a 2xx status, since anything else fails
  /// [NativeHttpClient.openDatagramSession].
  int get status;

  /// The headers of the server's answer.
  Headers get headers;

  /// The datagrams the server sends on this session, as they arrive. Datagrams that arrive while nothing listens are
  /// buffered. The stream ends when the session does, with the session's error if it failed.
  Stream<Uint8List> get datagrams;

  /// Anything the server writes on the session's request stream, such as capsules (RFC 9297 § 3). Most protocols
  /// built on datagrams alone leave it empty. Ends when the session does.
  Stream<Uint8List> get data;

  /// Sends one datagram. Completes once the datagram is handed to QUIC, which says nothing about delivery.
  ///
  /// Throws a [NativeHttpException] if the session has ended or the datagram can't be sent, for example because it is
  /// larger than the connection's maximum datagram size.
  Future<void> send(Uint8List datagram);

  /// Finishes the session's request stream, which asks the server to end the session. [done] completes once it has.
  Future<void> close();

  /// Resets the session's request stream, ending the session at once.
  Future<void> cancel();

  /// Completes when the session ends: normally when the server ends it, after [close] or on its own, or with a
  /// [ConnectException] (`unavailable`, with a [NativeHttpException] cause) if it failed, or `canceled` after
  /// [cancel].
  Future<void> get done;
}

/// The server answered a datagram session's CONNECT request with a status other than 2xx.
final class DatagramSessionRejected implements Exception {
  const DatagramSessionRejected(this.status, this.headers);

  final int status;
  final Headers headers;

  @override
  String toString() => 'DatagramSessionRejected: the server answered $status';
}
