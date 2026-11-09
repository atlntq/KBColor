// KBColor (universal): menu bar app for the keyboard light and the fans,
// through KBColor.kext and the SSDT-KBLT / SSDT-FANM that the setup assistant
// generated for this laptop. The menu is built from the "Capabilities" the
// kext publishes (KBCD.GCAP), so the same app runs on every supported model:
//
//   ASUS TUF:        one colour, brightness through the system (AsusSMC),
//                    fan Silent / Normal / Turbo, Fn+F5
//   Acer Predator:   4 zones, effects, brightness 0-100 %, fan Normal /
//                    Turbo / Custom %, Turbo key
//
// Choices are saved and reapplied at launch. In automatic fan control the app
// picks the mode from the CPU temperature. The menu also lists temperatures,
// power draw and fan speeds.

import AppKit
import IOKit
import ServiceManagement

// KBCD.GCAP bits (keep in sync with the setup assistant's templates)
struct Caps: OptionSet {
    let rawValue: Int
    static let color      = Caps(rawValue: 0x001)
    static let zones      = Caps(rawValue: 0x002)
    static let effects    = Caps(rawValue: 0x004)
    static let brightKext = Caps(rawValue: 0x008)
    static let brightSys  = Caps(rawValue: 0x010)
    static let fan        = Caps(rawValue: 0x020)
    static let fanSilent  = Caps(rawValue: 0x040)
    static let fanCustom  = Caps(rawValue: 0x080)
    static let rpm        = Caps(rawValue: 0x100)
    static let fanKey     = Caps(rawValue: 0x200)
    // bits 16-23: fan key label, 1 = Fn+F5, 2 = Turbo key
    var keyName: String { [1: "Fn+F5", 2: "Turbo tuşu"][(rawValue >> 16) & 0xFF] ?? "Fan tuşu" }
}

let presets: [(String, UInt32)] = [
    ("Beyaz", 0xFFFFFF), ("Kırmızı", 0xFF0000), ("Turuncu", 0xFF4000),
    ("Sarı", 0xFFB000), ("Yeşil", 0x00FF00), ("Camgöbeği", 0x00FFFF),
    ("Mavi", 0x0000FF), ("Mor", 0x8000FF), ("Pembe", 0xFF00A0),
]

// (name, mode, uses colour, uses direction)
let effects: [(String, Int, Bool, Bool)] = [
    ("Sabit", 0, true, false), ("Nefes", 1, true, false), ("Neon", 2, false, false),
    ("Dalga", 3, false, true), ("Kayma", 4, true, true), ("Zoom", 5, true, false),
]

let customSpeeds = [30, 40, 50, 60, 70, 80, 90, 100]

// kIOMessageServicePropertyChange, sent by the kext after the fan key.
let kMsgPropertyChange: UInt32 = 0xE000_0130

func withKext<T>(_ body: (io_service_t) -> T?) -> T? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    return body(svc)
}

func setKext(_ key: String, _ value: Int) -> Bool {
    withKext { IORegistryEntrySetCFProperties($0, [key: NSNumber(value: value)] as CFDictionary) == KERN_SUCCESS } ?? false
}

