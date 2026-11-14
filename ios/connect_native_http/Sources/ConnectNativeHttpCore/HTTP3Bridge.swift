import Foundation
import HTTP3
import HTTPTypes
import Logging
import NIOCore
import NIOHTTP3
import NIOHTTPTypes
import NIOPosix
import NIOQUIC
import NIOQUICHelpers
import X509

// Bridges swift-nio-http3 to lib/src/nio_http3/nio_http3_client.dart, one HTTP/3 request stream per call,
// with the same channel protocol as the Android bridge. Dart sends request chunks as method calls; response headers,
// body chunks and the outcome go to `emit`. Kept free of Flutter so it can be tested without a Flutter app, on macOS
// or Linux.
//
// Datagram sessions add to that protocol: `openDatagrams` opens an Extended CONNECT (RFC 9220) request stream, and
// `sendDatagram` sends an HTTP datagram (RFC 9297) on it. Datagrams from the server arrive as `datagram` events. The
// session is otherwise a call like any other: `headers` with the server's answer, `data` with anything it writes on
// the stream, `end` and `cancel` to close it, and `done`, `failed` or `canceled` when it ends.
//
// Failures are reported in `NSURLErrorDomain` codes, which lib/src/nio_http3/ns_url_error.dart already classifies.
//
// Everything runs on one event loop, `loop`: the bridge's state, and every channel of every connection.
public final class HTTP3Bridge: @unchecked Sendable {
  public enum Reply {
    case success(Any?)
    /// The call's arguments were not what the method takes. Refused rather than force-unwrapped, which would crash the
    /// app.
    case error(code: String, message: String)
    case notImplemented
  }

  struct BadArgument: Error {
    let name: String
  }

  private let emit: ([String: Any]) -> Void
  /// When set, replaces the system trust store; tests use it for their own CA.
  private let trustRoots: [Certificate]?
  let loop: any EventLoop
  private let logger: Logger

  /// How long a new connection may take to resolve and finish its QUIC handshake, unless its engine sets its own. QUIC
  /// itself waits out its idle timeout before giving up on a server that never answers, and ignores ICMP errors.
  var connectTimeout: TimeAmount = .seconds(10)

  private var engines: [Int: Engine] = [:]
  private var calls: [Int: Call] = [:]
  private var nextEngineId = 1

  public convenience init(emit: @escaping ([String: Any]) -> Void) {
    self.init(trustRoots: nil, emit: emit)
  }

  init(trustRoots: [Certificate]?, emit: @escaping ([String: Any]) -> Void) {
    self.trustRoots = trustRoots
    self.emit = emit
    self.loop = MultiThreadedEventLoopGroup.singleton.next()
    var logger = Logger(label: "connect_native_http")
    logger.logLevel = .critical
    self.logger = logger
  }

  /// Handles one method call. `reply` may be called on any thread.
  public func handle(_ method: String, _ args: [String: Any], reply: @escaping (Reply) -> Void) {
    do {
      try dispatch(method, args, reply: reply)
    } catch let bad as BadArgument {
      reply(.error(code: "badArguments", message: "\(method): missing or mistyped argument \(bad.name)"))
    } catch {
      reply(.error(code: "badArguments", message: "\(method): \(error)"))
    }
  }

  private func arg<T>(_ args: [String: Any], _ name: String) throws -> T {
    guard let value = args[name] as? T else { throw BadArgument(name: name) }
    return value
  }

  /// An optional argument that must be a positive integer when present; absent or null for none.
  private func optionalPositiveInt(_ args: [String: Any], _ name: String) throws -> Int? {
    guard let value = args[name], !(value is NSNull) else { return nil }
    guard let n = value as? Int, n > 0 else { throw BadArgument(name: name) }
    return n
  }

  private func headerList(_ args: [String: Any]) throws -> [[String]] {
    let headers: [[String]] = try arg(args, "headers")
    guard headers.allSatisfy({ $0.count == 2 }) else { throw BadArgument(name: "headers") }
    return headers
  }

