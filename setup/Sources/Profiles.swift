// Vendor profiles. Each one looks for the firmware interface it knows in the
// parsed namespace, records every check it made (shown in the app and the
// README), and fills its SSDT templates with the paths it found.

import Foundation

// KBCD.GCAP bits, the same as in KBColor.app.
enum Cap {
    static let color = 0x001, zones = 0x002, effects = 0x004, brightKext = 0x008, brightSys = 0x010
    static let fan = 0x020, fanSilent = 0x040, fanCustom = 0x080, rpm = 0x100, fanKey = 0x200
    static let keyFnF5 = 0x01_0000, keyTurbo = 0x02_0000
}

struct Check {
    enum Level { case ok, warn, fail }
    var level: Level
    var text: String
}

// A method to rename in the firmware so the SSDT can replace it.
struct Rename {
    var method: ACPIPath   // the original, e.g. \_SB_.PCI0.LPCB.EC__._Q58
    var newName: String    // e.g. XQ58
    var reason: String
}

struct GeneratedTable { var name: String; var dsl: String }

// One acpiexec call and what it must do.
struct TestCall { var command: String; var expectNoError = true }

struct Result {
    var vendor: String
    var features: [String]          // human readable, for the README
    var caps: Int
    var checks: [Check]
    var tables: [GeneratedTable]    // in load order
    var renames: [Rename]
    var tests: [TestCall]
    var extraKexts: [String]        // kexts the user needs besides KBColor
    var hardwareNotes: [String]     // things only real hardware can confirm
    var discovery: [ProbeRegion]? = nil   // set when offsets must be found with Windows
}

protocol Profile {
    var name: String { get }
    // nil if the dump does not look like this vendor at all.
    func analyze(_ ns: Namespace, offsets: KeyboardOffsets?, forceDiscovery: Bool) -> Result?
}

let allProfiles: [Profile] = [AcerPredatorProfile(), AsusTUFProfile()]

func fill(_ template: String, _ values: [String: String]) -> String {
    var s = template
    for (k, v) in values { s = s.replacingOccurrences(of: "{{\(k)}}", with: v) }
    return s
}

func hex(_ v: Int) -> String { String(format: "0x%08X", v) }

// MARK: - Acer Predator / Nitro (PredatorSense WMI: WMID.WMBH)

struct AcerPredatorProfile: Profile {
    let name = "Acer Predator / Nitro"

