import Flutter
import UIKit
import CoreMotion
import CoreHaptics
import CoreFoundation

/// Bounded, foreground-only sensory feedback. No questions, answers or history.
final class InteractionBridge {
  private let motionChannel: FlutterMethodChannel
  private let hapticChannel: FlutterMethodChannel
  private let motion = CMMotionManager()
  private let queue = OperationQueue()
  private var sampling = false
  private var generation = 0
  private var initial: (Double, Double)?
  private let sampleLock = NSLock()
  private var latestSample: (Double, Double, Int)?
  private var deliveryPending = false
  private var observers: [NSObjectProtocol] = []
  private var engine: CHHapticEngine?
  private var player: CHHapticPatternPlayer?
  private var holdPlayer: CHHapticAdvancedPatternPlayer?
  private var expiry: DispatchWorkItem?
  private var hapticOwner: Int?

  init(messenger: FlutterBinaryMessenger) {
    motionChannel = FlutterMethodChannel(name: "ask_universe/motion", binaryMessenger: messenger)
    hapticChannel = FlutterMethodChannel(name: "ask_universe/haptics", binaryMessenger: messenger)
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    motionChannel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.arguments == nil else { return result(FlutterError(code: "invalid", message: nil, details: nil)) }
      switch call.method {
      case "start": self.startMotion(); result(nil)
      case "stop": self.stopMotion(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    hapticChannel.setMethodCallHandler { [weak self] call, result in
      guard let self, let owner = InteractionPolicy.owner(call.arguments) else {
        return result(FlutterError(code: "invalid", message: nil, details: nil))
      }
      guard InteractionPolicy.commands.contains(call.method) else {
        return result(FlutterMethodNotImplemented)
      }
      if call.method == "cancel" {
        if self.hapticOwner == owner { self.cancelPlayers(); self.hapticOwner = nil }
      } else {
        self.hapticOwner = owner
        self.feedback(call.method)
      }
      if call.method == "release" {
        // Dart awaits this acknowledgement before requesting microphone access.
        // Reply immediately for other events, including cancellation. The short
        // completion retains no bridge/player and cannot resume a stopped effect.
        DispatchQueue.main.asyncAfter(deadline: .now() + InteractionPolicy.releaseAcknowledgementDelay) {
          result(nil)
        }
      } else {
        result(nil)
      }
    }
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.stopMotion(); self?.stopHaptics()
      })
    }
  }
  private func startMotion() {
    guard !sampling, motion.isDeviceMotionAvailable,
      UIApplication.shared.applicationState == .active else { return }
    sampling = true; generation += 1; initial = nil
    let token = generation
    motion.deviceMotionUpdateInterval = InteractionPolicy.motionInterval
    motion.startDeviceMotionUpdates(to: queue) { [weak self] sample, _ in
      guard let sample else { return }
      let x = sample.gravity.x, y = sample.gravity.y
      guard x.isFinite, y.isFinite else { return }
      self?.receiveMotion(x, y, token)
    }
  }
  // Coalesce samples: a busy main thread can retain only the latest sample and
  // one queued delivery, never minutes of stale sensor callbacks.
  private func receiveMotion(_ x: Double, _ y: Double, _ token: Int) {
    sampleLock.lock()
    latestSample = (x, y, token)
    if deliveryPending { sampleLock.unlock(); return }
    deliveryPending = true
    sampleLock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.sampleLock.lock()
      let sample = self.latestSample
      self.latestSample = nil; self.deliveryPending = false
      self.sampleLock.unlock()
      guard let (x, y, token) = sample, self.sampling, self.generation == token,
        UIApplication.shared.applicationState == .active else { return }
      if self.initial == nil { self.initial = (x, y) }
      guard let initial = self.initial,
        let tilt = InteractionPolicy.tilt(x:x,y:y,originX:initial.0,originY:initial.1) else { return }
      self.motionChannel.invokeMethod("tilt", arguments: tilt)
    }
  }
  private func stopMotion() {
    sampling = false; generation += 1; initial = nil
    motion.stopDeviceMotionUpdates()
    sampleLock.lock(); latestSample = nil; sampleLock.unlock()
  }
  private func cancelPlayers() {
    expiry?.cancel(); expiry = nil
    try? player?.stop(atTime: CHHapticTimeImmediate)
    try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
    player = nil; holdPlayer = nil
  }
  private func stopHaptics() {
    cancelPlayers(); engine?.stop(completionHandler: nil); engine = nil
  }
  private func fallback(_ event: String) {
    guard UIApplication.shared.applicationState == .active else { return }
    let impact = UIImpactFeedbackGenerator(style: event == "release" || event == "reveal" ? .medium : .soft)
    impact.prepare()
    impact.impactOccurred()
  }
  private func feedback(_ event: String) {
    cancelPlayers()
    guard event != "cancel", UIApplication.shared.applicationState == .active else { return }
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
      fallback(event)
      return
    }
    do {
      if engine == nil {
        let next = try CHHapticEngine()
        next.playsHapticsOnly = true
        next.isAutoShutdownEnabled = true
        next.stoppedHandler = { _ in }
        next.resetHandler = { [weak self, weak next] in DispatchQueue.main.async {
          guard let self, self.engine === next else { return }
          self.stopHaptics()
        } }
        engine = next
      }
      guard let engine else { return }
      try engine.start()
      func pulse(_ time: Double, _ strength: Float, _ sharp: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: sharp)], relativeTime: time)
      }
      if event == "hold" {
        let continuous = CHHapticEvent(eventType: .hapticContinuous, parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: InteractionPolicy.holdIntensity),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: InteractionPolicy.holdSharpness)], relativeTime: 0, duration: 1)
        let accents = InteractionPolicy.pulses("hold").map { pulse($0.time, $0.intensity, $0.sharpness) }
        let pattern = try CHHapticPattern(events: [continuous] + accents, parameters: [])
        let next = try engine.makeAdvancedPlayer(with: pattern)
        next.loopEnabled = true; next.loopEnd = 1
        holdPlayer = next; try next.start(atTime: CHHapticTimeImmediate)
      } else {
        let events = InteractionPolicy.pulses(event).map { pulse($0.time,$0.intensity,$0.sharpness) }
        player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
        try player?.start(atTime: CHHapticTimeImmediate)
      }
      // A lost pointer/channel can never leave an unbounded physical effect.
      let timeout = DispatchWorkItem { [weak self] in self?.cancelPlayers() }
      expiry = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + (event == "hold" ? InteractionPolicy.holdDeadline : event == "animation" ? 5 : 1), execute: timeout)
    } catch {
      // A transient Core Haptics server error must not silently erase feedback.
      // Use one bounded system impulse; never retry a continuous hold in a loop.
      stopHaptics()
      fallback(event)
    }
  }
  deinit { stopMotion(); stopHaptics(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