func published(_ key: String) -> Int? {
    withKext { svc in
        (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }
}

// From KBCD.GCAP, or inferred for older kexts / SSDTs without it.
let caps: Caps = {
    _ = setKext("Refresh", 1) || setKext("ReadFanMode", 1)
    let props: [String: Any] = withKext { svc in
        var d: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &d, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return d?.takeRetainedValue() as? [String: Any]
    } ?? [:]
    return Caps(rawValue: withKext({ _ in true }) == nil ? 0 : Diagnostics.capabilities(props).caps)
}()

// (name, mode, symbol) in menu order, from the capabilities.
let fanModes: [(String, Int, String)] = {
    var m: [(String, Int, String)] = []
    if caps.contains(.fanSilent) { m.append(("Sessiz", 2, "leaf.fill")) }
    m.append(("Normal", 0, "fan.fill"))
    m.append(("Turbo", 1, "flame.fill"))
    if caps.contains(.fanCustom) { m.append(("Özel", 2, "dial.medium.fill")) }
    return m
}()

struct FanState { var mode: Int?; var pct: Int?; var cpu: Int?; var gpu: Int? }

func publishedFans() -> FanState {
    FanState(mode: published("FanMode"), pct: published("FanSpeed"), cpu: published("CPUFanRPM"), gpu: published("GPUFanRPM"))
}

func readFans() -> FanState {
    // "ReadFanMode": the ASUS 1.x kext
    guard setKext("Refresh", 1) || setKext("ReadFanMode", 1) else { return FanState() }
    return publishedFans()
}

func setFanMode(_ mode: Int) -> Bool { setKext("FanMode", mode) }

// Reads numeric keys from AppleSMC (struct layout of the SMC user client).
final class SMC {
    struct KeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var plimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var info: (size: UInt32, type: UInt32, attr: UInt8, pad: (UInt8, UInt8, UInt8)) = (0, 0, 0, (0, 0, 0))
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    var conn: io_connect_t = 0

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        if IOServiceOpen(svc, mach_task_self_, 0, &conn) != KERN_SUCCESS { conn = 0 }
    }

    func call(_ input: KeyData) -> KeyData? {
        var i = input, o = KeyData(), n = MemoryLayout<KeyData>.size
        let r = IOConnectCallStructMethod(conn, 2, &i, MemoryLayout<KeyData>.size, &o, &n)
        return r == KERN_SUCCESS && o.result == 0 ? o : nil
    }

    // nil if the key is missing or of a type not handled here.
    func value(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var q = KeyData()
        q.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        q.data8 = 9  // key info
        guard let info = call(q) else { return nil }
        q.info = info.info
        q.data8 = 5  // read
        guard let v = call(q) else { return nil }
        let b = withUnsafeBytes(of: v.bytes) { Array($0.prefix(4)) }
        let be16 = UInt16(b[0]) << 8 | UInt16(b[1])
        switch (info.info.type, info.info.size) {
        case (0x7370_3738, 2): return Double(Int16(bitPattern: be16)) / 256  // sp78
        case (0x7370_3936, 2): return Double(Int16(bitPattern: be16)) / 64   // sp96
        case (0x7369_3136, 2): return Double(Int16(bitPattern: be16))        // si16
        case (0x7569_3136, 2): return Double(be16)                           // ui16
        case (0x666C_7420, 4):                                               // flt, little endian
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        default: return nil
        }
    }
}

// CPU sensors, sampled in one place at a steady rate. Every read of an
// SMCProcessor key makes the kext recompute power from the RAPL energy
// counters, but its per-core threads refresh those counters only every
// 500 ms, so reads at uneven intervals alternate between 0 W and spikes.
// The CPU keys are read only here, once a second, and power is averaged over
// the last few samples.
final class CPUSensors {
    static let powerKeys = ["PCPR", "PCPC", "PCPG"]
    static let window = 4
    let smc: SMC
    private(set) var package: Double?
    private(set) var cores: [Double] = []
    private var history: [String: [Double]] = [:]

    init(_ smc: SMC) { self.smc = smc }

    func sample() {
        package = smc.value("TC0P")
        cores = (1...16).lazy.map { self.smc.value("TC\(String($0, radix: 16, uppercase: true))C") }
            .prefix { $0 != nil }.compactMap { $0 }
        for k in Self.powerKeys {
            guard let v = smc.value(k) else { history[k] = nil; continue }
            history[k] = Array((history[k, default: []] + [v]).suffix(Self.window))
        }
    }

    func power(_ key: String) -> Double? {
        guard let h = history[key], !h.isEmpty else { return nil }
        return h.reduce(0, +) / Double(h.count)
    }
}

func sensorTitles(_ cpu: CPUSensors, _ smc: SMC) -> [String] {
    func w(_ v: Double?) -> String { v.map { String(format: "%.1f W", $0) } ?? "—" }
    func c(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }
    let cores = cpu.cores
    var rows = ["CPU paketi: \(c(cpu.package))"]
    if !cores.isEmpty { rows.append("Çekirdekler: " + cores.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " °C") }
    rows.append("CPU gücü: \(w(cpu.power("PCPR")))")
    rows.append("Çekirdek: \(w(cpu.power("PCPC")))  ·  iGPU: \(w(cpu.power("PCPG")))")
    if let ma = smc.value("B0AC"), let mv = smc.value("B0AV") {
        let watts = abs(ma * mv) / 1_000_000
        rows.append(ma < 0 ? String(format: "Pil: %.1f W harcanıyor", watts)
                    : ma > 0 ? String(format: "Pil: şarj oluyor (%.1f W)", watts) : "Pil: adaptörde")
    }
    return rows
}

