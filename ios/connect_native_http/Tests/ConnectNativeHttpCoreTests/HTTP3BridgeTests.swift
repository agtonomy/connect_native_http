import Foundation
import X509
import XCTest

@testable import ConnectNativeHttpCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// Bridge behavior the Dart integration tests can't reach, on macOS or Linux,, against test_server/. run_integration_tests.sh starts the
// server and passes its URL as SERVER_URL and its CA certificate (DER) as SERVER_CA.
final class HTTP3BridgeTests: XCTestCase {
  private static let converse = "/connectrpc.eliza.v1.ElizaService/Converse"
  private static let say = "/connectrpc.eliza.v1.ElizaService/Say"
  private static let datagramEcho = "/datagrams/echo"

  private var serverURL = ""
  private var bridge: HTTP3Bridge!
  private let lock = NSLock()
  private var events: [[String: Any]] = []
  private var writeReturned = false

  override func setUpWithError() throws {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["SERVER_URL"], let caPath = env["SERVER_CA"] else {
      throw XCTSkip("SERVER_URL and SERVER_CA are not set; run these through run_integration_tests.sh")
    }
    serverURL = url
    let ca = try Certificate(derEncoded: Array(try Data(contentsOf: URL(fileURLWithPath: caPath))))
    bridge = HTTP3Bridge(trustRoots: [ca]) { [weak self] event in
      guard let self else { return }
      lock.withLock { self.events.append(event) }
    }
  }

  // Writes before the connection is up wait for it, and return once it fails.
  func testWritesWaitingForTheConnectionReturnWhenItFails() async throws {
    let engine = try await invoke("createEngine", ["connectTimeoutMs": 500]) as! Int
    // Nothing listens on the discard port, so the QUIC handshake never completes and no stream is opened.
    let unreachable = try XCTUnwrap(URLComponents(string: serverURL)).with(port: 9)
    try await invoke("open", [
      "engineId": engine, "callId": 1, "url": unreachable + Self.say, "method": "POST",
      "headers": [["content-type", "application/proto"]], "hasBody": true,
    ])
    Task {
      try await self.write(1, Data(count: 1 << 20))
      self.lock.withLock { self.writeReturned = true }
    }
    try await waitUntil("the call failed") { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "failed")
    XCTAssertEqual(outcome(1)?["code"] as? Int, -1004, "\(String(describing: outcome(1)))")
    try await waitUntil("the write returned", timeout: 2) { self.lock.withLock { self.writeReturned } }
  }

  func testRedirectOfARequestWithABodyIsReturnedInsteadOfFollowed() async throws {
    let engine = try await createEngine()
    try await open(engine, callId: 1, path: "/redirect" + Self.say, contentType: "application/proto")
    try await write(1, sentence("hi"))
    try await invoke("end", ["callId": 1])
    try await waitUntil("the call ended") { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "done", "\(String(describing: outcome(1)))")
    XCTAssertEqual(event(1, "headers")?["status"] as? Int, 307)
  }

  func testShutdownLetsACallInFlightFinishAndRefusesNewOnes() async throws {
    let engine = try await createEngine()
    try await open(engine, callId: 1, path: Self.converse, contentType: "application/connect+proto")
    try await invoke("shutdownEngine", ["engineId": engine])
    try await write(1, envelope(sentence("bye")))
    try await invoke("end", ["callId": 1])
    try await waitUntil("the call ended") { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "done", "\(String(describing: outcome(1)))")
    XCTAssertTrue(received(1).contains("echo: bye"))

    try await open(engine, callId: 2, path: Self.converse, contentType: "application/connect+proto")
    try await waitUntil("the second call ended") { self.outcome(2) != nil }
    XCTAssertEqual(outcome(2)?["type"] as? String, "failed")
    XCTAssertEqual(outcome(2)?["domain"] as? String, "ConnectNativeHttp")
  }