  private func dispatch(_ method: String, _ args: [String: Any], reply: @escaping (Reply) -> Void) throws {
    switch method {
    case "createEngine":
      // Every call goes over HTTP/3, so the origins that serve it need no list. Still checked, as the Dart client
      // sends it.
      let origins = args["http3Origins"] as? [[Any]] ?? []
      guard origins.allSatisfy({ $0.count == 2 }) else { throw BadArgument(name: "http3Origins") }
      let quicIdleTimeoutMs = try optionalPositiveInt(args, "quicIdleTimeoutMs")
      let connectTimeoutMs = try optionalPositiveInt(args, "connectTimeoutMs")
      loop.execute {
        let id = self.nextEngineId
        self.nextEngineId += 1
        self.engines[id] = Engine(
          id: id, quicIdleTimeoutMs: quicIdleTimeoutMs, connectTimeout: connectTimeoutMs.map { .milliseconds(Int64($0)) })
        reply(.success(id))
      }
    case "shutdownEngine":
      let engineId: Int = try arg(args, "engineId")
      loop.execute {
        // Calls in flight finish on their connections, which close once they have none left.
        guard let engine = self.engines.removeValue(forKey: engineId) else { return }
        for connection in engine.connections.values {
          self.retire(connection)
        }
        engine.connections = [:]
      }
      reply(.success(nil))
    case "open", "openDatagrams":
      let engineId: Int = try arg(args, "engineId")
      let callId: Int = try arg(args, "callId")
      let url: String = try arg(args, "url")
      let headers = try headerList(args)
      let readIdleTimeoutMs = try optionalPositiveInt(args, "readIdleTimeoutMs")
      let kind: Call.Kind
      if method == "open" {
        let httpMethod: String = try arg(args, "method")
        kind = .request(method: httpMethod)
      } else {
        let proto: String = try arg(args, "protocol")
        kind = .datagrams(protocol: proto)
      }
      loop.execute { self.open(engineId, callId, url, kind, headers, readIdleTimeoutMs) }
      reply(.success(nil))
    case "write":
      let callId: Int = try arg(args, "callId")
      let data: Data = try arg(args, "data")
      // Replies once the bytes are written to the stream, so a fast producer waits for the network.
      loop.execute {
        guard let call = self.calls[callId] else {
          reply(.success(nil))
          return
        }
        call.write(.body(ByteBuffer(bytes: data))) { reply(.success(nil)) }
      }
    case "end":
      let callId: Int = try arg(args, "callId")
      loop.execute {
        self.calls[callId]?.write(.end(nil)) {}
      }
      reply(.success(nil))
    case "sendDatagram":
      let callId: Int = try arg(args, "callId")
      let data: Data = try arg(args, "data")
      loop.execute { self.sendDatagram(callId, data, reply: reply) }
    case "cancel":
      let callId: Int = try arg(args, "callId")
      // Set when the call hit its deadline. The server was given a deadline a step earlier, so on a live connection
      // its deadline_exceeded would have ended the call first.
      let value = args["evictConnection"]
      guard value == nil || value is NSNull || value is Bool else { throw BadArgument(name: "evictConnection") }
      let evict = value as? Bool ?? false
      loop.execute {
        guard let call = self.calls[callId] else { return }
        if evict {
          self.evictConnection(of: call)
        }
        self.finish(call, ["callId": callId, "type": "canceled"])
      }
      reply(.success(nil))
    default:
      reply(.notImplemented)
    }
  }

  static func now() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  // MARK: Engines and connections

  private final class Engine {
    let id: Int
    let quicIdleTimeoutMs: Int?
    let connectTimeout: TimeAmount?
    // The connection new calls to each origin ("host:port") go to.
    var connections: [String: Connection] = [:]

    init(id: Int, quicIdleTimeoutMs: Int?, connectTimeout: TimeAmount?) {
      self.id = id
      self.quicIdleTimeoutMs = quicIdleTimeoutMs
      self.connectTimeout = connectTimeout
    }
  }

