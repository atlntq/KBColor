// Diagnostic report, shared by KBColor Kurulum and KBColor.app.
//
// Collects everything needed to tell why KBColor does not work on a machine,
// in one text file the user can attach to the forum thread:
//   - system: macOS, model, CPU, OpenCore version, boot-args
//   - ACPI: does \_SB.KBCD exist, is KBColor.kext attached, which KBCD
//     methods exist, every property the kext publishes (old kexts included)
//   - kernel log of the current boot: ACPI errors and the kext's own lines
//   - optionally config.plist: SSDT order, the fan key rename, the kext
//     entry, and whether the files are in the EFI next to it
// and puts a plain-language summary of the problems on top.
//
// Only reads; the one call into the kext is "Refresh", which re-reads state.

import Foundation
import IOKit

struct DiagFinding {
    enum Level: String { case ok = "✓", warn = "!", fail = "✗", info = "i" }
    var level: Level
    var text: String
}

final class Diagnostics {
    static let forumURL = URL(string: "https://osxinfo.net/konu/kbcolor-hackintosh-dizustuler-icin-klavye-isigi-ve-fan-kontrolu-acpi-dokumunden-ssdt-hazirlayan-kurulum-yardimcisiyla-asus-tuf-acer-predator.33539/")!

    let config: URL?
    let progress: (String) -> Void
    var injectedLog: String?   // tests only: used instead of `log show`
    private(set) var findings: [DiagFinding] = []
    private var sections: [(String, String)] = []

    init(config: URL?, progress: @escaping (String) -> Void = { _ in }) {
        self.config = config
        self.progress = progress
    }

    // MARK: helpers

    private func add(_ l: DiagFinding.Level, _ t: String) { findings.append(DiagFinding(level: l, text: t)) }