    func analyze(_ ns: Namespace, offsets: KeyboardOffsets?, forceDiscovery: Bool) -> Result? {
        guard let wmbh = ns.methods(named: "WMBH").first(where: {
            $0.body.contains("LEqual (Arg1, 0x06)") && $0.body.contains("LEqual (Arg1, 0x14)") && $0.body.contains("KB1R")
        }) else { return nil }

        var checks = [Check(level: .ok, text: "PredatorSense WMI metodu: \(wmbh.path.short) (oyun ışığı çağrıları 0x06 ve 0x14 var)")]
        let lightNames = ["KBLE", "KBLS", "KBBP", "KBCS", "KBED", "KBCR", "KBCG", "KBCB"]
        guard let kble = ns.fields(named: "KBLE").first else {
            checks.append(Check(level: .fail, text: "EC alanı KBLE bulunamadı"))
            return Result(vendor: name, features: [], caps: 0, checks: checks, tables: [], renames: [], tests: [], extraKexts: [], hardwareNotes: [])
        }
        let ec = kble.path.parent
        let missing = lightNames.filter { ns.field($0, in: ec) == nil }
        if !missing.isEmpty {
            checks.append(Check(level: .fail, text: "\(ec.short) içinde eksik ışık alanları: \(missing.joined(separator: ", "))"))
            return Result(vendor: name, features: [], caps: 0, checks: checks, tables: [], renames: [], tests: [], extraKexts: [], hardwareNotes: [])
        }
        checks.append(Check(level: .ok, text: "Klavye ışığı alanları \(ec.short) içinde: \(lightNames.joined(separator: ", "))"))

        var zones = 0
        while zones < 4, ["R", "G", "B"].allSatisfy({ ns.field("KB\(zones + 1)\($0)", in: ec) != nil }) { zones += 1 }
        checks.append(Check(level: zones == 4 ? .ok : .warn, text: "Bölge renk alanları: \(zones) bölge (KB1R…KB\(zones)B)"))

        var caps = Cap.color | Cap.effects | Cap.brightKext | (zones == 4 ? Cap.zones : 0)
        var features = ["Klavye rengi" + (zones == 4 ? " (tüm klavye veya 4 bölge)" : ""),
                        "Efektler: Sabit, Nefes, Neon, Dalga, Kayma, Zoom; hız ve yön",
                        "Parlaklık %0-100"]
        var tables: [GeneratedTable] = []
        var renames: [Rename] = []
        var tests = [TestCall(command: "execute \\_SB.KBCD.GCAP"),
                     TestCall(command: "execute \\_SB.KBCD.GLGT"),
                     TestCall(command: "execute \\_SB.KBCD.SCLR 0xFF0000"),
                     TestCall(command: "execute \\_SB.KBCD.SEFF 0x020503"),
                     TestCall(command: "execute \\_SB.KBCD.SBRT 0x32")]
        if zones == 4 { tests.append(TestCall(command: "execute \\_SB.KBCD.SZCL 0x020000FF")) }
        var notes = ["Dalga efektinde 4. bayt (KBCS) 8 olarak gönderiliyor (PredatorSense'teki gibi). Dalga çalışmazsa SSDT-KBLT'de 0 yapılıp denenmeli."]

        // Fans
        let hasFanBehavior = wmbh.body.contains("Case (0x0E)")
        let hasCustom = wmbh.body.contains("LEqual (Arg1, 0x10)") && ns.field("CPUF", in: ec) != nil && ns.field("GPUF", in: ec) != nil
        let hasLED = wmbh.body.contains("Case (0x02)")
        let rpm = ns.field("C1FR", in: ec) != nil && ns.field("G1FR", in: ec) != nil
        var fanKeyQ: MethodInfo?
        if hasFanBehavior && hasCustom {
            caps |= Cap.fan | Cap.fanCustom
            features.append("Fan modu: Normal / Turbo / Özel %")
            checks.append(Check(level: .ok, text: "Fan davranışı (WMBH 0x0E) ve özel fan hızı (WMBH 0x10 → \(ec.short).CPUF/GPUF) var"))
            notes.append("Fan modu (WMBH 0x0E) ve Turbo LED'i (WMBH 0x02) BIOS'un SMI işleyicisinden geçiyor, simülasyonda denenemez. Değerler Linux acer-wmi ile aynı (0x410009 / 0x820009 / 0xC30009). Turbo seçince fanlar hızlanmıyorsa ilk bakılacak yer burası.")
            if rpm {
                caps |= Cap.rpm
                features.append("CPU/GPU fan devri (RPM)")
                checks.append(Check(level: .ok, text: "Fan devri alanları: \(ec.short).C1FR / G1FR"))
            } else {
                checks.append(Check(level: .warn, text: "Fan devri alanları (C1FR/G1FR) yok: RPM gösterilmeyecek"))
            }
            let rx = try! NSRegularExpression(pattern: #"Store \(0x07, Index \([\^\\\w.]*FEBC, Zero\)\)[\s\S]*Store \(0x04, Index \([\^\\\w.]*FEBC, One\)\)"#)
            fanKeyQ = ns.methods.values.filter { $0.path.parent == ec && $0.path.last.hasPrefix("_Q") }
                .first { rx.firstMatch(in: $0.body, range: NSRange(location: 0, length: ($0.body as NSString).length)) != nil }
            if let q = fanKeyQ {
                caps |= Cap.fanKey | Cap.keyTurbo
                features.append("Turbo tuşu: Normal ↔ Turbo")
                checks.append(Check(level: .ok, text: "Turbo tuşu olayı: \(q.path.short) (PredatorSense'e 7/4 olayı gönderiyor)"))
                renames.append(Rename(method: q.path, newName: "X" + q.path.last.dropFirst(), reason: "Turbo tuşu (SSDT-FANM)"))
                notes.append("Turbo tuşu: EC bu tuşa kendisi de tepki veriyorsa iki kez geçiş yapabilir. Tuşa basınca ekranda Turbo görünüp fanlar hızlanmıyorsa bildir.")
            } else {
                checks.append(Check(level: .warn, text: "Turbo tuşu olayı bulunamadı: tuş macOS'ta çalışmayacak, menüden seçilebilir"))
            }
            tests += [TestCall(command: "execute \\_SB.KBCD.SFAN 1"), TestCall(command: "execute \\_SB.KBCD.GFAN"),
                      TestCall(command: "execute \\_SB.KBCD.SPCT 0x46")]
            if rpm { tests.append(TestCall(command: "execute \\_SB.KBCD.GRPM 0")) }
            if let q = fanKeyQ { tests.append(TestCall(command: "execute \(q.path.short)")) }
        } else {
            checks.append(Check(level: .warn, text: "Fan davranışı çağrıları (WMBH 0x0E / 0x10) bulunamadı: fan kontrolü olmayacak"))
        }

        tables.append(GeneratedTable(name: "SSDT-KBLT", dsl: acerKBLT(wmbh: wmbh.path, ec: ec, zones: zones, caps: caps)))
        if caps & Cap.fan != 0 {
            tables.append(GeneratedTable(name: "SSDT-FANM", dsl: acerFANM(wmbh: wmbh.path, ec: ec, rpm: rpm, led: hasLED, key: fanKeyQ?.path)))
        }
        return Result(vendor: name, features: features, caps: caps, checks: checks, tables: tables, renames: renames,
                      tests: tests, extraKexts: [], hardwareNotes: notes)
    }

    func acerKBLT(wmbh: ACPIPath, ec: ACPIPath, zones: Int, caps: Int) -> String {
        let e = ec.short
        var ext = ["KBLE", "KBLS", "KBBP", "KBED", "KBCR", "KBCG", "KBCB"]
        var reads = ""
        for z in 0..<zones {
            ext += ["KB\(z + 1)R", "KB\(z + 1)G", "KB\(z + 1)B"]
            reads += "            ZCLR [\(z)] = RGB (\(e).KB\(z + 1)R, \(e).KB\(z + 1)G, \(e).KB\(z + 1)B)\n"
        }
        let externals = ext.map { "    External (\(e).\($0), FieldUnitObj)" }.joined(separator: "\n")
        return fill(acerKBLTTemplate, ["WMBH": wmbh.short, "EC": e, "EXTERNALS": externals, "ZONE_READS": reads,
                                       "ZONES": String(zones), "CAPS": hex(caps)])
    }

    func acerFANM(wmbh: ACPIPath, ec: ACPIPath, rpm: Bool, led: Bool, key: ACPIPath?) -> String {
        let e = ec.short
        var ext = "    External (\(e), DeviceObj)\n"
        var keyBlock = "", rpmBlock = ""
        if let key {
            let x = "X" + key.last.dropFirst()
            ext += "    External (\(e).\(x), MethodObj)    // 0 Arguments\n"
            keyBlock = fill(acerKeyTemplate, ["EC": e, "Q": String(key.short.split(separator: ".").last!), "XQ": x])
        }
        if rpm {
            ext += "    External (\(e).C1FR, FieldUnitObj)\n    External (\(e).G1FR, FieldUnitObj)\n"
            rpmBlock = fill(acerRPMTemplate, ["EC": e])
        }
        let ledBlock = led ? fill(acerLEDTemplate, ["WMBH": wmbh.short]) : ""
        return fill(acerFANMTemplate, ["WMBH": wmbh.short, "EXTERNALS": ext, "KEY": keyBlock, "RPM": rpmBlock, "LED": ledBlock])
    }
}

// MARK: - ASUS TUF (FX506 family EC layout)

struct AsusTUFProfile: Profile {
    let name = "ASUS TUF (FX506 ailesi)"