  /// One QUIC connection to an origin, on a UDP socket of its own, so closing that socket ends everything on it.
  final class Connection {
    let origin: String
    let host: String
    let port: Int
    var udp: (any Channel)?
    var channel: (any Channel)?
    var h3: HTTP3ClientConnection<Void, NIOQUIC.QUICStreamCreator>?
    /// Succeeds once the connection can carry requests; fails if it can't be set up.
    let ready: EventLoopPromise<Void>
    /// Succeeds with the server's SETTINGS, which an Extended CONNECT has to wait for (RFC 9220 § 3).
    let settings: EventLoopPromise<ReceivedSettings>
    var calls: [Int: Call] = [:]
    var datagramSessions: [QUICStreamID: Call] = [:]
    var isReady = false
    /// Taken out of its engine's pool: it closes once its last call ends.
    var retired = false
    var closed = false
    /// When this connection last received anything, in uptime nanoseconds.
    var lastReceived: UInt64 = 0

    init(origin: String, host: String, port: Int, loop: any EventLoop) {
      self.origin = origin
      self.host = host
      self.port = port
      self.ready = loop.makePromise()
      self.settings = loop.makePromise()
    }
  }

  private func connection(for engine: Engine, host: String, port: Int) -> Connection {
    let origin = "\(host.lowercased()):\(port)"
    if let existing = engine.connections[origin], !existing.closed {
      return existing
    }
    let connection = Connection(origin: origin, host: host, port: port, loop: loop)
    engine.connections[origin] = connection
    connect(connection, quicIdleTimeoutMs: engine.quicIdleTimeoutMs)
    let timeout = engine.connectTimeout ?? connectTimeout
    loop.scheduleTask(in: timeout) {
      if !connection.isReady && !connection.closed {
        self.connectionFailed(connection, ConnectError.timedOut(timeout))
      }
    }
    return connection
  }

  private func connect(_ connection: Connection, quicIdleTimeoutMs: Int?) {
    let loop = self.loop
    let host = connection.host
    let port = connection.port
    // getaddrinfo blocks, so it runs on NIO's thread pool.
    let resolved = NIOThreadPool.singleton.runIfActive(eventLoop: loop) {
      try SocketAddress.makeAddressResolvingHost(host, port: port)
    }
    resolved.whenFailure { error in
      self.connectionFailed(connection, ConnectError.resolve(error))
    }
    resolved.whenSuccess { address in
      do {
        try self.dial(connection, address: address, quicIdleTimeoutMs: quicIdleTimeoutMs)
      } catch {
        self.connectionFailed(connection, ConnectError.connect(error))
      }
    }
  }

  enum ConnectError: Error {
    case resolve(any Error)
    case connect(any Error)
    case timedOut(TimeAmount)
  }

  private func quicConfiguration(quicIdleTimeoutMs: Int?) -> QUICConfiguration {
    var configuration = QUICConfiguration.forClient(
      verificationConfiguration: .x509Certificates(trustRootsFilePath: nil),
      applicationProtocols: ["h3"]
    )
    if let ms = quicIdleTimeoutMs {
      configuration.maxIdleTimeout = .milliseconds(ms)
    }
    return configuration
  }

  private func dial(_ connection: Connection, address: SocketAddress, quicIdleTimeoutMs: Int?) throws {
    let configuration = quicConfiguration(quicIdleTimeoutMs: quicIdleTimeoutMs)
    let verifier =
      if let trustRoots {
        try AsyncVerifier(trustRoots: trustRoots, eventLoop: loop)
      } else {
        AsyncVerifier(eventLoop: loop)
      }
    let logger = self.logger
    let bindHost = address.protocol == .inet6 ? "::" : "0.0.0.0"
    let serverName = connection.host
    DatagramBootstrap(group: loop)
      .channelInitializer { udp in
        udp.eventLoop.makeCompletedFuture {
          let quic = QUICHandler(
            channel: udp,
            quicConfiguration: configuration,
            asyncVerifier: verifier,
            authenticator: nil,
            logger: logger,
            inboundConnectionInitializer: { _, _ in
              udp.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
            },
            inboundStreamInitializer: Self.inboundStream,
            noMoreConnections: {}
          )
          try udp.pipeline.syncOperations.addHandler(quic)
        }
      }
      .bind(host: bindHost, port: 0)
      .whenComplete { result in
        switch result {
        case .failure(let error):
          self.connectionFailed(connection, ConnectError.connect(error))
        case .success(let udp):
          connection.udp = udp
          if connection.closed {
            // Retired, or its engine shut down, while it was dialing.
            udp.close(promise: nil)
            return
          }
          self.handshake(connection, udp: udp, serverName: serverName, address: address)
        }
      }
  }

