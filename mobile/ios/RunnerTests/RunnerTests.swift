import Darwin
import Foundation
import Testing

struct RunnerTests {
  @Test func bundledModelIsAccessibleToTheFlutterWorker() throws {
    let assets = Bundle.main.bundleURL.appendingPathComponent(
      "Frameworks/App.framework/flutter_assets/assets/stage2",
      isDirectory: true
    )
    for name in ["model.onnx", "tokenizer.json", "head.json"] {
      #expect(FileManager.default.isReadableFile(atPath: assets.appendingPathComponent(name).path))
    }

    let process = try #require(dlopen(nil, RTLD_LAZY))
    defer { dlclose(process) }
    #expect(dlsym(process, "OrtGetApiBase") != nil)
  }
}
