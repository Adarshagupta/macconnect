import Darwin
import Foundation

enum Log {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func line(_ message: String) {
        lock.lock()
        let text = "\(formatter.string(from: Date())) \(message)\n"
        lock.unlock()
        fputs(text, stderr)
        fflush(stderr)
    }
}

/// If nothing in the agent makes progress for a long time, exit so launchd starts a fresh copy.
/// Uptime does not count time the Mac spends asleep, so waking up does not look like a hang.
enum Heartbeat {
    private static let lock = NSLock()
    private static var last = ProcessInfo.processInfo.systemUptime

    static func beat() {
        lock.lock()
        last = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    static func startWatchdog(limit: TimeInterval = 90) {
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 5)
                Heartbeat.lock.lock()
                let idle = ProcessInfo.processInfo.systemUptime - Heartbeat.last
                Heartbeat.lock.unlock()
                if idle > limit {
                    Log.line("The agent made no progress for \(Int(idle)) seconds. Restarting.")
                    exit(1)
                }
            }
        }
        thread.name = "com.macconnect.watchdog"
        thread.start()
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let what: String
    var description: String { "\(what) timed out" }
}

final class OneShot {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Runs blocking work on a background thread so it never ties up Swift's async thread pool.
func blocking<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Gives up after `seconds` even if the operation ignores cancellation (ScreenCaptureKit calls can hang).
func withTimeout<T>(seconds: Double, what: String, _ operation: @escaping () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let gate = OneShot()
        Task {
            do {
                let value = try await operation()
                if gate.claim() { continuation.resume(returning: value) }
            } catch {
                if gate.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if gate.claim() { continuation.resume(throwing: TimeoutError(what: what)) }
        }
    }
}