    func analyze(_ ns: Namespace, offsets known: KeyboardOffsets?, forceDiscovery: Bool) -> Result? {
        guard let atkd = ns.devices.first(where: { $0.last == "ATKD" }) else { return nil }
        var checks = [Check(level: .ok, text: "ASUS ATK cihazı: \(atkd.short)")]
        func failed() -> Result {
            Result(vendor: name, features: [], caps: 0, checks: checks, tables: [], renames: [], tests: [], extraKexts: [], hardwareNotes: [])
        }

        if ns.methods[atkd.child("SKBV")] != nil {
            checks.append(Check(level: .fail, text: "\(atkd.short).SKBV dökümde zaten tanımlı. Bu DSDT yamalanmış görünüyor (önceden eklenmiş SKBV); OpenCore SysReport ile alınmış yamasız döküm kullan."))
            return failed()
        }
        // The colour bytes are not named in the DSDT. On the FX506 family they
        // were found by comparing EC snapshots (KBLT at block +0x24, colour at
        // +0x2B); other models go through discovery with Windows.
        let kblt = ns.fields(named: "KBLT").first { ns.regions[$0.region]?.space == "SystemMemory" }
        let ec = kblt?.path.parent ?? ns.devices.filter { ["EC__", "EC0_", "H_EC"].contains($0.last) }
            .sorted { $0.description < $1.description }.first
        guard let ec else {
            checks.append(Check(level: .fail, text: "Gömülü denetleyici (EC) cihazı bulunamadı"))
            return failed()
        }
        var offsets = known
        if offsets == nil, !forceDiscovery, let kblt, let base = ns.regions[kblt.region]?.base,
           kblt.bitOffset == 0x24 * 8, let kbsc = ns.field("KBSC", in: ec), kbsc.region == kblt.region, kbsc.bitOffset == 0x28 * 8 {
            offsets = KeyboardOffsets(colorAddr: base + 0x2B, levelAddr: base + 0x24, maxLevel: 3)
            checks.append(Check(level: .ok, text: "Klavye bloğu \(kblt.region.short) (SystemMemory 0x\(String(base, radix: 16, uppercase: true))): KBLT +0x24, KBSC +0x28, FX506 düzeni"))
            checks.append(Check(level: .warn, text: String(format: "Statik renk adresi 0x%llX (bölge +0x2B): FX506LU'da doğrulanmış ofset", base + 0x2B)))
        } else if let o = known {
            checks.append(Check(level: .ok, text: String(format: "Keşifle doğrulanan adresler: renk 0x%llX, seviye 0x%llX (0…%d)", o.colorAddr, o.levelAddr, o.maxLevel)))
        }
        guard let offsets else {
            let regions = ns.regions.values.filter {
                $0.space == "SystemMemory" && $0.path.parent == ec && ($0.length ?? 0) >= 0x20 && ($0.length ?? 0) <= 0x400 && $0.base != nil
            }.sorted { $0.base! < $1.base! }.prefix(4).map {
                ProbeRegion(path: $0.path.short, base: $0.base!, length: Int($0.length!))
            }
            guard !regions.isEmpty else {
                checks.append(Check(level: .fail, text: "\(ec.short) içinde bellek eşlemeli EC bölgesi yok; keşif yapılamaz"))
                return failed()
            }
            checks.append(Check(level: .warn, text: "Klavye renk/seviye adresleri bu modelin dökümünde yok: Windows yardımıyla keşif gerekli (" + regions.map { "\($0.path) \($0.length) bayt" }.joined(separator: ", ") + ")"))
            var r = failed()
            r.discovery = Array(regions)
            return r
        }
        var caps = Cap.color | Cap.brightSys
        var features = ["Klavye rengi (tek bölge)", "Parlaklık: sistem kaydırıcısı ve Fn+↑/↓ (AsusSMC üzerinden)"]
        var tests = [TestCall(command: "execute \\_SB.KBCD.GCAP"),
                     TestCall(command: "execute \\_SB.KBCD.SCLR 0xFF0000"),
                     TestCall(command: "execute \(atkd.short).SKBV 0x80"),
                     TestCall(command: "execute \\_SB.KBCD.GCLR")]
        var tables = [GeneratedTable(name: "SSDT-KBLT", dsl: "")]
        var renames: [Rename] = []
        var notes = [known != nil ? "Adresler bu bilgisayarda Windows yardımıyla bulunup canlı test edildi." :
                     String(format: "Renk adresi (0x%llX) FX506LU'da EC karşılaştırmasıyla bulundu. Renk değişmiyorsa kurulum yardımcısında \"Windows ile keşfet\" seçeneğiyle adresleri bu bilgisayarda bul.", offsets.colorAddr)]

        let need = ["FNGM", "FRMS", "FRS2"].filter { ns.field($0, in: ec) == nil }
        let hasOK = ns.names.contains(ec.child("ECOK")), hasMutex = ns.mutexes.contains(ec.child("MUT0"))
        if need.isEmpty && hasOK && hasMutex {
            caps |= Cap.fan | Cap.fanSilent | Cap.rpm
            features += ["Fan modu: Sessiz / Normal / Turbo", "CPU/GPU fan devri (RPM)"]
            checks.append(Check(level: .ok, text: "Fan modu ve devri: \(ec.short).FNGM, FRMS, FRS2 (ECOK, MUT0 ile)"))
            if let q = ns.methods.values.first(where: { $0.path.parent == ec && $0.path.last.hasPrefix("_Q") && $0.body.contains("ATKD.IANE (0xAE)") }) {
                caps |= Cap.fanKey | Cap.keyFnF5
                features.append("Fn+F5: Normal → Turbo → Sessiz")
                checks.append(Check(level: .ok, text: "Fn+F5 olayı: \(q.path.short) (ATKD olay 0xAE)"))
                renames.append(Rename(method: q.path, newName: "X" + q.path.last.dropFirst(), reason: "Fn+F5 fan tuşu (SSDT-FANM)"))
                tests.append(TestCall(command: "execute \(q.path.short)"))
            } else {
                checks.append(Check(level: .warn, text: "Fn+F5 olayı (ATKD.IANE 0xAE) bulunamadı: fan modu yalnızca menüden"))
            }
            tests += [TestCall(command: "execute \\_SB.KBCD.GFAN"), TestCall(command: "execute \\_SB.KBCD.GRPM 0")]
            tables.append(GeneratedTable(name: "SSDT-FANM", dsl: asusFANM(ec: ec, key: renames.first?.method)))
        } else {
            let missing = need + (hasOK ? [] : ["ECOK"]) + (hasMutex ? [] : ["MUT0"])
            checks.append(Check(level: .warn, text: "Fan alanları eksik (\(missing.joined(separator: ", "))): fan kontrolü olmayacak"))
        }
        tables[0].dsl = fill(asusKBLTTemplate, ["ATKD": atkd.short,
                                                "ADDR": String(format: "0x%08llX", offsets.colorAddr),
                                                "LVLADDR": String(format: "0x%08llX", offsets.levelAddr),
                                                "MAXLVL": String(format: "0x%02X", offsets.maxLevel), "CAPS": hex(caps)])
        notes.append("Klavye parlaklığı AsusSMC.kext'in \(atkd.short).SKBV çağrısıyla çalışır; AsusSMC yüklü değilse parlaklık kaydırıcısı ve Fn+↑/↓ çalışmaz.")
        return Result(vendor: name, features: features, caps: caps, checks: checks, tables: tables, renames: renames,
                      tests: tests, extraKexts: ["AsusSMC.kext (klavye parlaklığı için, Lilu'dan sonra)"], hardwareNotes: notes)
    }

