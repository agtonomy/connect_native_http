import ConnectNativeHttpCore
import Flutter
import Foundation

// Connects the bridges to their Flutter channels: URLSessionBridge, the default, and HTTP3Bridge, which the Dart side
// uses when NativeHttpConfig.enableDatagrams is set. Each bridge is created on its channel's first method call.
public final class ConnectNativeHttpPlugin: NSObject, FlutterPlugin {
  private let urlSession = BridgeChannel { emit in
    let bridge = URLSessionBridge(emit: emit)
    return { method, args, reply in
      bridge.handle(method, args) { result in
        switch result {
        case .success(let value): reply(value)
        case .error(let code, let message): reply(FlutterError(code: code, message: message, details: nil))
        case .notImplemented: reply(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private let http3 = BridgeChannel { emit in
    guard #available(iOS 27, *) else {
      return { method, _, reply in
        reply(FlutterError(
          code: "unsupported", message: "\(method): HTTP datagrams need iOS 27 or later", details: nil))
      }
    }
    let bridge = HTTP3Bridge(emit: emit)
    return { method, args, reply in
      bridge.handle(method, args) { result in
        switch result {
        case .success(let value): reply(value)
        case .error(let code, let message): reply(FlutterError(code: code, message: message, details: nil))
        case .notImplemented: reply(FlutterMethodNotImplemented)
        }
      }
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ConnectNativeHttpPlugin()
    instance.urlSession.register(name: "connect_native_http/urlsession", with: registrar)
    instance.http3.register(name: "connect_native_http/http3", with: registrar)
  }
}

/// One bridge's method channel and event channel.
private final class BridgeChannel: NSObject, FlutterStreamHandler {
  typealias Handle = (_ method: String, _ args: [String: Any], _ reply: @escaping (Any?) -> Void) -> Void

  private let makeBridge: (@escaping ([String: Any]) -> Void) -> Handle
  private var sink: FlutterEventSink?
  private lazy var bridge: Handle = makeBridge { [weak self] event in
    let payload = event.mapValues { $0 is Data ? FlutterStandardTypedData(bytes: $0 as! Data) : $0 }
    DispatchQueue.main.async { self?.sink?(payload) }
  }

  init(makeBridge: @escaping (@escaping ([String: Any]) -> Void) -> Handle) {
    self.makeBridge = makeBridge
  }

  func register(name: String, with registrar: FlutterPluginRegistrar) {
    let methods = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
    // The channels hold the handler, and so this object, for as long as the engine runs.
    methods.setMethodCallHandler { call, result in
      self.handle(call, result: result)
    }
    FlutterEventChannel(name: "\(name)/events", binaryMessenger: registrar.messenger()).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = (call.arguments as? [String: Any] ?? [:]).mapValues {
      ($0 as? FlutterStandardTypedData)?.data ?? $0
    }
    bridge(call.method, args) { reply in
      DispatchQueue.main.async { result(reply) }
    }
  }
}
