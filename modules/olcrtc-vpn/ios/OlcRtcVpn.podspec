Pod::Spec.new do |s|
  s.name           = 'OlcRtcVpn'
  s.version        = '1.0.0'
  s.summary        = 'One Last Chance packet tunnel bridge'
  s.description    = 'A minimal Expo bridge for NETunnelProviderManager and app lifecycle logs.'
  s.author         = 'Ruslan Khasanshin'
  s.homepage       = 'https://github.com/hu553in/one-last-chance'
  s.license        = { :type => 'MIT' }
  s.platforms      = {
    :ios => '16.4',
  }
  s.source         = {
    :git => 'https://github.com/hu553in/one-last-chance.git',
    :tag => "v#{s.version}",
  }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'NetworkExtension'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
end
