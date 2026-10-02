// NetSpeed — a tiny macOS menu bar network speed monitor.
// Build with ./build.sh (requires Xcode Command Line Tools).

import Cocoa
import ServiceManagement

// MARK: - Reading interface counters

struct Counters {
    var rx: UInt64
    var tx: UInt64
}

/// Interfaces whose traffic is already counted on a physical interface
/// (VPN tunnels, internet-sharing bridges) or is local-only.
private let ignoredPrefixes = ["lo", "utun", "ipsec", "bridge", "gif", "stf", "llw"]

/// Reads 64-bit byte counters for every interface via sysctl(NET_RT_IFLIST2).
/// (getifaddrs only exposes 32-bit counters, which wrap every 4 GB.)
func readCounters() -> Counters {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else {
        return Counters(rx: 0, tx: 0)
    }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else {
        return Counters(rx: 0, tx: 0)
    }

    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))

    buf.withUnsafeBytes { raw in
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= len {
            let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let msgLen = Int(hdr.ifm_msglen)
            if msgLen <= 0 { break }

            if Int32(hdr.ifm_type) == RTM_IFINFO2,
               offset + MemoryLayout<if_msghdr2>.size <= len {
                let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var skip = (h2.ifm_flags & IFF_LOOPBACK) != 0
                if !skip, if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                    let name = String(cString: nameBuf)
                    skip = ignoredPrefixes.contains { name.hasPrefix($0) }
                }
                if !skip {
                    rx &+= h2.ifm_data.ifi_ibytes
                    tx &+= h2.ifm_data.ifi_obytes
                }
            }
            offset += msgLen
        }
    }
    return Counters(rx: rx, tx: tx)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    private var last = readCounters()
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var sessionRx: UInt64 = 0
    private var sessionTx: UInt64 = 0
    private var peakRx: Double = 0
    private var peakTx: Double = 0

    private let downItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let upItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let peakItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let totalItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let bitsItem = NSMenuItem(title: "Show in Bits (Mbps)", action: #selector(toggleBits), keyEquivalent: "b")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var intervalItems: [NSMenuItem] = []

    private let defaults = UserDefaults.standard
    private var interval: TimeInterval {
        get { let v = defaults.double(forKey: "interval"); return v > 0 ? v : 1 }
        set { defaults.set(newValue, forKey: "interval") }
    }
    private var useBits: Bool {
        get { defaults.bool(forKey: "useBits") }
        set { defaults.set(newValue, forKey: "useBits") }
    }

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        updateFixedWidth()
        render(rx: 0, tx: 0)
        startTimer()
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        for item in [downItem, upItem, peakItem, totalItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let intervalMenu = NSMenu()
        for secs in [0.5, 1.0, 2.0, 5.0] {
            let title = secs < 1 ? "0.5 seconds" : "\(Int(secs)) second\(secs == 1 ? "" : "s")"
            let item = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        let intervalParent = NSMenuItem(title: "Update Every", action: nil, keyEquivalent: "")
        intervalParent.submenu = intervalMenu
        menu.addItem(intervalParent)

        bitsItem.target = self
        menu.addItem(bitsItem)

        let resetItem = NSMenuItem(title: "Reset Session Stats", action: #selector(resetStats), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        if #available(macOS 13.0, *) {
            loginItem.target = self
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        let openNet = NSMenuItem(title: "Open Network Settings…", action: #selector(openNetworkSettings), keyEquivalent: "")
        openNet.target = self
        menu.addItem(openNet)
        menu.addItem(NSMenuItem(title: "Quit NetSpeed", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        refreshMenuState()
    }

    private func refreshMenuState() {
        bitsItem.state = useBits ? .on : .off
        for item in intervalItems {
            item.state = (item.representedObject as? Double) == interval ? .on : .off
        }
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Double else { return }
        interval = secs
        refreshMenuState()
        startTimer()
    }

    @objc private func toggleBits() {
        useBits.toggle()
        refreshMenuState()
        updateFixedWidth()
        tick()
    }

    @objc private func resetStats() {
        sessionRx = 0; sessionTx = 0; peakRx = 0; peakTx = 0
        tick()
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change login item"
            alert.informativeText = "\(error.localizedDescription)\n\nTry moving NetSpeed.app to /Applications first."
            alert.runModal()
        }
        refreshMenuState()
    }

    @objc private func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Sampling

    private func startTimer() {
        timer?.invalidate()
        last = readCounters()
        lastTime = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common) // keeps updating while the menu is open
        timer = t
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let current = readCounters()
        let dt = max(now - lastTime, 0.001)

        // Counters can drop when an interface disappears (e.g. Wi-Fi off); treat as zero.
        let dRx = current.rx >= last.rx ? current.rx - last.rx : 0
        let dTx = current.tx >= last.tx ? current.tx - last.tx : 0

        last = current
        lastTime = now
        sessionRx &+= dRx
        sessionTx &+= dTx

        let rxRate = Double(dRx) / dt
        let txRate = Double(dTx) / dt
        peakRx = max(peakRx, rxRate)
        peakTx = max(peakTx, txRate)
        render(rx: rxRate, tx: txRate)
    }

    // MARK: Display

    private func rate(_ bytesPerSec: Double) -> String {
        var value = useBits ? bytesPerSec * 8 : bytesPerSec
        let units = useBits ? ["bps", "Kbps", "Mbps", "Gbps"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var i = 0
        while value >= 1000 && i < units.count - 1 { value /= 1000; i += 1 }
        let number = (i == 0 || value >= 100) ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(number) \(units[i])"
    }

    private func total(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func titleString(rx: Double, tx: Double) -> String {
        "↓ \(rate(rx))  ↑ \(rate(tx))"
    }

    /// Fix the status item's width so the menu bar doesn't jitter as numbers change.
    private func updateFixedWidth() {
        let widest = useBits ? "↓ 99.9 Kbps  ↑ 99.9 Kbps" : "↓ 99.9 KB/s  ↑ 99.9 KB/s"
        let width = (widest as NSString).size(withAttributes: [.font: font]).width
        statusItem.length = ceil(width) + 12
    }

    private func render(rx: Double, tx: Double) {
        guard let button = statusItem.button else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        button.attributedTitle = NSAttributedString(
            string: titleString(rx: rx, tx: tx),
            attributes: [.font: font, .paragraphStyle: style, .baselineOffset: -0.5]
        )
        button.toolTip = "Download \(rate(rx)) · Upload \(rate(tx))"

        downItem.title = "Download:  \(rate(rx))"
        upItem.title = "Upload:  \(rate(tx))"
        peakItem.title = "Peak:  ↓ \(rate(peakRx))  ↑ \(rate(peakTx))"
        totalItem.title = "Session:  ↓ \(total(sessionRx))  ↑ \(total(sessionTx))"
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
