import Foundation

private enum VoiceTestError: Error { case failed(String) }

@main struct NativeVoiceTests {
  static var passed = 0
  static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw VoiceTestError.failed(message) }
  }
  static func pass(_ message: String) {
    passed += 1
    print("PASS \(message)")
  }

  static func main() throws {
    try check(VoicePolicy.locale(for: "ru") == "ru-RU", "Russian locale")
    try check(VoicePolicy.locale(for: "en") == "en-US", "English locale")
    for unknown in ["", "en-US", "ru_RU", "fr", "EN"] {
      try check(VoicePolicy.locale(for: unknown) == nil, "unsupported locale")
    }
    pass("only explicit RU and EN voice locales are accepted")

    let validIDs: [Int64] = [0, 1, 9_007_199_254_740_991]
    for valid in validIDs {
      try check(VoicePolicy.requestID(NSNumber(value: valid)) == Int(valid), "valid ID")
    }
    let invalidIDs: [Any] = [true, false, -1, 1.5, "1", NSNull(), NSNumber(value: UInt64.max), 9_007_199_254_740_992 as Int64]
    for invalid in invalidIDs {
      try check(VoicePolicy.requestID(invalid) == nil, "invalid ID")
    }
    try check(VoicePolicy.requestID(nil) == nil, "missing ID")
    pass("request identity rejects booleans strings fractions and overflow")

    let lifecycle = VoiceLifecycle()
    let canceled = lifecycle.begin(id: 1)
    try check(lifecycle.phase == .permission, "starts awaiting permission")
    try check(lifecycle.retire(canceled), "cancel before permission")
    try check(!lifecycle.accepts(canceled) && !lifecycle.listen(canceled), "late permission cannot capture")
    pass("cancel invalidates delayed permission completion")

    let old = lifecycle.begin(id: 7)
    let current = lifecycle.begin(id: 7)
    try check(old != current, "generation independent of external ID")
    try check(!lifecycle.accepts(old) && !lifecycle.retire(old), "old terminal event ignored")
    try check(lifecycle.accepts(current) && lifecycle.phase == .permission, "new request survives stale completion")
    pass("supersession rejects callbacks even when caller reuses an ID")

    try check(lifecycle.listen(current), "permission success starts once")
    try check(!lifecycle.listen(current), "duplicate permission cannot restart")
    try check(!lifecycle.stop(old), "stale stop cannot affect microphone")
    try check(lifecycle.phase == .listening, "current request still listening")
    pass("duplicate and stale callbacks cannot start or stop another capture")

    try check(lifecycle.stop(current), "stop listening")
    try check(lifecycle.phase == .finishing && lifecycle.accepts(current), "final transcript still accepted")
    try check(!lifecycle.stop(current) && !lifecycle.listen(current), "stop is idempotent and never resumes")
    pass("graceful stop keeps final results but forbids automatic restart")

    try check(lifecycle.retire(current), "final result retires generation")
    try check(!lifecycle.retire(current) && !lifecycle.accepts(current), "only one terminal result")
    try check(lifecycle.ticket == nil && lifecycle.phase == nil, "no retained lifecycle")
    pass("terminal delivery retires once and rejects later transcript or level")

    var quiet = VoiceLevelMeter()
    for _ in 0..<200 {
      try check(quiet.update(rms: 0, seconds: 0.02) == 0, "silence")
      try check(quiet.update(rms: 0.002, seconds: 0.02) == 0, "below noise floor")
    }
    pass("silence and low room noise do not produce synthetic animation")

    var meter = VoiceLevelMeter()
    var previous = 0.0
    for _ in 0..<20 {
      let level = meter.update(rms: 0.5, seconds: 0.02)
      try check(level > previous && level <= 1 && level.isFinite, "smooth bounded attack")
      previous = level
    }
    let loud = meter.level
    try check(loud > 0.95, "voice reaches visible level")
    let release = meter.update(rms: 0, seconds: 0.02)
    try check(release < loud && release > loud * 0.8, "gradual release")
    for _ in 0..<250 { _ = meter.update(rms: 0, seconds: 0.02) }
    try check(meter.level == 0, "returns fully to quiet")
    pass("level follows actual RMS with smooth attack and slower release")

    for invalid in [Double.nan, Double.infinity, -1] {
      try check(meter.update(rms: invalid, seconds: 0.02) == 0, "nonfinite RMS")
    }
    for duration in [Double.nan, Double.infinity, 0, -1] {
      try check(meter.update(rms: 1, seconds: duration) == 0, "invalid interval")
    }
    try check(meter.update(rms: 100, seconds: 10) <= 1, "large finite input bounded")
    pass("invalid audio measurements cannot leak NaN or unbounded levels")

    try check(VoicePolicy.acceptsTranscript(String(repeating: "a", count: 8192)), "text boundary")
    try check(!VoicePolicy.acceptsTranscript(String(repeating: "a", count: 8193)), "overlong text rejected, not truncated")
    try check(VoicePolicy.acceptsTranscript(String(repeating: "🌟", count: 4096)), "UTF16 boundary")
    try check(!VoicePolicy.acceptsTranscript(String(repeating: "🌟", count: 4097)), "Dart UTF16 length respected")
    pass("transcript size matches Dart UTF16 limit without silent truncation")

    var transcript = VoiceTranscriptBuffer()
    try check(transcript.update("Should", start: 0.2, end: 0.5) == "Should", "first partial")
    try check(transcript.update("Should I read", start: 0.2, end: 1.5) == "Should I read", "cumulative partial")
    try check(transcript.update("Should I read", start: 0.2, end: 1.5) == "Should I read", "repeated callback")
    try check(transcript.update("Should I write", start: 0.2, end: 1.5) == "Should I write", "corrected hypothesis")
    pass("partial and corrected hypotheses replace the same audio range without duplication")

    try check(transcript.update("today", start: 3, end: 3.5) == "Should I write today", "new utterance after silence")
    try check(transcript.update("today or", start: 3, end: 4) == "Should I write today or", "new partial keeps prior utterance")
    try check(transcript.update("today or tomorrow?", start: 3, end: 4.8) == "Should I write today or tomorrow?", "final phrase revision")
    pass("a later disjoint audio range keeps the accepted phrase across a pause")

    try check(transcript.update("Should I write today or tomorrow?", start: 0.2, end: 4.8) == "Should I write today or tomorrow?", "full cumulative result replaces covered snapshots")
    try check(transcript.update("", start: nil, end: nil) == "Should I write today or tomorrow?", "empty result")
    try check(transcript.update(" \n", start: nil, end: nil) == "Should I write today or tomorrow?", "blank result")
    pass("cumulative final and empty silence results do not duplicate or erase previous speech")

    var repeated = VoiceTranscriptBuffer()
    try check(repeated.update("yes", start: 0, end: 0.4) == "yes", "initial word")
    try check(repeated.update("yes", start: 1, end: 1.4) == "yes yes", "intentional repeated word")
    try check(repeated.update("yes", start: 1, end: 1.4) == "yes yes", "repeated same event")
    pass("intentional repetition at distinct audio times is preserved without duplicate callbacks")

    var untimed = VoiceTranscriptBuffer()
    try check(untimed.update("first", start: 0, end: 0.5) == "first", "known prefix")
    try check(untimed.update("second", start: 2, end: 2.5) == "first second", "known current phrase")
    try check(untimed.update("second revised", start: 0, end: 0) == "first second revised", "zero duration partial")
    try check(untimed.update("second complete", start: 2, end: 3) == "first second complete", "timing resumes")
    try check(untimed.update("all revised", start: 0, end: 3) == "all revised", "timestamp reset is a revision, never guessed append")
    pass("untimed partials revise only the active phrase and ambiguous resets never guess a boundary")

    var bounded = VoiceTranscriptBuffer()
    let nearLimit = String(repeating: "🌟", count: 4095)
    try check(bounded.update(nearLimit, start: 0, end: 1) == nearLimit, "UTF16 prefix")
    try check(bounded.update("x", start: 2, end: 3) == nearLimit + " x", "combined boundary")
    try check(bounded.update("xx", start: 2, end: 3) == nil, "combined overflow")
    try check(bounded.text == nearLimit + " x", "overflow retains last accepted text")
    pass("combined utterances enforce UTF16 bounds without silent truncation or state corruption")

    let invalidTiming: [(Double?, Double?)] = [(Double.nan, 1), (0, Double.infinity), (-1, 1), (2, 1), (nil, 1), (0, nil)]
    for interval in invalidTiming {
      try check(bounded.update("invalid", start: interval.0, end: interval.1) == nil, "invalid interval rejected")
      try check(bounded.text == nearLimit + " x", "invalid interval cannot edit current draft")
    }
    bounded = VoiceTranscriptBuffer()
    try check(bounded.text.isEmpty, "capture disposal clears text")
    try check(bounded.update("fresh capture", start: 0, end: 1) == "fresh capture", "new capture has no old transcript")
    pass("invalid timing cannot corrupt text and a new capture has no retained transcription")

    try check(VoicePolicy.recordingSeconds == 60 && VoicePolicy.permissionSeconds == 60, "bounded capture and permissions")
    try check(VoicePolicy.finalizationSeconds == 2, "bounded finalization")
    pass("capture permission and finalization waits have explicit limits")
    print("Native voice checks: \(passed)/\(passed) passed")
  }
}