    func asusFANM(ec: ACPIPath, key: ACPIPath?) -> String {
        let e = ec.short
        var ext = "", keyBlock = ""
        if let key {
            let x = "X" + key.last.dropFirst()
            ext = "    External (\(e).\(x), MethodObj)    // 0 Arguments\n"
            keyBlock = fill(asusKeyTemplate, ["EC": e, "Q": String(key.short.split(separator: ".").last!), "XQ": x])
        }
        return fill(asusFANMTemplate, ["EC": e, "EXTERNALS": ext, "KEY": keyBlock])
    }
}

// MARK: - Templates

let acerKBLTTemplate = #"""
/*
 * SSDT-KBLT: RGB keyboard through PredatorSense WMI ({{WMBH}}).
 * Generated by the KBColor setup assistant.
 *
 *   WMBH (0, 0x06, {zone, R, G, B})   static colour of one zone (bit 1/2/4/8)
 *   WMBH (0, 0x14, {mode, speed, brightness, KBCS, direction, R, G, B})
 *       mode 0 static, 1 breathing, 2 neon, 3 wave, 4 shifting, 5 zoom
 *       speed 0..9, brightness 0..100, direction 1 = right to left, 2 = left to right
 *
 * The state is read once from the EC ({{EC}}) and then kept here.
 * \_SB.KBCD (KBCD0001) is matched by KBColor.kext. Load before SSDT-FANM.
 */
DefinitionBlock ("", "SSDT", 2, "KBCLR", "KBLT", 0x00003000)
{
    External ({{WMBH}}, MethodObj)    // 3 Arguments
{{EXTERNALS}}

    Device (\_SB.KBCD)
    {
        Name (_HID, "KBCD0001")

        Method (_STA, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (0x0F)
            }

            Return (Zero)
        }

        // Capabilities for KBColor.app
        Method (GCAP, 0, NotSerialized)
        {
            Return ({{CAPS}})
        }

        Name (LINI, Zero)
        Name (LMOD, Zero)
        Name (LSPD, 0x05)
        Name (LBRT, 0x64)
        Name (LDIR, One)
        Name (LCLR, 0x00FFFFFF)
        Name (ZCLR, Package (0x04)
        {
            0x00FFFFFF,
            0x00FFFFFF,
            0x00FFFFFF,
            0x00FFFFFF
        })

        Method (RGB, 3, NotSerialized)
        {
            Return ((((ToInteger (Arg0) & 0xFF) << 0x10) | (((ToInteger (Arg1) & 0xFF) << 0x08) | (ToInteger (Arg2) & 0xFF))))
        }

        Method (LRD, 0, Serialized)
        {
            If (LINI)
            {
                Return (Zero)
            }

            LMOD = {{EC}}.KBLE
            If ((LMOD > 0x05))
            {
                LMOD = Zero
            }

            LSPD = {{EC}}.KBLS
            If ((LSPD > 0x09))
            {
                LSPD = 0x05
            }

            LBRT = {{EC}}.KBBP
            If ((LBRT > 0x64))
            {
                LBRT = 0x64
            }

            LDIR = {{EC}}.KBED
            If (((LDIR == Zero) || (LDIR > 0x02)))
            {
                LDIR = One
            }

            LCLR = RGB ({{EC}}.KBCR, {{EC}}.KBCG, {{EC}}.KBCB)
{{ZONE_READS}}            LINI = One
            Return (Zero)
        }

        // Arg0: zone 0..3, Arg1: 0xRRGGBB
        Method (LZON, 2, Serialized)
        {
            Name (ZB, Buffer (0x04){})
            CreateByteField (ZB, Zero, ZN)
            CreateByteField (ZB, One, ZR)
            CreateByteField (ZB, 0x02, ZG)
            CreateByteField (ZB, 0x03, ZL)
            ZN = (One << ToInteger (Arg0))
            ZR = ((ToInteger (Arg1) >> 0x10) & 0xFF)
            ZG = ((ToInteger (Arg1) >> 0x08) & 0xFF)
            ZL = (ToInteger (Arg1) & 0xFF)
            {{WMBH}} (Zero, 0x06, ZB)
        }

        Method (LAPL, 0, Serialized)
        {
            Name (LB, Buffer (0x10){})
            CreateByteField (LB, Zero, BMOD)
            CreateByteField (LB, One, BSPD)
            CreateByteField (LB, 0x02, BBRT)
            CreateByteField (LB, 0x03, BKCS)
            CreateByteField (LB, 0x04, BDIR)
            CreateByteField (LB, 0x05, BRED)
            CreateByteField (LB, 0x06, BGRN)
            CreateByteField (LB, 0x07, BBLU)
            If ((LMOD == Zero))
            {
                Local0 = Zero
                While ((Local0 < {{ZONES}}))
                {
                    LZON (Local0, DerefOf (ZCLR [Local0]))
                    Local0++
                }

                BSPD = Zero
                BDIR = Zero
            }
            Else
            {
                BSPD = LSPD
                BDIR = LDIR
            }

            BMOD = LMOD
            BBRT = LBRT
            If ((LMOD == 0x03))
            {
                BKCS = 0x08
            }

            BRED = ((LCLR >> 0x10) & 0xFF)
            BGRN = ((LCLR >> 0x08) & 0xFF)
            BBLU = (LCLR & 0xFF)
            {{WMBH}} (Zero, 0x14, LB)
            Return (Zero)
        }

        // ---- called by KBColor.kext; all return 0 on success ----

        Method (SCLR, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            If ((Local0 > 0x00FFFFFF))
            {
                Return (One)
            }

            LRD ()
            LCLR = Local0
            ZCLR [Zero] = Local0
            ZCLR [One] = Local0
            ZCLR [0x02] = Local0
            ZCLR [0x03] = Local0
            Return (LAPL ())
        }

        // (zone << 24) | 0xRRGGBB, zone 1..4; switches to static
        Method (SZCL, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            Local1 = (Local0 >> 0x18)
            If (((Local1 < One) || (Local1 > {{ZONES}})))
            {
                Return (One)
            }

            LRD ()
            ZCLR [(Local1 - One)] = (Local0 & 0x00FFFFFF)
            LMOD = Zero
            Return (LAPL ())
        }

        // mode | (speed << 8) | (direction << 16)
        Method (SEFF, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            Local1 = (Local0 & 0xFF)
            Local2 = ((Local0 >> 0x08) & 0xFF)
            Local3 = ((Local0 >> 0x10) & 0xFF)
            If ((((Local1 > 0x05) || (Local2 > 0x09)) || ((Local3 < One) || (Local3 > 0x02))))
            {
                Return (One)
            }

            LRD ()
            LMOD = Local1
            LSPD = Local2
            LDIR = Local3
            Return (LAPL ())
        }

        Method (SBRT, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            If ((Local0 > 0x64))
            {
                Return (One)
            }

            LRD ()
            LBRT = Local0
            Return (LAPL ())
        }

        // mode | (speed << 8) | (direction << 16) | (brightness << 24)
        Method (GLGT, 0, Serialized)
        {
            LRD ()
            Return ((((LMOD | (LSPD << 0x08)) | (LDIR << 0x10)) | (LBRT << 0x18)))
        }

        Method (GCLR, 0, Serialized)
        {
            LRD ()
            Return (LCLR)
        }
    }
}
"""#

let acerFANMTemplate = #"""
/*
 * SSDT-FANM: fan mode through PredatorSense WMI ({{WMBH}}).
 * Generated by the KBColor setup assistant.
 *
 *   WMBH (0, 0x0E, value)          fan behaviour (BIOS SMI handler)
 *       bits 15..0 fans (CPU 0x1, GPU 0x8), bits 17..16 CPU mode,
 *       bits 23..22 GPU mode: 1 auto, 2 max, 3 custom
 *   WMBH (0, 0x10, {fan, percent})  custom speed, fan 1 = CPU, 4 = GPU
 *
 * The BIOS has no getter for the fan behaviour, so the last mode is kept in
 * FMOD (the EC starts in auto). Adds to \_SB.KBCD: load after SSDT-KBLT.
 */
