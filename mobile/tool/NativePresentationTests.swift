import Darwin
import Foundation

private enum ProfileTestError: Error { case failed(String), injected }

@main struct NativePresentationTests {
  static var passed = 0
  static let initial: [String: Any] = [
    "version": 2, "name": "Test", "background": "aurora", "answerStyle": "livingMatter",
    "onboardingStep": 0, "completed": false, "termsVersion": 0, "audioEnabled": true,
    "ambientEnabled": false, "hapticsEnabled": true,
  ]
  static let legacyInitial: [String: Any] = [
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
    for background in ["stars", "galaxy", "aurora", "gravity"] {
      for style in ["livingMatter", "liquidMetal", "infinity", "constellation"] {
        var profile = changed("background", background)
        profile["answerStyle"] = style
        _ = try PresentationSchema.profile(raw(profile))
      }
    }
    pass("all fixed background and answer style combinations are valid")

    let legacyBackgrounds = ["stars": "stars", "galaxy": "galaxy", "nebula": "aurora", "blackHole": "gravity"]
    let legacyStyles = ["coin": "livingMatter", "sphere": "liquidMetal", "blackHole": "infinity", "constellation": "constellation"]
    for (oldBackground, background) in legacyBackgrounds {
      for (oldStyle, style) in legacyStyles {
        var legacy = legacyInitial
        legacy["background"] = oldBackground
        legacy["answerStyle"] = oldStyle
        legacy["completed"] = true
        legacy["onboardingStep"] = 2
        legacy["termsVersion"] = 7
        legacy["audioEnabled"] = false
        let rawLegacy = try raw(legacy)
        let migrated = try PresentationSchema.profile(rawLegacy)
        try check(migrated["version"] as? Int == 2 && Set(migrated.keys) == PresentationSchema.keys, "migration schema")
        try check(migrated["background"] as? String == background && migrated["answerStyle"] as? String == style, "migration choices")
        try check(migrated["name"] as? String == "Test" && migrated["termsVersion"] as? Int == 7, "migration changed personal data or consent")
        try check(migrated["completed"] as? Bool == true && migrated["onboardingStep"] as? Int == 2, "migration changed onboarding")
        try check(migrated["audioEnabled"] as? Bool == false && migrated["ambientEnabled"] as? Bool == false && migrated["hapticsEnabled"] as? Bool == true, "migration audio preferences")
        let legacyRoot = root.appendingPathComponent("legacy-\(oldBackground)-\(oldStyle)")
        let legacyStore = PresentationStorage(root: legacyRoot)
        try check(try legacyStore.readProfile() == nil, "legacy fixture unexpectedly exists")
        let legacyTarget = legacyRoot.appendingPathComponent("profile.json")
        let legacyBytes = Data(rawLegacy.utf8)
        try legacyBytes.write(to: legacyTarget)
        for _ in 0..<2 {
          try check(try legacyStore.readProfile() == PresentationSchema.encode(migrated), "legacy read not canonical v2")
          try check(try Data(contentsOf: legacyTarget) == legacyBytes, "read rewrote legacy file")
          try check(!FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("profile.pending").path), "read staged a migration")
        }
      }
    }
    pass("all 16 legacy choices migrate in memory without changing the original bytes or consent")

