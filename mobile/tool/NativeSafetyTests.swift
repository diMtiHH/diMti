import Darwin
import Foundation

enum TestError: Error { case failed(String), injected }
func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
  let passed = try condition()
  if !passed { throw TestError.failed(label) }
}
func rejects(_ label: String, _ body: () throws -> Void) throws {
  do { try body() } catch { return }
  throw TestError.failed(label)
}

final class FakeKernel {
  var disk: ClockMarker?
  var names: Set<String> = []
  var saves = 0
  var creates = 0
  var error: Int32 = 0
  var failWrite = false
  var ambiguousWrite = false
  var crashBeforeCreate = false
  var order: [String] = []
  func resolve() throws -> String {
    try ClockContinuity.resolve(read: { self.disk }, save: { marker in
      self.order.append("save")
      self.saves += 1
      if self.failWrite { throw TestError.injected }
      self.disk = marker
      if self.ambiguousWrite { throw TestError.injected }
    }, semaphore: { name, create in
      if self.error != 0 { return self.error }
      if create {
        self.creates += 1
        self.order.append("create")
        if self.crashBeforeCreate { return EIO }
        if self.names.contains(name) { return EEXIST }
        self.names.insert(name)
        return 0
      }
      return self.names.contains(name) ? 0 : ENOENT
    }, fallback: { "boottime-v1:test" })
  }
}

