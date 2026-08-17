import Foundation
import NetworkExtension
import OneLastChanceRuntime
import Tun2SocksKit

public final class TunnelSupervisor: NSObject, @unchecked Sendable {
  private let configuration: String
  private let cancelTunnel: (Error) -> Void
  private let lock = NSLock()
  private let workerQueue = DispatchQueue(
    label: "com.github.hu553in.onelastchance.runtime",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let forwarderQueue = DispatchQueue(
    label: "com.github.hu553in.onelastchance.forwarder",
    qos: .userInitiated
  )
  private let forwarderGroup = DispatchGroup()
  private var runtime: RuntimebridgeRuntime?
  private var forwarderGeneration = 0
  private var forwarderActive = false
  private var forwarderEstablished = false
  private var forwarderExitCode: Int32?
  private var stopped = true

  public init(
    providerConfiguration: [String: Any],
    cancelTunnel: @escaping (Error) -> Void
  ) throws {
    guard
      (providerConfiguration["configurationVersion"] as? NSNumber)?.intValue
        == TunnelConstants.configurationVersion
    else {
      throw TunnelError.configurationOutdated
    }
    guard let nodes = providerConfiguration["nodes"] as? [[String: Any]], !nodes.isEmpty else {
      throw TunnelError.missingNodes
    }
    let selectedNodeIndex = (providerConfiguration["selectedNodeIndex"] as? NSNumber)?.intValue ?? 0
    guard nodes.indices.contains(selectedNodeIndex) else {
      throw TunnelError.invalidNodeSelection
    }
    let payload: [String: Any] = [
      "node": nodes[selectedNodeIndex],
      "deviceIDPath": TunnelConstants.deviceIDPath,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw TunnelError.invalidConfiguration
    }
    self.configuration = configuration
    self.cancelTunnel = cancelTunnel
    super.init()
  }

  public static func networkSettings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: TunnelConstants.tunnelAddress)
    settings.mtu = TunnelConstants.mtu as NSNumber

    let ipv4 = NEIPv4Settings(
      addresses: [TunnelConstants.tunnelAddress],
      subnetMasks: [TunnelConstants.tunnelSubnetMask]
    )
    ipv4.includedRoutes = [.default()]
    ipv4.excludedRoutes = [
      NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0")
    ]
    settings.ipv4Settings = ipv4

