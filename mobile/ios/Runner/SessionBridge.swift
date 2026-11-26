import Darwin
import Flutter
import Foundation
import UserNotifications

// Every operation, including asynchronous notification calls, is serialized.
// Errors expose fixed codes only; paths, state and question text are never logged.
@MainActor
final class SessionBridge {
  private var tail: Task<Void, Never>?
  private let center = UNUserNotificationCenter.current()
  private let fileManager = FileManager.default
  private let channel: FlutterMethodChannel
  // KERN_BOOTTIME is a documented timestamp, not a boot UUID. Cache it for
  // this process so a wall-clock edit cannot change the active clock domain.
  // Across process restarts it can change after a clock edit as well as reboot;
  // that deliberately takes the core's bounded UTC recovery path (see STAGE_3).
  private static var processClockDomain: String?
  private var englishNoticeApproved: Bool {
    Bundle.main.object(forInfoDictionaryKey: "UniverseEnglishNoticeApproved") as? Bool == true
  }
  private enum BridgeError: Error { case invalid, storage, clock }

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
          case BridgeError.invalid: code = "invalid_state"
          default: code = "storage_unavailable"
          }
          result(FlutterError(code: code, message: nil, details: nil))
        }
      }
    }
  }

  private func folder(_ scope: String) throws -> URL {
    guard scope == "real" || scope == "diagnostic" else { throw BridgeError.invalid }
    let support = try fileManager.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    var url = support.appendingPathComponent("UniverseSessionV1", isDirectory: true)
      .appendingPathComponent(scope, isDirectory: true)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
    return url
  }

  private func read(_ scope: String, _ name: String) throws -> String? {
    let url = try folder(scope).appendingPathComponent(name + ".json")
    do {
      let data = try Data(contentsOf: url)
      guard data.count <= 2048, let text = String(data: data, encoding: .utf8) else { throw BridgeError.invalid }
      return text
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
      return nil
    }
  }

  private func write(_ scope: String, _ name: String, _ value: String) throws {
    guard let data = value.data(using: .utf8), data.count <= 2048 else { throw BridgeError.invalid }
    let dir = try folder(scope)
    let temp = dir.appendingPathComponent(name + ".pending")
    let target = dir.appendingPathComponent(name + ".json")
    // Protected, excluded directory; the bounded staging file is never read as
    // committed state. Atomic rename is within the same filesystem/directory.
    try data.write(to: temp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    let file = try FileHandle(forWritingTo: temp)
    do { try file.synchronize(); try file.close() }
    catch { try? file.close(); throw error }
    guard Darwin.rename(temp.path, target.path) == 0 else { throw BridgeError.storage }
    let descriptor = Darwin.open(dir.path, O_RDONLY)
    guard descriptor >= 0 else { throw BridgeError.storage }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw BridgeError.storage }
  }

  private func dictionary(_ text: String) throws -> [String: Any] {
    guard let data = text.data(using: .utf8),
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.invalid }
    return value
  }

  private func validateState(_ text: String) throws -> [String: Any] {
    let value = try dictionary(text)
    guard value["version"] as? Int == 1, let phase = value["phase"] as? String else { throw BridgeError.invalid }
    var keys: Set<String> = ["version", "phase"]
    switch phase {
    case "idle", "reserved": break
    case "pending":
      keys.insert("answer")
      guard ["yes", "no"].contains(value["answer"] as? String ?? "") else { throw BridgeError.invalid }
    case "cooldown":
      keys.formUnion(["utcDeadline", "continuousDeadline", "bootToken"])
      guard let utc = value["utcDeadline"] as? Int64,
        let continuous = value["continuousDeadline"] as? Int64,
        utc >= 0, continuous >= 0, utc <= 9_007_199_254_740_991, continuous <= 9_007_199_254_740_991,
        let boot = value["bootToken"] as? String, !boot.isEmpty, boot.count <= 128 else { throw BridgeError.invalid }
    default: throw BridgeError.invalid
    }
    guard Set(value.keys) == keys else { throw BridgeError.invalid }
    return value
  }

  private func clock() throws -> [String: Any] {
    if Self.processClockDomain == nil {
      var boot = timeval()
      var size = MemoryLayout<timeval>.size
      var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
      let status = mib.withUnsafeMutableBufferPointer { buffer in
        sysctl(buffer.baseAddress, UInt32(buffer.count), &boot, &size, nil, 0)
      }
      guard status == 0, size == MemoryLayout<timeval>.size,
        boot.tv_sec > 0, boot.tv_usec >= 0, boot.tv_usec < 1_000_000 else { throw BridgeError.clock }
      Self.processClockDomain = "boottime-v1:\(boot.tv_sec):\(boot.tv_usec)"
    }
    guard let domain = Self.processClockDomain else { throw BridgeError.clock }
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { throw BridgeError.clock }
    let milliseconds = Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000
    let utc = Date().timeIntervalSince1970 * 1000
    guard milliseconds.isFinite, utc.isFinite, milliseconds >= 0, utc >= 0,
      milliseconds < 9_007_199_252_940_991, utc < 9_007_199_252_940_991 else { throw BridgeError.clock }
    return ["utcMs": Int64(utc), "continuousMs": Int64(milliseconds), "bootToken": domain]
  }

  private func preferences(_ scope: String) throws -> [String: Any] {
    guard let raw = try read(scope, "preferences") else { return ["language": "ru", "notifications": false] }
    let value = try dictionary(raw)
    guard Set(value.keys) == ["language", "notifications"],
      ["ru", "en"].contains(value["language"] as? String ?? ""), value["notifications"] is Bool else { throw BridgeError.invalid }
    return value
  }

  private func savePreferences(_ scope: String, _ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else { throw BridgeError.invalid }
    try write(scope, "preferences", text)
  }

  private func notificationID(_ scope: String) -> String {
    return scope == "real" ? "universe.cooldown.v1" : "universe.cooldown.v1.diagnostic"
  }

  private func cancel(_ scope: String) {
    let ids = [notificationID(scope)]
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  private func schedule(_ scope: String) async throws {
    let prefs = try preferences(scope)
    if prefs["language"] as? String == "en" && !englishNoticeApproved { cancel(scope); return }
    let settings = await center.notificationSettings()
    guard prefs["notifications"] as? Bool == true else { cancel(scope); return }
    guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
      cancel(scope)
      throw BridgeError.invalid
    }
    guard let raw = try read(scope, "state") else { cancel(scope); return }
    let state = try validateState(raw)
    guard state["phase"] as? String == "cooldown" else { cancel(scope); return }
    let now = try clock()
    let sameBoot = state["bootToken"] as? String == now["bootToken"] as? String
    let deadline = state[sameBoot ? "continuousDeadline" : "utcDeadline"] as! Int64
    let current = now[sameBoot ? "continuousMs" : "utcMs"] as! Int64
    let left = min(Int64(1_800_000), deadline - current)
    guard left > 0 else { cancel(scope); return }
    let content = UNMutableNotificationContent()
    let ru = prefs["language"] as? String == "ru"
    content.title = scope == "diagnostic" ? (ru ? "Проверка ядра" : "Core check") : (ru ? "Спроси Вселенную" : "Ask the Universe")
    content.body = ru ? "Вселенная снова готова тебя услышать" : "The Universe is ready to hear you again"
    content.sound = .default
    let request = UNNotificationRequest(identifier: notificationID(scope), content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, Double(left) / 1000), repeats: false))
    try await center.add(request)
  }

  private func perform(_ call: FlutterMethodCall) async throws -> Any? {
    guard let args = call.arguments as? [String: Any], let scope = args["scope"] as? String,
      scope == "real" || scope == "diagnostic" else { throw BridgeError.invalid }
    switch call.method {
    case "readState": return try read(scope, "state")
    case "writeState":
      guard let value = args["value"] as? String else { throw BridgeError.invalid }
      _ = try validateState(value)
      try write(scope, "state", value)
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
      guard let enabled = args["enabled"] as? Bool else { throw BridgeError.invalid }
      var prefs = try preferences(scope)
      if enabled && prefs["language"] as? String == "en" && !englishNoticeApproved { return false }
      var granted = false
      if enabled { granted = try await center.requestAuthorization(options: [.alert, .sound]) }
      prefs["notifications"] = enabled && granted
      try savePreferences(scope, prefs)
      if enabled && granted { try await schedule(scope) } else { cancel(scope) }
      return enabled && granted
    case "scheduleNotification": try await schedule(scope); return nil
    case "cancelNotification": cancel(scope); return nil
    case "resetDiagnostic":
      guard scope == "diagnostic" else { throw BridgeError.invalid }
      cancel(scope)
      try write(scope, "state", "{\"version\":1,\"phase\":\"idle\"}")
      return nil
    default: return FlutterMethodNotImplemented
    }
  }
}