  // Unidirectional streams the server opens (control, QPACK) go to the connection's HTTP/3 handler.
  private static let inboundStream: @Sendable (any Channel) -> EventLoopFuture<Void> = { stream in
    stream.parent!.pipeline.handler(
      type: HTTP3ConnectionHandler<NIOQUIC.QUICStreamCreator, HTTP3ClosureInboundStreamInitializer>.self
    ).flatMap { $0.inboundStreamReceived(stream) }
  }

  private func handshake(_ connection: Connection, udp: any Channel, serverName: String, address: SocketAddress) {
    let logger = self.logger
    let handler = ConnectionHandler(bridge: self, connection: connection)
    let quic: QUICHandler<QUICStreamChannels>
    do {
      quic = try udp.pipeline.syncOperations.handler(type: QUICHandler<QUICStreamChannels>.self)
    } catch {
      connectionFailed(connection, ConnectError.connect(error))
      return
    }
    let established = quic.createOutboundConnection(
      serverName: serverName,
      remoteAddress: address,
      connectionInitializer: { channel, streamCreator in
        channel.eventLoop.makeCompletedFuture {
          let h3: HTTP3ClientConnection<Void, NIOQUIC.QUICStreamCreator> = try channel.pipeline.syncOperations
            .configureAsyncHTTP3ClientPipeline(
              settings: HTTP3Settings(h3Datagram: true),
              streamCreator: streamCreator,
              logger: logger,
              inboundPushStreamInitializer: { _ in }
            )
          try channel.pipeline.syncOperations.addHandler(handler)
          connection.h3 = h3
        }
      },
      inboundStreamInitializer: Self.inboundStream
    )
    established.whenComplete { result in
      switch result {
      case .failure(let error):
        self.connectionFailed(connection, ConnectError.connect(error))
      case .success(let (channel, _)):
        connection.channel = channel
        connection.lastReceived = Self.now()
        channel.closeFuture.whenComplete { _ in self.connectionClosed(connection) }
        if connection.closed {
          channel.close(promise: nil)
          return
        }
        connection.isReady = true
        connection.ready.succeed(())
      }
    }
  }

  private func connectionFailed(_ connection: Connection, _ error: any Error) {
    connection.ready.fail(error)
    connection.settings.fail(error)
    connectionClosed(connection)
  }

  /// The connection ended, by either side or because it could not be set up. Its calls fail as their streams close.
  fileprivate func connectionClosed(_ connection: Connection) {
    connection.ready.fail(ChannelError.ioOnClosedChannel)
    connection.settings.fail(ChannelError.ioOnClosedChannel)
    if !connection.closed {
      connection.closed = true
      for engine in engines.values where engine.connections[connection.origin] === connection {
        engine.connections.removeValue(forKey: connection.origin)
      }
    }
    connection.udp?.close(promise: nil)
    for call in connection.calls.values where call.stream == nil {
      // Still waiting for the connection; those with a stream fail when it closes.
      fail(call, connection.channel == nil ? .cannotConnectToHost : .networkConnectionLost, "connection closed")
    }
  }

  /// Takes `connection` out of new calls' way. It closes once the calls on it have ended.
  private func retire(_ connection: Connection) {
    connection.retired = true
    for engine in engines.values where engine.connections[connection.origin] === connection {
      engine.connections.removeValue(forKey: connection.origin)
    }
    closeIfIdle(connection)
  }

  private func closeIfIdle(_ connection: Connection) {
    guard connection.retired, connection.calls.isEmpty, !connection.closed else { return }
    connection.closed = true
    if let channel = connection.channel {
      // Closing the QUIC connection channel sends CONNECTION_CLOSE; the UDP socket follows in connectionClosed.
      channel.close(promise: nil)
    } else {
      connection.udp?.close(promise: nil)
    }
  }