    private func sh(_ exe: String, _ args: [String], timeout: TimeInterval = 20) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return "(\(exe) çalıştırılamadı: \(error))" }
        var data = Data()
        let reader = DispatchQueue(label: "diag.read")
        let done = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return String(decoding: data, as: UTF8.self) + "\n(zaman aşımı, \(Int(timeout)) sn)"
        }
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func service(_ matching: CFDictionary) -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, matching)
    }

    private static func props(_ s: io_service_t) -> [String: Any] {
        var d: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(s, &d, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = d?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    private static func describe(_ v: Any) -> String {
        switch v {
        case let n as NSNumber: return n.intValue > 9 ? "\(n) (0x\(String(n.intValue, radix: 16, uppercase: true)))" : "\(n)"
        case let d as Data: return "<\(d.count) bayt>"
        case let a as [Any]: return "[" + a.map { describe($0) }.joined(separator: ", ") + "]"
        case let s as String: return "\"\(s)\""
        default: return "\(v)"
        }
    }

    static let capNames: [(Int, String)] = [
        (0x001, "renk"), (0x002, "4 bölge"), (0x004, "efektler"), (0x008, "parlaklık (kext)"),
        (0x010, "parlaklık (sistem/AsusSMC)"), (0x020, "fan modu"), (0x040, "Sessiz"), (0x080, "Özel %"),
        (0x100, "fan RPM"), (0x200, "fan tuşu"), (0x0100_0000, "KEŞİF SONDASI"),
    ]

    // MARK: sections

    private func system() {
        progress("Sistem bilgileri…")
        let oc = sh("/usr/sbin/nvram", ["4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version"])
        let ba = sh("/usr/sbin/nvram", ["boot-args"])
        let text = """
        macOS: \(sh("/usr/bin/sw_vers", ["-productVersion"])) (\(sh("/usr/bin/sw_vers", ["-buildVersion"])))
        Model (SMBIOS): \(sh("/usr/sbin/sysctl", ["-n", "hw.model"]))
        CPU: \(sh("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]))
        OpenCore: \(oc.split(separator: "\t").last.map(String.init) ?? "bilinmiyor")
        boot-args: \(ba.split(separator: "\t").last.map(String.init) ?? "(yok)")
        Rapor zamanı: \(ISO8601DateFormatter().string(from: Date()))
        """
        sections.append(("Sistem", text))
    }

    private var methods: [String]?
    private var caps: Int?
    private var kextProps: [String: Any] = [:]
    private var kextPresent = false

    private func kext() {
        progress("KBCD cihazı ve KBColor.kext…")
        var lines: [String] = []
        let kbcd = Diagnostics.service(IOServiceNameMatching("KBCD0001"))
        if kbcd == 0 {
            lines.append("\\_SB.KBCD (KBCD0001): YOK")
            add(.fail, "KBCD cihazı yok: SSDT-KBLT yüklenmemiş. config.plist → ACPI → Add içinde SSDT-KBLT.aml var mı ve Enabled mı, dosya EFI/OC/ACPI içinde mi? Açılış günlüğündeki ACPI hatalarına da bakın.")
        } else {
            let p = Diagnostics.props(kbcd)
            lines.append("\\_SB.KBCD (KBCD0001): var, _STA = \(p["_STA"].map { Diagnostics.describe($0) } ?? "?")")
            IOObjectRelease(kbcd)
        }

        let svc = Diagnostics.service(IOServiceMatching("KBColor"))
        kextPresent = svc != 0
        let loaded = sh("/usr/bin/kmutil", ["showloaded", "--list-only", "--bundle-identifier", "com.atlntq.KBColor"])
            .split(separator: "\n").filter { $0.contains("com.atlntq") }.joined(separator: "\n")
        lines.append("kmutil: " + (loaded.isEmpty ? "com.atlntq.KBColor yüklü değil" : loaded))

        if svc != 0 {
            defer { IOObjectRelease(svc) }
            _ = IORegistryEntrySetCFProperties(svc, ["Refresh": NSNumber(value: 1)] as CFDictionary)
            kextProps = Diagnostics.props(svc)
            methods = kextProps["Methods"] as? [String]
            caps = (kextProps["Capabilities"] as? NSNumber)?.intValue
            let ver = kextProps["Version"] as? String ?? loaded.components(separatedBy: "(").dropFirst().first?.components(separatedBy: ")").first ?? "?"
            add(.ok, "KBColor.kext \(ver) yüklü ve KBCD'ye bağlı.")
            lines.append("")
            lines.append("KBColor özellikleri:")
            let skip: Set<String> = ["IOGeneralInterest", "IOUserClientClass", "IOPowerManagement"]
            for k in kextProps.keys.sorted() where !skip.contains(k) {
                lines.append("  \(k) = \(Diagnostics.describe(kextProps[k]!))")
            }
            let (c, inferred) = Diagnostics.capabilities(kextProps)
            let names = Diagnostics.capNames.filter { c & $0.0 != 0 }.map { $0.1 }
            lines.append("  → yetenekler\(inferred ? " (GCAP yok, çıkarım)" : ""): " + (names.isEmpty ? "yok" : names.joined(separator: ", ")))
            if inferred {
                add(.warn, "SSDT'lerde GCAP yok (eski paket). Menü yetenekleri tahminle kuruluyor; KBColor Kurulum ile SSDT'leri yeniden üretmeniz önerilir.")
            }
        } else if kbcd != 0 {
            add(.fail, "KBCD cihazı var ama KBColor.kext ona bağlanmamış. config.plist → Kernel → Add içinde KBColor.kext Enabled mı, BundlePath \"KBColor.kext\", ExecutablePath \"Contents/MacOS/KBColor\" mı?")
        } else if loaded.isEmpty {
            add(.warn, "KBColor.kext de yüklü değil (Kernel → Add girdisini kontrol edin).")
        }
        sections.append(("KBCD ve KBColor.kext", lines.joined(separator: "\n")))
        interpretKext()
    }

    private func interpretKext() {
        guard kextPresent else { return }
        if let caps, caps & 0x0100_0000 != 0 {
            add(.info, "Keşif sondası (SSDT-KBCP) yüklü: keşif modundasınız. Keşif bitince son paketteki SSDT'lerle değiştirin.")
            return
        }
        let has = { (m: String) -> Bool? in self.methods.map { $0.contains(m) } }
        if methods == nil {
            add(.warn, "Eski bir KBColor.kext sürümü (metot listesi yayınlamıyor). Daha ayrıntılı bilgi için 2.1.0 veya sonrasına güncelleyin; aşağıdaki çıkarımlar yayınlanan değerlere dayanıyor.")
        }
        let light = has("SCLR") ?? (kextProps["Color"] != nil || kextProps["Effect"] != nil)
        if light {
            add(.ok, "Klavye ışığı metotları çalışıyor (SSDT-KBLT yüklü)" + (kextProps["Color"].map { " · renk " + Diagnostics.describe($0) } ?? "") + ".")
        } else {
            add(.fail, "Klavye ışığı metotları (SCLR) yok: SSDT-KBLT eksik ya da farklı bir SSDT KBCD'yi tanımlıyor.")
        }
        let fanExpected = (caps.map { $0 & 0x020 != 0 }) ?? true
        let fan = has("GFAN") ?? (kextProps["FanMode"] != nil)
        if fan {
            if kextProps["FanMode"] == nil {
                add(.warn, "Fan metotları var ama mod okunamadı (EC hazır değil ya da GFAN hata veriyor).")
            } else {
                add(.ok, "Fan metotları çalışıyor (SSDT-FANM yüklü) · mod \(Diagnostics.describe(kextProps["FanMode"]!))"
                    + (kextProps["CPUFanRPM"].map { " · CPU fanı \(Diagnostics.describe($0)) RPM" } ?? "") + ".")
            }
        } else if fanExpected {
            add(.fail, "Fan metotları (GFAN/SFAN) yok: SSDT-FANM yüklenmemiş. En sık iki sebep: fan tuşu rename'i (_Qxx → XQxx) config.plist → ACPI → Patch içinde yok ya da kapalı (o zaman SSDT-FANM firmware'deki _Qxx'i ikinci kez tanımlar ve tablo reddedilir), veya ACPI → Add içinde SSDT-FANM, SSDT-KBLT'den önce.")
        }
    }

    // The kernel writes every ACPI message in fragments, each line twice.
    // Joins them back into whole messages.
    static func acpiMessages(_ raw: String) -> [String] {
        var msgs: [String] = []
        var cur = ""
        var last = ""
        for line in raw.split(separator: "\n").map(String.init) {
            guard let r = line.range(of: "(AppleACPIPlatform) ") else { continue }
            let frag = String(line[r.upperBound...]).replacingOccurrences(of: "\\134", with: "\\")
            if frag == last { continue }  // duplicate copy
            last = frag
            let t = frag.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ACPI Error:") || t.hasPrefix("ACPI Exception:") || t.hasPrefix("ACPI Warning:") || t.hasPrefix("ACPI:") {
                if !cur.isEmpty { msgs.append(cur) }
                cur = t
            } else if t.hasPrefix("(") && t.contains("/") && t.hasSuffix(")") {
                // ACPICA source location, e.g. (20160930/dswload-462): ends a message
                if !cur.isEmpty { msgs.append(cur); cur = "" }
            } else {
                cur += cur.isEmpty ? t : " " + t
            }
        }
        if !cur.isEmpty { msgs.append(cur) }
        return msgs
    }

    static let ownTables = ["KBLT", "FANM", "KBCP"]

    private func bootLog() {
        progress("Açılış günlüğü okunuyor (yaklaşık yarım dakika)…")
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        let boot = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // ACPI tables load a few seconds before kern.boottime is final.
        let raw = injectedLog ?? sh("/usr/bin/log", ["show", "--start", f.string(from: boot.addingTimeInterval(-120)),
                                      "--end", f.string(from: boot.addingTimeInterval(240)), "--style", "compact",
                                      "--predicate", #"sender == "AppleACPIPlatform" OR (process == "kernel" AND eventMessage CONTAINS "KBColor:")"#],
                     timeout: 120)
        let msgs = Diagnostics.acpiMessages(raw)
        var own = raw.split(separator: "\n").map(String.init).filter { $0.contains("KBColor:") }
        own = own.enumerated().filter { $0.offset == 0 || $0.element != own[$0.offset - 1] }.map { $0.element }
        let problems = msgs.filter { $0.contains("Error") || $0.contains("Exception") || $0.contains("Warning") }

        // Table load failures: "(SSDT:FANM) while loading table", with the
        // names reported just before it.
        var failed: [(table: String, names: [String])] = []
        var names: [String] = []
        let nameRx = try! NSRegularExpression(pattern: #"\[([\\^A-Za-z0-9_.]+)\]"#)
        let tableRx = try! NSRegularExpression(pattern: #"\((?:SSDT|DSDT):\s*([A-Za-z0-9_\-]+)\s*\) while loading table"#)
        for m in problems {
            let ns = m as NSString
            if let t = tableRx.firstMatch(in: m, range: NSRange(location: 0, length: ns.length)) {
                failed.append((ns.substring(with: t.range(at: 1)), names))
                names = []
            } else {
                for n in nameRx.matches(in: m, range: NSRange(location: 0, length: ns.length)) {
                    let v = ns.substring(with: n.range(at: 1))
                    if !names.contains(v) { names.append(v) }
                }
            }
        }

        var body = "Açılış: \(ISO8601DateFormatter().string(from: boot)), \(msgs.count) ACPI mesajı\n"
        body += "\nHatalar ve uyarılar (\(problems.count)):\n" + (problems.isEmpty ? "  (yok)" : problems.map { "  " + $0 }.joined(separator: "\n"))
        body += "\n\nYüklenemeyen tablolar: " + (failed.isEmpty ? "yok" : failed.map { "\($0.table)" + ($0.names.isEmpty ? "" : " [\($0.names.joined(separator: ", "))]") }.joined(separator: "; "))
        if let summary = msgs.first(where: { $0.contains("table load failures") || $0.contains("successful") }) { body += "\n" + summary }
        body += "\n\nKBColor.kext satırları:\n" + (own.isEmpty ? "  (yok; 2.1.0 öncesi kext log yazmaz)" : own.map { "  " + $0 }.joined(separator: "\n"))
        sections.append(("Açılış günlüğü (ACPI)", body))

        for t in failed where Diagnostics.ownTables.contains(where: { t.table.uppercased().contains($0) }) {
            let n = t.names.joined(separator: ", ")
            var hint = "Tablo hiç yüklenmedi."
            if t.names.contains(where: { $0.contains("_Q") }) {
                hint = "\(n) firmware'de zaten var: fan tuşu rename'i (_Qxx → XQxx) eksik ya da kapalı."
            } else if t.names.contains(where: { $0.contains("KBCD") }) {
                hint = "\(n) iki kez tanımlanıyor: KBCD'yi tanımlayan iki SSDT var (ör. eski KBColor SSDT'si ya da keşif sondası SSDT-KBCP ile SSDT-KBLT birlikte)."
            } else if !n.isEmpty {
                hint = "Sorunlu adlar: \(n)."
            }
            add(.fail, "SSDT-\(t.table) açılışta yüklenemedi. \(hint)")
        }
        let others = failed.filter { t in !Diagnostics.ownTables.contains(where: { t.table.uppercased().contains($0) }) }
        if !others.isEmpty {
            add(.info, "Başka tablolar da yüklenemedi (\(others.map { $0.table }.joined(separator: ", "))). Bunlar KBColor'ın tabloları değil; çoğu hackintosh'ta firmware tablolarında görülür ve genelde zararsızdır.")
        }
        if problems.contains(where: { $0.contains("Could not resolve") && ($0.contains("KBCD") || $0.contains("XQ")) }) {
            add(.fail, "Açılışta çözülemeyen ad var (KBCD ya da XQxx): SSDT-FANM, SSDT-KBLT'den önce yükleniyor ya da rename uygulanmamış.")
        }
        if let miss = own.first(where: { $0.contains("methods missing:") }),
           let list = miss.components(separatedBy: "methods missing:").last?.trimmingCharacters(in: .whitespaces), !list.isEmpty {
            add(.info, "Kext'in bildirdiği eksik metotlar: \(list)")
        }
        for l in own where l.contains("failed:") || l.contains(") returned") {
            add(.warn, "Kext çağrısı hata verdi: " + (l.components(separatedBy: "KBColor:").last ?? l).trimmingCharacters(in: .whitespaces))
        }
        if raw.isEmpty || msgs.isEmpty {
            add(.info, "Açılış günlüğünden ACPI mesajı okunamadı (günlük temizlenmiş ya da çok eski olabilir).")
        }
    }

    private func configCheck(_ url: URL) {
        progress("config.plist kontrol ediliyor…")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            add(.warn, "config.plist okunamadı: \(url.path)")
            return
        }
        let ocDir = url.deletingLastPathComponent()
        let before = findings.count
        var lines = ["Dosya: \(url.path)"]
        let acpi = root["ACPI"] as? [String: Any] ?? [:]
        let adds = acpi["Add"] as? [[String: Any]] ?? []
        func enabled(_ d: [String: Any]) -> Bool { d["Enabled"] as? Bool ?? false }
        lines.append("ACPI → Add (KBColor ile ilgili olanlar, sırasıyla):")
        var kblt: Int?, fanm: Int?, kbcp: Int?
        for (i, a) in adds.enumerated() {
            let path = a["Path"] as? String ?? ""
            guard ["KBLT", "FANM", "KBCP"].contains(where: { path.uppercased().contains($0) }) else { continue }
            let exists = FileManager.default.fileExists(atPath: ocDir.appendingPathComponent("ACPI").appendingPathComponent(path).path)
            lines.append("  [\(i)] \(path)  Enabled=\(enabled(a))  dosya \(exists ? "var" : "YOK")")
            if path.uppercased().contains("KBLT") && enabled(a) { kblt = i }
            if path.uppercased().contains("FANM") && enabled(a) { fanm = i }
            if path.uppercased().contains("KBCP") && enabled(a) { kbcp = i }
            if enabled(a) && !exists { add(.fail, "config.plist'te \(path) etkin ama EFI/OC/ACPI içinde dosya yok.") }
        }
        if kblt == nil && kbcp == nil { add(.fail, "config.plist → ACPI → Add içinde etkin bir SSDT-KBLT yok.") }
        if let k = kblt, let f = fanm, f < k { add(.fail, "config.plist'te SSDT-FANM (\(f)), SSDT-KBLT'den (\(k)) önce: sırayı değiştirin, KBLT önce gelmeli.") }
        if kbcp != nil && kblt != nil { add(.fail, "Keşif sondası SSDT-KBCP ile SSDT-KBLT aynı anda etkin: aynı cihazı iki kez tanımlarlar. Sondayı kaldırın.") }

        let patches = acpi["Patch"] as? [[String: Any]] ?? []
        lines.append("ACPI → Patch (_Qxx rename'leri):")
        var renames: [String] = []
        for (i, p) in patches.enumerated() {
            guard let find = p["Find"] as? Data, let rep = p["Replace"] as? Data,
                  let r = find.range(of: Data("_Q".utf8)), r.lowerBound + 4 <= find.count else { continue }
            let name = String(decoding: find[r.lowerBound..<(r.lowerBound + 4)], as: UTF8.self)
            let newName = rep.count >= r.lowerBound + 4 ? String(decoding: rep[r.lowerBound..<(r.lowerBound + 4)], as: UTF8.self) : "?"
            let sig = (p["TableSignature"] as? Data).map { String(decoding: $0, as: UTF8.self) } ?? ""
            lines.append("  [\(i)] \(name) → \(newName)  Enabled=\(enabled(p))  Find=\(find.map { String(format: "%02X", $0) }.joined())  Count=\(p["Count"] ?? 0)  Table=\(sig.isEmpty ? "(hepsi)" : sig)  \(p["Comment"] as? String ?? "")")
            if enabled(p) { renames.append(newName) }
        }
        if fanm != nil && renames.isEmpty {
            add(.fail, "SSDT-FANM etkin ama config.plist'te etkin bir _Qxx → XQxx rename'i yok. Kurulum paketindeki config-ekle.plist'ten ACPI → Patch girdisini ekleyin.")
        }

        let kexts = (root["Kernel"] as? [String: Any])?["Add"] as? [[String: Any]] ?? []
        lines.append("Kernel → Add:")
        var kextOK = false
        for (i, k) in kexts.enumerated() where (k["BundlePath"] as? String ?? "").contains("KBColor") {
            let bp = k["BundlePath"] as? String ?? ""
            let exists = FileManager.default.fileExists(atPath: ocDir.appendingPathComponent("Kexts").appendingPathComponent(bp).path)
            lines.append("  [\(i)] \(bp)  Enabled=\(enabled(k))  ExecutablePath=\(k["ExecutablePath"] ?? "")  dosya \(exists ? "var" : "YOK")")
            if enabled(k) { kextOK = true }
            if enabled(k) && !exists { add(.fail, "config.plist'te \(bp) etkin ama EFI/OC/Kexts içinde yok.") }
        }
        if !kextOK { add(.fail, "config.plist → Kernel → Add içinde etkin bir KBColor.kext girdisi yok.") }
        if findings[before...].allSatisfy({ $0.level != .fail }) {
            add(.ok, "config.plist'teki KBColor girdileri (sıra, rename, kext) doğru görünüyor.")
        }
        sections.append(("config.plist", lines.joined(separator: "\n")))
    }

    // MARK: run

    func run() -> String {
        system()
        kext()
        if let config { configCheck(config) }
        bootLog()
        if findings.allSatisfy({ $0.level == .ok || $0.level == .info }) {
            add(.ok, "Belirgin bir sorun bulunamadı. Sorun sürüyorsa bu raporu ve ne olduğunu (ne yaptınız, ne oldu) forum konusuna yazın.")
        }
        progress("Rapor hazır.")
        var out = "KBColor tanılama raporu\n=======================\n\n== Özet ==\n"
        let order: [DiagFinding.Level] = [.fail, .warn, .info, .ok]
        for l in order { for f in findings where f.level == l { out += "\(f.level.rawValue) \(f.text)\n" } }
        for (title, body) in sections { out += "\n== \(title) ==\n\(body)\n" }
        out += "\nForum konusu: \(Diagnostics.forumURL.absoluteString)\n"
        return out
    }

    // Tests only: runs the boot log analysis on `injectedLog`.
    func analyzeLogForTest() -> [DiagFinding] {
        bootLog()
        return findings
    }

    // KBCD.GCAP bits for a kext that does not publish "Capabilities": the
    // hand-made 2.0 Acer package and the ASUS 1.x kext have no GCAP. Taken
    // from "Methods" (kext 2.1+) or else from the values the kext publishes.
    static func capabilities(_ p: [String: Any]) -> (caps: Int, inferred: Bool) {
        if let c = (p["Capabilities"] as? NSNumber)?.intValue { return (c, false) }
        var c = 0
        if let m = p["Methods"] as? [String] {
            if m.contains("SCLR") { c |= 0x001 }
            if m.contains("SZCL") { c |= 0x002 }
            if m.contains("SEFF") { c |= 0x004 }
            if m.contains("SBRT") { c |= 0x008 } else if m.contains("SCLR") { c |= 0x010 }
            if m.contains("SFAN") { c |= 0x020 | (m.contains("SPCT") ? 0x080 : 0x040) }
            if m.contains("GRPM") { c |= 0x100 }
        } else {
            let effects = p["Effect"] != nil || p["Brightness"] != nil   // Acer-style SSDT
            if p["Color"] != nil || effects { c |= 0x001 }
            if effects { c |= 0x002 | 0x004 | 0x008 } else if p["Color"] != nil { c |= 0x010 }
            if p["FanMode"] != nil { c |= 0x020 | (p["FanSpeed"] != nil || effects ? 0x080 : 0x040) }
            if p["CPUFanRPM"] != nil { c |= 0x100 }
        }
        // Nothing about the light published yet (the ASUS 1.x kext only shows
        // "Color" after a change): offer a single colour with system brightness.
        if c & 0x00F == 0 && c & 0x010 == 0 { c |= 0x001 | 0x010 }
        if c & 0x020 != 0 { c |= 0x200 }
        return (c, true)
    }

    // Writes the report to the Desktop and returns its URL.
    static func save(_ text: String) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("KBColor-tani-\(f.string(from: Date())).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