  func testReadIdleTimeoutFailsAQuietCallAndTheEngineCarriesOn() async throws {
    let engine = try await createEngine()
    // The timeout also covers setting up the connection, which can outlast it on a loaded simulator. A call first
    // leaves a connection for the timed one to reuse.
    try await open(engine, callId: 10, path: Self.say, contentType: "application/proto")
    try await write(10, sentence("warm up"))
    try await invoke("end", ["callId": 10])
    try await waitUntil("the warm-up call ended", timeout: 10) { self.outcome(10) != nil }
    try await open(
      engine, callId: 1, path: Self.converse, contentType: "application/connect+proto", readIdleTimeoutMs: 500)
    try await waitUntil("the greeting arrived") { self.received(1).contains("hello") }
    let start = Date()
    try await waitUntil("the call timed out") { self.outcome(1) != nil }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(outcome(1)?["type"] as? String, "failed", "\(String(describing: outcome(1)))")
    XCTAssertEqual(outcome(1)?["code"] as? Int, NSURLErrorTimedOut)
    XCTAssertLessThan(elapsed, 2, "a 500 ms read-idle timeout took \(elapsed) s")

    // New calls go to a new connection.
    try await open(engine, callId: 2, path: Self.say, contentType: "application/proto")
    try await write(2, sentence("after"))
    try await invoke("end", ["callId": 2])
    try await waitUntil("the next call ended") { self.outcome(2) != nil }
    XCTAssertEqual(outcome(2)?["type"] as? String, "done", "\(String(describing: outcome(2)))")
    XCTAssertTrue(received(2).contains("say: after"))
  }

  // A call that hit its deadline is canceled at once, and moves the engine's new calls to a new connection.
  func testADeadlineCancelEndsTheCallAndTheEngineCarriesOn() async throws {
    let engine = try await createEngine()
    try await open(engine, callId: 1, path: Self.converse, contentType: "application/connect+proto")
    try await waitUntil("the greeting arrived", timeout: 10) { self.received(1).contains("hello") }
    try await invoke("cancel", ["callId": 1, "evictConnection": true])
    try await waitUntil("the call was canceled") { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "canceled", "\(String(describing: outcome(1)))")

    try await open(engine, callId: 2, path: Self.say, contentType: "application/proto")
    try await write(2, sentence("after"))
    try await invoke("end", ["callId": 2])
    try await waitUntil("the next call ended", timeout: 10) { self.outcome(2) != nil }
    XCTAssertEqual(outcome(2)?["type"] as? String, "done", "\(String(describing: outcome(2)))")
  }

  func testMalformedArgumentsAreRefusedInsteadOfCrashing() async throws {
    let malformed: [(String, [String: Any])] = [
      ("open", [:]),
      ("open", ["engineId": "1", "callId": 1, "url": serverURL, "method": "POST", "headers": [[String]](), "hasBody": true]),
      ("open", ["engineId": 1, "callId": 1, "url": serverURL, "method": "POST", "headers": [["one"]], "hasBody": true]),
      ("open", [
        "engineId": 1, "callId": 1, "url": serverURL, "method": "POST", "headers": [[String]](), "hasBody": true,
        "readIdleTimeoutMs": "soon",
      ]),
      ("open", [
        "engineId": 1, "callId": 1, "url": serverURL, "method": "POST", "headers": [[String]](), "hasBody": true,
        "readIdleTimeoutMs": 0,
      ]),
      ("write", ["callId": 1, "data": "not bytes"]),
      ("end", ["callId": "1"]),
      ("cancel", [:]),
      ("cancel", ["callId": 1, "evictConnection": "yes"]),
      ("shutdownEngine", ["engineId": NSNull()]),
      ("createEngine", ["http3Origins": [["localhost"]]]),
      ("createEngine", ["quicIdleTimeoutMs": "soon"]),
      ("createEngine", ["connectTimeoutMs": 0]),
      ("openDatagrams", ["engineId": 1, "callId": 1, "url": serverURL, "headers": [[String]]()]),
      ("openDatagrams", ["engineId": 1, "callId": 1, "url": serverURL, "protocol": 1, "headers": [[String]]()]),
      ("sendDatagram", ["callId": 1]),
      ("sendDatagram", ["callId": 1, "data": "not bytes"]),
    ]
    for (method, arguments) in malformed {
      let result = await reply(method, arguments)
      guard case .error(let code, _) = result else {
        XCTFail("\(method) \(arguments): \(result)")
        continue
      }
      XCTAssertEqual(code, "badArguments")
    }
    // The bridge still works afterwards.
    let engine = try await createEngine()
    try await open(engine, callId: 1, path: Self.say, contentType: "application/proto")
    try await write(1, sentence("hi"))
    try await invoke("end", ["callId": 1])
    try await waitUntil("the call ended") { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "done", "\(String(describing: outcome(1)))")
  }