DefinitionBlock ("", "SSDT", 2, "KBCLR", "FANM", 0x00003000)
{
    External (_SB_.KBCD, DeviceObj)
    External ({{WMBH}}, MethodObj)    // 3 Arguments
{{EXTERNALS}}
{{KEY}}
    Scope (\_SB.KBCD)
    {
        Name (FMOD, Zero)
        Name (FPCT, 0x3C)

        // 0 = Normal (auto), 1 = Turbo, 2 = Custom
        Method (GFAN, 0, NotSerialized)
        {
            Return (FMOD)
        }

        Method (GPCT, 0, NotSerialized)
        {
            Return (FPCT)
        }

        Method (FPWR, 2, Serialized)
        {
            Name (FB, Buffer (0x08){})
            CreateByteField (FB, Zero, FID)
            CreateByteField (FB, One, FPC)
            FID = Arg0
            FPC = Arg1
            {{WMBH}} (Zero, 0x10, FB)
        }

        Method (SFAN, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            If ((Local0 == Zero))
            {
                Local1 = 0x00410009
            }
            ElseIf ((Local0 == One))
            {
                Local1 = 0x00820009
            }
            ElseIf ((Local0 == 0x02))
            {
                Local1 = 0x00C30009
            }
            Else
            {
                Return (One)
            }

            {{WMBH}} (Zero, 0x0E, Local1)
            If ((Local0 == 0x02))
            {
                FPWR (One, FPCT)
                FPWR (0x04, FPCT)
            }
{{LED}}
            FMOD = Local0
            Return (Zero)
        }

        Method (SPCT, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            If ((Local0 > 0x64))
            {
                Return (One)
            }

            FPCT = Local0
            Return (SFAN (0x02))
        }
{{RPM}}    }
}
"""#

let acerLEDTemplate = #"""

            // Turbo key LED
            If ((Local0 == One))
            {
                {{WMBH}} (Zero, 0x02, 0x00010001)
            }
            Else
            {
                {{WMBH}} (Zero, 0x02, One)
            }

