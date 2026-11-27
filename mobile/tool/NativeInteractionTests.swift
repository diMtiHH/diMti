import Foundation

private enum Failure: Error { case failed(String) }
@main struct NativeInteractionTests {
  static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure.failed(message) } }
  static func main() throws {
    try check(InteractionPolicy.owner(["owner":1]) == 1, "valid owner")
    try check(InteractionPolicy.owner(["owner":9007199254740991]) != nil,"maximum owner")
    print("PASS interaction 1: exact bounded owner identity")
    let invalidOwners: [Any] = [true,false,0,-1,1.5,Double.nan,Double.infinity,"1",9007199254740992]
    for value in invalidOwners {
      try check(InteractionPolicy.owner(["owner":value]) == nil,"invalid owner")
    }
    try check(InteractionPolicy.owner(["owner":1,"other":2]) == nil,"extra argument")
    print("PASS interaction 2: malformed identities rejected")
    try check(InteractionPolicy.commands == Set(["tap","hold","release","animation","reveal","cancel"]),"fixed commands")
    try check(InteractionPolicy.pulses("yes").isEmpty && InteractionPolicy.pulses("no").isEmpty,"no answer channel")
    print("PASS interaction 3: no answer-dependent haptic commands")
    for event in InteractionPolicy.commands {
      let values = InteractionPolicy.pulses(event)
      try check(values.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time < 4.5 && $0.intensity > 0 && $0.intensity <= 0.6 && $0.sharpness >= 0 && $0.sharpness <= 1 }),"finite pattern")
      try check(zip(values,values.dropFirst()).allSatisfy({ pair in pair.0.time <= pair.1.time }),"ordered pattern")
    }
    print("PASS interaction 4: all pattern parameters bounded and ordered")
    try check(InteractionPolicy.holdIntensity < 0.2 && InteractionPolicy.holdSharpness < 0.2,"soft hold")
    print("PASS interaction 5: soft continuous hold")
    let animation = InteractionPolicy.pulses("animation")
    try check(animation.count == 10 && Set(animation.map(\.intensity)).count > 5,"varying rhythm")
    try check(animation.contains(where: {$0.time == 2.2}) && animation.contains(where: {$0.time == 3.8}),"visual milestones")
    print("PASS interaction 6: varied rhythm aligns to animation milestones")
    try check(InteractionPolicy.pulses("release")[0].intensity > InteractionPolicy.holdIntensity * 3,"distinct release")
    print("PASS interaction 7: release is stronger than hold")
    try check(InteractionPolicy.tilt(x:0.2,y:-0.5,originX:0.2,originY:-0.5) == [0,0],"relative centre")
    try check(InteractionPolicy.tilt(x:100,y:-100,originX:0,originY:0) == [1,1],"bounded tilt")
    print("PASS interaction 8: motion is centred and bounded")
    try check(InteractionPolicy.tilt(x:.nan,y:0,originX:0,originY:0) == nil,"invalid sample")
    try check(InteractionPolicy.tilt(x:0,y:0,originX:.infinity,originY:0) == nil,"invalid baseline")
    print("PASS interaction 9: nonfinite motion is ignored")
    try check(InteractionPolicy.motionInterval >= 0.05 && InteractionPolicy.holdDeadline == 15,"bounded sampling and hold")
    print("PASS interaction 10: sample rate and lost-pointer lifetime bounded")
    let hold = InteractionPolicy.pulses("hold")
    try check(hold.first?.time == 0 && hold.first!.intensity > InteractionPolicy.holdIntensity,
      "hold must be perceptible at onset, before its quiet sustained texture")
    try check(hold.allSatisfy({ $0.intensity < 0.3 }), "hold accents stay soft")
    print("PASS interaction 11: soft hold onset is immediate and bounded")
    try check(InteractionPolicy.releaseAcknowledgementDelay >= 0.1 && InteractionPolicy.releaseAcknowledgementDelay <= 0.2,
      "release acknowledgement must precede capture with bounded latency")
    print("PASS interaction 12: release acknowledgement waits for the short impulse")
    print("Native interaction checks: 12/12 passed")
  }
}