  // A call that ran out of time (its read-idle timeout, or its deadline) may be stuck on a dead connection. It is
  // taken to be if nothing has arrived on the call's connection, on any call, since the call last received anything;
  // otherwise only that call was slow. The engine's new calls then go to a new connection, and the old one closes once
  // the calls still on it have ended. Calls that time out together on the same dead connection replace it once.
  private func evictConnection(of call: Call) {
    guard let connection = call.connection, !connection.retired, !connection.closed else { return }
    if connection.lastReceived > call.lastReceived {
      return
    }
    retire(connection)
  }

  // MARK: Calls

  final class Call {
    enum Kind {
      case request(method: String)
      case datagrams(protocol: String)
    }

    let callId: Int
    let kind: Kind
    var connection: Connection?
    var stream: (any Channel)?
    var streamID: QUICStreamID?
    /// Request parts written before the stream existed, sent once it does.
    var pending: [(HTTPRequestPart, () -> Void)] = []
    var ended = false
    var finished = false
    /// When the call last received anything, or started, in uptime nanoseconds.
    var lastReceived = HTTP3Bridge.now()
    var readIdleTimeoutMs: Int?
    var idleTimer: Scheduled<Void>?
    /// Why the stream failed, when it reports an error before it closes.
    var streamError: (any Error)?

    init(callId: Int, kind: Kind) {
      self.callId = callId
      self.kind = kind
    }

    var isDatagramSession: Bool {
      if case .datagrams = kind { return true }
      return false
    }

    /// Writes `part` to the stream, or queues it until the stream exists. `done` runs once it is written, or the call
    /// has ended, so a caller waiting on it never hangs.
    func write(_ part: HTTPRequestPart, done: @escaping () -> Void) {
      if finished || ended {
        done()
        return
      }
      if case .end = part {
        ended = true
      }
      guard let stream else {
        pending.append((part, done))
        return
      }
      stream.writeAndFlush(part).whenComplete { _ in done() }
    }

    func flushPending() {
      guard let stream else { return }
      let parts = pending
      pending = []
      for (part, done) in parts {
        stream.write(part).whenComplete { _ in done() }
      }
      stream.flush()
    }

    func releasePending() {
      let parts = pending
      pending = []
      for (_, done) in parts {
        done()
      }
    }
  }

  private func failure(_ callId: Int, domain: String, code: Int, message: String) -> [String: Any] {
    ["callId": callId, "type": "failed", "domain": domain, "code": code, "message": message]
  }

  private func open(
    _ engineId: Int, _ callId: Int, _ url: String, _ kind: Call.Kind, _ headers: [[String]], _ readIdleTimeoutMs: Int?
  ) {
    guard let engine = engines[engineId], let components = URLComponents(string: url), let host = components.host,
      !host.isEmpty
    else {
      emit(failure(
        callId, domain: "ConnectNativeHttp", code: 0, message: "engine \(engineId) is shut down or \(url) is invalid"))
      return
    }
    guard components.scheme?.lowercased() == "https" else {
      emit(failure(
        callId, domain: NSURLErrorDomainName, code: URLError.unsupportedURL.rawValue,
        message: "\(url): only https is served, over HTTP/3"))
      return
    }
    let request: HTTPRequest
    do {
      request = try Self.request(kind, components: components, host: host, headers: headers)
    } catch {
      // As Cronet does, a request the stack can't send fails without being sent.
      emit(failure(
        callId, domain: NSURLErrorDomainName, code: URLError.badURL.rawValue, message: "\(url): \(error)"))
      return
    }

    let call = Call(callId: callId, kind: kind)
    call.readIdleTimeoutMs = readIdleTimeoutMs
    calls[callId] = call
    scheduleIdleCheck(call)
    let connection = self.connection(for: engine, host: host, port: components.port ?? 443)
    attach(call, to: connection, request: request, engine: engine, retried: false)
  }

