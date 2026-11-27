import Darwin
import Foundation

enum PresentationWriteStep: String, CaseIterable {
  case beforeStaging, afterStaging, afterFileSync, afterRename, afterDirectorySync
}
enum PresentationStorageError: Error { case system(Int32) }

// Separate from question/session data. The bridge serializes access. Injection
// checkpoints are available only to the standalone native test executable.
struct PresentationStorage {
  let root: URL
  var checkpoint: (PresentationWriteStep) throws -> Void = { _ in }

  private func directory() throws -> URL {
    var directory = root
    #if os(iOS)
    let attributes: [FileAttributeKey: Any] = [
      .posixPermissions: 0o700,
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
    ]
    #else
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    #endif
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
    try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    return directory
  }

  func readProfile() throws -> String? {
    let url = try directory().appendingPathComponent("profile.json")
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 {
      let code = errno
      if code == ENOENT { return nil }
      throw PresentationStorageError.system(code)
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var data = Data()
    while data.count <= PresentationSchema.maxBytes {
      guard let chunk = try file.read(upToCount: PresentationSchema.maxBytes + 1 - data.count), !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard data.count <= PresentationSchema.maxBytes, let text = String(data: data, encoding: .utf8) else { throw PresentationDataError.invalid }
    // Legacy v1 is mapped in memory only. Reading must never replace the
    // user's original file; an explicit later write atomically commits v2.
    return try PresentationSchema.encode(PresentationSchema.profile(text))
  }

  func writeProfile(_ raw: String) throws {
    // Do not even create the directory for an invalid write.
    let value = try PresentationSchema.encode(PresentationSchema.profile(raw))
    let data = Data(value.utf8)
    let folder = try directory()
    let pending = folder.appendingPathComponent("profile.pending")
    let target = folder.appendingPathComponent("profile.json")
    try checkpoint(.beforeStaging)
    #if os(iOS)
    try data.write(to: pending, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: pending, options: .atomic)
    #endif
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
    try checkpoint(.afterStaging)
    let file = try FileHandle(forWritingTo: pending)
    do { try file.synchronize(); try file.close() }
    catch { try? file.close(); throw error }
    try checkpoint(.afterFileSync)
    guard Darwin.rename(pending.path, target.path) == 0 else { throw PresentationStorageError.system(errno) }
    try checkpoint(.afterRename)
    let descriptor = Darwin.open(folder.path, O_RDONLY)
    guard descriptor >= 0 else { throw PresentationStorageError.system(errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw PresentationStorageError.system(errno) }
    try checkpoint(.afterDirectorySync)
  }

  func readWorld() throws -> String? {
    let url = try directory().appendingPathComponent("world.json")
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw PresentationStorageError.system(errno)
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var data = Data()
    while data.count <= WorldSchema.maxBytes {
      guard let chunk = try file.read(upToCount: WorldSchema.maxBytes + 1 - data.count), !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard let raw = String(data: data, encoding: .utf8) else { throw PresentationDataError.invalid }
    try WorldSchema.validate(raw)
    return raw
  }

  func writeWorld(_ raw: String) throws {
    try WorldSchema.validate(raw)
    let folder = try directory()
    let pending = folder.appendingPathComponent("world.pending")
    let target = folder.appendingPathComponent("world.json")
    let data = Data(raw.utf8)
    try checkpoint(.beforeStaging)
    #if os(iOS)
    try data.write(to: pending, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: pending, options: .atomic)
    #endif
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
    try checkpoint(.afterStaging)
    let file = try FileHandle(forWritingTo: pending)
    do { try file.synchronize(); try file.close() }
    catch { try? file.close(); throw error }
    try checkpoint(.afterFileSync)
    guard Darwin.rename(pending.path, target.path) == 0 else { throw PresentationStorageError.system(errno) }
    try checkpoint(.afterRename)
    let descriptor = Darwin.open(folder.path, O_RDONLY)
    guard descriptor >= 0 else { throw PresentationStorageError.system(errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw PresentationStorageError.system(errno) }
    try checkpoint(.afterDirectorySync)
  }
}
