import Foundation
import XCTest

@testable import ConnectNativeHttpCore

// Bridge behavior the Dart integration tests can't reach, against test_server/. run_integration_tests.sh starts the
// server, passes its URL as SERVER_URL and installs its CA in the simulator's trust store; the bridge only uses that
// store.
final class URLSessionBridgeTests: XCTestCase {
  private static let converse = "/connectrpc.eliza.v1.ElizaService/Converse"
  private static let say = "/connectrpc.eliza.v1.ElizaService/Say"

  private var serverURL = ""
  private var bridge: URLSessionBridge!
  private let lock = NSLock()
  private var events: [[String: Any]] = []
  private var writeReturned = false

  override func setUpWithError() throws {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["SERVER_URL"] else {
      throw XCTSkip("SERVER_URL is not set; run these through run_integration_tests.sh")
    }
    serverURL = url
    bridge = URLSessionBridge { [weak self] event in
      guard let self else { return }
      lock.withLock { self.events.append(event) }
    }
  }

  func testWriteWaitingOnAFullBufferReturnsOnceTheCallIsCanceled() async throws {
    let engine = try await createEngine()
    try await open(engine, callId: 1, path: Self.converse, contentType: "application/connect+proto")
    try await write(1, envelope(sentence("stall")))
    try await waitUntil("the server stopped reading") { self.received(1).contains("echo: stall") }

    Task {
      try await self.write(1, Data(count: 32 << 20))
      self.lock.withLock { self.writeReturned = true }
    }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertFalse(lock.withLock { writeReturned }, "32 MiB fit in the buffers before a server that stopped reading")

    try await invoke("cancel", ["callId": 1])
    try await waitUntil("the call was canceled") { self.event(1, "canceled") != nil }
    try await waitUntil("the write returned", timeout: 2) { self.lock.withLock { self.writeReturned } }
  }

  func testWriteWaitingOnAFullBufferReturnsWhenTheConnectionFails() async throws {
    let engine = try await createEngine()
    // Nothing listens on the discard port, so URLSession fails the task without ever opening the body stream.
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

  // MARK: Bridge calls

  @discardableResult
  private func invoke(_ method: String, _ arguments: [String: Any]) async throws -> Any? {
    let reply = await withCheckedContinuation { (done: CheckedContinuation<URLSessionBridge.Reply, Never>) in
      bridge.handle(method, arguments) { done.resume(returning: $0) }
    }
    guard case .success(let value) = reply else {
      throw XCTSkip("\(method) is not implemented")
    }
    return value
  }

  private func createEngine() async throws -> Int {
    let url = try XCTUnwrap(URL(string: serverURL))
    let origin: [Any] = [url.host!, url.port ?? 443]
    return try await invoke("createEngine", ["http3Origins": [origin]]) as! Int
  }

  private func open(_ engine: Int, callId: Int, path: String, contentType: String) async throws {
    try await invoke("open", [
      "engineId": engine, "callId": callId, "url": serverURL + path, "method": "POST",
      "headers": [["content-type", contentType], ["connect-protocol-version", "1"]], "hasBody": true,
    ])
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

  /// The response body so far, as text; Connect framing and protobuf leave the sentences readable.
  private func received(_ callId: Int) -> String {
    var body = Data()
    for e in snapshot() where e["callId"] as? Int == callId && e["type"] as? String == "data" {
      body.append(e["data"] as! Data)
    }
    return String(decoding: body, as: UTF8.self)
  }

  private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
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
