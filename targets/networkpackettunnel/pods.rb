# 5.16.0 enables a UDP path that is incompatible with the pinned olcRTC runtime.
pod 'Tun2SocksKit', :podspec => 'https://raw.githubusercontent.com/EbrahimTahernejad/Tun2SocksKit/5.14.4/Tun2SocksKit.podspec'
pod 'OlcRtcTunnelCore', :path => File.expand_path('../../native/olcrtc-tunnel-core', __dir__)
