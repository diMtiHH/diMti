import AVFoundation
import Flutter
import Foundation
import UIKit

// Default Flutter channels and audio/lifecycle callbacks are serialized on main.
// The channel accepts no file path, URL, speech text, or microphone operation.
final class PresentationBridge: NSObject, AVAudioPlayerDelegate {
  private let channel: FlutterMethodChannel
  private let audio = AVAudioSession.sharedInstance()
  private var player: AVAudioPlayer?
  private var activeID: Int?
  private var durationMs = 0
  private var positionMs = 0
  private var audioActivated = false
  private var playbackDeadline: DispatchWorkItem?
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ask_universe/presentation", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      self.handle(call, result: result)
    }
    let center = NotificationCenter.default
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                 AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.stopNarration()
      })
    }
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: audio, queue: .main) { [weak self] notice in
      guard let type = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            type == AVAudioSession.InterruptionType.began.rawValue else { return }
      self?.stopNarration()
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: audio, queue: .main) { [weak self] notice in
      guard let reason = notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            reason != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
      self?.stopNarration()
    })
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    playbackDeadline?.cancel()
    player?.stop()
    if audioActivated { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
  }

  private func storage() throws -> PresentationStorage {
    let support = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    return PresentationStorage(root: support.appendingPathComponent("UniversePresentationV1", isDirectory: true))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "readProfile": result(try storage().readProfile())
      case "writeProfile":
        guard let args = call.arguments as? [String: Any], Set(args.keys) == ["value"],
              let value = args["value"] as? String else { throw PresentationDataError.invalid }
        try storage().writeProfile(value)
        result(nil)
      case "narrationInfo":
        guard let args = call.arguments as? [String: Any], Set(args.keys) == ["language"] else {
          return result(error("unavailable"))
        }
        let candidate = try narrationPlayer(args["language"])
        guard let duration = NarrationPolicy.durationMilliseconds(candidate.duration) else {
          return result(error("unavailable"))
        }
        result(["durationMs": duration])
      case "playNarration":
        guard let args = call.arguments as? [String: Any], Set(args.keys) == ["language", "id"],
              let id = NarrationPolicy.identity(args["id"]) else { return result(error("unavailable")) }
        stopNarration()
        guard UIApplication.shared.applicationState == .active else { return result(error("interrupted")) }
        let candidate = try narrationPlayer(args["language"])
        guard let duration = NarrationPolicy.durationMilliseconds(candidate.duration) else {
          return result(error("unavailable"))
        }
        do {
          try audio.setCategory(.playback, mode: .spokenAudio, options: [])
          try audio.setActive(true)
          audioActivated = true
          candidate.delegate = self
          candidate.numberOfLoops = 0
          player = candidate
          activeID = id
          durationMs = duration
          positionMs = 0
          guard candidate.play() else {
            stopNarration()
            return result(error("unavailable"))
          }
          let deadline = DispatchWorkItem { [weak self, weak candidate] in
            guard let self, let candidate, self.activeID == id, self.player === candidate else { return }
            self.stopNarration()
          }
          playbackDeadline = deadline
          DispatchQueue.main.asyncAfter(deadline: .now() + candidate.duration + 2, execute: deadline)
          result(["durationMs": duration])
        } catch {
          stopNarration()
          result(self.error("unavailable"))
        }
      case "narrationPosition":
        guard let args = call.arguments as? [String: Any], Set(args.keys) == ["id"],
              let id = NarrationPolicy.identity(args["id"]), activeID == id else {
          return result(error("interrupted"))
        }
        if let player {
          let time = player.currentTime
          if time.isFinite {
            positionMs = Int(min(Double(durationMs), max(0, time * 1000)).rounded())
          }
        }
        result(["positionMs": positionMs, "durationMs": durationMs, "playing": player?.isPlaying == true])
      case "stopNarration":
        guard let args = call.arguments as? [String: Any], Set(args.keys) == ["id"],
              let id = NarrationPolicy.identity(args["id"]) else { return result(error("unavailable")) }
        if activeID == id { stopNarration() }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch is PresentationDataError {
      let isStorage = call.method == "readProfile" || call.method == "writeProfile"
      result(self.error(isStorage ? "invalid_profile" : "unavailable"))
    } catch {
      let isStorage = call.method == "readProfile" || call.method == "writeProfile"
      result(self.error(isStorage ? "storage_unavailable" : "unavailable"))
    }
  }

  private func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  private func narrationPlayer(_ language: Any?) throws -> AVAudioPlayer {
    guard let filename = NarrationPolicy.filename(language) else { throw PresentationDataError.invalid }
    let url = Bundle.main.bundleURL.appendingPathComponent(
      "Frameworks/App.framework/flutter_assets/assets/onboarding/" + filename
    )
    // Initializing a player reads only the bundled file; no prepare/play or
    // session activation occurs for the read-only narrationInfo method.
    return try AVAudioPlayer(contentsOf: url)
  }

  private func releaseAudio() {
    playbackDeadline?.cancel()
    playbackDeadline = nil
    player?.delegate = nil
    player?.stop()
    player = nil
    if audioActivated {
      try? audio.setActive(false, options: .notifyOthersOnDeactivation)
      audioActivated = false
    }
  }

  private func stopNarration() {
    activeID = nil
    durationMs = 0
    positionMs = 0
    releaseAudio()
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard self.player === player else { return }
    if flag {
      positionMs = durationMs
      releaseAudio()
    } else { stopNarration() }
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    guard self.player === player else { return }
    stopNarration()
  }
}
