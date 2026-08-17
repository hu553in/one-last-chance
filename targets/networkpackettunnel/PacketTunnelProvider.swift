import NetworkExtension
import OlcRtcTunnelCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let lifecycleQueue = DispatchQueue(
    label: "com.github.hu553in.onelastchance.packet-tunnel-lifecycle")
  private var supervisor: TunnelSupervisor?
  private var generation = 0

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    lifecycleQueue.async {
      self.beginStart(completionHandler: completionHandler)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    TunnelLogger.info("Stop requested with reason \(reason.rawValue).")
    lifecycleQueue.async {
      self.generation += 1
      self.reasserting = false
      guard let supervisor = self.supervisor else {
        completionHandler()
        return
      }
      self.supervisor = nil
      supervisor.stop(completion: completionHandler)
    }
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)? = nil
  ) {
    guard messageData == Data("drain-logs".utf8) else {
      completionHandler?(nil)
      return
    }
    completionHandler?(TunnelLogger.drain().data(using: .utf8))
  }

  private func beginStart(completionHandler: @escaping (Error?) -> Void) {
    generation += 1
    let currentGeneration = generation
    TunnelLogger.info(
      "PacketTunnelProvider entered; build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")."
    )
    do {
      guard
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?
          .providerConfiguration
      else {
        throw PacketTunnelError.missingConfiguration
      }
      let supervisor = try TunnelSupervisor(
        providerConfiguration: configuration,
        cancelTunnel: { [weak self] error in
          self?.lifecycleQueue.async {
            guard self?.generation == currentGeneration else { return }
            TunnelLogger.info("Cancelling packet tunnel: \(error.localizedDescription)")
            self?.cancelTunnelWithError(error)
          }
        }
      )
      self.supervisor = supervisor
      supervisor.start { error in
        self.lifecycleQueue.async {
          guard self.isCurrent(supervisor, generation: currentGeneration) else {
            completionHandler(PacketTunnelError.cancelled)
            return
          }
          if let error {
            self.failStart(error, supervisor: supervisor, completionHandler: completionHandler)
            return
          }
          TunnelLogger.info("olcRTC is ready; applying full-tunnel network settings.")
          self.setTunnelNetworkSettings(TunnelSupervisor.networkSettings()) { error in
            self.lifecycleQueue.async {
              guard self.isCurrent(supervisor, generation: currentGeneration) else {
                completionHandler(PacketTunnelError.cancelled)
                return
              }
              if let error {
                self.failStart(error, supervisor: supervisor, completionHandler: completionHandler)
                return
              }
              TunnelLogger.info("Network settings applied; starting packet forwarding.")
              supervisor.startForwarding { error in
                self.lifecycleQueue.async {
                  guard self.isCurrent(supervisor, generation: currentGeneration) else {
                    completionHandler(PacketTunnelError.cancelled)
                    return
                  }
                  if let error {
                    self.failStart(
                      error, supervisor: supervisor, completionHandler: completionHandler)
                    return
                  }
                  self.reasserting = false
                  TunnelLogger.info("Packet tunnel fully established.")
                  completionHandler(nil)
                }
              }
            }
          }
        }
      }
    } catch {
      TunnelLogger.error("Packet tunnel setup failed: \(error.localizedDescription)")
      completionHandler(error)
    }
  }

  private func isCurrent(_ supervisor: TunnelSupervisor, generation: Int) -> Bool {
    self.generation == generation && self.supervisor === supervisor
  }

  private func failStart(
    _ error: Error,
    supervisor: TunnelSupervisor,
    completionHandler: @escaping (Error?) -> Void
  ) {
    TunnelLogger.error("Packet tunnel start failed: \(error.localizedDescription)")
    generation += 1
    self.supervisor = nil
    reasserting = false
    completionHandler(error)
    supervisor.stop {}
  }
}

private enum PacketTunnelError: LocalizedError {
  case cancelled
  case missingConfiguration

  var errorDescription: String? {
    switch self {
    case .cancelled: "The packet tunnel start was cancelled."
    case .missingConfiguration: "The packet tunnel has no saved subscription configuration."
    }
  }
}
