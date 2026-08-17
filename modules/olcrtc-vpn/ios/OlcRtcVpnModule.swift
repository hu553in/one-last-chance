import ExpoModulesCore
import Foundation
import NetworkExtension

private enum OlcRtcVpnConstants {
  static let localizedDescription = "One Last Chance"
  static let configurationVersion = 3
  static let drainLogsMessage = Data("drain-logs".utf8)

  static let providerBundleIdentifier: String = {
    if let plugInsURL = Bundle.main.builtInPlugInsURL,
      let extensionURL = try? FileManager.default.contentsOfDirectory(
        at: plugInsURL,
        includingPropertiesForKeys: nil
      ).first(where: { $0.pathExtension == "appex" }),
      let identifier = Bundle(url: extensionURL)?.bundleIdentifier
    {
      return identifier
    }
    return "\(Bundle.main.bundleIdentifier ?? "com.github.hu553in.onelastchance").packet-tunnel"
  }()
}

private final class OlcRtcVpnException: GenericException<String>, @unchecked Sendable {
  override var reason: String { param }
}

private struct OlcNodeRecord: Record {
  @Field var name: String = ""
  @Field var provider: String = ""
  @Field var transport: String = ""
  @Field var room: String = ""
  @Field var key: String = ""
  @Field var vp8FPS: Int = 30
  @Field var vp8BatchSize: Int = 64

  var dictionary: [String: Any] {
    [
      "name": name,
      "provider": provider,
      "transport": transport,
      "room": room,
      "key": key,
      "vp8FPS": vp8FPS,
      "vp8BatchSize": vp8BatchSize,
    ]
  }
}

private struct SubscriptionRecord: Record {
  @Field var name: String = ""
  @Field var nodes: [OlcNodeRecord] = []
  @Field var refreshedAt: Double = 0

  var dictionary: [String: Any] {
    [
      "configurationVersion": OlcRtcVpnConstants.configurationVersion,
      "name": name,
      "refreshedAt": refreshedAt,
      "nodes": nodes.map(\.dictionary),
      "selectedNodeIndex": 0,
    ]
  }
}

public final class OlcRtcVpnModule: Module {
  private let controller = VPNController()
  private var statusObserver: NSObjectProtocol?

  public func definition() -> ModuleDefinition {
    Name("OlcRtcVpn")
    Events("onStatusChange")

    OnStartObserving {
      self.startObservingStatus()
    }

    OnStopObserving {
      self.stopObservingStatus()
    }

    AsyncFunction("getSnapshot") { (promise: Promise) in
      self.controller.snapshot { result in
        self.resolve(result, operation: "Snapshot", promise: promise)
      }
    }

    AsyncFunction("configure") { (subscription: SubscriptionRecord, promise: Promise) in
      self.controller.configure(subscription.dictionary) { result in
        self.resolve(result, operation: "Configuration", promise: promise)
      }
    }

    AsyncFunction("selectNode") { (index: Int, promise: Promise) in
      self.controller.selectNode(index) { result in
        self.resolve(result, operation: "Node selection", promise: promise)
      }
    }

    AsyncFunction("connect") { (promise: Promise) in
      self.controller.connect { result in
        self.resolveVoid(result, operation: "Connect", promise: promise)
      }
    }

    AsyncFunction("disconnect") { (promise: Promise) in
      self.controller.disconnect { result in
        self.resolveVoid(result, operation: "Disconnect", promise: promise)
      }
    }

    AsyncFunction("getLogs") {
      self.controller.captureProviderLogs()
      return AppLog.read()
    }

    AsyncFunction("clearLogs") { (promise: Promise) in
      self.controller.clearLogs {
        promise.resolve()
      }
    }
  }

