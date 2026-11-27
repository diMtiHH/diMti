import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var sessionBridge: SessionBridge?
  private var voiceBridge: VoiceBridge?
  private var presentationBridge: PresentationBridge?
  private var ambientBridge: AmbientBridge?
  private var graphicsBudgetBridge: GraphicsBudgetBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    sessionBridge = SessionBridge(messenger: engineBridge.applicationRegistrar.messenger())
    let ambient = AmbientBridge(messenger: engineBridge.applicationRegistrar.messenger())
    ambientBridge = ambient
    graphicsBudgetBridge = GraphicsBudgetBridge(messenger: engineBridge.applicationRegistrar.messenger())
    voiceBridge = VoiceBridge(messenger: engineBridge.applicationRegistrar.messenger(),
      audioActivityChanged: { [weak ambient] capturing in ambient?.setVoiceCapturing(capturing) })
    presentationBridge = PresentationBridge(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