// Automatic fan control. With Silent: Silent below `low`, Turbo from `high`,
// Normal in between. Without: Normal / Turbo around `high`. Stepping down
// needs the temperature `hysteresis` degrees under the threshold.
let hysteresis = 5.0
let lowChoices = [45, 50, 55, 60, 65, 70]
let highChoices = [70, 75, 80, 85, 90]

func autoMode(current: Int, temp: Double, low: Int, high: Int) -> Int {
    let lo = Double(low), hi = Double(high)
    guard caps.contains(.fanSilent) else {
        if current == 1 { return temp > hi - hysteresis ? 1 : 0 }
        return temp >= hi ? 1 : 0
    }
    switch current {
    case 1:  // Turbo
        if temp > hi - hysteresis { return 1 }
        return temp > lo - hysteresis ? 0 : 2
    case 0:  // Normal
        if temp >= hi { return 1 }
        return temp > lo - hysteresis ? 0 : 2
    default:  // Silent
        if temp >= hi { return 1 }
        return temp >= lo ? 0 : 2
    }
}

func rpmTitle(_ name: String, _ rpm: Int?) -> String {
    guard let rpm else { return "\(name): —" }
    return rpm == 0 ? "\(name): duruyor" : "\(name): \(rpm) RPM"
}

// A small panel in the style of the volume / brightness HUD.
final class HUD {
    let panel: NSPanel
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    let dots = NSStackView()
    var hide: DispatchWorkItem?

    init() {
        let size = NSSize(width: 200, height: 200)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 18
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        icon.symbolConfiguration = .init(pointSize: 72, weight: .regular)
        icon.contentTintColor = .labelColor
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        dots.orientation = .horizontal
        dots.spacing = 6
        for _ in fanModes {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.cornerRadius = 3
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: 36).isActive = true
            d.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dots.addArrangedSubview(d)
        }
        let text = NSStackView(views: [label, sub])
        text.orientation = .vertical
        text.spacing = 2
        let stack = NSStackView(views: [icon, text, dots])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
    }

    func show(mode: Int, detail: String) {
        guard let i = fanModes.firstIndex(where: { $0.1 == mode }) else { return }
        icon.image = NSImage(systemSymbolName: fanModes[i].2, accessibilityDescription: fanModes[i].0)
        label.stringValue = "Fan modu: \(fanModes[i].0)"
        sub.stringValue = detail
        for (j, d) in dots.arrangedSubviews.enumerated() {
            d.layer?.backgroundColor = (j == i ? NSColor.labelColor : NSColor.tertiaryLabelColor).cgColor
        }
        if let screen = NSScreen.main {
            let f = screen.frame, s = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.minY + f.height * 0.14))
        }
        hide?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.4
                self?.panel.animator().alphaValue = 0
            }, completionHandler: { self?.panel.orderOut(nil) })
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

// Private CoreBrightness KeyboardBrightnessClient, looked up at run time.
// Used when the keyboard backlight is a system one (AsusSMC), so the slider,
// Control Center and the brightness keys stay in sync.
final class KeyboardBrightness {
    typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    let getSel = NSSelectorFromString("brightnessForKeyboard:")
    let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
    var client: NSObject?
    var id: UInt64 = 0

    init() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }
        let c = cls.init()
        guard c.responds(to: getSel), c.responds(to: setSel),
              let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber],
              let first = ids.first else { return }
        client = c
        id = first.uint64Value
    }

    var level: Float? {
        guard let c = client else { return nil }
        return unsafeBitCast(c.method(for: getSel), to: Get.self)(c, getSel, id)
    }

    func set(_ v: Float) -> Bool {
        guard let c = client else { return false }
        return unsafeBitCast(c.method(for: setSel), to: Set.self)(c, setSel, max(0, min(1, v)), id)
    }
}

func nsColor(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
}

func swatch(_ rgb: UInt32) -> NSImage {
    NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
        let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        nsColor(rgb).setFill(); p.fill()
        NSColor.secondaryLabelColor.setStroke(); p.lineWidth = 0.5; p.stroke()
        return true
    }
}

// Saved settings. nil means "not chosen here yet": keep what the firmware has.
enum Store {
    static let d = UserDefaults.standard
    static func int(_ k: String) -> Int? { d.object(forKey: k) as? Int }
    static func set(_ k: String, _ v: Int?) { d.set(v, forKey: k) }

