import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

@main
enum MacConnectAgentMain {
    static func main() {
        // `--check` proves the program starts, without touching the screen or the network.
        if CommandLine.arguments.contains("--check") {
            print("MacConnect agent OK")
            exit(0)
        }

        Darwin.signal(SIGPIPE, SIG_IGN)
        Heartbeat.beat()
        Heartbeat.startWatchdog()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            await Agent().run()
        }
        app.run()
    }
}

final class Agent {
    private var discovery: Discovery?
    private var lastDiscoveryAttempt = Date.distantPast
    private var lastDirectAttempt = Date.distantPast
    private var directIndex = 0
    private var quietPolls = 0
    private var failures = 0
    private var triedManualAtStart = false

    func run() async {
        Log.line("MacConnect agent started as \"\(Wire.computerName)\"")
        PhoneHub.shared.start()
        while true {
            Heartbeat.beat()

            // Without Screen Recording there is nothing to show. Accessibility only affects control,
            // so the picture still goes to Windows without it.
            guard await Permissions.ensureScreenAccess() else {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            await Permissions.checkAccessibility()

            guard let target = await findTarget() else {
                continue
            }

            let started = Date()
            var accepted = false
            do {
                accepted = try await Session(beacon: target).run()
            } catch {
                Log.line("Could not connect to \(target.host): \(error)")
            }

            // A session that ran for a while counts as healthy. Quick failures back off, up to 8 seconds.
            if accepted && Date().timeIntervalSince(started) > 10 {
                failures = 0
            } else {
                failures += 1
            }
            let delay = min(8.0, pow(2.0, Double(min(failures, 3))))
            Heartbeat.beat()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Prefers the Windows viewer's broadcast. If none is heard, tries a saved address so a network
    /// that blocks broadcasts cannot lock the Mac out.
    private func findTarget() async -> Beacon? {
        // An address typed in by hand is tried first, straight away, once per start. After that the
        // broadcast is preferred and the manual address stays as a fallback.
        if !triedManualAtStart {
            triedManualAtStart = true
            if let host = Config.manualHost() {
                Log.line("Trying the address set by hand: \(host)")
                lastDirectAttempt = Date()
                return Beacon(host: host, port: Wire.tcpPort, name: "Windows PC at \(host)")
            }
        }

        if discovery == nil && Date().timeIntervalSince(lastDiscoveryAttempt) > 10 {
            lastDiscoveryAttempt = Date()
            discovery = Discovery.make()
        }

        if let discovery {
            let heard = try? await blocking { discovery.next() }
            if let beacon = heard {
                quietPolls = 0
                Config.rememberHost(beacon.host)
                Log.line("Found \(beacon.name) at \(beacon.host)")
                return beacon
            }
        } else {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        quietPolls += 1
        if quietPolls == 1 || quietPolls % 30 == 0 {
            Log.line("Waiting for the Windows viewer on this network")
        }

        if quietPolls >= 2 && Date().timeIntervalSince(lastDirectAttempt) >= 5 {
            let hosts = Config.savedHosts()
            if !hosts.isEmpty {
                lastDirectAttempt = Date()
                let host = hosts[directIndex % hosts.count]
                directIndex += 1
                Log.line("No broadcast heard. Trying saved address \(host)")
                return Beacon(host: host, port: Wire.tcpPort, name: "Windows PC at \(host)")
            }
        }
        return nil
    }
}

@MainActor
enum Permissions {
    private static var openedScreenSettings = false
    private static var openedAccessibilitySettings = false
    private static var warnedAccessibility = false
    private static var lastProbe = Date.distantPast
    private static var lastProbeResult = false

    static func ensureScreenAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // Some macOS versions keep reporting "no" until the app restarts even though access was granted,
        // so also try a real capture request now and then.
        if Date().timeIntervalSince(lastProbe) >= 30 {
            lastProbe = Date()
            lastProbeResult = await probeScreen()
            if !lastProbeResult {
                _ = CGRequestScreenCaptureAccess()
                openSettingsOnce(&openedScreenSettings, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                Log.line("Screen Recording is off for MacConnect Agent. Turn it on in System Settings > Privacy & Security.")
            }
        }
        return lastProbeResult
    }

    static func checkAccessibility() {
        if AXIsProcessTrusted() {
            warnedAccessibility = false
            return
        }
        if warnedAccessibility {
            return
        }
        warnedAccessibility = true
        Log.line("Accessibility is off for MacConnect Agent. Windows can see the Mac but cannot control it. Turn it on in System Settings > Privacy & Security.")
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettingsOnce(&openedAccessibilitySettings, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func probeScreen() async -> Bool {
        do {
            _ = try await withTimeout(seconds: 10, what: "Checking Screen Recording access") {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            return true
        } catch {
            return false
        }
    }

    private static func openSettingsOnce(_ opened: inout Bool, _ urlString: String) {
        guard !opened, let url = URL(string: urlString) else { return }
        opened = true
        NSWorkspace.shared.open(url)
    }
}