  private func attach(_ call: Call, to connection: Connection, request: HTTPRequest, engine: Engine, retried: Bool) {
    call.connection = connection
    connection.calls[call.callId] = call
    var ready = connection.ready.futureResult
    if call.isDatagramSession {
      ready = ready.flatMap { connection.settings.futureResult }.flatMapThrowing { settings in
        guard settings.extendedConnectSupported, settings.datagramsSupported else {
          throw DatagramsUnsupported(settings: settings)
        }
      }
    }
    ready.whenComplete { result in
      guard !call.finished else { return }
      switch result {
      case .failure(let error as DatagramsUnsupported):
        self.fail(call, domain: "ConnectNativeHttp", code: -2, error.description)
      case .failure(let error):
        let (code, message) = Self.connectFailure(error)
        self.fail(call, code, message)
      case .success:
        self.startStream(call, on: connection, request: request, engine: engine, retried: retried)
      }
    }
  }

  struct DatagramsUnsupported: Error, CustomStringConvertible {
    let settings: ReceivedSettings
    var description: String {
      "the server does not support HTTP datagrams over Extended CONNECT (SETTINGS_H3_DATAGRAM "
        + "\(settings.datagramsSupported), SETTINGS_ENABLE_CONNECT_PROTOCOL \(settings.extendedConnectSupported))"
    }
  }

  private func startStream(
    _ call: Call, on connection: Connection, request: HTTPRequest, engine: Engine, retried: Bool
  ) {
    guard let h3 = connection.h3 else {
      fail(call, .cannotConnectToHost, "connection closed")
      return
    }
    let handler = StreamHandler(bridge: self, call: call)
    let loop = self.loop
    let created = loop.makeFutureWithTask {
      try await h3.createRequestStream { parameters in
        // A server that has its answer may stop reading the request (STOP_SENDING, which quic-go sends whenever a
        // handler returns before reading the whole body). Without this option, that closes the whole stream, response
        // and all; with it, only the request side.
        parameters.channel.setOption(.halfCloseOnStopSending, value: true).flatMapThrowing {
          try parameters.channel.pipeline.syncOperations.addHandler(handler)
          return (parameters.channel, parameters.streamID)
        }
      }
    }
    created.whenComplete { result in
      switch result {
      case .failure(let error):
        guard !call.finished else { return }
        connection.calls.removeValue(forKey: call.callId)
        // The server sent GOAWAY, or the connection is going away: no stream was opened, so nothing was sent. One
        // retry on a new connection.
        if !retried, engine === self.engines[engine.id] {
          self.retire(connection)
          let fresh = self.connection(for: engine, host: connection.host, port: connection.port)
          self.attach(call, to: fresh, request: request, engine: engine, retried: true)
        } else {
          self.fail(call, .cannotConnectToHost, "could not open a request stream: \(error)")
          self.closeIfIdle(connection)
        }
      case .success(let (stream, streamID)):
        if call.finished {
          stream.close(promise: nil)
          return
        }
        call.stream = stream
        call.streamID = streamID
        if call.isDatagramSession {
          connection.datagramSessions[streamID] = call
        }
        // The head first, then anything Dart wrote meanwhile.
        call.pending.insert((.head(request), {}), at: 0)
        call.flushPending()
      }
    }
  }

  static func request(_ kind: Call.Kind, components: URLComponents, host: String, headers: [[String]]) throws
    -> HTTPRequest
  {
    var authority = host.contains(":") ? "[\(host)]" : host
    if let port = components.port, port != 443 {
      authority += ":\(port)"
    }
    var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    if let query = components.percentEncodedQuery {
      path += "?\(query)"
    }
    var fields = HTTPFields()
    for header in headers {
      let lower = header[0].lowercased()
      // Connection-specific fields are not allowed in HTTP/3 (RFC 9114 § 4.2), and the authority is :authority.
      if Self.connectionSpecific.contains(lower) || (lower == "te" && header[1].lowercased() != "trailers") {
        continue
      }
      guard let name = HTTPField.Name(header[0]) else {
        throw InvalidHeader(name: header[0])
      }
      guard HTTPField.isValidValue(header[1]) else {
        throw InvalidHeader(name: header[0])
      }
      fields.append(HTTPField(name: name, value: header[1]))
    }
    switch kind {
    case .request(let method):
      guard let method = HTTPRequest.Method(method) else { throw InvalidHeader(name: ":method") }
      return HTTPRequest(method: method, scheme: "https", authority: authority, path: path, headerFields: fields)
    case .datagrams(let proto):
      var request = HTTPRequest(method: .connect, scheme: "https", authority: authority, path: path, headerFields: fields)
      request.extendedConnectProtocol = proto
      return request
    }
  }