"""#

let acerRPMTemplate = #"""

        // Arg0: 0 = CPU fan, 1 = GPU fan. RPM, 0 if stopped.
        Method (GRPM, 1, Serialized)
        {
            If ((ToInteger (Arg0) == Zero))
            {
                Return ({{EC}}.C1FR)
            }

            Return ({{EC}}.G1FR)
        }

"""#

let acerKeyTemplate = #"""
    // Turbo key: needs the config.plist rename {{Q}} -> {{XQ}}
    Scope ({{EC}})
    {
        Method ({{Q}}, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                If ((\_SB.KBCD.GFAN () == One))
                {
                    \_SB.KBCD.SFAN (Zero)
                }
                Else
                {
                    \_SB.KBCD.SFAN (One)
                }

                Notify (\_SB.KBCD, 0x80)
            }
            Else
            {
                {{XQ}} ()
            }
        }
    }

"""#

let asusKBLTTemplate = #"""
/*
 * SSDT-KBLT: keyboard backlight for ASUS TUF (FX506 family EC layout).
 * Generated by the KBColor setup assistant.
 *
 * AsusSMC calls {{ATKD}}.SKBV(level) with level 0-255 for Fn+Up/Down and the
 * Control Center slider. EC RAM (found by comparing EC snapshots):
 *   {{LVLADDR}}   brightness level, 0 = off ... {{MAXLVL}} = max
 *   {{ADDR}}   static colour R, G, B
 * The EC has only a few levels, so in-between levels keep it at max and scale
 * the colour. \_SB.KBCD (KBCD0001) is matched by KBColor.kext.
 */
