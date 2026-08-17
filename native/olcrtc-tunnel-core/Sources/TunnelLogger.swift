import Foundation

public enum TunnelLogger {
  private static let lock = NSLock()
  private static let maximumBytes = 512 * 1024
  private static let retainedBytes = 256 * 1024
  private static let maximumMessageCharacters = 512
  private static let keyExpression = try! NSRegularExpression(pattern: #"[0-9a-fA-F]{64}"#)
  private static let secretExpression = try! NSRegularExpression(
    pattern: #"(?i)(token|password|secret|jwt|key)(=|:|%3D)([^\s&]+)"#
  )

  public static func info(_ message: String) {
    write("info", message)
  }

  public static func warning(_ message: String) {
    write("warning", message)
  }

  public static func error(_ message: String) {
    write("error", message)
  }

  public static func drain() -> String {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return "" }
    try? Data().write(to: logURL, options: .atomic)
    return String(data: data, encoding: .utf8) ?? ""
  }

  private static func write(_ level: String, _ message: String) {
    let clean = String(redacted(message).prefix(maximumMessageCharacters))
    let line = "\(ISO8601DateFormatter().string(from: Date())) [tunnel/\(level)] \(clean)\n"
    guard let data = line.data(using: .utf8) else { return }

    lock.lock()
    defer { lock.unlock() }
    do {
      try FileManager.default.createDirectory(
        at: logURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: logURL.path) {
        try Data().write(to: logURL, options: .atomic)
      }
      let handle = try FileHandle(forWritingTo: logURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.synchronize()
      rotateIfNeeded()
    } catch {
      // There is intentionally no second logging path: this file is the source of truth.
    }
  }

  private static func rotateIfNeeded() {
    guard let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size > maximumBytes,
      let data = try? Data(contentsOf: logURL)
    else { return }
    let retained = data.suffix(retainedBytes)
    let start = retained.firstIndex(of: 10).map { retained.index(after: $0) } ?? retained.startIndex
    try? Data(retained[start...]).write(to: logURL, options: .atomic)
  }

  private static func redacted(_ message: String) -> String {
    let singleLine = message.replacingOccurrences(of: "\n", with: " ")
    let withoutKeys = keyExpression.stringByReplacingMatches(
      in: singleLine,
      range: NSRange(singleLine.startIndex..., in: singleLine),
      withTemplate: "<redacted-key>"
    )
    return secretExpression.stringByReplacingMatches(
      in: withoutKeys,
      range: NSRange(withoutKeys.startIndex..., in: withoutKeys),
      withTemplate: "$1$2<redacted>"
    )
  }

  private static let logURL = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
  )[0].appendingPathComponent("OneLastChance/tunnel.log")
}
