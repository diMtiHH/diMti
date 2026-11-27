import Foundation

enum AmbientPolicy {
  static let environments = ["stars", "galaxy", "aurora", "gravity"]
  static func filename(_ value: Any?) -> String? {
    guard let environment = value as? String, environments.contains(environment) else { return nil }
    return environment + ".wav"
  }
  static func validDuration(_ seconds: Double) -> Bool {
    seconds.isFinite && seconds > 0 && seconds <= 60
  }
  static let cueEvents = ["touch", "transform", "reveal"]
  static func cueFilename(_ value: Any?) -> String? {
    guard let event = value as? String, cueEvents.contains(event) else { return nil }
    return "cue-" + event + ".wav"
  }
  static func validCueDuration(_ seconds: Double) -> Bool {
    seconds.isFinite && seconds > 0 && seconds <= 2
  }
  // A late ambient stop must never deactivate an audio session acquired by
  // recording or another owner. Keep this rule independent of UIKit for tests.
  static func mayDeactivate(owned: Bool, voiceCapturing: Bool, categoryIsAmbient: Bool) -> Bool {
    owned && !voiceCapturing && categoryIsAmbient
  }
}