  private func startObservingStatus() {
    guard statusObserver == nil else { return }
    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.controller.status { status in
        self.sendEvent("onStatusChange", ["status": status])
      }
    }
  }

  private func stopObservingStatus() {
    guard let statusObserver else { return }
    NotificationCenter.default.removeObserver(statusObserver)
    self.statusObserver = nil
    controller.stopCapturingProviderLogs()
  }

  private func resolve(_ result: Result<[String: Any], Error>, operation: String, promise: Promise)
  {
    switch result {
    case .success(let value): promise.resolve(value)
    case .failure(let error):
      log(error, operation: operation)
      promise.reject(OlcRtcVpnException(error.localizedDescription))
    }
  }

  private func resolveVoid(_ result: Result<Void, Error>, operation: String, promise: Promise) {
    switch result {
    case .success: promise.resolve()
    case .failure(let error):
      log(error, operation: operation)
      promise.reject(OlcRtcVpnException(error.localizedDescription))
    }
  }

  private func log(_ error: Error, operation: String) {
    let value = error as NSError
    AppLog.append(
      level: "error",
      message: "\(operation) failed: \(value.domain) \(value.code): \(value.localizedDescription)"
    )
  }
}

private final class VPNController {
  private let queue = DispatchQueue(label: "com.github.hu553in.onelastchance.vpn-manager")
  private var manager: NETunnelProviderManager?
  private var lastLoggedStatus: String?
  private var logCaptureTimer: DispatchSourceTimer?
  private var logClearGeneration = 0
  private var logRequestID = 0
  private var logRequestPending = false
  private var lastProviderLogIssue: String?
  private var disconnectRequested = false

  func snapshot(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    queue.async {
      self.loadManager(create: false) { result in
        switch result {
        case .success(let manager): completion(.success(self.snapshotDictionary(manager)))
        case .failure(let error): completion(.failure(error))
        }
      }
    }
  }

  func configure(
    _ configuration: [String: Any],
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    queue.async {
      do {
        let encoded = try PropertyListSerialization.data(
          fromPropertyList: configuration,
          format: .binary,
          options: 0
        )
        guard encoded.count <= 512 * 1024 else {
          throw ControllerError.configurationTooLarge
        }
      } catch {
        completion(.failure(error))
        return
      }

      self.loadManager(create: true) { result in
        switch result {
        case .failure(let error):
          completion(.failure(error))
        case .success(nil):
          completion(.failure(ControllerError.managerUnavailable))
        case .success(let manager?):
          guard manager.connection.status == .invalid || manager.connection.status == .disconnected
          else {
            completion(.failure(ControllerError.disconnectBeforeUpdating))
            return
          }
          let preparedConfiguration = self.configurationByPreservingSelection(
            configuration, manager: manager)
          self.saveConfiguration(preparedConfiguration, to: manager) { result in
            if case .success = result {
              let name = preparedConfiguration["name"] as? String ?? "olcRTC subscription"
              let nodeCount = (preparedConfiguration["nodes"] as? [[String: Any]])?.count ?? 0
              AppLog.append(
                level: "info", message: "Saved subscription “\(name)” with \(nodeCount) nodes.")
            }
            completion(result)
          }
        }
      }
    }
  }

  func selectNode(
    _ index: Int,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    queue.async {
      self.loadManager(create: false) { result in
        switch result {
        case .failure(let error):
          completion(.failure(error))
        case .success(nil):
          completion(.failure(ControllerError.notConfigured))
        case .success(let manager?):
          guard manager.connection.status == .invalid || manager.connection.status == .disconnected
          else {
            completion(.failure(ControllerError.disconnectBeforeUpdating))
            return
          }
          guard let currentProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
            var configuration = currentProtocol.providerConfiguration,
            (configuration["configurationVersion"] as? NSNumber)?.intValue
              == OlcRtcVpnConstants.configurationVersion,
            let nodes = configuration["nodes"] as? [[String: Any]],
            !nodes.isEmpty
          else {
            completion(.failure(ControllerError.configurationOutdated))
            return
          }
          guard nodes.indices.contains(index) else {
            completion(.failure(ControllerError.invalidNodeSelection))
            return
          }
          if Self.selectedNodeIndex(in: configuration, nodes: nodes) == index {
            completion(.success(self.snapshotDictionary(manager)))
            return
          }
          configuration["selectedNodeIndex"] = index
          self.saveConfiguration(configuration, to: manager) { result in
            if case .success = result {
              let name = nodes[index]["name"] as? String ?? "Unnamed node"
              AppLog.append(level: "info", message: "Selected VPN node “\(name)”.")
            }
            completion(result)
          }
        }
      }
    }
  }

