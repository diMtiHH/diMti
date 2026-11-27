import CoreFoundation
import Foundation

enum PresentationDataError: Error { case invalid }

enum PresentationSchema {
  static let maxBytes = 2048
  static let legacyKeys: Set<String> = ["version", "name", "background", "answerStyle", "onboardingStep", "completed", "termsVersion", "audioEnabled"]
  static let keys = legacyKeys.union(["ambientEnabled", "hapticsEnabled"])
  private static let legacyBackgrounds = ["stars": "stars", "galaxy": "galaxy", "nebula": "aurora", "blackHole": "gravity"]
  private static let legacyStyles = ["coin": "livingMatter", "sphere": "liquidMetal", "blackHole": "infinity", "constellation": "constellation"]

  private static func boolean(_ value: Any?) throws -> Bool {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else { throw PresentationDataError.invalid }
    return number.boolValue
  }

  private static func integer(_ value: Any?, maximum: Int) throws -> Int {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue >= 0, number.doubleValue <= Double(maximum),
          number.doubleValue.rounded() == number.doubleValue else { throw PresentationDataError.invalid }
    return number.intValue
  }

  private static func dictionary(_ text: String) throws -> [String: Any] {
    guard text.utf8.count <= maxBytes, let data = text.data(using: .utf8),
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PresentationDataError.invalid
    }
    // Foundation has already checked JSON syntax. Reject repeated keys,
    // including escaped spellings, and noninteger numeric syntax explicitly.
    // This profile is flat; nested values are rejected by the field types below.
    let bytes = Array(text.utf8)
    var found: Set<String> = []
    var i = 0
    while i < bytes.count {
      if bytes[i] == 34 {
        let start = i
        i += 1
        while i < bytes.count {
          if bytes[i] == 92 {
            if i + 5 < bytes.count && bytes[i + 1] == 117,
               let scalar = UInt32(String(decoding: bytes[(i + 2)..<(i + 6)], as: UTF8.self), radix: 16) {
              if (0xD800...0xDBFF).contains(scalar) {
                guard i + 11 < bytes.count, bytes[i + 6] == 92, bytes[i + 7] == 117,
                      let low = UInt32(String(decoding: bytes[(i + 8)..<(i + 12)], as: UTF8.self), radix: 16),
                      (0xDC00...0xDFFF).contains(low) else { throw PresentationDataError.invalid }
                i += 12
                continue
              }
              if (0xDC00...0xDFFF).contains(scalar) { throw PresentationDataError.invalid }
              i += 6
              continue
            }
            i += 2
            continue
          }
          if bytes[i] == 34 { break }
          i += 1
        }
        i += 1
        var next = i
        while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
        if next < bytes.count && bytes[next] == 58 {
          guard let key = try JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: [.fragmentsAllowed]) as? String,
                found.insert(key).inserted else { throw PresentationDataError.invalid }
        }
        continue
      }
      if bytes[i] == 45 || (48...57).contains(bytes[i]) {
        while i < bytes.count && ([45, 43, 46, 69, 101].contains(bytes[i]) || (48...57).contains(bytes[i])) {
          if [46, 69, 101].contains(bytes[i]) { throw PresentationDataError.invalid }
          i += 1
        }
        continue
      }
      i += 1
    }
    return value
  }

  static func profile(_ text: String) throws -> [String: Any] {
    let value: [String: Any]
    do { value = try dictionary(text) }
    catch { throw PresentationDataError.invalid }
    let version = try integer(value["version"], maximum: 2)
    guard version == 1 || version == 2,
          Set(value.keys) == (version == 1 ? legacyKeys : keys),
          let name = value["name"] as? String,
          name.unicodeScalars.count <= 40,
          !name.unicodeScalars.contains(where: { $0.value <= 31 || (127...159).contains($0.value) }),
          let background = value["background"] as? String,
          let style = value["answerStyle"] as? String else {
      throw PresentationDataError.invalid
    }
    let step = try integer(value["onboardingStep"], maximum: 2)
    let terms = try integer(value["termsVersion"], maximum: 100000)
    let completed = try boolean(value["completed"])
    _ = try boolean(value["audioEnabled"])
    guard (completed ? (step == 2 && terms >= 1) : terms == 0) else { throw PresentationDataError.invalid }
    var canonical = value
    if version == 1 {
      guard let migratedBackground = legacyBackgrounds[background],
            let migratedStyle = legacyStyles[style] else { throw PresentationDataError.invalid }
      canonical["version"] = 2
      canonical["background"] = migratedBackground
      canonical["answerStyle"] = migratedStyle
      // Onboarding narration permission does not opt the user into ambience.
      canonical["ambientEnabled"] = false
      canonical["hapticsEnabled"] = true
    } else {
      guard ["stars", "galaxy", "aurora", "gravity"].contains(background),
            ["livingMatter", "liquidMetal", "infinity", "constellation"].contains(style) else {
        throw PresentationDataError.invalid
      }
      _ = try boolean(value["ambientEnabled"])
      _ = try boolean(value["hapticsEnabled"])
    }
    return canonical
  }

  static func encode(_ value: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { throw PresentationDataError.invalid }
    return text
  }
}

enum NarrationPolicy {
  static func filename(_ language: Any?) -> String? {
    guard let language = language as? String else { return nil }
    switch language {
    case "ru": return "ru.wav"
    case "en": return "en.wav"
    default: return nil
    }
  }

  static func identity(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
    let id = number.int64Value
    guard id > 0, id <= 9_007_199_254_740_991,
          number == NSNumber(value: id) else { return nil }
    return Int(id)
  }

  static func durationMilliseconds(_ seconds: TimeInterval) -> Int? {
    guard seconds.isFinite, seconds > 0, seconds <= 600 else { return nil }
    let milliseconds = Int((seconds * 1000).rounded())
    return milliseconds > 0 ? milliseconds : nil
  }
}
