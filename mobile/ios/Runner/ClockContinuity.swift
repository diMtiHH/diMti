import Darwin
import Foundation

enum ClockContinuityError: Error { case invalidMarker, system(Int32) }

struct ClockMarker: Codable, Equatable {
  let version: Int
  let name: String
  let token: String

  static func fresh(name: String? = nil) -> ClockMarker {
    ClockMarker(version: 1,
      name: name ?? "/atu" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24),
      token: UUID().uuidString)
  }

  static func decode(_ data: Data) throws -> ClockMarker {
    guard data.count <= 512,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["version", "name", "token"] else { throw ClockContinuityError.invalidMarker }
    let marker = try JSONDecoder().decode(ClockMarker.self, from: data)
    guard marker.version == 1, marker.name.hasPrefix("/atu"), marker.name.utf8.count == 28,
      marker.name.dropFirst(4).allSatisfy({ "0123456789abcdef".contains($0) }),
      UUID(uuidString: marker.token) != nil else { throw ClockContinuityError.invalidMarker }
    return marker
  }
}

// Caller holds an exclusive file lock. A NEW token must be durably committed
// BEFORE a missing kernel marker is created. This ordering also handles a crash
// after an ambiguous disk write: another launch rotates again before creation.
enum ClockContinuity {
  static func resolve(read: () throws -> ClockMarker?,
                      save: (ClockMarker) throws -> Void,
                      semaphore: (String, Bool) -> Int32,
                      fallback: () throws -> String) throws -> String {
    let previous = try read()
    if let previous = previous {
      let status = semaphore(previous.name, false)
      if status == 0 { return "semaphore-v1:" + previous.token }
      if unsupported(status) { return try fallback() }
      guard status == ENOENT else { throw ClockContinuityError.system(status) }
    }
    let next = ClockMarker.fresh(name: previous?.name)
    try save(next)
    let status = semaphore(next.name, true)
    if unsupported(status) { return try fallback() }
    guard status == 0 else { throw ClockContinuityError.system(status) }
    return "semaphore-v1:" + next.token
  }

  static func unsupported(_ status: Int32) -> Bool {
    [EPERM, EACCES, ENOSYS, ENOTSUP].contains(status)
  }
}

// One cached domain for both scopes. No device identifier, entitlement or
// question data. The random name lives only in the app's protected container.
final class ClockDomain {
  private var cached: String?
  private let directory: URL
  init(directory: URL) { self.directory = directory }

  func token() throws -> String {
    if let cached = cached { return cached }
    let manager = FileManager.default
    #if os(iOS)
    let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    #else
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    #endif
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
    let lock = Darwin.open(directory.appendingPathComponent("marker.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw ClockContinuityError.system(errno) }
    defer { Darwin.close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ClockContinuityError.system(errno) }
    defer { flock(lock, LOCK_UN) }
    let result = try ClockContinuity.resolve(read: read, save: save,
      semaphore: { name, create in name.withCString { universe_clock_semaphore($0, create ? 1 : 0) } },
      fallback: Self.bootTime)
    cached = result
    return result
  }

  private func read() throws -> ClockMarker? {
    do { return try ClockMarker.decode(Data(contentsOf: directory.appendingPathComponent("marker.json"))) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
  }

  private func save(_ marker: ClockMarker) throws {
    let data = try JSONEncoder().encode(marker)
    let temp = directory.appendingPathComponent("marker.pending")
    let target = directory.appendingPathComponent("marker.json")
    #if os(iOS)
    try data.write(to: temp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: temp, options: .atomic)
    #endif
    let file = try FileHandle(forWritingTo: temp)
    do { try file.synchronize(); try file.close() }
    catch { try? file.close(); throw error }
    guard Darwin.rename(temp.path, target.path) == 0 else { throw ClockContinuityError.system(errno) }
    let descriptor = Darwin.open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw ClockContinuityError.system(errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw ClockContinuityError.system(errno) }
  }

  private static func bootTime() throws -> String {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    let status = mib.withUnsafeMutableBufferPointer { buffer in
      sysctl(buffer.baseAddress, UInt32(buffer.count), &boot, &size, nil, 0)
    }
    guard status == 0, size == MemoryLayout<timeval>.size,
      boot.tv_sec > 0, boot.tv_usec >= 0, boot.tv_usec < 1_000_000 else { throw ClockContinuityError.system(EINVAL) }
    return "boottime-v1:\(boot.tv_sec):\(boot.tv_usec)"
  }
}