  func connect(completion: @escaping (Result<Void, Error>) -> Void) {
    queue.async {
      self.loadManager(create: false) { result in
        switch result {
        case .failure(let error): completion(.failure(error))
        case .success(nil): completion(.failure(ControllerError.notConfigured))
        case .success(let manager?):
          manager.loadFromPreferences { error in
            self.queue.async {
              if let error {
                self.manager = nil
                completion(.failure(error))
                return
              }
              switch manager.connection.status {
              case .connected, .connecting, .reasserting:
                completion(.success(()))
              case .disconnecting:
                completion(.failure(ControllerError.stillDisconnecting))
              case .invalid, .disconnected:
                self.prepareForStart(manager, completion: completion)
              @unknown default:
                completion(.failure(ControllerError.unknownStatus))
              }
            }
          }
        }
      }
    }
  }

  func disconnect(completion: @escaping (Result<Void, Error>) -> Void) {
    queue.async {
      self.loadManager(create: false) { result in
        switch result {
        case .failure(let error): completion(.failure(error))
        case .success(nil): completion(.success(()))
        case .success(let manager?):
          self.stopLogCaptureTimer()
          self.disconnectRequested = true
          manager.connection.stopVPNTunnel()
          AppLog.append(level: "info", message: "Disconnect requested.")
          completion(.success(()))
        }
      }
    }
  }

  func status(completion: @escaping (String) -> Void) {
    queue.async {
      self.loadManager(create: false) { result in
        guard case .success(let manager?) = result else {
          completion("invalid")
          return
        }
        let status = Self.statusName(manager.connection.status)
        self.recordSystemStatus(status, connection: manager.connection)
        completion(status)
      }
    }
  }

  func captureProviderLogs() {
    queue.async {
      let clearGeneration = self.logClearGeneration
      self.loadManager(create: false) { result in
        guard self.logClearGeneration == clearGeneration else { return }
        guard case .success(let manager?) = result else { return }
        self.captureProviderLogs(from: manager.connection)
      }
    }
  }

  func clearLogs(completion: @escaping () -> Void) {
    queue.async {
      self.logClearGeneration += 1
      self.logRequestID += 1
      self.logRequestPending = false
      self.lastProviderLogIssue = nil
      AppLog.clear()
      let clearGeneration = self.logClearGeneration
      self.loadManager(create: false) { result in
        if self.logClearGeneration == clearGeneration,
          case .success(let manager?) = result
        {
          self.captureProviderLogs(from: manager.connection, discard: true)
        }
        completion()
      }
    }
  }

  func stopCapturingProviderLogs() {
    queue.async {
      self.stopLogCaptureTimer()
    }
  }

  private func saveConfiguration(
    _ configuration: [String: Any],
    to manager: NETunnelProviderManager,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    manager.protocolConfiguration = makeProtocol(configuration: configuration)
    manager.localizedDescription = OlcRtcVpnConstants.localizedDescription
    manager.isEnabled = true
    disableAutomaticReconnect(manager)
    manager.saveToPreferences { error in
      self.queue.async {
        if let error {
          self.manager = nil
          completion(.failure(error))
          return
        }
        manager.loadFromPreferences { error in
          self.queue.async {
            if let error {
              self.manager = nil
              completion(.failure(error))
            } else {
              completion(.success(self.snapshotDictionary(manager)))
            }
          }
        }
      }
    }
  }

