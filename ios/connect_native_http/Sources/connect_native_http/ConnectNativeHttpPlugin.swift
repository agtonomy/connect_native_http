import ConnectNativeHttpCore
import Flutter
import Foundation

// Connects a URLSessionBridge to its Flutter channels.
public final class ConnectNativeHttpPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private lazy var bridge = URLSessionBridge { [weak self] event in
    let payload = event.mapValues { $0 is Data ? FlutterStandardTypedData(bytes: $0 as! Data) : $0 }
    DispatchQueue.main.async { self?.sink?(payload) }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ConnectNativeHttpPlugin()
    let methods = FlutterMethodChannel(name: "connect_native_http/urlsession", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "connect_native_http/urlsession/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = (call.arguments as? [String: Any] ?? [:]).mapValues {
      ($0 as? FlutterStandardTypedData)?.data ?? $0
    }
    bridge.handle(call.method, args) { reply in
      DispatchQueue.main.async {
        switch reply {
        case .success(let value): result(value)
        case .error(let code, let message): result(FlutterError(code: code, message: message, details: nil))
        case .notImplemented: result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
