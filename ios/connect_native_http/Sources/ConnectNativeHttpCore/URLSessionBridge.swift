import Foundation

// Bridges URLSession to lib/src/url_session/url_session_http_client.dart, one task per call, with the same protocol
// as the Android bridge. Dart sends request chunks as method calls; response headers, body chunks and the outcome go
// to `emit`, from the bridge's own queue. Kept free of Flutter so it can be tested without a Flutter app.
public final class URLSessionBridge {
  public enum Reply {
    case success(Any?)
    /// The call's arguments were not what the method takes. Refused rather than force-unwrapped, which would crash the
    /// app.
    case error(code: String, message: String)
    case notImplemented
  }

  private struct BadArgument: Error {
    let name: String
  }

  private let emit: ([String: Any]) -> Void
  private let trustedRoots: [SecCertificate]

  // URLSession delegate callbacks and all state below run on this queue, so none of it needs locking.
  private let queue = DispatchQueue(label: "connect_native_http")
  private lazy var delegateQueue: OperationQueue = {
    let q = OperationQueue()
    q.underlyingQueue = queue
    q.maxConcurrentOperationCount = 1
    return q
  }()
  private var sessions: [Int: Session] = [:]
  private var calls: [Int: Call] = [:]
  private var callsByTask: [URLSessionTask: Call] = [:]
  private var nextSessionId = 1

  private final class Session {
    // Replaced after a call times out, so new calls dial a fresh connection; see `evictConnection`.
    var urlSession: URLSession
    let http3Origins: Set<String>
    // When `urlSession` last received anything from each origin ("host:port"), in uptime nanoseconds.
    var lastReceived: [String: UInt64] = [:]

    init(urlSession: URLSession, http3Origins: Set<String>) {
      self.urlSession = urlSession
      self.http3Origins = http3Origins
    }
  }

  private final class Call {
    let callId: Int
    var engineId = 0
    // The URLSession the call's task runs in.
    var urlSession: URLSession?
    var origin = ""
    // When the call last received anything, or started, in uptime nanoseconds.
    var lastReceived = URLSessionBridge.now()
    var task: URLSessionTask!
    var input: InputStream?
    var output: OutputStream?
    var bodyStreamTaken = false
    // Writes to the bound stream pair block while its buffer is full, so they run here rather than on `queue`.
    let writer = DispatchQueue(label: "connect_native_http.writer")

    init(callId: Int) {
      self.callId = callId
    }
  }

  public convenience init(emit: @escaping ([String: Any]) -> Void) {
    self.init(trustedRoots: [], emit: emit)
  }

  /// `trustedRoots`, when not empty, replaces the system trust store; tests use it for their own CA.
  init(trustedRoots: [SecCertificate], emit: @escaping ([String: Any]) -> Void) {
    self.trustedRoots = trustedRoots
    self.emit = emit
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

  private func dispatch(_ method: String, _ args: [String: Any], reply: @escaping (Reply) -> Void) throws {
    switch method {
    case "createEngine":
      let origins = try (args["http3Origins"] as? [[Any]] ?? []).map { origin -> String in
        guard origin.count == 2 else { throw BadArgument(name: "http3Origins") }
        return "\(origin[0]):\(origin[1])"
      }
      queue.async {
        let id = self.nextSessionId
        self.nextSessionId += 1
        self.sessions[id] = Session(urlSession: self.makeURLSession(), http3Origins: Set(origins))
        reply(.success(id))
      }
    case "shutdownEngine":
      let engineId: Int = try arg(args, "engineId")
      queue.async {
        self.sessions.removeValue(forKey: engineId)?.urlSession.finishTasksAndInvalidate()
      }
      reply(.success(nil))
    case "open":
      let engineId: Int = try arg(args, "engineId")
      let callId: Int = try arg(args, "callId")
      let url: String = try arg(args, "url")
      let method: String = try arg(args, "method")
      let headers: [[String]] = try arg(args, "headers")
      guard headers.allSatisfy({ $0.count == 2 }) else { throw BadArgument(name: "headers") }
      let hasBody: Bool = try arg(args, "hasBody")
      let readIdleTimeoutMs = try optionalPositiveInt(args, "readIdleTimeoutMs")
      queue.async { self.open(engineId, callId, url, method, headers, hasBody, readIdleTimeoutMs) }
      reply(.success(nil))
    case "write":
      let callId: Int = try arg(args, "callId")
      let data: Data = try arg(args, "data")
      // Reply once the bytes are in the stream buffer, so a fast producer waits for URLSession to read them.
      queue.async {
        guard let c = self.calls[callId], let output = c.output else {
          reply(.success(nil))
          return
        }
        c.writer.async {
          Self.writeAll(data, to: output)
          reply(.success(nil))
        }
      }
    case "end":
      let callId: Int = try arg(args, "callId")
      queue.async {
        guard let c = self.calls[callId], let output = c.output else { return }
        c.writer.async { output.close() }
      }
      reply(.success(nil))
    case "cancel":
      let callId: Int = try arg(args, "callId")
      // Set when the call hit its deadline. The server was given a deadline a step earlier, so on a live connection
      // its deadline_exceeded would have ended the call first.
      let value = args["evictConnection"]
      guard value == nil || value is NSNull || value is Bool else { throw BadArgument(name: "evictConnection") }
      let evict = value as? Bool ?? false
      queue.async {
        guard let c = self.calls[callId] else { return }
        if evict {
          self.evictConnection(of: c)
        }
        c.task.cancel()
      }
      reply(.success(nil))
    default:
      reply(.notImplemented)
    }
  }

  /// An optional argument that must be a positive integer when present; absent or null for none.
  private func optionalPositiveInt(_ args: [String: Any], _ name: String) throws -> Int? {
    guard let value = args[name], !(value is NSNull) else { return nil }
    guard let n = value as? Int, n > 0 else { throw BadArgument(name: name) }
    return n
  }

  static func now() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  private func failure(_ callId: Int, domain: String, code: Int, message: String) -> [String: Any] {
    ["callId": callId, "type": "failed", "domain": domain, "code": code, "message": message]
  }

  private func makeURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    // URLSession fails a task that receives nothing for this long. Its default of 60 s would end a quiet stream or a
    // long-running unary call; callers bound calls with deadlines, or set the client's read-idle timeout.
    configuration.timeoutIntervalForRequest = Self.sessionIdleTimeout
    // Only a bridge with its own roots implements the trust challenge. With the system's roots there is nothing for
    // the delegate to decide, so certificate checks are left entirely to the network stack.
    let delegate = trustedRoots.isEmpty ? Delegate(bridge: self) : TrustingDelegate(bridge: self)
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
  }

