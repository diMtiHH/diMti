import AVFoundation
import Flutter
import Speech
import UIKit

// Serializes appending/endAudio against the realtime input callback. Buffers
// are passed directly to Speech and are never saved to files or logged.
private final class VoiceAudioInput {
  private let lock = NSLock()
  private let request: SFSpeechAudioBufferRecognitionRequest
  private var accepting = true
  private var meter = VoiceLevelMeter()
  private var lastLevelTime: UInt64 = 0

  init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

  func append(_ buffer: AVAudioPCMBuffer) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    guard accepting else { return nil }
    request.append(buffer)
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0,
          buffer.format.sampleRate > 0 else { return nil }
    var sum = 0.0
    for index in 0..<Int(buffer.frameLength) {
      let value = Double(samples[index])
      if value.isFinite { sum += value * value }
    }
    let level = meter.update(
      rms: sqrt(sum / Double(buffer.frameLength)),
      seconds: Double(buffer.frameLength) / buffer.format.sampleRate
    )
    let now = DispatchTime.now().uptimeNanoseconds
    guard lastLevelTime == 0 || now - lastLevelTime >= 50_000_000 else { return nil }
    lastLevelTime = now
    return level
  }

  func end() {
    lock.lock()
    defer { lock.unlock() }
    guard accepting else { return }
    accepting = false
    request.endAudio()
  }
}

