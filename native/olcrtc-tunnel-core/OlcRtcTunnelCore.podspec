Pod::Spec.new do |s|
  s.name = 'OlcRtcTunnelCore'
  s.version = '1.0.0'
  s.summary = 'olcRTC runtime supervisor for the One Last Chance packet tunnel'
  s.description = 'A small lifecycle adapter around the pinned olcRTC mobile runtime.'
  s.homepage = 'https://github.com/hu553in/one-last-chance'
  s.license = { :type => 'MIT' }
  s.author = 'Ruslan Khasanshin'
  s.source = {
    :git => 'https://github.com/hu553in/one-last-chance.git',
    :tag => "v#{s.version}",
  }
  s.platform = :ios, '16.4'
  s.swift_version = '5.9'
  s.static_framework = true
  s.source_files = 'Sources/**/*.swift'
  s.vendored_frameworks = 'Frameworks/OneLastChanceRuntime.xcframework'
  s.dependency 'Tun2SocksKit'
  s.frameworks = 'Foundation', 'NetworkExtension'
  s.libraries = 'resolv'
end
