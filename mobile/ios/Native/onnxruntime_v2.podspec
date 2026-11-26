Pod::Spec.new do |s|
  s.name = 'onnxruntime_v2'
  s.version = '1.23.0'
  s.summary = 'Microsoft ONNX Runtime C API for the Flutter FFI binding.'
  s.homepage = 'https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime/1.23.0'
  s.authors = { 'Microsoft' => 'onnxruntime@microsoft.com' }
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.platform = :ios, '15.1'
  s.source = {
    :http => 'https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.23.0/microsoft.ml.onnxruntime.1.23.0.nupkg',
    :type => 'zip',
    :sha256 => 'cadbf21358de4b6002eddce08329465071271d52bb1483779f6f09670af281fc'
  }
  s.prepare_command = 'unzip -q runtimes/ios/native/onnxruntime.xcframework.zip'
  s.vendored_frameworks = 'onnxruntime.xcframework'
  s.static_framework = true
  s.libraries = 'c++'
  s.weak_frameworks = 'CoreML'
end
