import CoreFoundation
import Foundation

enum SessionDataError: Error { case invalid }
enum SessionScope: String { case real, diagnostic }
enum SessionFile: String { case state, preferences }

enum SessionSchema {
  static let maxBytes = 2048
  static let maxDeadline: Int64 = 9_007_199_254_740_991

  // Foundation bridges NSNumber(1) to Bool and true to integer 1. Neither
  // conversion is a valid substitute for the JSON types in the Dart contract.
  static func boolean(_ value: Any?) throws -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID() else { throw SessionDataError.invalid }
    return number.boolValue
  }

  private static func integer(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue >= 0, number.doubleValue <= Double(maxDeadline),
      number.doubleValue.rounded() == number.doubleValue else { throw SessionDataError.invalid }
    return number.int64Value
  }

  private static func dictionary(_ text: String) throws -> [String: Any] {
    guard text.utf8.count <= maxBytes,
      let data = text.data(using: .utf8),
      let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw SessionDataError.invalid }
    // Syntax was checked above. Reject duplicate (also escaped) keys instead
    // of relying on Foundation/Dart's different duplicate-key choices. Numeric
    // fields must also retain integer syntax: 1.0 and 1e0 are not Dart ints.
    let bytes = Array(text.utf8)
    var keys: Set<String> = []
    var i = 0
    while i < bytes.count {
      let byte = bytes[i]
      if byte == 34 {
        let start = i
        i += 1
        while i < bytes.count {
          if bytes[i] == 92 { i += 2; continue }
          if bytes[i] == 34 { break }
          i += 1
        }
        i += 1
        var next = i
        while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
        if next < bytes.count && bytes[next] == 58 {
          guard let key = try JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: [.fragmentsAllowed]) as? String,
            keys.insert(key).inserted else { throw SessionDataError.invalid }
        }
        continue
      }
      if byte == 45 || (48...57).contains(byte) {
        while i < bytes.count && ([45, 43, 46, 69, 101].contains(bytes[i]) ||
                                 (48...57).contains(bytes[i])) {
          if [46, 69, 101].contains(bytes[i]) { throw SessionDataError.invalid }
          i += 1
        }
        continue
      }
      i += 1
    }
    return value
  }

  static func state(_ text: String, scope: SessionScope) throws -> [String: Any] {
    guard text.utf16.count <= 1024 else { throw SessionDataError.invalid }
    let value = try dictionary(text)
    let version = try integer(value["version"])
    guard let phase = value["phase"] as? String,
      version == 1 || (version == 2 && scope == .diagnostic && phase == "cooldown") else { throw SessionDataError.invalid }
    var keys: Set<String> = ["version", "phase"]
    switch phase {
    case "idle", "reserved": break
    case "pending":
      keys.insert("answer")
      guard ["yes", "no"].contains(value["answer"] as? String ?? "") else { throw SessionDataError.invalid }
    case "cooldown":
      keys.formUnion(["utcDeadline", "continuousDeadline", "bootToken"])
      if version == 2 {
        keys.insert("durationMs")
        guard try integer(value["durationMs"]) == 60_000 else { throw SessionDataError.invalid }
      }
      _ = try integer(value["utcDeadline"])
      _ = try integer(value["continuousDeadline"])
      guard let boot = value["bootToken"] as? String, !boot.isEmpty,
        boot.utf16.count <= 128 else { throw SessionDataError.invalid }
    default: throw SessionDataError.invalid
    }
    guard Set(value.keys) == keys else { throw SessionDataError.invalid }
    return value
  }

  static func preferences(_ text: String) throws -> [String: Any] {
    let value = try dictionary(text)
    guard Set(value.keys) == ["language", "notifications"],
      ["ru", "en"].contains(value["language"] as? String ?? "") else { throw SessionDataError.invalid }
    _ = try boolean(value["notifications"])
    return value
  }

  static func encode(_ value: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { throw SessionDataError.invalid }
    return text
  }
}
