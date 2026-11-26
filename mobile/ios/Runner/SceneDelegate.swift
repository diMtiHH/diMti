import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var privacyCover: UIView?
  override func sceneWillResignActive(_ scene: UIScene) {
    if let window = (scene as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) {
      let cover = UIView(frame: window.bounds)
      cover.backgroundColor = .black
      cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      window.addSubview(cover)
      privacyCover?.removeFromSuperview()
      privacyCover = cover
    }
    super.sceneWillResignActive(scene)
  }
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }
}
