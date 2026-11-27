import Darwin
import Foundation

enum SessionWriteStep: String, CaseIterable {
  case beforeStaging, afterStaging, afterFileSync, afterRename, afterDirectorySync
}
enum SessionStorageError: Error { case system(Int32) }

// One owner per scope, serialized by SessionBridge. The optional checkpoint is
// injected only by the standalone test executable, never from a channel call,
// environment variable or an app setting. No testing commands exist in the app.
struct SessionStorage {
  let root: URL
  var checkpoint: (SessionWriteStep) throws -> Void
  let preferredLanguages: [String]

  init(root: URL, checkpoint: @escaping (SessionWriteStep) throws -> Void = { _ in },
       preferredLanguages: [String] = Locale.preferredLanguages) {
    self.root = root
    self.checkpoint = checkpoint
    self.preferredLanguages = preferredLanguages
  }

  static func initialLanguage(_ preferred: [String]) -> String {
    for identifier in preferred {
      let language = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
      if language == "ru" || language == "en" { return language! }
    }
    return "ru"
  }

  private func folder(_ scope: SessionScope) throws -> URL {
    var directory = root.appendingPathComponent(scope.rawValue, isDirectory: true)
    #if os(iOS)
    let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    #else
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    #endif
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    return directory
  }

  private func read(_ scope: SessionScope, _ name: SessionFile) throws -> String? {
    let url = try folder(scope).appendingPathComponent(name.rawValue + ".json")
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 {
      let code = errno
      if code == ENOENT { return nil }
      throw SessionStorageError.system(code)
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    // Read at most the allowed size plus one byte, including a possible short
    // read. A malformed or oversized committed file never falls back to staging.
    var data = Data()
    while data.count <= SessionSchema.maxBytes {
      guard let chunk = try file.read(upToCount: SessionSchema.maxBytes + 1 - data.count), !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard data.count <= SessionSchema.maxBytes, let text = String(data: data, encoding: .utf8) else { throw SessionDataError.invalid }
    return text
  }

  private func write(_ scope: SessionScope, _ name: SessionFile, _ value: String) throws {
    guard let data = value.data(using: .utf8), data.count <= SessionSchema.maxBytes else { throw SessionDataError.invalid }
    let directory = try folder(scope)
    let temp = directory.appendingPathComponent(name.rawValue + ".pending")
    let target = directory.appendingPathComponent(name.rawValue + ".json")
    try checkpoint(.beforeStaging)
    #if os(iOS)
    try data.write(to: temp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: temp, options: .atomic)
    #endif
    try checkpoint(.afterStaging)
    let file = try FileHandle(forWritingTo: temp)
    do { try file.synchronize(); try file.close() }
    catch { try? file.close(); throw error }
    try checkpoint(.afterFileSync)
    guard Darwin.rename(temp.path, target.path) == 0 else { throw SessionStorageError.system(errno) }
    try checkpoint(.afterRename)
    let descriptor = Darwin.open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw SessionStorageError.system(errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw SessionStorageError.system(errno) }
    try checkpoint(.afterDirectorySync)
  }

  func readState(_ scope: SessionScope) throws -> String? {
    guard let raw = try read(scope, .state) else { return nil }
    return try SessionSchema.encode(SessionSchema.state(raw, scope: scope))
  }

  func writeState(_ scope: SessionScope, _ raw: String) throws {
    // Validate before touching the existing files; store only checked values.
    // Re-encoding keeps one canonical form, without unchecked raw formatting.
    let value = try SessionSchema.encode(SessionSchema.state(raw, scope: scope))
    try write(scope, .state, value)
  }

  func preferences(_ scope: SessionScope) throws -> [String: Any] {
    guard let raw = try read(scope, .preferences) else {
      return ["language": Self.initialLanguage(preferredLanguages), "notifications": false]
    }
    return try SessionSchema.preferences(raw)
  }

  func savePreferences(_ scope: SessionScope, _ preferences: [String: Any]) throws {
    let raw = try SessionSchema.encode(preferences)
    _ = try SessionSchema.preferences(raw)
    try write(scope, .preferences, raw)
  }
}