  func testUnaryCallGoesOverHTTP3() async throws {
    let engine = try await createEngine()
    try await open(engine, callId: 1, path: Self.say, contentType: "application/proto")
    try await write(1, sentence("hi"))
    try await invoke("end", ["callId": 1])
    try await waitUntil("the call ended", timeout: 10) { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "done", "\(String(describing: outcome(1)))")
    let headers = try XCTUnwrap(event(1, "headers"))
    XCTAssertEqual(headers["status"] as? Int, 200)
    XCTAssertEqual(headers["protocol"] as? String, "h3")
    let fields = try XCTUnwrap(headers["headers"] as? [[String]])
    XCTAssertTrue(fields.contains(["x-proto", "HTTP/3.0"]), "\(fields)")
    XCTAssertTrue(received(1).contains("say: hi"))
  }

  // The server ends Converse after "bye" while the client's side is still open. The call ends with the response.
  func testACallEndsWithItsResponseWhileTheRequestIsStillOpen() async throws {
    let engine = try await createEngine()
    try await open(engine, callId: 1, path: Self.converse, contentType: "application/connect+proto")
    try await write(1, envelope(sentence("bye")))
    try await waitUntil("the call ended", timeout: 10) { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "done", "\(String(describing: outcome(1)))")
    XCTAssertTrue(received(1).contains("hello"))
    XCTAssertTrue(received(1).contains("echo: bye"))
  }

  func testCallsShareOneConnection() async throws {
    let engine = try await createEngine()
    for id in 1...3 {
      try await open(engine, callId: id, path: Self.say, contentType: "application/proto")
      try await write(id, sentence("call \(id)"))
      try await invoke("end", ["callId": id])
    }
    try await waitUntil("the calls ended", timeout: 10) { (1...3).allSatisfy { self.outcome($0) != nil } }
    let addresses = Set((1...3).compactMap { id in
      (event(id, "headers")?["headers"] as? [[String]])?.first { $0[0] == "x-remote-addr" }?[1]
    })
    XCTAssertEqual(addresses.count, 1, "\(addresses)")
  }

  // The QUIC stack doesn't say why a TLS handshake failed, so a rejected certificate is a failed secure connection,
  // which was not sent, rather than NSURLErrorServerCertificateUntrusted.
  func testAServerCertificateFromAnotherCAFailsTheSecureConnection() async throws {
    // The system's roots, which don't include the test server's CA.
    let untrusting = HTTP3Bridge { [weak self] event in
      guard let self else { return }
      lock.withLock { self.events.append(event) }
    }
    let engine = try await reply(untrusting, "createEngine", [:]) as! Int
    _ = try await reply(untrusting, "open", [
      "engineId": engine, "callId": 1, "url": serverURL + Self.say, "method": "POST",
      "headers": [["content-type", "application/proto"]], "hasBody": true,
    ])
    try await waitUntil("the call failed", timeout: 10) { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "failed", "\(String(describing: outcome(1)))")
    XCTAssertEqual(outcome(1)?["domain"] as? String, "NSURLErrorDomain")
    XCTAssertEqual(outcome(1)?["code"] as? Int, -1200, "\(String(describing: outcome(1)))")
  }

  // The client's QUIC idle timeout is what notices a dead path: with the server's UDP frozen, a quiet call fails within
  // it, and the next call dials a new connection.
  func testTheQUICIdleTimeoutEndsCallsOnADeadPath() async throws {
    let admin = ProcessInfo.processInfo.environment["ADMIN_URL"] ?? "http://localhost:8081"
    let engine = try await invoke("createEngine", ["quicIdleTimeoutMs": 1000]) as! Int
    try await open(engine, callId: 1, path: Self.converse, contentType: "application/connect+proto")
    try await waitUntil("the greeting arrived", timeout: 10) { self.received(1).contains("hello") }
    try await post(admin + "/freeze?for=10s")
    defer { Task { try? await self.post(admin + "/unfreeze") } }
    let start = Date()
    try await waitUntil("the call failed", timeout: 5) { self.outcome(1) != nil }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(outcome(1)?["type"] as? String, "failed", "\(String(describing: outcome(1)))")
    XCTAssertEqual(outcome(1)?["code"] as? Int, -1005, "\(String(describing: outcome(1)))")
    XCTAssertLessThan(elapsed, 3, "a 1 s QUIC idle timeout took \(elapsed) s")

    try await post(admin + "/unfreeze")
    try await open(engine, callId: 2, path: Self.say, contentType: "application/proto")
    try await write(2, sentence("after"))
    try await invoke("end", ["callId": 2])
    try await waitUntil("the next call ended", timeout: 10) { self.outcome(2) != nil }
    XCTAssertEqual(outcome(2)?["type"] as? String, "done", "\(String(describing: outcome(2)))")
  }

