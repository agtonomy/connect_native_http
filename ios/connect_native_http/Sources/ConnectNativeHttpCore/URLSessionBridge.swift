import Foundation

// Bridges URLSession to lib/src/url_session/url_session_http_client.dart, one task per call, with the same protocol
// as the Android bridge. Dart sends request chunks as method calls; response headers, body chunks and the outcome go
// to `emit`, from the bridge's own queue. Kept free of Flutter so it can be tested without a Flutter app.
public final class URLSessionBridge {
  public enum Reply {
    case success(Any?)
    case notImplemented
  }

  private let emit: ([String: Any]) -> Void

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
    let urlSession: URLSession
    let http3Origins: Set<String>

    init(urlSession: URLSession, http3Origins: Set<String>) {
      self.urlSession = urlSession
      self.http3Origins = http3Origins
    }
  }

  private final class Call {
    let callId: Int
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

  public init(emit: @escaping ([String: Any]) -> Void) {
    self.emit = emit
  }

  /// Handles one method call. `reply` may be called on any thread.
  public func handle(_ method: String, _ args: [String: Any], reply: @escaping (Reply) -> Void) {
    switch method {
    case "createEngine":
      let origins = (args["http3Origins"] as? [[Any]] ?? []).map { "\($0[0]):\($0[1])" }
      queue.async {
        let configuration = URLSessionConfiguration.ephemeral
        // URLSession fails a task that receives nothing for this long. Its default of 60 s would end a quiet stream
        // or a long-running unary call; callers bound calls with deadlines instead.
        configuration.timeoutIntervalForRequest = 24 * 60 * 60
        let session = URLSession(
          configuration: configuration, delegate: Delegate(bridge: self), delegateQueue: self.delegateQueue)
        let id = self.nextSessionId
        self.nextSessionId += 1
        self.sessions[id] = Session(urlSession: session, http3Origins: Set(origins))
        reply(.success(id))
      }
    case "shutdownEngine":
      let engineId = args["engineId"] as! Int
      queue.async {
        self.sessions.removeValue(forKey: engineId)?.urlSession.finishTasksAndInvalidate()
      }
      reply(.success(nil))
    case "open":
      let engineId = args["engineId"] as! Int
      let callId = args["callId"] as! Int
      let url = args["url"] as! String
      let method = args["method"] as! String
      let headers = args["headers"] as! [[String]]
      let hasBody = args["hasBody"] as! Bool
      queue.async { self.open(engineId, callId, url, method, headers, hasBody) }
      reply(.success(nil))
    case "write":
      let callId = args["callId"] as! Int
      let data = args["data"] as! Data
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
      let callId = args["callId"] as! Int
      queue.async {
        guard let c = self.calls[callId], let output = c.output else { return }
        c.writer.async { output.close() }
      }
      reply(.success(nil))
    case "cancel":
      let callId = args["callId"] as! Int
      queue.async { self.calls[callId]?.task.cancel() }
      reply(.success(nil))
    default:
      reply(.notImplemented)
    }
  }

  private func failure(_ callId: Int, domain: String, code: Int, message: String) -> [String: Any] {
    ["callId": callId, "type": "failed", "domain": domain, "code": code, "message": message]
  }

  private func open(
    _ engineId: Int, _ callId: Int, _ url: String, _ method: String, _ headers: [[String]], _ hasBody: Bool
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
    request.assumesHTTP3Capable = session.http3Origins.contains("\(target.host ?? ""):\(port)")

    let c = Call(callId: callId)
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

  fileprivate func didReceive(_ response: URLResponse, for task: URLSessionTask) {
    guard let c = callsByTask[task], let http = response as? HTTPURLResponse else { return }
    let headers = http.allHeaderFields.map { [String(describing: $0.key), String(describing: $0.value)] }
    emit(["callId": c.callId, "type": "headers", "status": http.statusCode, "protocol": NSNull(), "headers": headers])
  }

  fileprivate func didReceive(_ data: Data, for task: URLSessionTask) {
    guard let c = callsByTask[task] else { return }
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
    emit(failure(c.callId, domain: error.domain, code: error.code, message: error.localizedDescription))
  }

  // 64 KiB, the bound pair's buffer: how much request body may wait for URLSession to read it.
  private static let bodyBufferBytes = 64 * 1024
}

// URLSession keeps its delegate until the session is invalidated, so this holds the bridge weakly.
//
// It deliberately has no authentication challenge method: certificates are checked against the system trust store
// only, inside the network stack. A delegate that implements the challenge at all gets every TLS handshake's
// certificate check, QUIC and TCP alike, sent through `queue`, behind every call's callbacks; on a loaded device that
// held a QUIC handshake long enough for URLSession's TCP attempt to win the race. Tests trust their server's CA by
// installing it in the device's (or Mac's) trust store.
private final class Delegate: NSObject, URLSessionDataDelegate {
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