  struct InvalidHeader: Error, CustomStringConvertible {
    let name: String
    var description: String { "invalid header \(name)" }
  }

  private static let connectionSpecific: Set<String> = [
    "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
  ]

  // MARK: Stream events, on `loop`

  fileprivate func received(_ call: Call) {
    let now = Self.now()
    call.lastReceived = now
    call.connection?.lastReceived = now
  }

  fileprivate func didReceive(_ part: HTTPResponsePart, for call: Call) {
    guard !call.finished else { return }
    received(call)
    switch part {
    case .head(let response):
      // Interim responses (1xx) carry nothing the caller needs.
      if response.status.kind == .informational {
        return
      }
      let headers = response.headerFields.map { [$0.name.canonicalName, $0.value] }
      emit([
        "callId": call.callId, "type": "headers", "status": response.status.code, "protocol": "h3",
        "headers": headers,
      ])
    case .body(let buffer):
      emit(["callId": call.callId, "type": "data", "data": Data(buffer.readableBytesView)])
    case .end(let trailers):
      if let trailers, !trailers.isEmpty {
        emit([
          "callId": call.callId, "type": "trailers", "headers": trailers.map { [$0.name.canonicalName, $0.value] },
        ])
      }
      // The whole response is in, so the call is over, even while its request body is still open.
      finish(call, ["callId": call.callId, "type": "done"])
    }
  }

  fileprivate func streamClosed(_ call: Call) {
    guard !call.finished else { return }
    let message = call.streamError.map { "stream closed: \($0)" } ?? "stream closed before the response ended"
    fail(call, .networkConnectionLost, message)
  }

  fileprivate func didReceive(_ datagram: HTTP3Datagram, on connection: Connection) {
    connection.lastReceived = Self.now()
    guard let call = connection.datagramSessions[datagram.streamID], !call.finished else { return }
    received(call)
    emit(["callId": call.callId, "type": "datagram", "data": Data(datagram.payload.readableBytesView)])
  }

  fileprivate func didReceive(_ settings: ReceivedSettings, on connection: Connection) {
    connection.lastReceived = Self.now()
    connection.settings.succeed(settings)
  }

  private func sendDatagram(_ callId: Int, _ data: Data, reply: @escaping (Reply) -> Void) {
    guard let call = calls[callId], call.isDatagramSession else {
      reply(.error(code: "datagramFailed", message: "no open datagram session \(callId)"))
      return
    }
    guard let channel = call.connection?.channel, let streamID = call.streamID else {
      reply(.error(code: "datagramFailed", message: "datagram session \(callId) is not open yet"))
      return
    }
    let datagram = HTTP3Datagram(streamID: streamID, payload: ByteBuffer(bytes: data))
    channel.writeAndFlush(datagram).whenComplete { result in
      switch result {
      case .success:
        reply(.success(nil))
      case .failure(let error):
        reply(.error(code: "datagramFailed", message: "\(error)"))
      }
    }
  }

  // MARK: Ending calls

  private func fail(_ call: Call, _ code: URLError.Code, _ message: String) {
    fail(call, domain: NSURLErrorDomainName, code: code.rawValue, message)
  }

  private func fail(_ call: Call, domain: String, code: Int, _ message: String) {
    finish(call, failure(call.callId, domain: domain, code: code, message: message))
  }