  private func post(_ url: String) async throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
    request.httpMethod = "POST"
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, url)
  }

  // MARK: Datagram sessions

  func testDatagramsEchoOnAnExtendedConnectSession() async throws {
    let engine = try await createEngine()
    try await openDatagrams(engine, callId: 1)
    try await waitUntil("the session was accepted", timeout: 10) { self.event(1, "headers") != nil }
    XCTAssertEqual(event(1, "headers")?["status"] as? Int, 200)
    XCTAssertEqual(event(1, "headers")?["protocol"] as? String, "h3")

    for text in ["one", "two", "three"] {
      try await invoke("sendDatagram", ["callId": 1, "data": Data(text.utf8)])
    }
    // Datagrams are unreliable, but nothing is lost on loopback.
    try await waitUntil("the echoes arrived") { self.datagrams(1).count == 3 }
    XCTAssertEqual(Set(datagrams(1)), ["one", "two", "three"])

    // Finishing the request stream ends the session; the server then closes its side.
    try await invoke("end", ["callId": 1])
    try await waitUntil("the session ended") { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "done", "\(String(describing: outcome(1)))")
  }

  func testDatagramsCanBeSentBeforeTheServerAnswers() async throws {
    let engine = try await createEngine()
    try await openDatagrams(engine, callId: 1)
    // The stream exists once the reply to sendDatagram is a success; until then it is refused.
    try await waitUntil("a datagram was taken", timeout: 10) {
      if case .success = await self.reply("sendDatagram", ["callId": 1, "data": Data("early".utf8)]) {
        return true
      }
      return false
    }
    try await waitUntil("the echo arrived") { self.datagrams(1).contains("early") }
  }

  func testTheServerEndsADatagramSession() async throws {
    let engine = try await createEngine()
    try await openDatagrams(engine, callId: 1)
    try await waitUntil("the session was accepted", timeout: 10) { self.event(1, "headers") != nil }
    try await invoke("sendDatagram", ["callId": 1, "data": Data("close".utf8)])
    try await waitUntil("the session ended") { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "done", "\(String(describing: outcome(1)))")

    if case .success = await reply("sendDatagram", ["callId": 1, "data": Data("late".utf8)]) {
      XCTFail("a datagram was taken for an ended session")
    }
  }

  func testDatagramSessionsAndCallsShareAConnection() async throws {
    let engine = try await createEngine()
    try await openDatagrams(engine, callId: 1)
    try await openDatagrams(engine, callId: 2)
    try await open(engine, callId: 3, path: Self.say, contentType: "application/proto")
    try await write(3, sentence("alongside"))
    try await invoke("end", ["callId": 3])
    try await waitUntil("both sessions were accepted", timeout: 10) {
      self.event(1, "headers") != nil && self.event(2, "headers") != nil
    }
    try await invoke("sendDatagram", ["callId": 1, "data": Data("for one".utf8)])
    try await invoke("sendDatagram", ["callId": 2, "data": Data("for two".utf8)])
    try await waitUntil("the echoes arrived") { !self.datagrams(1).isEmpty && !self.datagrams(2).isEmpty }
    XCTAssertEqual(datagrams(1), ["for one"])
    XCTAssertEqual(datagrams(2), ["for two"])
    try await waitUntil("the call ended") { self.outcome(3) != nil }
    XCTAssertEqual(outcome(3)?["type"] as? String, "done", "\(String(describing: outcome(3)))")

    try await invoke("cancel", ["callId": 1])
    try await waitUntil("the session was canceled") { self.outcome(1) != nil }
    XCTAssertEqual(outcome(1)?["type"] as? String, "canceled")
    // The other session is unaffected.
    try await invoke("sendDatagram", ["callId": 2, "data": Data("still".utf8)])
    try await waitUntil("the echo arrived") { self.datagrams(2).contains("still") }
  }

  func testATooLargeDatagramIsRefused() async throws {
    let engine = try await createEngine()
    try await openDatagrams(engine, callId: 1)
    try await waitUntil("the session was accepted", timeout: 10) { self.event(1, "headers") != nil }
    let result = await reply("sendDatagram", ["callId": 1, "data": Data(count: 64 * 1024)])
    guard case .error(let code, _) = result else {
      XCTFail("a 64 KiB datagram was taken: \(result)")
      return
    }
    XCTAssertEqual(code, "datagramFailed")
    // The session carries on.
    try await invoke("sendDatagram", ["callId": 1, "data": Data("small".utf8)])
    try await waitUntil("the echo arrived") { self.datagrams(1).contains("small") }
  }

  // MARK: Bridge calls

  private func reply(_ method: String, _ arguments: [String: Any]) async -> HTTP3Bridge.Reply {
    await withCheckedContinuation { (done: CheckedContinuation<HTTP3Bridge.Reply, Never>) in
      bridge.handle(method, arguments) { done.resume(returning: $0) }
    }
  }

  private func reply(_ bridge: HTTP3Bridge, _ method: String, _ arguments: [String: Any]) async throws -> Any? {
    let result = await withCheckedContinuation { (done: CheckedContinuation<HTTP3Bridge.Reply, Never>) in
      bridge.handle(method, arguments) { done.resume(returning: $0) }
    }
    guard case .success(let value) = result else {
      XCTFail("\(method): \(result)")
      throw CancellationError()
    }
    return value
  }

  private func openDatagrams(_ engine: Int, callId: Int) async throws {
    try await invoke("openDatagrams", [
      "engineId": engine, "callId": callId, "url": serverURL + Self.datagramEcho, "protocol": "datagram-echo",
      "headers": [["user-agent", "connect_native_http tests"]],
    ])
  }

  @discardableResult
  private func invoke(_ method: String, _ arguments: [String: Any]) async throws -> Any? {
    switch await reply(method, arguments) {
    case .success(let value):
      return value
    case .error(let code, let message):
      XCTFail("\(method): \(code): \(message)")
      throw CancellationError()
    case .notImplemented:
      throw XCTSkip("\(method) is not implemented")
    }
  }

  private func createEngine() async throws -> Int {
    let url = try XCTUnwrap(URL(string: serverURL))
    let origin: [Any] = [url.host!, url.port ?? 443]
    return try await invoke("createEngine", ["http3Origins": [origin]]) as! Int
  }

  private func open(
    _ engine: Int, callId: Int, path: String, contentType: String, readIdleTimeoutMs: Int? = nil
  ) async throws {
    var arguments: [String: Any] = [
      "engineId": engine, "callId": callId, "url": serverURL + path, "method": "POST",
      "headers": [["content-type", contentType], ["connect-protocol-version", "1"]], "hasBody": true,
    ]
    arguments["readIdleTimeoutMs"] = readIdleTimeoutMs
    try await invoke("open", arguments)
  }

  private func write(_ callId: Int, _ data: Data) async throws {
    try await invoke("write", ["callId": callId, "data": data])
  }

  // MARK: Events

  private func snapshot() -> [[String: Any]] {
    lock.withLock { events }
  }

  private func event(_ callId: Int, _ type: String) -> [String: Any]? {
    snapshot().first { $0["callId"] as? Int == callId && $0["type"] as? String == type }
  }

  private func outcome(_ callId: Int) -> [String: Any]? {
    snapshot().first {
      $0["callId"] as? Int == callId && ["done", "failed", "canceled"].contains($0["type"] as? String ?? "")
    }
  }

  /// The datagrams received on a session so far, as text.
  private func datagrams(_ callId: Int) -> [String] {
    snapshot().filter { $0["callId"] as? Int == callId && $0["type"] as? String == "datagram" }.map {
      String(decoding: $0["data"] as! Data, as: UTF8.self)
    }
  }

  /// The response body so far, as text; Connect framing and protobuf leave the sentences readable.
  private func received(_ callId: Int) -> String {
    var body = Data()
    for e in snapshot() where e["callId"] as? Int == callId && e["type"] as? String == "data" {
      body.append(e["data"] as! Data)
    }
    return String(decoding: body, as: UTF8.self)
  }

  private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
      if Date() > deadline {
        XCTFail("timed out after \(timeout) s waiting until \(what); events: \(snapshot())")
        throw CancellationError()
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}

extension URLComponents {
  fileprivate func with(port: Int) -> String {
    var copy = self
    copy.port = port
    return copy.string!
  }
}

/// A `SayRequest` or `ConverseRequest`: field 1, the sentence.
private func sentence(_ text: String) -> Data {
  let utf8 = Data(text.utf8)
  precondition(utf8.count < 128)
  return Data([0x0A, UInt8(utf8.count)]) + utf8
}

/// A Connect streaming message: flags, big-endian length, payload.
private func envelope(_ payload: Data) -> Data {
  let n = UInt32(payload.count)
  return Data([0, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + payload
}
