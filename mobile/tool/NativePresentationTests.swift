import Darwin
import Foundation

private enum ProfileTestError: Error { case failed(String), injected }

@main struct NativePresentationTests {
  static var passed = 0
  static let initial: [String: Any] = [
    "version": 1, "name": "Test", "background": "stars", "answerStyle": "sphere",
    "onboardingStep": 0, "completed": false, "termsVersion": 0, "audioEnabled": true,
  ]

  static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ProfileTestError.failed(message) }
  }
  static func reject(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw ProfileTestError.failed(message)
  }
  static func pass(_ message: String) {
    passed += 1
    print("PASS \(message)")
  }
  static func changed(_ key: String, _ value: Any) -> [String: Any] {
    var next = initial
    next[key] = value
    return next
  }
  static func raw(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
  }

  static func main() throws {
    if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--crash" {
      let point = PresentationWriteStep(rawValue: CommandLine.arguments[2])!
      let store = PresentationStorage(root: URL(fileURLWithPath: CommandLine.arguments[3]), checkpoint: { step in
        if step == point { Darwin._exit(73) }
      })
      try store.writeProfile(CommandLine.arguments[4])
      throw ProfileTestError.failed("crash point not reached")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("universe-presentation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let profileRoot = root.appendingPathComponent("UniversePresentationV1")
    let store = PresentationStorage(root: profileRoot)
    let original = try raw(initial)
    for background in ["stars", "galaxy", "nebula", "blackHole"] {
      for style in ["coin", "sphere", "blackHole", "constellation"] {
        var profile = changed("background", background)
        profile["answerStyle"] = style
        _ = try PresentationSchema.profile(raw(profile))
      }
    }
    pass("all fixed background and answer style combinations are valid")

    for key in PresentationSchema.keys {
      var missing = initial
      missing.removeValue(forKey: key)
      try reject("missing field accepted") { _ = try PresentationSchema.profile(raw(missing)) }
    }
    try reject("unknown field accepted") { _ = try PresentationSchema.profile(raw(changed("question", "not allowed"))) }
    let badFields: [(String, Any)] = [
      ("version", 0), ("version", true), ("version", 2), ("name", 7),
      ("background", "../nebula"), ("answerStyle", "unknown"),
      ("onboardingStep", -1), ("onboardingStep", 3), ("onboardingStep", true),
      ("termsVersion", -1), ("termsVersion", 100001), ("termsVersion", false),
      ("completed", 1), ("completed", "false"), ("audioEnabled", 0), ("audioEnabled", "true"),
    ]
    for (key, value) in badFields {
      try reject("wrong field type or value") { _ = try PresentationSchema.profile(raw(changed(key, value))) }
    }
    pass("exact profile keys strict booleans integers and enums are enforced")

    for malformed in ["[]", "null", "{", original.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
                      original.replacingOccurrences(of: "\"version\":1", with: "\"version\":1e0"),
                      original.replacingOccurrences(of: "\"name\":\"Test\"", with: "\"name\":\"\\ud800\""),
                      original.replacingOccurrences(of: "\"name\":\"Test\"", with: "\"name\":\"First\",\"name\":\"Test\""),
                      original.replacingOccurrences(of: "\"name\":\"Test\"", with: "\"n\\u0061me\":\"First\",\"name\":\"Test\"") ] {
      try reject("ambiguous JSON accepted") { _ = try PresentationSchema.profile(malformed) }
    }
    try reject("oversized JSON accepted") { _ = try PresentationSchema.profile(String(repeating: " ", count: 2049) + original) }
    pass("duplicate escaped keys decimal syntax malformed and oversized JSON are rejected")

    for name in ["", String(repeating: "a", count: 40), String(repeating: "🌟", count: 40), String(repeating: "e\u{301}", count: 20)] {
      _ = try PresentationSchema.profile(raw(changed("name", name)))
    }
    _ = try PresentationSchema.profile(original.replacingOccurrences(of: "\"name\":\"Test\"", with: "\"name\":\"\\ud83c\\udf1f\""))
    for name in [String(repeating: "a", count: 41), String(repeating: "🌟", count: 41), String(repeating: "e\u{301}", count: 21)] {
      try reject("name scalar limit ignored") { _ = try PresentationSchema.profile(raw(changed("name", name))) }
    }
    for code in Array(0...31) + Array(127...159) {
      let name = "A" + String(UnicodeScalar(code)!)
      try reject("control in name accepted") { _ = try PresentationSchema.profile(raw(changed("name", name))) }
    }
    pass("names use 40 Unicode scalars and reject every C0 and C1 control")

    for step in 0...2 {
      var profile = changed("onboardingStep", step)
      _ = try PresentationSchema.profile(raw(profile))
      profile["termsVersion"] = 1
      try reject("incomplete terms acknowledged") { _ = try PresentationSchema.profile(raw(profile)) }
      profile["completed"] = true
      if step == 2 { _ = try PresentationSchema.profile(raw(profile)) }
      else { try reject("completed before third slide") { _ = try PresentationSchema.profile(raw(profile)) } }
    }
    var completed = changed("completed", true)
    completed["onboardingStep"] = 2
    try reject("completed without terms") { _ = try PresentationSchema.profile(raw(completed)) }
    completed["termsVersion"] = 100000
    let accepted = try raw(completed)
    _ = try PresentationSchema.profile(accepted)
    pass("completion requires slide two and nonzero accepted terms version")

    let untouched = root.appendingPathComponent("invalid-never-created")
    try reject("invalid write succeeded") { try PresentationStorage(root: untouched).writeProfile("{}") }
    try check(!FileManager.default.fileExists(atPath: untouched.path), "invalid write touched storage")
    try check(try store.readProfile() == nil, "missing committed file is not missing")
    try store.writeProfile(original)
    let before = try Data(contentsOf: profileRoot.appendingPathComponent("profile.json"))
    try reject("invalid replacement succeeded") { try store.writeProfile("{}") }
    try check(try Data(contentsOf: profileRoot.appendingPathComponent("profile.json")) == before, "invalid write changed profile")
    try check(try store.readProfile() == PresentationSchema.encode(PresentationSchema.profile(original)), "canonical roundtrip")
    pass("validation happens before writes and valid profile roundtrips canonically")

    let sessionRoot = root.appendingPathComponent("UniverseSessionV1")
    try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: false)
    let sessionSentinel = sessionRoot.appendingPathComponent("state.json")
    let sentinel = Data("separate-session-fixture".utf8)
    try sentinel.write(to: sessionSentinel)
    try store.writeProfile(accepted)
    try check(try Data(contentsOf: sessionSentinel) == sentinel, "profile touched question state")
    let properties = try profileRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
    try check(properties.isExcludedFromBackup == true, "profile directory included in backup")
    let attributes = try FileManager.default.attributesOfItem(atPath: profileRoot.path)
    try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "profile folder permissions")
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: profileRoot.appendingPathComponent("profile.json").path)
    try check((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "profile file permissions")
    pass("private no-backup profile storage remains separate from session state")

    let target = profileRoot.appendingPathComponent("profile.json")
    let staging = profileRoot.appendingPathComponent("profile.pending")
    try Data(original.utf8).write(to: staging)
    for bad in [Data("{".utf8), Data([0xff, 0xfe]), Data(repeating: 32, count: 2049)] {
      try bad.write(to: target)
      try reject("corruption silently defaulted or recovered from staging") { _ = try store.readProfile() }
      try check(try Data(contentsOf: target) == bad, "corrupt data was overwritten")
    }
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sessionSentinel)
    try reject("symlink read followed") { _ = try store.readProfile() }
    try FileManager.default.removeItem(at: target)
    pass("corruption invalid UTF8 oversized files and symlinks never become defaults")

    var interruptions = 0
    for hadOld in [false, true] {
      for point in PresentationWriteStep.allCases {
        let directory = root.appendingPathComponent("crash-\(hadOld)-\(point.rawValue)")
        let isolated = PresentationStorage(root: directory)
        if hadOld { try isolated.writeProfile(original) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash", point.rawValue, directory.path, accepted]
        try child.run()
        child.waitUntilExit()
        try check(child.terminationStatus == 73, "child did not stop at write checkpoint")
        let committed = [.afterRename, .afterDirectorySync].contains(point)
        let expected: String?
        if committed { expected = try PresentationSchema.encode(PresentationSchema.profile(accepted)) }
        else if hadOld { expected = try PresentationSchema.encode(PresentationSchema.profile(original)) }
        else { expected = nil }
        try check(try isolated.readProfile() == expected, "interrupted write returned partial or wrong record")
        interruptions += 1
      }
    }
    pass("ten process interruptions preserve only the old or committed profile")

    try store.writeProfile(original)
    let ambiguous = PresentationStorage(root: profileRoot, checkpoint: { point in
      if point == .afterRename { throw ProfileTestError.injected }
    })
    try reject("lost acknowledgement swallowed") { try ambiguous.writeProfile(accepted) }
    try check(try store.readProfile() == PresentationSchema.encode(PresentationSchema.profile(accepted)), "committed state not recovered")
    try check(!FileManager.default.fileExists(atPath: staging.path), "successful rename left staging")
    pass("ambiguous post-rename error propagates while committed profile remains readable")

    try check(NarrationPolicy.filename("ru") == "ru.wav" && NarrationPolicy.filename("en") == "en.wav", "fixed filenames")
    let invalidLanguages: [Any] = ["../ru", "ru.wav", "en-US", "", true, NSNull()]
    for invalid in invalidLanguages {
      try check(NarrationPolicy.filename(invalid) == nil, "arbitrary audio path accepted")
    }
    try check(NarrationPolicy.identity(1) == 1 && NarrationPolicy.identity(9_007_199_254_740_991 as Int64) != nil, "valid playback ID")
    let invalidIDs: [Any] = [0, -1, true, 1.5, "1", NSNull()]
    for invalid in invalidIDs {
      try check(NarrationPolicy.identity(invalid) == nil, "invalid playback ID")
    }
    pass("narration accepts only fixed bundled languages and positive integer identities")

    try check(NarrationPolicy.durationMilliseconds(1.234) == 1234, "duration milliseconds")
    for invalid in [Double.nan, Double.infinity, -1, 0, 601] {
      try check(NarrationPolicy.durationMilliseconds(invalid) == nil, "invalid or unbounded duration")
    }
    pass("narration durations are finite positive and bounded")
    print("Native presentation checks: \(passed)/\(passed) passed; \(interruptions) process interruptions")
  }
}