DefinitionBlock ("", "SSDT", 2, "KBCLR", "KBLT", 0x00003000)
{
    External ({{ATKD}}, DeviceObj)

    Scope ({{ATKD}})
    {
        OperationRegion (KBLR, SystemMemory, {{LVLADDR}}, One)
        Field (KBLR, ByteAcc, NoLock, Preserve)
        {
            KBLB,   8
        }

        OperationRegion (KBCR, SystemMemory, {{ADDR}}, 0x03)
        Field (KBCR, ByteAcc, NoLock, Preserve)
        {
            KCLR,   8,
            KCLG,   8,
            KCLB,   8
        }

        Name (BINI, Zero)
        Name (BASR, 0xFF)
        Name (BASG, 0xFF)
        Name (BASB, 0xFF)
        Name (KLVL, 0xFF)

        // Read the current colour once and normalise it to full intensity.
        Method (KBBC, 0, Serialized)
        {
            Local1 = KCLR
            Local2 = KCLG
            Local3 = KCLB
            Local4 = Local1
            If ((Local2 > Local4))
            {
                Local4 = Local2
            }

            If ((Local3 > Local4))
            {
                Local4 = Local3
            }

            If ((Local4 == Zero))
            {
                Local1 = 0xFF
                Local2 = 0xFF
                Local3 = 0xFF
                Local4 = 0xFF
            }

            BASR = (((Local1 * 0xFF) + (Local4 >> One)) / Local4)
            BASG = (((Local2 * 0xFF) + (Local4 >> One)) / Local4)
            BASB = (((Local3 * 0xFF) + (Local4 >> One)) / Local4)
            BINI = One
        }

        Method (KBAP, 0, Serialized)
        {
            KCLR = (((BASR * KLVL) + 0x7F) / 0xFF)
            KCLG = (((BASG * KLVL) + 0x7F) / 0xFF)
            KCLB = (((BASB * KLVL) + 0x7F) / 0xFF)
            KBLB = {{MAXLVL}}
        }

        Method (SKBC, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            BASR = ((Local0 >> 0x10) & 0xFF)
            BASG = ((Local0 >> 0x08) & 0xFF)
            BASB = (Local0 & 0xFF)
            BINI = One
            If ((KLVL != Zero))
            {
                KBAP ()
            }

            Return (Zero)
        }

        Method (SKBV, 1, Serialized)
        {
            If (_OSI ("Darwin"))
            {
                If ((BINI == Zero))
                {
                    KBBC ()
                }

                Local0 = ToInteger (Arg0)
                If ((Local0 > 0xFF))
                {
                    Local0 = 0xFF
                }

                KLVL = Local0
                If ((Local0 == Zero))
                {
                    KBLB = Zero
                    Return (Zero)
                }

                KBAP ()
            }

            Return (Zero)
        }
    }

    Device (\_SB.KBCD)
    {
        Name (_HID, "KBCD0001")

        Method (_STA, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (0x0F)
            }

            Return (Zero)
        }

        Method (GCAP, 0, NotSerialized)
        {
            Return ({{CAPS}})
        }

        Method (SCLR, 1, Serialized)
        {
            If ((ToInteger (Arg0) > 0x00FFFFFF))
            {
                Return (One)
            }

            Return ({{ATKD}}.SKBC (Arg0))
        }

        Method (GCLR, 0, Serialized)
        {
            If (({{ATKD}}.BINI == Zero))
            {
                {{ATKD}}.KBBC ()
            }

            Return (((({{ATKD}}.BASR << 0x10) | ({{ATKD}}.BASG << 0x08)) | {{ATKD}}.BASB))
        }
    }
}
"""#

let asusFANMTemplate = #"""
/*
 * SSDT-FANM: fan mode (Silent / Normal / Turbo) for ASUS TUF.
 * Generated by the KBColor setup assistant.
 *
 *   {{EC}}.FNGM   0 = Normal, 1 = Turbo, 2 = Silent (the EC applies it itself)
 *   RPM = 0x20E6DA / FRMS (CPU fan), 0x20E6DA / FRS2 (GPU fan)
 *
 * Adds to \_SB.KBCD: load after SSDT-KBLT.
 */