  private func configurationByPreservingSelection(
    _ configuration: [String: Any],
    manager: NETunnelProviderManager
  ) -> [String: Any] {
    var updated = configuration
    guard let nodes = configuration["nodes"] as? [[String: Any]], !nodes.isEmpty,
      let currentConfiguration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
        .providerConfiguration,
      (currentConfiguration["configurationVersion"] as? NSNumber)?.intValue
        == OlcRtcVpnConstants.configurationVersion,
      let currentNodes = currentConfiguration["nodes"] as? [[String: Any]],
      !currentNodes.isEmpty
    else {
      updated["selectedNodeIndex"] = 0
      return updated
    }

    let currentIndex = Self.selectedNodeIndex(in: currentConfiguration, nodes: currentNodes)
    let currentNode = currentNodes[currentIndex]
    updated["selectedNodeIndex"] = nodes.firstIndex(where: { Self.sameNode($0, currentNode) }) ?? 0
    return updated
  }

  private static func sameNode(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    ["provider", "transport", "room"].allSatisfy { key in
      lhs[key] as? String == rhs[key] as? String
    }
  }

  private static func selectedNodeIndex(
    in configuration: [String: Any],
    nodes: [[String: Any]]
  ) -> Int {
    let index = (configuration["selectedNodeIndex"] as? NSNumber)?.intValue ?? 0
    return nodes.indices.contains(index) ? index : 0
  }

