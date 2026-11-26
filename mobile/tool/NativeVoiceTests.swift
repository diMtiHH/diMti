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

    try check(VoicePolicy.recordingSeconds == 60 && VoicePolicy.permissionSeconds == 60, "bounded capture and permissions")
    try check(VoicePolicy.finalizationSeconds == 2, "bounded finalization")
    pass("capture permission and finalization waits have explicit limits")
    print("Native voice checks: \(passed)/\(passed) passed")
  }
}
