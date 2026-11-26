import Foundation
import CoreFoundation

// Shared with the automatic native checks; contains no audio, text history or I/O.
enum VoicePolicy {
  static let recordingSeconds: TimeInterval = 60
  static let permissionSeconds: TimeInterval = 60
  static let finalizationSeconds: TimeInterval = 2
  static let maxTextUTF16 = 8192

  static func acceptsTranscript(_ text: String) -> Bool {
    text.utf16.count <= maxTextUTF16
  }

  static func locale(for language: String) -> String? {
    switch language {
    case "ru": return "ru-RU"
    case "en": return "en-US"
    default: return nil
    }
  }

  static func requestID(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          String(cString: number.objCType) != "f",
          String(cString: number.objCType) != "d" else { return nil }
    let integer = number.int64Value
    guard integer >= 0, integer <= 9_007_199_254_740_991,
          number == NSNumber(value: integer) else { return nil }
    return Int(integer)
  }
}

struct VoiceTicket: Equatable {
  let id: Int
  let generation: UUID
}

// Main-thread owner. Generation identity also rejects stale callbacks when a
// caller accidentally reuses an external id after cancellation.
final class VoiceLifecycle {
  enum Phase: Equatable { case permission, listening, finishing }
  private(set) var ticket: VoiceTicket?
  private(set) var phase: Phase?

  @discardableResult func begin(id: Int) -> VoiceTicket {
    let next = VoiceTicket(id: id, generation: UUID())
    ticket = next
    phase = .permission
    return next
  }

  func accepts(_ candidate: VoiceTicket) -> Bool { ticket == candidate }

  func listen(_ candidate: VoiceTicket) -> Bool {
    guard accepts(candidate), phase == .permission else { return false }
    phase = .listening
    return true
  }

  func stop(_ candidate: VoiceTicket) -> Bool {
    guard accepts(candidate), phase == .listening else { return false }
    phase = .finishing
    return true
  }

  @discardableResult func retire(_ candidate: VoiceTicket) -> Bool {
    guard accepts(candidate) else { return false }
    ticket = nil
    phase = nil
    return true
  }
}

struct VoiceLevelMeter {
  private(set) var level = 0.0

  mutating func update(rms: Double, seconds: Double) -> Double {
    guard rms.isFinite, rms >= 0, seconds.isFinite, seconds > 0 else {
      level = 0
      return level
    }
    // Room noise below -48 dB does not animate the star. A quiet room does not
    // get a synthetic minimum level. Attack is faster than release.
    let db = 20 * log10(max(min(rms, 1), 0.000_001))
    let target = max(0, min(1, (db + 48) / 36))
    let tau = target > level ? 0.06 : 0.30
    let alpha = 1 - exp(-min(seconds, 1) / tau)
    level += (target - level) * alpha
    if level < 0.0001 { level = 0 }
    return max(0, min(1, level))
  }
}