  private func loadManager(
    create: Bool,
    completion: @escaping (Result<NETunnelProviderManager?, Error>) -> Void
  ) {
    if let manager {
      completion(.success(manager))
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      self.queue.async {
        if let error {
          self.manager = nil
          completion(.failure(error))
          return
        }
        let matchingManager = managers?.first(where: { candidate in
          (candidate.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
            == OlcRtcVpnConstants.providerBundleIdentifier
        })
        let resolved = matchingManager ?? (create ? NETunnelProviderManager() : nil)
        self.manager = resolved
        completion(.success(resolved))
      }
    }
  }

  private func makeProtocol(configuration: [String: Any]) -> NETunnelProviderProtocol {
    let tunnelProtocol = NETunnelProviderProtocol()
    tunnelProtocol.providerBundleIdentifier = OlcRtcVpnConstants.providerBundleIdentifier
    tunnelProtocol.providerConfiguration = configuration
    tunnelProtocol.serverAddress =
      configuration["name"] as? String ?? OlcRtcVpnConstants.localizedDescription
    return tunnelProtocol
  }

  private func prepareForStart(
    _ manager: NETunnelProviderManager,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let currentProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
      let configuration = currentProtocol.providerConfiguration,
      let nodes = configuration["nodes"] as? [[String: Any]],
      (configuration["configurationVersion"] as? NSNumber)?.intValue
        == OlcRtcVpnConstants.configurationVersion
    else {
      completion(.failure(ControllerError.configurationOutdated))
      return
    }
    guard !nodes.isEmpty else {
      completion(.failure(ControllerError.noAvailableNodes))
      return
    }

    AppLog.append(
      level: "info",
      message: "Refreshing the saved VPN configuration before connecting."
    )
    saveConfiguration(configuration, to: manager) { result in
      switch result {
      case .success:
        self.start(manager, completion: completion)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  private func start(
    _ manager: NETunnelProviderManager,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      disconnectRequested = false
      try manager.connection.startVPNTunnel()
      AppLog.append(level: "info", message: "Connect requested.")
      updateLogCapture(for: .connecting, connection: manager.connection)
      completion(.success(()))
    } catch {
      self.manager = nil
      completion(.failure(error))
    }
  }

  private func snapshotDictionary(_ manager: NETunnelProviderManager?) -> [String: Any] {
    let status = manager.map { Self.statusName($0.connection.status) } ?? "invalid"
    recordSystemStatus(status, connection: manager?.connection)
    guard let manager,
      let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
        .providerConfiguration,
      (configuration["configurationVersion"] as? NSNumber)?.intValue
        == OlcRtcVpnConstants.configurationVersion,
      let name = configuration["name"] as? String,
      let refreshedAt = (configuration["refreshedAt"] as? NSNumber)?.doubleValue,
      let nodes = configuration["nodes"] as? [[String: Any]]
    else {
      return [
        "status": status,
        "summary": NSNull(),
      ]
    }
    let nodeSummaries = nodes.map { node in
      [
        "name": node["name"] as? String ?? "Unnamed node",
        "provider": node["provider"] as? String ?? "",
        "transport": node["transport"] as? String ?? "",
      ]
    }
    return [
      "status": status,
      "summary": [
        "name": name,
        "nodes": nodeSummaries,
        "selectedNodeIndex": Self.selectedNodeIndex(in: configuration, nodes: nodes),
        "refreshedAt": refreshedAt,
      ],
    ]
  }

  private func recordSystemStatus(_ status: String, connection: NEVPNConnection?) {
    guard status != lastLoggedStatus else { return }
    lastLoggedStatus = status
    AppLog.append(level: "status", message: "VPN status changed to \(status).")
    if let connection {
      updateLogCapture(for: connection.status, connection: connection)
    }
    if status == "disconnected", disconnectRequested {
      disconnectRequested = false
      return
    }
    if status == "disconnected", #available(iOS 16.0, *) {
      connection?.fetchLastDisconnectError { error in
        guard let error else { return }
        let value = error as NSError
        let message: String
        if value.domain == NEVPNConnectionErrorDomain,
          value.code == NEVPNConnectionError.pluginFailed.rawValue
        {
          message =
            "VPN extension stopped unexpectedly (pluginFailed; \(value.domain) \(value.code))."
        } else {
          message =
            "Last VPN disconnect: \(value.domain) \(value.code): \(value.localizedDescription)"
        }
        AppLog.append(
          level: "error",
          message: message
        )
      }
    }
  }

  private func updateLogCapture(for status: NEVPNStatus, connection: NEVPNConnection) {
    switch status {
    case .connecting, .connected, .reasserting:
      captureProviderLogs(from: connection)
      guard logCaptureTimer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
      timer.setEventHandler { [weak self, weak connection] in
        guard let self, let connection else { return }
        self.captureProviderLogs(from: connection)
      }
      logCaptureTimer = timer
      timer.resume()
    default:
      stopLogCaptureTimer()
    }
  }

  private func stopLogCaptureTimer() {
    logCaptureTimer?.cancel()
    logCaptureTimer = nil
  }

  private func captureProviderLogs(from connection: NEVPNConnection, discard: Bool = false) {
    guard !logRequestPending,
      let session = connection as? NETunnelProviderSession,
      [.connecting, .connected, .reasserting].contains(session.status)
    else { return }

    logRequestID += 1
    let requestID = logRequestID
    logRequestPending = true
    do {
      try session.sendProviderMessage(OlcRtcVpnConstants.drainLogsMessage) { data in
        self.queue.async {
          guard self.logRequestID == requestID else { return }
          self.logRequestPending = false
          self.lastProviderLogIssue = nil
          if !discard, let data, let lines = String(data: data, encoding: .utf8) {
            AppLog.append(contents: lines)
          }
        }
      }
    } catch {
      logRequestPending = false
      recordProviderLogIssue("Provider log request failed: \(error.localizedDescription)")
      return
    }
    queue.asyncAfter(deadline: .now() + 2) {
      guard self.logRequestID == requestID, self.logRequestPending else { return }
      self.logRequestPending = false
      self.recordProviderLogIssue(
        "Packet tunnel did not answer the provider log request within 2 seconds.")
    }
  }

  private func disableAutomaticReconnect(_ manager: NETunnelProviderManager) {
    manager.isOnDemandEnabled = false
    manager.onDemandRules = nil
  }

  private func recordProviderLogIssue(_ message: String) {
    guard lastProviderLogIssue != message else { return }
    lastProviderLogIssue = message
    AppLog.append(level: "warning", message: message)
  }

  private static func statusName(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid: "invalid"
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .connected: "connected"
    case .reasserting: "reasserting"
    case .disconnecting: "disconnecting"
    @unknown default: "invalid"
    }
  }
}

private enum ControllerError: LocalizedError {
  case configurationTooLarge
  case managerUnavailable
  case notConfigured
  case configurationOutdated
  case noAvailableNodes
  case invalidNodeSelection
  case disconnectBeforeUpdating
  case stillDisconnecting
  case unknownStatus