  /// The `URLRequest.timeoutInterval` for a read-idle timeout of `ms` milliseconds, or nil for the session's.
  static func requestTimeoutInterval(readIdleTimeoutMs ms: Int?) -> TimeInterval? {
    guard let ms else { return nil }
    let interval = TimeInterval(ms) / 1000
    // URLSession takes a request's 60 s, URLRequest's default, to mean "not set" and applies the session's value
    // instead, however the request got it. One millisecond more is still honored.
    return interval == 60 ? 60.001 : interval
  }

  private func open(
    _ engineId: Int, _ callId: Int, _ url: String, _ method: String, _ headers: [[String]], _ hasBody: Bool,
    _ readIdleTimeoutMs: Int?
  ) {
    guard let session = sessions[engineId], let target = URL(string: url) else {
      emit(failure(
        callId, domain: "ConnectNativeHttp", code: 0, message: "engine \(engineId) is shut down or \(url) is invalid"))
      return
    }
    var request = URLRequest(url: target)
    request.httpMethod = method
    for h in headers {
      // URLRequest holds one value per name; addValue joins repeated headers with commas, as RFC 9110 allows.
      request.addValue(h[1], forHTTPHeaderField: h[0])
    }
    let port = target.port ?? (target.scheme == "http" ? 80 : 443)
    let origin = "\(target.host ?? ""):\(port)"
    request.assumesHTTP3Capable = session.http3Origins.contains(origin)
    // The request's read-idle timeout: URLSession fails the task once it has received nothing for this long, with
    // NSURLErrorTimedOut.
    if let interval = Self.requestTimeoutInterval(readIdleTimeoutMs: readIdleTimeoutMs) {
      request.timeoutInterval = interval
    }

    let c = Call(callId: callId)
    c.engineId = engineId
    c.urlSession = session.urlSession
    c.origin = origin
    if hasBody {
      var input: InputStream?
      var output: OutputStream?
      Stream.getBoundStreams(withBufferSize: Self.bodyBufferBytes, inputStream: &input, outputStream: &output)
      output!.open()
      c.input = input
      c.output = output
      c.task = session.urlSession.uploadTask(withStreamedRequest: request)
    } else {
      c.task = session.urlSession.dataTask(with: request)
    }
    calls[callId] = c
    callsByTask[c.task] = c
    c.task.resume()
  }

