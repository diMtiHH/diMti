import Foundation
import CoreFoundation

struct HapticPulse {
  let time: Double
  let intensity: Float
  let sharpness: Float
}

enum InteractionPolicy {
  static let commands: Set<String> = ["tap", "hold", "release", "animation", "reveal", "cancel"]
  static let motionInterval = 1.0 / 20.0
  static let holdIntensity: Float = 0.14
  static let holdSharpness: Float = 0.12
  static let holdDeadline = 15.0
  static func owner(_ arguments: Any?) -> Int? {
    guard let args = arguments as? [String: Any], args.count == 1,
      let raw = args["owner"] as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(),
      raw.doubleValue.isFinite, raw.doubleValue > 0, raw.doubleValue <= 9007199254740991,
      raw.doubleValue.rounded(.towardZero) == raw.doubleValue else { return nil }
    return raw.intValue
  }
  static func tilt(x: Double, y: Double, originX: Double, originY: Double) -> [Double]? {
    guard [x,y,originX,originY].allSatisfy({ $0.isFinite }) else { return nil }
    return [min(1,max(-1,(x-originX)*2)), min(1,max(-1,-(y-originY)*2))]
  }
  static func pulses(_ event: String) -> [HapticPulse] {
    let values: [(Double,Float,Float)]
    switch event {
    case "animation": values = [(0,0.12,0.1),(0.65,0.16,0.1),(1.25,0.20,0.15),
      (1.8,0.24,0.2),(2.2,0.30,0.25),(2.7,0.18,0.2),(3.15,0.34,0.3),
      (3.5,0.22,0.25),(3.8,0.46,0.4),(4.15,0.30,0.3)]
    case "release", "reveal": values = [(0,0.60,0.55)]
    case "tap": values = [(0,0.18,0.14)]
    case "hold": values = [(0.45,0.12,0.08)]
    default: values = []
    }
    return values.map { HapticPulse(time:$0.0,intensity:$0.1,sharpness:$0.2) }
  }
}
