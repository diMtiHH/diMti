import Darwin
import Flutter
import Foundation
import UserNotifications

// Operations are serialized; every OS notification callback has a deadline.
// Errors expose fixed codes only; paths, state and question text are never logged.
@MainActor
final class SessionBridge {
  private var tail: Task<Void, Never>?
  private let center = UNUserNotificationCenter.current()
  private let fileManager = FileManager.default
  private let channel: FlutterMethodChannel
  private static var processClock: ClockDomain?
  // An add with an unknown outcome fences further adds for this scope until
  // its late callback has cancelled that request. Cancel/reset remain usable.
  private let delivery = NotificationDelivery()
  private var englishNoticeApproved: Bool {
    Bundle.main.object(forInfoDictionaryKey: "UniverseEnglishNoticeApproved") as? Bool == true
  }
  private enum BridgeError: Error { case invalid, storage, clock, notification }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "app.asktheuniverse/session.v1", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      let previous = self.tail
      self.tail = Task { @MainActor in
        await previous?.value
        do { result(try await self.perform(call)) }
        catch {
          let code: String
          switch error {
          case BridgeError.clock: code = "clock_unavailable"
          case BridgeError.invalid, is SessionDataError: code = "invalid_state"
          case BridgeError.notification, is CallbackDeadline, is NotificationDeliveryError: code = "notification_unavailable"
          default: code = "storage_unavailable"
          }
          result(FlutterError(code: code, message: nil, details: nil))
        }
      }
    }
  }

  private func storage() throws -> SessionStorage {
    let support = try fileManager.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    return SessionStorage(root: support.appendingPathComponent("UniverseSessionV1", isDirectory: true))
  }

  private func clock() throws -> [String: Any] {
    let domain: String
    do {
      if Self.processClock == nil {
        let support = try fileManager.url(for: .applicationSupportDirectory,
          in: .userDomainMask, appropriateFor: nil, create: true)
        Self.processClock = ClockDomain(directory: support
          .appendingPathComponent("UniverseSessionV1", isDirectory: true)
          .appendingPathComponent("clock", isDirectory: true))
      }
      guard let clock = Self.processClock else { throw BridgeError.clock }
      domain = try clock.token()
    } catch { throw BridgeError.clock }
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { throw BridgeError.clock }
    let milliseconds = Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000
    let utc = Date().timeIntervalSince1970 * 1000
    guard milliseconds.isFinite, utc.isFinite, milliseconds >= 0, utc >= 0,
      milliseconds < 9_007_199_252_940_991, utc < 9_007_199_252_940_991 else { throw BridgeError.clock }
    return ["utcMs": Int64(utc), "continuousMs": Int64(milliseconds), "bootToken": domain]
  }

  private func preferences(_ scope: SessionScope) throws -> [String: Any] {
    try storage().preferences(scope)
  }

  private func savePreferences(_ scope: SessionScope, _ value: [String: Any]) throws {
    try storage().savePreferences(scope, value)
  }

  private func notificationID(_ scope: SessionScope) -> String {
    return scope == .real ? "universe.cooldown.v1" : "universe.cooldown.v1.diagnostic"
  }

  private func cancel(_ scope: SessionScope) {
    let ids = [notificationID(scope)]
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  private func schedule(_ scope: SessionScope) async throws {
    let prefs = try preferences(scope)
    if prefs["language"] as? String == "en" && !englishNoticeApproved { cancel(scope); return }
    guard prefs["notifications"] as? Bool == true else { cancel(scope); return }
    guard delivery.isAvailable(scope.rawValue) else { throw BridgeError.notification }
    let settings = try await BoundedCallback<UNNotificationSettings>.wait(seconds: 2) { reply in
      center.getNotificationSettings { reply(.success($0)) }
    }
    guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
      cancel(scope)
      throw BridgeError.invalid
    }
    guard let raw = try storage().readState(scope) else { cancel(scope); return }
    let state = try SessionSchema.state(raw, scope: scope)
    guard state["phase"] as? String == "cooldown" else { cancel(scope); return }
    let now = try clock()
    let sameBoot = state["bootToken"] as? String == now["bootToken"] as? String
    let deadline = state[sameBoot ? "continuousDeadline" : "utcDeadline"] as! Int64
    let current = now[sameBoot ? "continuousMs" : "utcMs"] as! Int64
    let duration = state["durationMs"] as? Int64 ?? 1_800_000
    let left = min(duration, deadline - current)
    guard left > 0 else { cancel(scope); return }
    let content = UNMutableNotificationContent()
    let ru = prefs["language"] as? String == "ru"
    content.title = scope == .diagnostic ? (ru ? "Проверка ядра" : "Core check") : (ru ? "Спроси Вселенную" : "Ask the Universe")
    content.body = ru ? "Вселенная снова готова тебя услышать" : "The Universe is ready to hear you again"
    content.sound = .default
    let request = UNNotificationRequest(identifier: notificationID(scope), content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, Double(left) / 1000), repeats: false))
    try await delivery.add(scope.rawValue, cancel: { [self] in cancel(scope) }) { reply in
      center.add(request) { error in
        if let error = error { reply(.failure(error)) }
        else { reply(.success(())) }
      }
    }
  }

  private func perform(_ call: FlutterMethodCall) async throws -> Any? {
    guard let args = call.arguments as? [String: Any], let rawScope = args["scope"] as? String,
      let scope = SessionScope(rawValue: rawScope) else { throw BridgeError.invalid }
    switch call.method {
    case "readState": return try storage().readState(scope)
    case "writeState":
      guard let value = args["value"] as? String else { throw BridgeError.invalid }
      try storage().writeState(scope, value)
      return nil
    case "clock": return try clock()
    case "preferences":
      var prefs = try preferences(scope)
      prefs["englishNotifications"] = englishNoticeApproved
      return prefs
    case "setLanguage":
      guard let language = args["language"] as? String, ["ru", "en"].contains(language) else { throw BridgeError.invalid }
      var prefs = try preferences(scope)
      prefs["language"] = language
      try savePreferences(scope, prefs)
      // Notification delivery is optional, including after permission revocation.
      // The core reconciles again on load and reports notification-only failures.
      try? await schedule(scope)
      return nil
    case "setNotifications":
      let enabled = try SessionSchema.boolean(args["enabled"])
      var prefs = try preferences(scope)
      if enabled && prefs["language"] as? String == "en" && !englishNoticeApproved { return false }
      var granted = false
      if enabled {
        granted = try await BoundedCallback<Bool>.wait(seconds: 60) { reply in
          center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error { reply(.failure(error)) }
            else { reply(.success(granted)) }
          }
        }
      }
      prefs["notifications"] = enabled && granted
      try savePreferences(scope, prefs)
      if enabled && granted { try await schedule(scope) } else { cancel(scope) }
      return enabled && granted
    case "scheduleNotification": try await schedule(scope); return nil
    case "cancelNotification": cancel(scope); return nil
    case "resetDiagnostic":
      guard scope == .diagnostic else { throw BridgeError.invalid }
      cancel(scope)
      try storage().writeState(scope, "{\"version\":1,\"phase\":\"idle\"}")
      return nil
    default: return FlutterMethodNotImplemented
    }
  }
}
