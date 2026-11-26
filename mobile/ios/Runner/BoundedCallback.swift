import Foundation

enum CallbackDeadline: Error { case exceeded }
enum NotificationDeliveryError: Error { case uncertain }

@MainActor
final class NotificationDelivery {
  private var uncertain: Set<String> = []
  func isAvailable(_ scope: String) -> Bool { !uncertain.contains(scope) }

  func add(_ scope: String, seconds: Double = 2, cancel: @escaping () -> Void,
           start: (@escaping (Result<Void, Error>) -> Void) -> Void) async throws {
    guard isAvailable(scope) else { throw NotificationDeliveryError.uncertain }
    try await BoundedCallback<Void>.wait(seconds: seconds, onTimeout: { [self] in
      uncertain.insert(scope)
      cancel()
    }, onLate: { [self] in
      // Fenced until this cancellation: a newer request cannot be removed.
      cancel()
      uncertain.remove(scope)
    }, start: start)
  }
}

// Unlike a task-group race, this does not wait for an uncancellable OS call
// after the deadline. Only the first callback can affect the continuation.
@MainActor
final class BoundedCallback<Value> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var timer: Task<Void, Never>?
  private var expired = false
  private var received = false
  private let onTimeout: () -> Void
  private let onLate: () -> Void

  private init(_ continuation: CheckedContinuation<Value, Error>,
               onTimeout: @escaping () -> Void, onLate: @escaping () -> Void) {
    self.continuation = continuation
    self.onTimeout = onTimeout
    self.onLate = onLate
  }

  static func wait(seconds: Double, onTimeout: @escaping () -> Void = {},
                   onLate: @escaping () -> Void = {},
                   start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let gate = BoundedCallback(continuation, onTimeout: onTimeout, onLate: onLate)
      gate.timer = Task { @MainActor in
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        catch { return }
        gate.timeout()
      }
      start { result in Task { @MainActor in gate.finish(result) } }
    }
  }

  private func timeout() {
    guard let continuation = continuation else { return }
    self.continuation = nil
    timer = nil
    expired = true
    onTimeout()
    continuation.resume(throwing: CallbackDeadline.exceeded)
  }

  private func finish(_ result: Result<Value, Error>) {
    guard !received else { return }
    received = true
    timer?.cancel()
    timer = nil
    if let continuation = continuation {
      self.continuation = nil
      continuation.resume(with: result)
    } else if expired { onLate() }
  }
}