  /// Ends `call` with `event`, its last, and releases everything it holds.
  private func finish(_ call: Call, _ event: [String: Any]) {
    guard !call.finished else { return }
    call.finished = true
    calls.removeValue(forKey: call.callId)
    call.idleTimer?.cancel()
    call.idleTimer = nil
    call.releasePending()
    if let stream = call.stream {
      // Resets the stream if it is still open either way.
      stream.close(promise: nil)
    }
    if let connection = call.connection {
      connection.calls.removeValue(forKey: call.callId)
      if let streamID = call.streamID {
        connection.datagramSessions.removeValue(forKey: streamID)
      }
      closeIfIdle(connection)
    }
    emit(event)
  }

  // MARK: Read-idle timeout

  private func scheduleIdleCheck(_ call: Call) {
    guard let ms = call.readIdleTimeoutMs else { return }
    let timeout = UInt64(ms) * 1_000_000
    let elapsed = Self.now() &- call.lastReceived
    let remaining = elapsed >= timeout ? 0 : timeout - elapsed
    call.idleTimer = loop.scheduleTask(in: .nanoseconds(Int64(remaining))) {
      guard !call.finished else { return }
      if Self.now() &- call.lastReceived >= timeout {
        self.evictConnection(of: call)
        self.fail(call, .timedOut, "received nothing for \(ms) ms")
      } else {
        self.scheduleIdleCheck(call)
      }
    }
  }

  // MARK: Error mapping

  /// The `NSURLErrorDomain` code and message for a connection that could not be set up. None of these sent the
  /// request.
  static func connectFailure(_ error: any Error) -> (URLError.Code, String) {
    switch error {
    case ConnectError.resolve(let cause):
      return (.cannotFindHost, "\(cause)")
    case ConnectError.timedOut(let timeout):
      return (.cannotConnectToHost, "no QUIC handshake within \(timeout.nanoseconds / 1_000_000) ms")
    case ConnectError.connect(let cause):
      // The QUIC stack closes a connection whose TLS handshake failed with CRYPTO_ERROR 0x100 and nothing more, so a
      // certificate it rejected can't be told apart from other TLS failures. URLSession reports those as
      // NSURLErrorSecureConnectionFailed.
      if let error = cause as? QUICConnectionError, !error.isApplication, (0x100...0x1FF).contains(error.code) {
        return (.secureConnectionFailed, "TLS handshake failed: \(error.reason) (CRYPTO_ERROR \(error.code))")
      }
      return (.cannotConnectToHost, "\(cause)")
    default:
      return (.cannotConnectToHost, "\(error)")
    }
  }
}

/// `NSURLErrorDomain`, spelled out: swift-corelibs-foundation names the constant differently.
let NSURLErrorDomainName = "NSURLErrorDomain"

// MARK: Channel handlers

/// On a connection channel, after its HTTP/3 handler: routes the connection's datagrams and SETTINGS to the bridge.
private final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTP3Datagram

  private let bridge: HTTP3Bridge
  private let connection: HTTP3Bridge.Connection

  init(bridge: HTTP3Bridge, connection: HTTP3Bridge.Connection) {
    self.bridge = bridge
    self.connection = connection
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    bridge.didReceive(unwrapInboundIn(data), on: connection)
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let settings = event as? ReceivedSettings {
      bridge.didReceive(settings, on: connection)
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    // The connection closes after a connection error; its calls fail as their streams close.
    context.fireErrorCaught(error)
  }
}

/// On a request stream channel: hands the response to the bridge.
private final class StreamHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPResponsePart
  typealias OutboundOut = HTTPRequestPart

  private let bridge: HTTP3Bridge
  private let call: HTTP3Bridge.Call

  init(bridge: HTTP3Bridge, call: HTTP3Bridge.Call) {
    self.bridge = bridge
    self.call = call
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    bridge.didReceive(unwrapInboundIn(data), for: call)
  }

  // The stream closes after an error that ends it; it reports that error first. Others, such as the server's
  // STOP_SENDING once it has its answer, leave the response to be read.
  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    call.streamError = error
  }

  func channelInactive(context: ChannelHandlerContext) {
    bridge.streamClosed(call)
    context.fireChannelInactive()
  }
}
