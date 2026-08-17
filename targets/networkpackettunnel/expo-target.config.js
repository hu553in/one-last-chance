/** @type {import('@bacons/apple-targets/app.plugin').ConfigFunction} */
module.exports = () => ({
  type: 'network-packet-tunnel',
  bundleIdentifier: '.packet-tunnel',
  deploymentTarget: '16.4',
  entitlements: {
    'com.apple.developer.networking.networkextension': ['packet-tunnel-provider'],
  },
});