final class VoiceBridge {
  private let channel: FlutterMethodChannel
  private let lifecycle = VoiceLifecycle()
  private let audio = AVAudioSession.sharedInstance()
  private var engine: AVAudioEngine?
  private var input: VoiceAudioInput?
  private var recognizer: SFSpeechRecognizer?
  private var task: SFSpeechRecognitionTask?
  private var tapInstalled = false
  private var audioActivated = false
  private var startResult: FlutterResult?
  private var permissionDeadline: DispatchWorkItem?
  private var recordingDeadline: DispatchWorkItem?
  private var finalDeadline: DispatchWorkItem?
  private var awaitingActivation: VoiceTicket?
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ask_universe/voice", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "Voice unavailable", details: nil))
        return
      }
      self.handle(call, result: result)
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
      guard let self, let ticket = self.awaitingActivation else { return }
      self.awaitingActivation = nil
      self.beginCapture(ticket)
    })
    observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
      self?.interrupt()
    })
    observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
      // Permission alerts themselves temporarily deactivate the application.
      guard let self, self.lifecycle.phase != .permission else { return }
      self.interrupt()
    })
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: audio, queue: .main) { [weak self] notice in
      guard let value = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            value == AVAudioSession.InterruptionType.began.rawValue else { return }
      self?.interrupt()
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: audio, queue: .main) { [weak self] notice in
      guard let self, self.lifecycle.phase != .permission,
            let value = notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            value != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
      self.interrupt()
    })
    observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: audio, queue: .main) { [weak self] _ in
      self?.interrupt()
    })
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    permissionDeadline?.cancel()
    recordingDeadline?.cancel()
    finalDeadline?.cancel()
    input?.end()
    engine?.stop()
    if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
    task?.cancel()
    if audioActivated { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
    startResult?(FlutterError(code: "interrupted", message: "Voice interrupted", details: nil))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "availability" {
      guard let args = call.arguments as? [String: Any],
            let language = args["language"] as? String,
            let locale = VoicePolicy.locale(for: language) else {
        result(FlutterError(code: "unavailable", message: "Voice language unavailable", details: nil))
        return
      }
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
      result([
        "supported": recognizer?.supportsOnDeviceRecognition == true && recognizer?.isAvailable == true,
        "microphoneAuthorized": audio.recordPermission == .granted,
        "speechAuthorized": SFSpeechRecognizer.authorizationStatus() == .authorized,
      ])
      return
    }
    guard ["start", "stop", "cancel"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
          let id = VoicePolicy.requestID(args["id"]) else {
      result(FlutterError(code: "failed", message: "Invalid voice request", details: nil))
      return
    }
    if call.method == "start" {
      if let previous = lifecycle.ticket { complete(previous, error: nil) }
      guard let language = args["language"] as? String,
            let locale = VoicePolicy.locale(for: language) else {
        result(FlutterError(code: "unavailable", message: "Voice language unavailable", details: nil))
        return
      }
      let ticket = lifecycle.begin(id: id)
      startResult = result
      let deadline = DispatchWorkItem { [weak self] in
        guard let self, self.lifecycle.accepts(ticket), self.lifecycle.phase == .permission else { return }
        self.complete(ticket, error: "unavailable")
      }
      permissionDeadline = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + VoicePolicy.permissionSeconds, execute: deadline)
      requestPermissions(ticket, locale: locale)
      return
    }
    if let ticket = lifecycle.ticket, ticket.id == id {
      if call.method == "cancel" { complete(ticket, error: nil) }
      else { stop(ticket) }
    }
    result(nil)
  }

  private func requestPermissions(_ ticket: VoiceTicket, locale: String) {
    guard lifecycle.accepts(ticket) else { return }
    // Do not even request the microphone if on-device recognition is absent.
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
          recognizer.supportsOnDeviceRecognition else {
      complete(ticket, error: "unavailable")
      return
    }
    self.recognizer = recognizer
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self, self.lifecycle.accepts(ticket) else { return }
        guard status == .authorized else {
          self.complete(ticket, error: "permissionDenied")
          return
        }
        let permission: (Bool) -> Void = { [weak self] granted in
          DispatchQueue.main.async {
            guard let self, self.lifecycle.accepts(ticket) else { return }
            guard granted else {
              self.complete(ticket, error: "permissionDenied")
              return
            }
            self.beginCapture(ticket)
          }
        }
        if #available(iOS 17.0, *) {
          AVAudioApplication.requestRecordPermission(completionHandler: permission)
        } else {
          self.audio.requestRecordPermission(permission)
        }
      }
    }
  }

  private func beginCapture(_ ticket: VoiceTicket) {
    guard lifecycle.accepts(ticket), lifecycle.phase == .permission else { return }
    if UIApplication.shared.applicationState == .background {
      complete(ticket, error: "interrupted")
      return
    }
    // Permission completion can arrive before UIKit reactivates the app. Keep
    // the original bounded permission deadline and wait for that activation.
    if UIApplication.shared.applicationState != .active {
      awaitingActivation = ticket
      return
    }
    guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
      complete(ticket, error: "unavailable")
      return
    }
    permissionDeadline?.cancel()
    permissionDeadline = nil
    do {
      try audio.setCategory(.record, mode: .measurement, options: [])
      try audio.setActive(true)
      audioActivated = true
      let engine = AVAudioEngine()
      self.engine = engine
      let node = engine.inputNode
      let format = node.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        complete(ticket, error: "unavailable")
        return
      }
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = true
      let input = VoiceAudioInput(request)
      self.input = input
      task = recognizer.recognitionTask(with: request) { [weak self] result, error in
        DispatchQueue.main.async {
          guard let self, self.lifecycle.accepts(ticket) else { return }
          if let result {
            let text = result.bestTranscription.formattedString
            guard VoicePolicy.acceptsTranscript(text) else {
              self.complete(ticket, error: "failed")
              return
            }
            self.emit(ticket, type: "transcript", values: ["text": text])
            if result.isFinal {
              self.complete(ticket, error: nil)
              return
            }
          }
          if error != nil {
            self.complete(ticket, error: "failed")
          }
        }
      }
      node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, input] buffer, _ in
        guard let level = input.append(buffer) else { return }
        DispatchQueue.main.async {
          guard let self, self.lifecycle.accepts(ticket), self.lifecycle.phase == .listening else { return }
          self.emit(ticket, type: "level", values: ["level": level])
        }
      }
      tapInstalled = true
      engine.prepare()
      try engine.start()
      guard lifecycle.listen(ticket) else { return }
      finishStart(nil)
      emit(ticket, type: "listening")
      let deadline = DispatchWorkItem { [weak self] in self?.stop(ticket) }
      recordingDeadline = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + VoicePolicy.recordingSeconds, execute: deadline)
    } catch {
      complete(ticket, error: "failed")
    }
  }

  private func stop(_ ticket: VoiceTicket) {
    guard lifecycle.accepts(ticket) else { return }
    if lifecycle.phase == .permission {
      complete(ticket, error: nil)
      return
    }
    guard lifecycle.stop(ticket) else { return }
    stopMicrophone()
    let deadline = DispatchWorkItem { [weak self] in
      guard let self, self.lifecycle.accepts(ticket), self.lifecycle.phase == .finishing else { return }
      self.complete(ticket, error: nil)
    }
    finalDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + VoicePolicy.finalizationSeconds, execute: deadline)
  }

  private func stopMicrophone() {
    recordingDeadline?.cancel()
    recordingDeadline = nil
    input?.end()
    engine?.stop()
    if tapInstalled {
      engine?.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine = nil
    if audioActivated {
      try? audio.setActive(false, options: .notifyOthersOnDeactivation)
      audioActivated = false
    }
  }

  private func interrupt() {
    if let ticket = lifecycle.ticket { complete(ticket, error: "interrupted") }
  }

  private func complete(_ ticket: VoiceTicket, error: String?) {
    guard lifecycle.retire(ticket) else { return }
    permissionDeadline?.cancel()
    permissionDeadline = nil
    awaitingActivation = nil
    finalDeadline?.cancel()
    finalDeadline = nil
    stopMicrophone()
    task?.cancel()
    task = nil
    input = nil
    recognizer = nil
    finishStart(FlutterError(code: error ?? "interrupted", message: "Voice stopped", details: nil))
    var event: [String: Any] = ["id": ticket.id, "type": error == nil ? "finished" : "error"]
    if let error { event["code"] = error }
    channel.invokeMethod("voiceEvent", arguments: event)
  }

  private func finishStart(_ error: FlutterError?) {
    let result = startResult
    startResult = nil
    result?(error)
  }

  private func emit(_ ticket: VoiceTicket, type: String, values: [String: Any] = [:]) {
    guard lifecycle.accepts(ticket) else { return }
    channel.invokeMethod("voiceEvent", arguments: values.merging([
      "id": ticket.id, "type": type,
    ]) { _, next in next })
  }
}
