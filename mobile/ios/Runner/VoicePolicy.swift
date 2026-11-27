import Foundation
import CoreFoundation

// Shared with automatic native checks. No audio, persistence, logging or I/O.
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

// Ephemeral snapshots of this capture, bounded by the same UTF16 limit as Dart.
// Apple timestamps refer to the processed audio stream. Only a disjoint later
// audio range commits an earlier utterance; overlapping partial results revise
// their range. We never infer a phrase boundary from words, confidence or a
// wall-clock pause, and never deduplicate intentional repeated spoken words.
struct VoiceTranscriptBuffer {
  private struct Part {
    let text: String
    let start: TimeInterval?
    let end: TimeInterval?
  }
  private var parts: [Part] = []
  private(set) var text = ""

  mutating func update(_ incoming: String, start: TimeInterval?, end: TimeInterval?) -> String? {
    guard VoicePolicy.acceptsTranscript(incoming) else { return nil }
    // Silence can produce an empty hypothesis; it must not erase the draft.
    guard !incoming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
    if let start, let end {
      guard start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
    } else if start != nil || end != nil { return nil }

    // Early partials may not have a positive duration yet. They remain editable
    // but cannot prove that a different utterance has begun.
    let timedStart: TimeInterval?
    let timedEnd: TimeInterval?
    if let start, let end, end > start {
      timedStart = start
      timedEnd = end
    } else {
      timedStart = nil
      timedEnd = nil
    }
    var retained: [Part]
    if let start = timedStart {
      retained = Array(parts.prefix { part in
        guard let previousStart = part.start, let previousEnd = part.end else { return false }
        return previousStart < start && previousEnd <= start
      })
    } else {
      // Missing timing cannot establish a new utterance. Revise the current
      // hypothesis, keeping only prefixes whose boundaries were established.
      retained = Array(parts.dropLast())
    }
    retained.append(Part(text: incoming, start: timedStart, end: timedEnd))
    let merged = retained.map(\.text).joined(separator: " ")
    guard VoicePolicy.acceptsTranscript(merged) else { return nil }
    parts = retained
    text = merged
    return text
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