@main
struct NativeSafetyTests {
  @MainActor
  static func main() async throws {
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "clock" {
      print(try ClockDomain(directory: URL(fileURLWithPath: CommandLine.arguments[2])).token())
      return
    }
    var passed = 0
    func pass(_ label: String) { passed += 1; print("PASS \(passed): \(label)") }

    let fake = FakeKernel()
    let original = try fake.resolve()
    try expect(fake.order == ["save", "create"], "durable token before kernel creation")
    try expect(original.hasPrefix("semaphore-v1:"), "kernel domain selected")
    pass("commit token before creating kernel marker")
    try expect(try fake.resolve() == original && fake.saves == 1 && fake.creates == 1,
      "same boot uses existing marker without writes")
    pass("process relaunch reuses token without clock/date dependency")
    let oldName = fake.disk!.name
    fake.names.removeAll()
    let rebooted = try fake.resolve()
    try expect(rebooted != original && fake.disk!.name == oldName && fake.names.count == 1,
      "missing kernel object rotates token and reuses private name")
    pass("simulated reboot rotates token")

    for ambiguous in [false, true] {
      let broken = FakeKernel()
      broken.failWrite = !ambiguous
      broken.ambiguousWrite = ambiguous
      try rejects("write failure must stop before kernel creation") { _ = try broken.resolve() }
      try expect(broken.creates == 0, "no marker from failed/uncertain commit")
      let possiblyCommitted = broken.disk?.token
      broken.failWrite = false
      broken.ambiguousWrite = false
      _ = try broken.resolve()
      try expect(broken.disk!.token != possiblyCommitted, "recovery rotates uncertain token")
      pass(ambiguous ? "ambiguous committed write recovery" : "failed write recovery")
    }
    let interrupted = FakeKernel()
    interrupted.crashBeforeCreate = true
    try rejects("crash before creation") { _ = try interrupted.resolve() }
    let abandoned = interrupted.disk!.token
    interrupted.crashBeforeCreate = false
    _ = try interrupted.resolve()
    try expect(interrupted.disk!.token != abandoned, "new launch never trusts missing marker")
    pass("crash between persisted token and kernel creation")

    for status in [EPERM, EACCES, ENOSYS, ENOTSUP] {
      let restricted = FakeKernel()
      restricted.error = status
      try expect(try restricted.resolve() == "boottime-v1:test", "creation capability fallback")
      restricted.disk = ClockMarker.fresh()
      try expect(try restricted.resolve() == "boottime-v1:test", "opening capability fallback")
    }
    pass("sandbox/unsupported API falls back on documented clock")
    for status in [EIO, EMFILE, ENFILE, ENOSPC, EINVAL, EEXIST] {
      let damaged = FakeKernel()
      damaged.error = status
      try rejects("unexpected kernel errors must not select fallback") { _ = try damaged.resolve() }
    }
    pass("unexpected resource failures block instead of weakening recovery")

    let marker = ClockMarker.fresh()
    let valid = try JSONEncoder().encode(marker)
    try expect(try ClockMarker.decode(valid) == marker, "valid marker")
    for bad in ["{}", "null", "{\"version\":true}", String(repeating: "x", count: 513),
      "{\"version\":1,\"name\":\"/foreign\",\"token\":\"\(marker.token)\"}"] {
      try rejects("invalid marker rejected") { _ = try ClockMarker.decode(Data(bad.utf8)) }
    }
    var extra = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    extra["unexpected"] = 1
    try rejects("unknown marker fields rejected") {
      _ = try ClockMarker.decode(JSONSerialization.data(withJSONObject: extra))
    }
    pass("strict private marker validation")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("universe-clock-test-" + UUID().uuidString)
    defer {
      if let data = try? Data(contentsOf: root.appendingPathComponent("marker.json")),
         let marker = try? ClockMarker.decode(data) { _ = marker.name.withCString { sem_unlink($0) } }
      try? FileManager.default.removeItem(at: root)
    }
    func child() throws -> String {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = ["clock", root.path]
      process.standardOutput = pipe
      try process.run()
      let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      try expect(process.terminationStatus == 0, "clock helper exit")
      return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let first = try child()
    let second = try child()
    try expect(first.hasPrefix("semaphore-v1:") && second == first, "real POSIX marker survives process exit")
    pass("real Darwin semaphore and atomic file survive separate processes")
    let onDisk = try ClockMarker.decode(Data(contentsOf: root.appendingPathComponent("marker.json")))
    try expect(onDisk.name.withCString { sem_unlink($0) } == 0, "remove only test-owned marker")
    try expect(try child() != first, "new domain after test marker removal")
    pass("real missing-marker recovery across processes (reboot simulation)")
    let lock = Darwin.open(root.appendingPathComponent("marker.lock").path, O_RDWR)
    try expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "test lock")
    try rejects("concurrent owner blocked") { _ = try ClockDomain(directory: root).token() }
    flock(lock, LOCK_UN)
    Darwin.close(lock)
    pass("concurrent clock initialization cannot race durable marker")
    try Data("{}".utf8).write(to: root.appendingPathComponent("marker.json"))
    try rejects("corrupt disk must block") { _ = try ClockDomain(directory: root).token() }
    // Restore our own marker solely so test cleanup can unlink it.
    let restored = ClockMarker(version: 1, name: onDisk.name, token: onDisk.token)
    try JSONEncoder().encode(restored).write(to: root.appendingPathComponent("marker.json"))
    pass("corrupt persisted clock marker cannot silently reset timer")

    let success = try await BoundedCallback<Int>.wait(seconds: 1) { reply in reply(.success(42)); reply(.success(99)) }
    try expect(success == 42, "callback resumes once")
    do {
      let _: Int = try await BoundedCallback.wait(seconds: 1) { $0(.failure(TestError.injected)) }
      throw TestError.failed("callback error lost")
    } catch TestError.injected {}
    pass("notification callback success/error and duplicate completion")
    do {
      let _: Int = try await BoundedCallback.wait(seconds: 0.01) { _ in }
      throw TestError.failed("missing callback hung")
    } catch CallbackDeadline.exceeded {}
    pass("missing OS callback releases the serial queue")

    let delivery = NotificationDelivery()
    var completion: ((Result<Void, Error>) -> Void)?
    var cancels = 0
    do {
      try await delivery.add("diagnostic", seconds: 0.01, cancel: { cancels += 1 }) { completion = $0 }
      throw TestError.failed("add deadline missing")
    } catch CallbackDeadline.exceeded {}
    try expect(cancels == 1 && !delivery.isAvailable("diagnostic") && delivery.isAvailable("real"), "per-scope uncertainty")
    do {
      try await delivery.add("diagnostic", cancel: {}) { _ in fatalError("fenced add called OS") }
      throw TestError.failed("new add not fenced")
    } catch NotificationDeliveryError.uncertain {}
    completion?(.success(()))
    completion?(.success(()))
    try await Task.sleep(nanoseconds: 10_000_000)
    try expect(cancels == 2 && delivery.isAvailable("diagnostic"), "late request cancelled once before unblocking")
    try await delivery.add("diagnostic", cancel: { cancels += 1 }) { $0(.success(())) }
    try expect(cancels == 2, "fresh valid notification not cancelled")
    pass("late add is cancelled; newer adds fenced; independent scopes and safe retry")
    print("Native safety checks: \(passed)/\(passed) passed")
  }
}