    var badLegacy = [legacyInitial]
    badLegacy[0]["ambientEnabled"] = false
    for (key, value) in [("version", 2 as Any), ("background", "aurora" as Any), ("answerStyle", "livingMatter" as Any),
                         ("audioEnabled", 1 as Any), ("completed", true as Any), ("hapticsEnabled", true as Any)] {
      var item = legacyInitial
      item[key] = value
      badLegacy.append(item)
    }
    var missingLegacy = legacyInitial
    missingLegacy.removeValue(forKey: "name")
    badLegacy.append(missingLegacy)
    for invalid in badLegacy {
      try reject("mixed or corrupt legacy schema migrated") { _ = try PresentationSchema.profile(raw(invalid)) }
    }
    let rawLegacy = try raw(legacyInitial)
    for invalid in [rawLegacy.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
                    rawLegacy.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"\\u0076ersion\":1")] {
      try reject("ambiguous legacy schema migrated") { _ = try PresentationSchema.profile(invalid) }
    }
    for step in 0...2 {
      for enabled in [false, true] {
        var legacy = legacyInitial
        legacy["onboardingStep"] = step
        legacy["audioEnabled"] = enabled
        let migrated = try PresentationSchema.profile(raw(legacy))
        try check(migrated["completed"] as? Bool == false && migrated["termsVersion"] as? Int == 0 && migrated["onboardingStep"] as? Int == step, "migration accepted unfinished terms")
        try check(migrated["audioEnabled"] as? Bool == enabled && migrated["ambientEnabled"] as? Bool == false, "narration opted user into ambience")
      }
    }
    pass("legacy migration rejects mixed schemas and preserves incomplete onboarding and narration choice")

    for key in PresentationSchema.keys {
      var missing = initial
      missing.removeValue(forKey: key)
      try reject("missing field accepted") { _ = try PresentationSchema.profile(raw(missing)) }
    }
    try reject("unknown field accepted") { _ = try PresentationSchema.profile(raw(changed("question", "not allowed"))) }
    let badFields: [(String, Any)] = [
      ("version", 0), ("version", true), ("version", 1), ("version", 3), ("name", 7),
      ("background", "../nebula"), ("answerStyle", "unknown"),
      ("background", "nebula"), ("background", "blackHole"),
      ("answerStyle", "coin"), ("answerStyle", "sphere"), ("answerStyle", "blackHole"),
      ("onboardingStep", -1), ("onboardingStep", 3), ("onboardingStep", true),
      ("termsVersion", -1), ("termsVersion", 100001), ("termsVersion", false),
      ("completed", 1), ("completed", "false"), ("audioEnabled", 0), ("audioEnabled", "true"),
      ("ambientEnabled", 1), ("ambientEnabled", "false"), ("hapticsEnabled", 0), ("hapticsEnabled", "true"),
    ]
    for (key, value) in badFields {
      try reject("wrong field type or value") { _ = try PresentationSchema.profile(raw(changed(key, value))) }
    }
    pass("exact profile keys strict booleans integers and enums are enforced")

    for malformed in ["[]", "null", "{", original.replacingOccurrences(of: "\"version\":2", with: "\"version\":2.0"),
                      original.replacingOccurrences(of: "\"version\":2", with: "\"version\":2e0"),
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

    for point in PresentationWriteStep.allCases {
      let directory = root.appendingPathComponent("legacy-crash-\(point.rawValue)")
      let isolated = PresentationStorage(root: directory)
      _ = try isolated.readProfile()
      let legacyTarget = directory.appendingPathComponent("profile.json")
      let legacyBytes = Data(rawLegacy.utf8)
      try legacyBytes.write(to: legacyTarget)
      let child = Process()
      child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = ["--crash", point.rawValue, directory.path, accepted]
      try child.run()
      child.waitUntilExit()
      try check(child.terminationStatus == 73, "legacy migration missed crash checkpoint")
      let committed = [.afterRename, .afterDirectorySync].contains(point)
      let bytes = try Data(contentsOf: legacyTarget)
      let expectedBytes = committed ? Data(try PresentationSchema.encode(PresentationSchema.profile(accepted)).utf8) : legacyBytes
      try check(bytes == expectedBytes, "interrupted migration changed original bytes before atomic rename")
      let expectedRead = try PresentationSchema.encode(PresentationSchema.profile(committed ? accepted : rawLegacy))
      try check(try isolated.readProfile() == expectedRead, "interrupted migration could not restore old or new profile")
      try check(try Data(contentsOf: legacyTarget) == bytes, "post-crash read committed a migration")
      interruptions += 1
    }
    pass("five migration process interruptions preserve exact v1 bytes until atomic v2 commit")

    try store.writeProfile(original)
    let ambiguous = PresentationStorage(root: profileRoot, checkpoint: { point in
      if point == .afterRename { throw ProfileTestError.injected }
    })
    try reject("lost acknowledgement swallowed") { try ambiguous.writeProfile(accepted) }
    try check(try store.readProfile() == PresentationSchema.encode(PresentationSchema.profile(accepted)), "committed state not recovered")
    try check(!FileManager.default.fileExists(atPath: staging.path), "successful rename left staging")
    pass("ambiguous post-rename error propagates while committed profile remains readable")

    for point in [PresentationWriteStep.afterFileSync, .afterRename] {
      try Data(rawLegacy.utf8).write(to: target)
      let migrating = PresentationStorage(root: profileRoot, checkpoint: { step in
        if step == point { throw ProfileTestError.injected }
      })
      try reject("migration write error swallowed") { try migrating.writeProfile(accepted) }
      let committed = point == .afterRename
      let expected = committed ? accepted : rawLegacy
      try check(try Data(contentsOf: target) == Data(expected.utf8), "migration acknowledgement error changed wrong version")
      try check(try store.readProfile() == PresentationSchema.encode(PresentationSchema.profile(expected)), "migration readback failed")
      try check(try Data(contentsOf: target) == Data(expected.utf8), "migration readback wrote data")
    }
    pass("migration write errors before and after rename require readback without silently resetting data")

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
    let world = "{\"version\":1,\"consent\":false,\"reduceMotion\":true,\"pending\":[],\"batch\":null,\"cache\":[]}"
    try store.writeWorld(world)
    try check(try store.readWorld() == world, "world preferences not restored")
    pass("world consent and quiet mode persist in separate state")
    for unsafe in [world.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"name\":\"private\""),
                   world.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
                   world.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
                   world.replacingOccurrences(of: "\"consent\":false", with: "\"consent\":0")] {
      try reject("unsafe world record accepted") { try store.writeWorld(unsafe) }
      try check(try store.readWorld() == world, "unsafe world write replaced original")
    }
    pass("world data rejects unknown personal fields, duplicate keys and wrong types")
    let counts = world.replacingOccurrences(of: "\"consent\":false", with: "\"consent\":true")
      .replacingOccurrences(of: "\"pending\":[]", with: "\"pending\":[{\"topic\":\"read_novel\",\"language\":\"ru\",\"day\":\"2026-11-27\",\"count\":1}]")
    try store.writeWorld(counts)
    for unsafe in [counts.replacingOccurrences(of: "read_novel", with: "private question"),
                   counts.replacingOccurrences(of: "2026-11-27", with: "2026-02-30"),
                   counts.replacingOccurrences(of: "\"count\":1", with: "\"count\":49"),
                   counts.replacingOccurrences(of: "\"consent\":true", with: "\"consent\":false")] {
      try reject("unsafe counter accepted") { try store.writeWorld(unsafe) }
    }
    pass("world queue accepts only known topics and bounded consented daily counts")
    for point in PresentationWriteStep.allCases {
      try store.writeWorld(world)
      let injected = PresentationStorage(root: profileRoot, checkpoint: { step in
        if step == point { throw ProfileTestError.injected }
      })
      try reject("world storage error swallowed") { try injected.writeWorld(counts) }
      let committed = [.afterRename, .afterDirectorySync].contains(point)
      try check(try store.readWorld() == (committed ? counts : world), "partial world state restored")
    }
    pass("world atomic replacement preserves old or new state at five fault boundaries")
    print("Native presentation checks: \(passed)/\(passed) passed; \(interruptions) process interruptions")
  }
}