  private static func writeAll(_ data: Data, to output: OutputStream) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var offset = 0
      while offset < data.count {
        let n = output.write(base + offset, maxLength: data.count - offset)
        // The task finished and closed its end of the pair; the call's outcome is reported elsewhere.
        if n <= 0 { return }
        offset += n
      }
    }
  }

  // MARK: URLSession callbacks, on `queue`.

  fileprivate func bodyStream(for task: URLSessionTask) -> InputStream? {
    guard let c = callsByTask[task], !c.bodyStreamTaken else {
      // A second request for the body means URLSession wants to resend it, which a stream that has already been
      // read cannot do.
      return nil
    }
    c.bodyStreamTaken = true
    return c.input
  }

  // A redirect would resend the request body, which has already been streamed; over HTTP/3 URLSession then waits
  // indefinitely for a body nobody can give it. Refusing hands the redirect response itself to the caller.
  fileprivate func followsRedirect(_ task: URLSessionTask) -> Bool {
    callsByTask[task]?.input == nil
  }

  // Anything from the server shows the call's connection is alive.
  private func received(_ c: Call) {
    let now = Self.now()
    c.lastReceived = now
    if let session = sessions[c.engineId], session.urlSession === c.urlSession {
      session.lastReceived[c.origin] = now
    }
  }

  fileprivate func didReceive(_ response: URLResponse, for task: URLSessionTask) {
    guard let c = callsByTask[task] else { return }
    received(c)
    guard let http = response as? HTTPURLResponse else { return }
    let headers = http.allHeaderFields.map { [String(describing: $0.key), String(describing: $0.value)] }
    emit(["callId": c.callId, "type": "headers", "status": http.statusCode, "protocol": NSNull(), "headers": headers])
  }

  fileprivate func didReceive(_ data: Data, for task: URLSessionTask) {
    guard let c = callsByTask[task] else { return }
    received(c)
    emit(["callId": c.callId, "type": "data", "data": data])
  }

  fileprivate func didComplete(_ task: URLSessionTask, error: Error?) {
    guard let c = callsByTask.removeValue(forKey: task) else { return }
    calls.removeValue(forKey: c.callId)
    // Closing the reading end unblocks a write still waiting on a full buffer, but only once it has been opened,
    // which URLSession skips when the connection fails first.
    if let input = c.input {
      if input.streamStatus == .notOpen {
        input.open()
      }
      input.close()
    }
    guard let error = error as NSError? else {
      emit(["callId": c.callId, "type": "done"])
      return
    }
    if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
      emit(["callId": c.callId, "type": "canceled"])
      return
    }
    if error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
      evictConnection(of: c)
    }
    emit(failure(c.callId, domain: error.domain, code: error.code, message: error.localizedDescription))
  }

  // A call that ran out of time (its read-idle timeout, or its deadline) may be stuck on a dead connection.
  // It is taken to be if nothing has arrived from the call's origin, on any call, since the call last received
  // anything; otherwise only that call was slow. URLSession pools connections per session and has no call that closes
  // one, so the engine's new calls go to a fresh URLSession, which dials its own connections. The old one finishes the
  // tasks it still has, and is then released. Calls that time out together on the same dead connection replace it
  // once.
  private func evictConnection(of c: Call) {
    guard let session = sessions[c.engineId], let old = c.urlSession, session.urlSession === old else { return }
    if let heard = session.lastReceived[c.origin], heard > c.lastReceived {
      return
    }
    session.urlSession = makeURLSession()
    session.lastReceived = [:]
    old.finishTasksAndInvalidate()
  }

  fileprivate func serverTrust(_ challenge: URLAuthenticationChallenge) -> (
    URLSession.AuthChallengeDisposition, URLCredential?
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      return (.performDefaultHandling, nil)
    }
    SecTrustSetAnchorCertificates(trust, trustedRoots as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    return SecTrustEvaluateWithError(trust, nil)
      ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
  }

  // 64 KiB, the bound pair's buffer: how much request body may wait for URLSession to read it.
  private static let bodyBufferBytes = 64 * 1024

  // A day: in effect no read-idle timeout, for requests that don't set one.
  private static let sessionIdleTimeout: TimeInterval = 24 * 60 * 60
}

// URLSession keeps its delegate until the session is invalidated, so this holds the bridge weakly.
private class Delegate: NSObject, URLSessionDataDelegate {
  weak var bridge: URLSessionBridge?

  init(bridge: URLSessionBridge) {
    self.bridge = bridge
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(bridge?.followsRedirect(task) == true ? request : nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
  ) {
    completionHandler(bridge?.bodyStream(for: task))
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    bridge?.didReceive(response, for: dataTask)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    bridge?.didReceive(data, for: dataTask)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    bridge?.didComplete(task, error: error)
  }
}

// A Delegate that also checks server certificates against the bridge's own roots. URLSession looks the method up by
// its Objective-C selector, hence the explicit name: a subclass doesn't inherit the protocol's @objc inference.
private final class TrustingDelegate: Delegate {
  @objc(URLSession:didReceiveChallenge:completionHandler:)
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let (disposition, credential) = bridge?.serverTrust(challenge) ?? (.performDefaultHandling, nil)
    completionHandler(disposition, credential)
  }
}
