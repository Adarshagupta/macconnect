import Darwin
import Foundation

/// Addresses to try when no broadcast is heard (some routers block Wi-Fi broadcasts).
///
/// 1. `windowsHost` from ~/Library/Application Support/MacConnect/config.json, if you set one.
/// 2. The last Windows PC this Mac found by broadcast.
enum Config {
    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacConnect", isDirectory: true)
    }

    private static var configURL: URL { directory.appendingPathComponent("config.json") }
    private static var lastHostURL: URL { directory.appendingPathComponent("last-host.txt") }

    /// The address typed in by hand (scripts/set-windows-ip.sh), if any.
    static func manualHost() -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["windowsHost"] as? String else {
            return nil
        }
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIPv4(host) {
            return host
        }
        if !host.isEmpty {
            Log.line("config.json: windowsHost \"\(host)\" is not an IPv4 address like 192.168.1.20")
        }
        return nil
    }

    static func savedHosts() -> [String] {
        var hosts: [String] = []
        if let host = manualHost() {
            hosts.append(host)
        }
        if let text = try? String(contentsOf: lastHostURL, encoding: .utf8) {
            let host = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isIPv4(host) && !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts
    }

    static func rememberHost(_ host: String) {
        guard isIPv4(host) else { return }
        if let existing = try? String(contentsOf: lastHostURL, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines) == host {
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? host.write(to: lastHostURL, atomically: true, encoding: .utf8)
    }

    private static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }
}