    let dns = NEDNSSettings(servers: [TunnelConstants.mapDNSAddress])
    dns.matchDomains = [""]
    settings.dnsSettings = dns
    return settings
  }

  public func start(completion: @escaping (Error?) -> Void) {
    lock.lock()
    guard stopped else {
      lock.unlock()
      completion(TunnelError.alreadyRunning)
      return
    }
    stopped = false
    guard let runtime = RuntimebridgeNewRuntime(self, self) else {
      stopped = true
      lock.unlock()
      completion(TunnelError.runtimeUnavailable)
      return
    }
    self.runtime = runtime
    lock.unlock()

    TunnelLogger.info("Starting olcRTC runtime.")
    workerQueue.async {
      do {
        try runtime.start(self.configuration)
        TunnelLogger.info("olcRTC runtime reported ready.")
        guard self.isCurrent(runtime) else { throw TunnelError.stopped }
        completion(nil)
      } catch {
        self.clear(runtime)
        runtime.stop()
        completion(error)
      }
    }
  }

  public func startForwarding(completion: @escaping (Error?) -> Void) {
    lock.lock()
    guard !stopped, runtime != nil else {
      lock.unlock()
      completion(TunnelError.stopped)
      return
    }
    guard !forwarderActive else {
      lock.unlock()
      completion(TunnelError.forwarderAlreadyRunning)
      return
    }
    forwarderGeneration += 1
    let generation = forwarderGeneration
    forwarderActive = true
    forwarderEstablished = false
    forwarderExitCode = nil
    forwarderGroup.enter()
    lock.unlock()

    TunnelLogger.info("Starting hev-socks5-tunnel packet forwarding.")
    forwarderQueue.async {
      let code = Socks5Tunnel.run(withConfig: .string(content: Self.tun2socksConfiguration()))
      self.forwarderGroup.leave()
      self.forwarderExited(code: code, generation: generation)
    }
    workerQueue.asyncAfter(deadline: .now() + TunnelConstants.forwarderStartDelay) {
      self.lock.lock()
      guard !self.stopped, self.forwarderGeneration == generation else {
        self.lock.unlock()
        completion(TunnelError.stopped)
        return
      }
      if let code = self.forwarderExitCode {
        self.lock.unlock()
        completion(TunnelError.forwarderExited(code))
        return
      }
      self.forwarderEstablished = true
      self.lock.unlock()
      TunnelLogger.info("hev-socks5-tunnel packet forwarding reported ready.")
      completion(nil)
    }
  }

  public func stop(completion: @escaping () -> Void) {
    TunnelLogger.info("Stopping olcRTC runtime.")
    lock.lock()
    stopped = true
    forwarderGeneration += 1
    forwarderActive = false
    forwarderEstablished = false
    forwarderExitCode = nil
    let runtime = self.runtime
    self.runtime = nil
    lock.unlock()
    Socks5Tunnel.quit()
    workerQueue.async {
      if self.forwarderGroup.wait(timeout: .now() + TunnelConstants.forwarderStopTimeout)
        == .timedOut
      {
        TunnelLogger.warning("hev-socks5-tunnel did not stop within the teardown deadline.")
      }
      runtime?.stop()
      completion()
    }
  }

  private func isCurrent(_ runtime: RuntimebridgeRuntime) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !stopped && self.runtime === runtime
  }

  private func clear(_ runtime: RuntimebridgeRuntime) {
    lock.lock()
    defer { lock.unlock() }
    if self.runtime === runtime {
      self.runtime = nil
      stopped = true
    }
  }

  private func forwarderExited(code: Int32, generation: Int) {
    lock.lock()
    guard forwarderGeneration == generation else {
      lock.unlock()
      return
    }
    forwarderActive = false
    let shouldCancel = !stopped && forwarderEstablished
    forwarderEstablished = false
    forwarderExitCode = code
    lock.unlock()

    let error = TunnelError.forwarderExited(code)
    TunnelLogger.error(error.localizedDescription)
    if shouldCancel {
      cancelTunnel(error)
    }
  }

  private static func tun2socksConfiguration() -> String {
    """
    tunnel:
      mtu: \(TunnelConstants.mtu)
      ipv4: \(TunnelConstants.tunnelAddress)
    socks5:
      port: \(TunnelConstants.socksPort)
      address: 127.0.0.1
      udp: 'tcp'
    mapdns:
      address: \(TunnelConstants.mapDNSAddress)
      port: 53
      network: \(TunnelConstants.mapDNSNetwork)
      netmask: \(TunnelConstants.mapDNSNetmask)
      cache-size: 10000
    misc:
      task-stack-size: 24576
      tcp-buffer-size: 4096
      connect-timeout: 10000
      tcp-read-write-timeout: 300000
      udp-read-write-timeout: 60000
      log-file: stderr
      log-level: warn
      limit-nofile: 65535
    """
  }
}

extension TunnelSupervisor: RuntimebridgeLogWriterProtocol {
  public func writeLog(_ message: String?) {
    guard let message, !message.isEmpty else { return }
    TunnelLogger.info(message)
  }
}

extension TunnelSupervisor: RuntimebridgeRuntimeObserverProtocol {
  public func runtimeFailed(_ message: String?) {
    let error = TunnelError.runtimeFailed(message ?? "Unknown runtime failure")
    TunnelLogger.error(error.localizedDescription)
    cancelTunnel(error)
  }
}

private enum TunnelConstants {
  static let configurationVersion = 3
  static let tunnelAddress = "198.18.0.1"
  static let tunnelSubnetMask = "255.255.255.0"
  static let mapDNSAddress = "198.18.0.2"
  static let mapDNSNetwork = "100.64.0.0"
  static let mapDNSNetmask = "255.192.0.0"
  static let mtu = 8_500
  static let socksPort = 21_080
  static let forwarderStartDelay = DispatchTimeInterval.milliseconds(250)
  static let forwarderStopTimeout = DispatchTimeInterval.seconds(2)
  static let deviceIDPath = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
  )[0].appendingPathComponent("olcrtc-device-id").path
}

private enum TunnelError: LocalizedError {
  case alreadyRunning
  case configurationOutdated
  case invalidConfiguration
  case forwarderAlreadyRunning
  case forwarderExited(Int32)
  case invalidNodeSelection
  case missingNodes
  case runtimeFailed(String)
  case runtimeUnavailable
  case stopped

  var errorDescription: String? {
    switch self {
    case .alreadyRunning: "The packet tunnel is already running."
    case .configurationOutdated:
      "The saved VPN configuration is outdated. Refresh the subscription."
    case .invalidConfiguration: "The saved VPN configuration is invalid."
    case .forwarderAlreadyRunning: "Packet forwarding is already running."
    case .forwarderExited(let code): "hev-socks5-tunnel exited unexpectedly with code \(code)."
    case .invalidNodeSelection: "The selected VPN node is no longer available."
    case .missingNodes: "The VPN configuration contains no olcRTC nodes."
    case .runtimeFailed(let message): message
    case .runtimeUnavailable: "The olcRTC runtime could not be created."
    case .stopped: "The packet tunnel was stopped."
    }
  }
}