    // Index 0 = whole keyboard, 1...4 = zones from left to right.
    static func color(_ zone: Int) -> UInt32? { int("color\(zone)").map { UInt32($0) } }
    static func setColor(_ zone: Int, _ rgb: UInt32) {
        if zone == 0 { for z in 1...4 { set("color\(z)", nil) } }
        set("color\(zone)", Int(rgb))
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var titleTimer: Timer?
    let menu = NSMenu()
    var pending: UInt32?
    var timer: Timer?
    let hud = HUD()
    var port: IONotificationPortRef?
    var interest: io_object_t = 0
    var liveItems: [NSMenuItem] = []
    lazy var kb = KeyboardBrightness()
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    var pendingLevel: Int?
    var levelTimer: Timer?
    var liveTimer: Timer?
    let smc = SMC()
    lazy var cpu = CPUSensors(smc)
    var autoTimer: Timer?
    var avgTemp: Double?
    var lastAutoChange = Date.distantPast

    var fanAuto: Bool {
        get { UserDefaults.standard.bool(forKey: "fanAuto") }
        set { UserDefaults.standard.set(newValue, forKey: "fanAuto") }
    }
    var autoLow: Int {
        get { Store.int("autoLow") ?? 60 }
        set { Store.set("autoLow", newValue) }
    }
    var autoHigh: Int {
        get { Store.int("autoHigh") ?? 80 }
        set { Store.set("autoHigh", newValue) }
    }
    var target: Int {
        get { caps.contains(.zones) ? Store.int("target") ?? 0 : 0 }
        set { Store.set("target", newValue) }
    }

    var effect: (Int, Int, Int) {
        let e = published("Effect") ?? 0x01_05_00
        return (e & 0xFF, (e >> 8) & 0xFF, max(1, (e >> 16) & 0xFF))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        startTitle()
        menu.delegate = self
        item.menu = menu
        restoreLighting()
        watchKext()
        if fanAuto && caps.contains(.fan) { startAuto() }
    }

    // Reapply what was chosen here: zone colours, then effect, then brightness.
    func restoreLighting() {
        if let c = Store.color(0) { _ = setKext("Color", Int(c)) }
        if caps.contains(.zones) {
            for z in 1...4 { if let c = Store.color(z) { _ = setKext("ZoneColor", z << 24 | Int(c)) } }
        }
        if caps.contains(.effects), let e = Store.int("effect") { _ = setKext("Effect", e) }
        if caps.contains(.brightKext), let b = Store.int("brightness") { _ = setKext("Brightness", b) }
    }

    func startTitle() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.cpu.sample()
            self?.updateTitle()
        }
        RunLoop.main.add(t, forMode: .common)
        titleTimer = t
        cpu.sample()
        updateTitle()
    }

    func updateTitle() {
        guard let b = item.button else { return }
        if let t = cpu.package {
            b.image = nil
            b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            b.title = String(format: "%.0f°", t)
            b.setAccessibilityLabel(String(format: "CPU %.0f derece", t))
        } else {
            b.title = ""
            b.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KBColor")
        }
    }

    func startAuto() {
        avgTemp = nil
        autoTimer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.autoTick() }
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
        autoTick()
    }

    func stopAuto() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    func autoTick() {
        guard let t = cpu.package, var mode = publishedFans().mode else { return }
        if caps.contains(.fanCustom) && mode == 2 { mode = 0 }
        let avg = avgTemp.map { $0 * 0.7 + t * 0.3 } ?? t
        avgTemp = avg
        let next = autoMode(current: mode, temp: avg, low: autoLow, high: autoHigh)
        guard next != publishedFans().mode, Date().timeIntervalSince(lastAutoChange) >= 10 else { return }
        if setFanMode(next) {
            lastAutoChange = Date()
            hud.show(mode: next, detail: "Otomatik")
        }
    }

    // The fan key is handled in ACPI; the kext then sends kIOMessageServicePropertyChange.
    func watchKext() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, svc, kIOGeneralInterest, { ref, _, type, _ in
            guard type == kMsgPropertyChange, let ref else { return }
            // The fan key is a manual choice, so it ends automatic control.
            let app = Unmanaged<App>.fromOpaque(ref).takeUnretainedValue()
            if app.fanAuto { app.fanAuto = false; app.stopAuto() }
            if let mode = publishedFans().mode { app.hud.show(mode: mode, detail: caps.keyName) }
        }, me, &interest)
    }

    func header(_ m: NSMenu, _ title: String) { m.addItem(withTitle: title, action: nil, keyEquivalent: "") }

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ action: Selector?, tag: Int, on: Bool, indent: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self; mi.tag = tag; mi.state = on ? .on : .off
        if indent { mi.indentationLevel = 1 }
        m.addItem(mi)
        return mi
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let fans = readFans()  // also refreshes the lighting properties
        if withKext({ _ in true }) == nil {
            header(m, "KBColor.kext yüklü değil")
            m.addItem(.separator())
        }
        if !caps.isDisjoint(with: [.color, .brightKext, .brightSys]) {
            let light = NSMenuItem(title: "Klavye ışığı", action: nil, keyEquivalent: "")
            light.image = NSImage(systemSymbolName: "light.max", accessibilityDescription: nil)
            light.submenu = lightMenu()
            m.addItem(light)
            m.addItem(.separator())
        }
        if caps.contains(.fan) { fanMenu(m, fans) }
        header(m, "Sensörler")
        liveItems = liveTitles(fans).map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
        for mi in liveItems { mi.indentationLevel = 1; m.addItem(mi) }
        m.addItem(.separator())
        let diag = NSMenuItem(title: "Tanılama raporu…", action: #selector(diagnose), keyEquivalent: "")
        diag.target = self
        diag.image = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: nil)
        m.addItem(diag)
        let login = NSMenuItem(title: "Açılışta başlat", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(NSMenuItem(title: "Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func fanMenu(_ m: NSMenu, _ fans: FanState) {
        let ok = fans.mode != nil
        header(m, "Fan kontrolü")
        for (title, auto) in [("Otomatik", true), ("Manuel", false)] {
            add(m, title, ok ? #selector(pickControl(_:)) : nil, tag: auto ? 1 : 0, on: fanAuto == auto)
        }
        let limits = NSMenuItem(title: "Otomatik eşikler", action: nil, keyEquivalent: "")
        limits.indentationLevel = 1
        let sub = NSMenu()
        if caps.contains(.fanSilent) {
            header(sub, "Normal'e geç")
            for c in lowChoices { add(sub, "\(c) °C", c < autoHigh ? #selector(pickLow(_:)) : nil, tag: c, on: c == autoLow) }
            sub.addItem(.separator())
        }
        header(sub, "Turbo'ya geç")
        for c in highChoices { add(sub, "\(c) °C", c > autoLow || !caps.contains(.fanSilent) ? #selector(pickHigh(_:)) : nil, tag: c, on: c == autoHigh) }
        limits.submenu = sub
        m.addItem(limits)

        header(m, "Fan modu")
        for (name, mode, symbol) in fanModes {
            let custom = mode == 2 && caps.contains(.fanCustom)
            let mi = add(m, custom ? "\(name) (%\(fans.pct ?? 60))" : name, ok ? #selector(pickFan(_:)) : nil,
                         tag: mode, on: mode == fans.mode)
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            if custom {
                let sm = NSMenu()
                for p in customSpeeds {
                    add(sm, "%\(p)", ok ? #selector(pickSpeed(_:)) : nil, tag: p, on: fans.mode == 2 && fans.pct == p, indent: false)
                }
                mi.submenu = sm
            }
        }
        m.addItem(.separator())
    }

    func lightMenu() -> NSMenu {
        let lm = NSMenu()
        if caps.contains(.brightKext) || caps.contains(.brightSys) {
            header(lm, "Parlaklık")
            let bar = NSMenuItem()
            bar.view = sliderView()
            lm.addItem(bar)
            lm.addItem(.separator())
        }
        var usesColor = true
        if caps.contains(.effects) {
            let (mode, speed, dir) = effect
            header(lm, "Efekt")
            for (name, m, _, _) in effects { add(lm, name, #selector(pickEffect(_:)), tag: m, on: m == mode) }
            let speedItem = NSMenuItem(title: "Hız", action: nil, keyEquivalent: "")
            speedItem.indentationLevel = 1
            let sm = NSMenu()
            for s in 1...9 { add(sm, "\(s)", mode == 0 ? nil : #selector(pickSpeed9(_:)), tag: s, on: s == speed, indent: false) }
            speedItem.submenu = sm
            lm.addItem(speedItem)
            let dirItem = NSMenuItem(title: "Yön", action: nil, keyEquivalent: "")
            dirItem.indentationLevel = 1
            let dm = NSMenu()
            let hasDir = effects.first { $0.1 == mode }?.3 ?? false
            for (t, d) in [("Sağdan sola", 1), ("Soldan sağa", 2)] {
                add(dm, t, hasDir ? #selector(pickDir(_:)) : nil, tag: d, on: d == dir, indent: false)
            }
            dirItem.submenu = dm
            lm.addItem(dirItem)
            lm.addItem(.separator())
            usesColor = effects.first { $0.1 == mode }?.2 ?? true
        }
        guard caps.contains(.color) else { return lm }
        if caps.contains(.zones) {
            header(lm, "Renk uygulanacak yer")
            for (t, z) in [("Tüm klavye", 0), ("Bölge 1 (sol)", 1), ("Bölge 2", 2), ("Bölge 3", 3), ("Bölge 4 (sağ)", 4)] {
                let mi = add(lm, t, #selector(pickTarget(_:)), tag: z, on: z == target)
                if let c = Store.color(z) { mi.image = swatch(c) }
            }
            lm.addItem(.separator())
        }
        header(lm, usesColor ? "Renk" : "Renk (bu efekt renk kullanmıyor)")
        for (name, rgb) in presets {
            add(lm, name, #selector(pick(_:)), tag: Int(rgb), on: Store.color(target) == rgb).image = swatch(rgb)
        }
        lm.addItem(.separator())
        add(lm, "Özel renk…", #selector(openPanel), tag: 0, on: false, indent: false).image = swatch(currentColor())
        return lm
    }

    func currentColor() -> UInt32 { Store.color(target) ?? UInt32(published("Color") ?? 0xFFFFFF) }

    func sliderView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let lo = NSImageView(image: NSImage(systemSymbolName: "sun.min", accessibilityDescription: nil)!)
        let hi = NSImageView(image: NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)!)
        for i in [lo, hi] { i.contentTintColor = .secondaryLabelColor }
        lo.frame = NSRect(x: 18, y: 7, width: 16, height: 16)
        hi.frame = NSRect(x: 210, y: 7, width: 16, height: 16)
        slider.frame = NSRect(x: 40, y: 5, width: 164, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(levelChanged(_:))
        let level = caps.contains(.brightKext) ? published("Brightness") : kb.level.map { Int(($0 * 100).rounded()) }
        if let level { slider.integerValue = level; slider.isEnabled = true } else { slider.isEnabled = false }
        for x in [lo, slider, hi] as [NSView] { v.addSubview(x) }
        return v
    }

    // Dragging fires many events; send at most ~10/s.
    @objc func levelChanged(_ s: NSSlider) {
        pendingLevel = s.integerValue
        if levelTimer == nil {
            let t = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.levelTimer = nil
                guard let v = self.pendingLevel else { return }
                self.pendingLevel = nil
                if caps.contains(.brightKext) {
                    if setKext("Brightness", v) { Store.set("brightness", v) } else { NSSound.beep() }
                } else if !self.kb.set(Float(v) / 100) { NSSound.beep() }
            }
            RunLoop.main.add(t, forMode: .common)
            levelTimer = t
        }
    }

    func setEffect(mode: Int, speed: Int, dir: Int) {
        let e = mode | speed << 8 | dir << 16
        if setKext("Effect", e) { Store.set("effect", e) } else { NSSound.beep() }
    }

    @objc func pickEffect(_ s: NSMenuItem) { let (_, sp, d) = effect; setEffect(mode: s.tag, speed: max(1, sp), dir: d) }
    @objc func pickSpeed9(_ s: NSMenuItem) { let (m, _, d) = effect; setEffect(mode: m, speed: s.tag, dir: d) }
    @objc func pickDir(_ s: NSMenuItem) { let (m, sp, _) = effect; setEffect(mode: m, speed: sp, dir: s.tag) }
    @objc func pickTarget(_ s: NSMenuItem) { target = s.tag }

    func apply(_ rgb: UInt32) {
        let z = target
        let ok = z == 0 ? setKext("Color", Int(rgb)) : setKext("ZoneColor", z << 24 | Int(rgb))
        guard ok else { NSSound.beep(); return }
        Store.setColor(z, rgb)
        // A zone colour switches the firmware to static mode.
        if z != 0 { Store.set("effect", published("Effect")) }
    }

    @objc func pick(_ s: NSMenuItem) { apply(UInt32(s.tag)) }

    func liveTitles(_ f: FanState) -> [String] {
        sensorTitles(cpu, smc) + (caps.contains(.rpm) ? [rpmTitle("CPU fanı", f.cpu), rpmTitle("GPU fanı", f.gpu)] : [])
    }

    @objc func pickFan(_ s: NSMenuItem) {
        if fanAuto { fanAuto = false; stopAuto() }
        if setFanMode(s.tag) { hud.show(mode: s.tag, detail: "Manuel") } else { NSSound.beep() }
    }

    @objc func pickSpeed(_ s: NSMenuItem) {
        if fanAuto { fanAuto = false; stopAuto() }
        if setKext("FanSpeed", s.tag) { hud.show(mode: 2, detail: "%\(s.tag)") } else { NSSound.beep() }
    }

    @objc func pickControl(_ s: NSMenuItem) {
        fanAuto = s.tag == 1
        if fanAuto { lastAutoChange = .distantPast; startAuto() } else { stopAuto() }
    }

    @objc func pickLow(_ s: NSMenuItem) { autoLow = s.tag }
    @objc func pickHigh(_ s: NSMenuItem) { autoHigh = s.tag }

    func menuWillOpen(_ m: NSMenu) {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let titles = self.liveTitles(readFans())
            guard titles.count == self.liveItems.count else { return }
            for (mi, title) in zip(self.liveItems, titles) { mi.title = title }
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func menuDidClose(_ m: NSMenu) {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    @objc func openPanel() {
        let p = NSColorPanel.shared
        p.showsAlpha = false
        p.color = nsColor(currentColor())
        p.setTarget(self); p.setAction(#selector(panelChanged(_:)))
        p.isContinuous = true
        NSApp.activate(ignoringOtherApps: true)
        p.orderFrontRegardless()
    }

    @objc func panelChanged(_ p: NSColorPanel) {
        guard let c = p.color.usingColorSpace(.sRGB) else { return }
        func b(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        pending = b(c.redComponent) << 16 | b(c.greenComponent) << 8 | b(c.blueComponent)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.timer = nil
                if let v = self.pending { self.pending = nil; self.apply(v) }
            }
        }
    }

    // Same report as KBColor Kurulum: saved to the Desktop, then shown.
    @objc func diagnose() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Tanılama raporu"
        a.informativeText = "Sistem, KBColor.kext ve açılıştaki ACPI hataları kontrol edilir ve rapor masaüstüne kaydedilir. EFI'deki config.plist'i de seçersen SSDT sırası, fan tuşu rename'i ve kext girdisi de kontrol edilir."
        a.addButton(withTitle: "config.plist seç…")
        a.addButton(withTitle: "config.plist olmadan")
        a.addButton(withTitle: "Vazgeç")
        let r = a.runModal()
        if r == .alertThirdButtonReturn { return }
        var config: URL?
        if r == .alertFirstButtonReturn {
            let p = NSOpenPanel()
            p.allowedContentTypes = [.propertyList]
            p.message = "EFI/OC/config.plist dosyasını seç"
            guard p.runModal() == .OK else { return }
            config = p.url
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let d = Diagnostics(config: config)
            let text = d.run()
            let file = try? Diagnostics.save(text)
            DispatchQueue.main.async {
                let done = NSAlert()
                let fails = d.findings.filter { $0.level == .fail }
                done.messageText = fails.isEmpty ? "Rapor hazır" : "Rapor hazır: \(fails.count) sorun bulundu"
                done.informativeText = (fails.isEmpty ? d.findings.prefix(3) : fails.prefix(3))
                    .map { "\($0.level.rawValue) \($0.text)" }.joined(separator: "\n\n")
                    + (file.map { "\n\nKaydedildi: \($0.lastPathComponent) (Masaüstü)" } ?? "")
                done.addButton(withTitle: "Finder'da göster")
                done.addButton(withTitle: "Forum konusunu aç")
                done.addButton(withTitle: "Kapat")
                NSApp.activate(ignoringOtherApps: true)
                switch done.runModal() {
                case .alertFirstButtonReturn: if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                case .alertSecondButtonReturn: NSWorkspace.shared.open(Diagnostics.forumURL)
                default: break
                }
            }
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
