import Darwin
import Foundation

enum StorageTestError: Error { case failed(String), injected }
func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
  let result = try condition()
  if !result { throw StorageTestError.failed(label) }
}
func mustReject(_ label: String, _ body: () throws -> Void) throws {
  do { try body() } catch { return }
  throw StorageTestError.failed(label)
}

struct RecordFixture: Decodable {
  let name: String
  let scope: String
  let raw: String
  let valid: Bool
}

@main
struct NativeStorageTests {
  static let records = [
    "{\"version\":1,\"phase\":\"idle\"}",
    "{\"version\":1,\"phase\":\"reserved\"}",
    "{\"version\":1,\"phase\":\"pending\",\"answer\":\"yes\"}",
    "{\"version\":1,\"phase\":\"cooldown\",\"utcDeadline\":1900000,\"continuousDeadline\":1900000,\"bootToken\":\"fixture-boot\"}"
  ]

  static func main() throws {
    if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "interrupt-write" {
      let cut = SessionWriteStep(rawValue: CommandLine.arguments[4])!
      let scope = SessionScope(rawValue: CommandLine.arguments[3])!
      let store = SessionStorage(root: URL(fileURLWithPath: CommandLine.arguments[2]), checkpoint: { step in
        if step == cut { _exit(73) }
      })
      try store.writeState(scope, records[Int(CommandLine.arguments[5])!])
      throw StorageTestError.failed("interruption checkpoint was not reached")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("universe-storage-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStorage(root: root)
    var passed = 0
    func pass(_ label: String) {
      passed += 1
      print("PASS storage \(passed): \(label)")
      fflush(stdout)
    }
    func path(_ scope: SessionScope, _ name: String) -> URL {
      root.appendingPathComponent(scope.rawValue).appendingPathComponent(name)
    }
    func canonical(_ index: Int, _ scope: SessionScope) throws -> String {
      try SessionSchema.encode(SessionSchema.state(records[index], scope: scope))
    }

    let fixtures = try JSONDecoder().decode([RecordFixture].self,
      from: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/session_records.json")))
    for fixture in fixtures {
      let scope = SessionScope(rawValue: fixture.scope)!
      try store.writeState(scope, records[3])
      let before = try Data(contentsOf: path(scope, "state.json"))
      if fixture.valid {
        try store.writeState(scope, fixture.raw)
        let saved = try store.readState(scope)!
        _ = try SessionSchema.state(saved, scope: scope)
      } else {
        try mustReject("invalid state accepted: " + fixture.name) { try store.writeState(scope, fixture.raw) }
        try check(try Data(contentsOf: path(scope, "state.json")) == before, "invalid input changed committed bytes")
      }
    }
    pass("shared Dart/Swift state contract: \(fixtures.count) cases; rejected input preserves bytes")

    for invalid in ["{\"language\":\"ru\",\"notifications\":1}",
      "{\"language\":\"ru\",\"notifications\":0}",
      "{\"language\":\"ru\",\"notifications\":\"true\"}",
      "{\"language\":\"ru\",\"notifications\":null}",
      "{\"language\":\"fr\",\"notifications\":false}",
      "{\"language\":\"ru\",\"notifications\":false,\"extra\":1}"] {
      try mustReject("invalid preferences accepted") { _ = try SessionSchema.preferences(invalid) }
    }
    try check(try SessionSchema.boolean(true), "bool accepted")
    for value in [NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: 2)] {
      try mustReject("numeric switch accepted as bool") { _ = try SessionSchema.boolean(value) }
    }
    pass("notification preference and channel switch require actual booleans")

    try store.savePreferences(.real, ["language": "ru", "notifications": true])
    let prefsBefore = try Data(contentsOf: path(.real, "preferences.json"))
    try mustReject("invalid preferences overwrite") {
      try store.savePreferences(.real, ["language": "ru", "notifications": 1])
    }
    try check(try Data(contentsOf: path(.real, "preferences.json")) == prefsBefore, "preference bytes preserved")
    pass("invalid preferences cannot overwrite saved opt-in")

    var crashes = 0
    for scope in [SessionScope.real, .diagnostic] {
      for (before, after) in [(0, 1), (1, 2), (2, 3), (3, 0)] {
        for cut in SessionWriteStep.allCases {
          try store.writeState(scope, records[before])
          let child = Process()
          child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
          child.arguments = ["interrupt-write", root.path, scope.rawValue, cut.rawValue, String(after)]
          try child.run()
          child.waitUntilExit()
          try check(child.terminationStatus == 73, "child exited at intended checkpoint")
          let committed = cut == .afterRename || cut == .afterDirectorySync ? after : before
          let recovered = try SessionStorage(root: root).readState(scope)
          try check(recovered == (try canonical(committed, scope)), "interrupted write exposed partial/incorrect state")
          crashes += 1
        }
      }
    }
    pass("\(crashes) process exits across 5 write checkpoints and both scopes")

    let freshRoot = root.appendingPathComponent("first-write")
    let interrupted = SessionStorage(root: freshRoot, checkpoint: { step in
      if step == .afterFileSync { throw StorageTestError.injected }
    })
    try mustReject("first write failure") { try interrupted.writeState(.real, records[1]) }
    try check(try SessionStorage(root: freshRoot).readState(.real) == nil, "staging is not a committed reservation")
    pass("first uncommitted reservation is never loaded from staging")

    try store.writeState(.real, records[2])
    let ambiguous = SessionStorage(root: root, checkpoint: { step in
      if step == .afterRename { throw StorageTestError.injected }
    })
    try mustReject("ambiguous write must propagate failure") { try ambiguous.writeState(.real, records[3]) }
    try check(try store.readState(.real) == canonical(3, .real), "reload sees committed cooldown after ambiguous error")
    pass("error after rename propagates; reload recovers the committed timer")

    try Data(records[2].utf8).write(to: path(.real, "state.pending"))
    for bad in [Data("{".utf8), Data([0xff, 0xfe]), Data(repeating: 32, count: 1024 * 1024)] {
      try bad.write(to: path(.real, "state.json"))
      try mustReject("damaged committed record must block") { _ = try store.readState(.real) }
      try check(try Data(contentsOf: path(.real, "state.json")) == bad, "damaged state not silently reset")
    }
    pass("corrupt, invalid UTF-8 and oversized committed files never use pending data")

    try store.writeState(.real, records[3])
    let realBefore = try Data(contentsOf: path(.real, "state.json"))
    try store.writeState(.diagnostic, records[0])
    try check(try Data(contentsOf: path(.real, "state.json")) == realBefore, "diagnostic reset changed real timer")
    let saved = try store.readState(.real)!
    try check(!saved.contains("answer") && !saved.contains("question"), "cooldown contains private input or answer")
    pass("diagnostic reset isolation and answer removal in committed cooldown")

    try store.writeState(.diagnostic, "{\"version\":1,\"phase\":\"fixture-discarded-value\",\"phase\":\"idle\"}")
    let canonicalBytes = try Data(contentsOf: path(.diagnostic, "state.json"))
    try check(!String(decoding: canonicalBytes, as: UTF8.self).contains("fixture-discarded-value"), "unused raw JSON value persisted")
    try check(!FileManager.default.fileExists(atPath: path(.diagnostic, "state.pending").path), "successful commit left staging data")
    pass("canonical write keeps only validated values and consumes staging file")

    for scope in [SessionScope.real, .diagnostic] {
      let values = try root.appendingPathComponent(scope.rawValue).resourceValues(forKeys: [.isExcludedFromBackupKey])
      try check(values.isExcludedFromBackup == true, "private folder included in backup")
    }
    pass("both private scope directories excluded from backup")
    print("Native storage checks: \(passed)/\(passed) passed; \(fixtures.count) contract cases; \(crashes) process interruptions")
  }
}