  var errorDescription: String? {
    switch self {
    case .configurationTooLarge: "Subscription is too large for the iOS VPN configuration."
    case .managerUnavailable: "iOS could not create the VPN configuration."
    case .notConfigured: "Save a subscription before connecting."
    case .configurationOutdated: "Refresh the subscription before connecting."
    case .noAvailableNodes: "The subscription contains no supported VPN nodes."
    case .invalidNodeSelection: "The selected VPN node is no longer available."
    case .disconnectBeforeUpdating: "Disconnect before updating the subscription."
    case .stillDisconnecting: "The previous VPN session is still disconnecting."
    case .unknownStatus: "iOS returned an unknown VPN status."
    }
  }
}

private enum AppLog {
  private static let lock = NSLock()
  private static let maximumBytes = 2 * 1024 * 1024
  private static let retainedBytes = 1024 * 1024
  private static let maximumMessageCharacters = 4096
  private static let keyExpression = try! NSRegularExpression(pattern: #"[0-9a-fA-F]{64}"#)
  private static let secretExpression = try! NSRegularExpression(
    pattern: #"(?i)(token|password|secret|jwt|key)(=|:|%3D)([^\s&]+)"#
  )

  static func append(level: String, message: String) {
    let cleanLevel = level.lowercased().prefix(8)
    let cleanMessage = redacted(message.replacingOccurrences(of: "\n", with: " "))
      .prefix(maximumMessageCharacters)
    let line = "\(ISO8601DateFormatter().string(from: Date())) [\(cleanLevel)] \(cleanMessage)\n"
    write(line)
  }

  static func append(contents: String) {
    let lines =
      contents
      .split(separator: "\n", omittingEmptySubsequences: true)
      .suffix(1_000)
      .map { redacted(String($0)).prefix(maximumMessageCharacters) }
    guard !lines.isEmpty else { return }
    write(lines.joined(separator: "\n") + "\n")
  }

  private static func write(_ value: String) {
    guard let data = value.data(using: .utf8) else { return }

    lock.lock()
    defer { lock.unlock() }
    do {
      if !FileManager.default.fileExists(atPath: logURL.path) {
        try Data().write(to: logURL, options: .atomic)
      }
      let handle = try FileHandle(forWritingTo: logURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.synchronize()
      rotateIfNeeded()
    } catch {}
  }

  static func read() -> String {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? Data(contentsOf: logURL),
      let value = String(data: data, encoding: .utf8)
    else { return "" }
    return value.split(separator: "\n", omittingEmptySubsequences: true).suffix(4_000).joined(
      separator: "\n")
  }

  static func clear() {
    lock.lock()
    defer { lock.unlock() }
    try? Data().write(to: logURL, options: .atomic)
  }

  private static func redacted(_ message: String) -> String {
    let withoutKeys = keyExpression.stringByReplacingMatches(
      in: message,
      range: NSRange(message.startIndex..., in: message),
      withTemplate: "<redacted-key>"
    )
    return secretExpression.stringByReplacingMatches(
      in: withoutKeys,
      range: NSRange(withoutKeys.startIndex..., in: withoutKeys),
      withTemplate: "$1$2<redacted>"
    )
  }

  private static let logURL: URL = {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = root.appendingPathComponent("OneLastChance", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("tunnel.log", isDirectory: false)
  }()

  private static func rotateIfNeeded() {
    guard let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size > maximumBytes,
      let data = try? Data(contentsOf: logURL)
    else { return }
    let retained = data.suffix(retainedBytes)
    let start = retained.firstIndex(of: 10).map { retained.index(after: $0) } ?? retained.startIndex
    try? Data(retained[start...]).write(to: logURL, options: .atomic)
  }
}
