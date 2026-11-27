import Flutter
import Foundation

/// Reads only coarse OS thermal/power state. It never reads a temperature,
/// records analytics, or changes a device setting.
final class GraphicsBudgetBridge {
  private let channel: FlutterMethodChannel
  private let process = ProcessInfo.processInfo
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ask_universe/graphicsBudget", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      guard call.arguments == nil || (call.arguments as? [String: Any])?.isEmpty == true else {
        return result(FlutterError(code: "invalid", message: nil, details: nil))
      }
      switch call.method {
      case "start":
        self.start()
        result(self.snapshot())
      case "stop":
        self.stop()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func snapshot() -> [String: Any] {
    let thermal: String
    switch process.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "critical"
    }
    return ["thermalState": thermal, "lowPowerMode": process.isLowPowerModeEnabled]
  }

  private func start() {
    guard observers.isEmpty else { return }
    // Apple requires reading thermalState before registering for its changes.
    _ = process.thermalState
    let center = NotificationCenter.default
    for name in [ProcessInfo.thermalStateDidChangeNotification,
                 Notification.Name.NSProcessInfoPowerStateDidChange] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        guard let self, !self.observers.isEmpty else { return }
        self.channel.invokeMethod("budgetChanged", arguments: self.snapshot())
      })
    }
  }

  private func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
  }

  deinit { stop() }
}
