import Foundation

private enum AmbientTestError: Error { case failed(String) }

@main struct NativeAmbientTests {
  static func check(_ value: Bool, _ message: String) throws {
    if !value { throw AmbientTestError.failed(message) }
  }
  static func main() throws {
    for environment in AmbientPolicy.environments {
      try check(AmbientPolicy.filename(environment) == environment + ".wav", "allowlisted loop")
    }
    print("PASS four fixed environment resources")
    let invalidValues: [Any] = ["../voice.wav", "https://example.org/audio", "aurora.wav", "Aurora", "", 1, true, ["stars"]]
    for invalid in invalidValues {
      try check(AmbientPolicy.filename(invalid) == nil, "reject arbitrary resource")
    }
    try check(AmbientPolicy.filename(nil) == nil, "reject missing resource")
    print("PASS no paths URLs or malformed resource types")
    for invalid in [Double.nan, Double.infinity, -1, 0, 61] {
      try check(!AmbientPolicy.validDuration(invalid), "reject malformed audio duration")
    }
    try check(AmbientPolicy.validDuration(20), "accept shipped loop duration")
    print("PASS bounded finite audio duration")
    try check(AmbientPolicy.mayDeactivate(owned: true, voiceCapturing: false, categoryIsAmbient: true), "release own session")
    try check(!AmbientPolicy.mayDeactivate(owned: false, voiceCapturing: false, categoryIsAmbient: true), "never release unowned session")
    print("PASS explicit ambient audio ownership")
    try check(!AmbientPolicy.mayDeactivate(owned: true, voiceCapturing: true, categoryIsAmbient: true), "voice owner wins before category update")
    try check(!AmbientPolicy.mayDeactivate(owned: true, voiceCapturing: false, categoryIsAmbient: false), "late stop after category handoff")
    try check(!AmbientPolicy.mayDeactivate(owned: true, voiceCapturing: true, categoryIsAmbient: false), "late stop during active recording")
    print("PASS recording ownership cannot be deactivated by ambient")
    for event in AmbientPolicy.cueEvents {
      try check(AmbientPolicy.cueFilename(event) == "cue-" + event + ".wav", "neutral cue resource")
    }
    let invalidCues: [Any] = ["yes", "no", "../cue-touch.wav", "https://example.org/audio", "touch.wav", "", 1, true]
    for invalid in invalidCues {
      try check(AmbientPolicy.cueFilename(invalid) == nil, "reject answer/path cue")
    }
    print("PASS three neutral cues with no answer-dependent resources")
    for invalid in [Double.nan, Double.infinity, -1, 0, 2.01] {
      try check(!AmbientPolicy.validCueDuration(invalid), "cue duration limit")
    }
    try check(AmbientPolicy.validCueDuration(0.24) && AmbientPolicy.validCueDuration(1.2), "short shipped cues")
    print("PASS finite short cue duration")
    print("Native ambient groups passed: 7")
  }
}