DefinitionBlock ("", "SSDT", 2, "KBCLR", "FANM", 0x00003000)
{
    External (_SB_.KBCD, DeviceObj)
    External ({{EC}}, DeviceObj)
    External ({{EC}}.ECOK, IntObj)
    External ({{EC}}.MUT0, MutexObj)
    External ({{EC}}.FNGM, FieldUnitObj)
    External ({{EC}}.FRMS, FieldUnitObj)
    External ({{EC}}.FRS2, FieldUnitObj)
{{EXTERNALS}}
{{KEY}}
    Scope (\_SB.KBCD)
    {
        // 0 = Normal, 1 = Turbo, 2 = Silent, 0xFF if the EC is not ready.
        Method (GFAN, 0, Serialized)
        {
            If (!{{EC}}.ECOK)
            {
                Return (0xFF)
            }

            Acquire ({{EC}}.MUT0, 0x1000)
            Local0 = {{EC}}.FNGM
            Release ({{EC}}.MUT0)
            Return (Local0)
        }

        Method (SFAN, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            If ((Local0 > 0x02))
            {
                Return (One)
            }

            If (!{{EC}}.ECOK)
            {
                Return (One)
            }

            Acquire ({{EC}}.MUT0, 0x1000)
            {{EC}}.FNGM = Local0
            Release ({{EC}}.MUT0)
            Return (Zero)
        }

        Method (GRPM, 1, Serialized)
        {
            If (!{{EC}}.ECOK)
            {
                Return (Zero)
            }

            Acquire ({{EC}}.MUT0, 0x1000)
            If ((ToInteger (Arg0) == Zero))
            {
                Local0 = {{EC}}.FRMS
            }
            Else
            {
                Local0 = {{EC}}.FRS2
            }

            Release ({{EC}}.MUT0)
            If ((Local0 == Zero))
            {
                Return (Zero)
            }

            Return ((0x0020E6DA / Local0))
        }
    }
}
"""#

let asusKeyTemplate = #"""
    // Fn+F5: needs the config.plist rename {{Q}} -> {{XQ}}. Steps
    // Normal -> Turbo -> Silent -> Normal and tells KBColor.kext.
    Scope ({{EC}})
    {
        Method ({{Q}}, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Local0 = \_SB.KBCD.GFAN ()
                If ((Local0 > 0x02))
                {
                    Return (Zero)
                }

                Local0++
                If ((Local0 > 0x02))
                {
                    Local0 = Zero
                }

                \_SB.KBCD.SFAN (Local0)
                Notify (\_SB.KBCD, 0x80)
            }
            Else
            {
                {{XQ}} ()
            }

            Return (Zero)
        }
    }

"""#
