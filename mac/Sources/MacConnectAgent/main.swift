import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

@main
enum Main {
    static func main() {
        Darwin.signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            await Agent().run()
        }
        app.run()
    }
}

final class Agent {
    func run() async {
        Log.line("MacConnect agent started")
        let discovery = await Discovery.listen()

        var quietWaits = 0
        while true {
            if !(await Permissions.ensure()) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }

            guard let beacon = discovery.next() else {
                quietWaits += 1
                if quietWaits == 1 || quietWaits % 15 == 0 {
                    Log.line("Waiting for the Windows viewer on this network")
                }
                continue
            }
            quietWaits = 0
            Log.line("Found \(beacon.name) at \(beacon.host)")
            do {
                try await Session(beacon: beacon).run()
            } catch {
                Log.line("Connection failed: \(error)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

@MainActor
enum Permissions {
    private static var openedScreen = false
    private static var openedAccessibility = false

    static func ensure() -> Bool {
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        if screen && accessibility {
            return true
        }
        if !screen {
            _ = CGRequestScreenCaptureAccess()
            openOnce(&openedScreen, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            Log.line("Allow Screen Recording for MacConnect Agent, then this Mac can appear on Windows")
        }
        if !accessibility {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [prompt: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openOnce(&openedAccessibility, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            Log.line("Allow Accessibility for MacConnect Agent so Windows can control the Mac")
        }
        return false
    }

    private static func openOnce(_ opened: inout Bool, _ urlString: String) {
        guard !opened, let url = URL(string: urlString) else { return }
        opened = true
        NSWorkspace.shared.open(url)
    }
}
