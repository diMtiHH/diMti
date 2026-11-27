import AVFoundation
import Flutter
import Foundation
import UIKit

/// Playback of four shipped original WAVs only. All state is main-thread owned.
/// Voice acquisition takes priority before it changes the shared audio category.
final class AmbientBridge: NSObject, AVAudioPlayerDelegate {
  private let channel: FlutterMethodChannel
  private let audio = AVAudioSession.sharedInstance()
  private var player: AVAudioPlayer?
  private var cuePlayer: AVAudioPlayer?
  private var environment: String?
  private var ownsSession = false
  private var voiceCapturing = false
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ask_universe/ambient", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      self.handle(call, result: result)
    }
    let center = NotificationCenter.default
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                 AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.stop(interrupted: true)
      })
    }
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                       object: audio, queue: .main) { [weak self] notice in
      guard let type = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            type == AVAudioSession.InterruptionType.began.rawValue else { return }
      self?.stop(interrupted: true)
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                       object: audio, queue: .main) { [weak self] notice in
      guard let self, let reason = notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
      if reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue {
        // Another component has already acquired the session. stop() checks
        // category ownership and will not call setActive(false) over it.
        if self.audio.category != .ambient { self.stop(interrupted: true) }
      } else {
        self.stop(interrupted: true)
      }
    })
  }

  func setVoiceCapturing(_ capturing: Bool) {
    if capturing && !voiceCapturing {
      // Invoked BEFORE VoiceBridge.setCategory(.record). Release our session
      // now, then block every play request until the voice owner releases it.
      stop(interrupted: true)
    }
    voiceCapturing = capturing
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["environment"],
            let filename = AmbientPolicy.filename(args["environment"]),
            let selection = args["environment"] as? String else {
        return result(error("unavailable"))
      }
      guard !voiceCapturing, UIApplication.shared.applicationState == .active else {
        return result(error("interrupted"))
      }
      if environment == selection, player?.isPlaying == true { return result(nil) }
      stop(interrupted: false)
      do {
        let url = Bundle.main.bundleURL.appendingPathComponent(
          "Frameworks/App.framework/flutter_assets/assets/audio/ambient/" + filename)
        let candidate = try AVAudioPlayer(contentsOf: url)
        guard AmbientPolicy.validDuration(candidate.duration) else { return result(error("unavailable")) }
        // .ambient respects the silent switch and mixes with other audio.
        // Native voice ownership above prevents this from overriding capture.
        try audio.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try audio.setActive(true)
        ownsSession = true
        candidate.delegate = self
        candidate.numberOfLoops = -1
        candidate.volume = 0
        player = candidate
        environment = selection
        guard candidate.play() else {
          stop(interrupted: false)
          return result(error("unavailable"))
        }
        candidate.setVolume(0.24, fadeDuration: 0.8)
        result(nil)
      } catch {
        stop(interrupted: false)
        result(error("unavailable"))
      }
    case "cue":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["event"],
            let filename = AmbientPolicy.cueFilename(args["event"]) else {
        return result(error("unavailable"))
      }
      // Cues borrow our already-active ambient session. Never acquire or
      // reconfigure it here, and never resume playback after an interruption.
      guard !voiceCapturing, UIApplication.shared.applicationState == .active,
            ownsSession, audio.category == .ambient, player?.isPlaying == true else {
        return result(error("interrupted"))
      }
      do {
        let url = Bundle.main.bundleURL.appendingPathComponent(
          "Frameworks/App.framework/flutter_assets/assets/audio/ambient/" + filename)
        let candidate = try AVAudioPlayer(contentsOf: url)
        guard AmbientPolicy.validCueDuration(candidate.duration) else {
          return result(error("unavailable"))
        }
        cuePlayer?.delegate = nil
        cuePlayer?.stop()
        candidate.delegate = self
        candidate.numberOfLoops = 0
        candidate.volume = 0.24
        cuePlayer = candidate
        guard candidate.play() else {
          cuePlayer = nil
          return result(error("unavailable"))
        }
        result(nil)
      } catch { result(error("unavailable")) }
    case "stop":
      guard call.arguments == nil || (call.arguments as? [String: Any])?.isEmpty == true else {
        return result(error("unavailable"))
      }
      stop(interrupted: false)
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  private func stop(interrupted: Bool) {
    let hadAudio = player != nil || cuePlayer != nil || ownsSession
    let deactivate = AmbientPolicy.mayDeactivate(owned: ownsSession,
      voiceCapturing: voiceCapturing, categoryIsAmbient: audio.category == .ambient)
    player?.delegate = nil
    player?.stop()
    cuePlayer?.delegate = nil
    cuePlayer?.stop()
    cuePlayer = nil
    player = nil
    environment = nil
    ownsSession = false
    if deactivate { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
    if interrupted && hadAudio {
      channel.invokeMethod("ambientEvent", arguments: ["type": "interrupted"])
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    if cuePlayer === player {
      cuePlayer?.delegate = nil
      cuePlayer = nil
      if !flag { stop(interrupted: true) }
      return
    }
    guard self.player === player else { return }
    stop(interrupted: true)
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    guard self.player === player || cuePlayer === player else { return }
    stop(interrupted: true)
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    player?.delegate = nil
    player?.stop()
    cuePlayer?.delegate = nil
    cuePlayer?.stop()
    if AmbientPolicy.mayDeactivate(owned: ownsSession, voiceCapturing: voiceCapturing,
                                  categoryIsAmbient: audio.category == .ambient) {
      try? audio.setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
}
