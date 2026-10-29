import AppKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Network

/// Watches whether the Mac runs on battery.
final class PowerMonitor {
    /// Called on the main thread.
    var onChange: ((Bool) -> Void)?
    private var source: CFRunLoopSource?
    private(set) var onBattery = false

    func start() {
        onBattery = PowerMonitor.isOnBattery()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.refresh()
        }
        if let created = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            source = created
            CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        }
        onChange?(onBattery)
    }

    func refresh() {
        let now = PowerMonitor.isOnBattery()
        guard now != onBattery else { return }
        onBattery = now
        onChange?(now)
    }

    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }
}

/// Watches for Low Data Mode (`isConstrained`) and for having no network at all.
final class NetworkMonitor {
    /// Called on the main thread with (offline, constrained).
    var onChange: ((Bool, Bool) -> Void)?
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "me.alirazakhan.Ladle.network")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            let constrained = path.isConstrained
            DispatchQueue.main.async { self?.onChange?(offline, constrained) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

/// Sleep and wake, so downloads save their place before the Mac sleeps and pick up after.
final class SleepWakeObserver {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onSleep?()
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onWake?()
        })
    }
}

/// Keeps the Mac from idling to sleep while something downloads (so Tonight can finish).
final class IdleSleepBlocker {
    private var activity: NSObjectProtocol?

    func set(active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Ladle is downloading")
        } else if !active, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}

/// "When the queue finishes: Put the Mac to sleep".
enum MacSleeper {
    static func sleepNow() {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else { return }
        _ = IOPMSleepSystem(port)
        IOServiceClose(port)
    }
}
