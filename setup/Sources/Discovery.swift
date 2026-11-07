// Windows-assisted discovery of EC offsets the firmware does not name.
//
// Some laptops (the ASUS TUF this started on) keep the keyboard colour and
// level in EC RAM bytes that no ACPI method or field describes. The vendor
// tool in Windows writes them, and the EC keeps them across a restart. So:
//
//   1. The assistant generates SSDT-KBCP, a temporary probe: \_SB.KBCD with
//      ECRN / ECRD (read whole candidate EC regions) and ECWR (write one byte,
//      used only for the confirmation tests). KBColor.kext exposes them.
//   2. The user sets a known colour / level in Windows, restarts into macOS
//      and takes a snapshot; repeated for each step. Each snapshot is three
//      reads a second apart, so bytes the EC changes by itself (temperatures,
//      counters) are left out.
//   3. The snapshots are compared to find the colour and level bytes.
//   4. Each candidate is written live and the user confirms what the keyboard
//      did; the old values are put back after every test.
//   5. With confirmed offsets the profile generates the final SSDTs, which
//      have no raw EC access.
//
// The state is saved in Application Support, so it survives the restarts.

import Foundation
import IOKit

struct ProbeRegion: Codable, Hashable {
    var path: String        // e.g. \_SB.PCI0.LPCB.EC0.ERM2
    var base: UInt64
    var length: Int
}

struct DiscoveryStep: Codable, Hashable {
    var id: String
    var color: UInt32       // what the user sets in Windows
    var level: String       // "max", "min", "off"
    var text: String        // instructions
}

// Offsets the ASUS template needs.
struct KeyboardOffsets: Codable, Hashable {
    var colorAddr: UInt64
    var levelAddr: UInt64
    var maxLevel: Int
}

struct DiscoveryState: Codable {
    var model: String
    var profile: String
    var dumpFolder: String
    var outputParent: String
    var regions: [ProbeRegion]
    var steps: [DiscoveryStep]
    var snapshots: [String: [[[UInt8]]]] = [:]   // step id -> 3 reads -> region bytes
    var confirmed: KeyboardOffsets?

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KBColor Kurulum", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kesif.json")
    }

    static func load() -> DiscoveryState? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiscoveryState.self, from: d)
    }

    func save() throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: DiscoveryState.url, options: .atomic)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    var nextStep: DiscoveryStep? { steps.first { snapshots[$0.id] == nil } }
}

let keyboardSteps: [DiscoveryStep] = [
    DiscoveryStep(id: "A", color: 0xFF0000, level: "max",
                  text: "Windows'ta üreticinin uygulamasında (Armoury Crate vb.) klavye rengini KIRMIZI, parlaklığı EN YÜKSEK yap."),
    DiscoveryStep(id: "B", color: 0x00FF00, level: "max",
                  text: "Windows'ta klavye rengini YEŞİL yap, parlaklık EN YÜKSEK kalsın."),
    DiscoveryStep(id: "C", color: 0x0000FF, level: "min",
                  text: "Windows'ta klavye rengini MAVİ, parlaklığı EN DÜŞÜK (kapalı değil) yap."),
    DiscoveryStep(id: "D", color: 0x0000FF, level: "off",
                  text: "Windows'ta klavye ışığını KAPAT (renk mavi kalsın)."),
]

// MARK: probe SSDT

func probeSSDT(_ regions: [ProbeRegion]) -> String {
    var decl = "", reads = "", writes = ""
    for (i, r) in regions.enumerated() {
        decl += """
                OperationRegion (PR\(i)_, SystemMemory, 0x\(String(r.base, radix: 16, uppercase: true)), 0x\(String(r.length, radix: 16, uppercase: true)))
                Field (PR\(i)_, ByteAcc, NoLock, Preserve)
                {
                    PD\(i)_,   \(r.length * 8)
                }

        """
        reads += """
                    If ((ToInteger (Arg0) == \(i)))
                    {
                        Return (PD\(i)_)
                    }

        """
        writes += """
                    If ((Local0 == \(i)))
                    {
                        If ((Local1 >= 0x\(String(r.length, radix: 16, uppercase: true))))
                        {
                            Return (One)
                        }

                        Local3 = (0x\(String(r.base, radix: 16, uppercase: true)) + Local1)
                    }

        """
    }
    return #"""
    /*
     * SSDT-KBCP: TEMPORARY probe for the KBColor setup assistant.
     * Reads the EC regions below and writes single bytes for the
     * confirmation tests. Remove it from the EFI once the final SSDTs are in.
     *
    \#(regions.map { " *   \($0.path)  0x\(String($0.base, radix: 16, uppercase: true)), \($0.length) bytes" }.joined(separator: "\n"))
     */
    DefinitionBlock ("", "SSDT", 2, "KBCLR", "KBCP", 0x00001000)
    {
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

            // probe flag only, no features
            Method (GCAP, 0, NotSerialized)
            {
                Return (0x01000000)
            }

    \#(decl)
            Method (ECRN, 0, NotSerialized)
            {
                Return (\#(regions.count))
            }

            Method (ECRD, 1, Serialized)
            {
    \#(reads)            Return (Buffer (One){ 0x00 })
            }

            // (region << 24) | (offset << 8) | value
            Method (ECWR, 1, Serialized)
            {
                Local0 = ((ToInteger (Arg0) >> 0x18) & 0xFF)
                Local1 = ((ToInteger (Arg0) >> 0x08) & 0xFFFF)
                Local2 = (ToInteger (Arg0) & 0xFF)
                Local3 = Zero
    \#(writes)            If ((Local3 == Zero))
                {
                    Return (One)
                }

                OperationRegion (PRWR, SystemMemory, Local3, One)
                Field (PRWR, ByteAcc, NoLock, Preserve)
                {
                    PRWB,   8
                }

                PRWB = Local2
                Return (Zero)
            }
        }
    }
    """#
}

// MARK: kext access

enum Probe {
    static func service() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
    }

    // True when KBColor.kext runs on SSDT-KBCP.
    static var available: Bool {
        let s = service()
        guard s != 0 else { return false }
        defer { IOObjectRelease(s) }
        let caps = (IORegistryEntryCreateCFProperty(s, "Capabilities" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue ?? 0
        return caps & 0x01000000 != 0
    }

    static func set(_ key: String, _ value: Int) -> Bool {
        let s = service()
        guard s != 0 else { return false }
        defer { IOObjectRelease(s) }
        return IORegistryEntrySetCFProperties(s, [key: NSNumber(value: value)] as CFDictionary) == KERN_SUCCESS
    }

    static func read() -> [[UInt8]]? {
        guard set("ECSnapshot", 1) else { return nil }
        let s = service()
        defer { IOObjectRelease(s) }
        guard let arr = IORegistryEntryCreateCFProperty(s, "ECSnapshot" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [Data] else { return nil }
        return arr.map { [UInt8]($0) }
    }

    static func write(region: Int, offset: Int, value: UInt8) -> Bool {
        set("ECWrite", region << 24 | offset << 8 | Int(value))
    }

    // Three reads a second apart.
    static func snapshot() -> [[[UInt8]]]? {
        var reads: [[[UInt8]]] = []
        for i in 0..<3 {
            if i > 0 { Thread.sleep(forTimeInterval: 1) }
            guard let r = read() else { return nil }
            reads.append(r)
        }
        return reads
    }
}

// MARK: analysis

struct Candidate: Hashable {
    var region: Int
    var offset: Int
    var maxLevel: Int = 0
}

enum Analysis {
    // Bytes that changed between the reads of any snapshot.
    static func volatile(_ state: DiscoveryState) -> [Set<Int>] {
        state.regions.indices.map { r in
            var v = Set<Int>()
            for reads in state.snapshots.values {
                for o in 0..<state.regions[r].length {
                    let vals = Set(reads.compactMap { $0.indices.contains(r) && $0[r].indices.contains(o) ? $0[r][o] : nil })
                    if vals.count > 1 { v.insert(o) }
                }
            }
            return v
        }
    }

    static func byte(_ s: DiscoveryState, _ step: String, _ r: Int, _ o: Int) -> Int? {
        guard let reads = s.snapshots[step], let first = reads.first, first.indices.contains(r),
              first[r].indices.contains(o) else { return nil }
        return Int(first[r][o])
    }

    // Three bytes that follow the colours of steps A (red), B (green), C (blue):
    // the set channel clearly above the other two.
    static func colorCandidates(_ s: DiscoveryState) -> [Candidate] {
        let vol = volatile(s)
        var out: [Candidate] = []
        for r in s.regions.indices {
            for o in 0..<(s.regions[r].length - 2) where !(o...(o + 2)).contains(where: { vol[r].contains($0) }) {
                var ok = true
                for (step, ch) in [("A", 0), ("B", 1), ("C", 2)] {
                    let v = (0...2).map { byte(s, step, r, o + $0) ?? -1 }
                    if v.contains(-1) { ok = false; break }
                    let others = v.enumerated().filter { $0.offset != ch }.map { $0.element }
                    if !(v[ch] >= 0x10 && others.allSatisfy { v[ch] >= 4 * max($0, 1) }) { ok = false; break }
                }
                if ok { out.append(Candidate(region: r, offset: o)) }
            }
        }
        return out
    }

    // A small level byte: equal for A and B (both max), smaller for C (min),
    // smaller again for D (off).
    static func levelCandidates(_ s: DiscoveryState) -> [Candidate] {
        let vol = volatile(s)
        var out: [Candidate] = []
        for r in s.regions.indices {
            for o in 0..<s.regions[r].length where !vol[r].contains(o) {
                guard let a = byte(s, "A", r, o), let b = byte(s, "B", r, o), let c = byte(s, "C", r, o),
                      let d = byte(s, "D", r, o) else { continue }
                if a == b && a > c && c > d && a <= 0x10 { out.append(Candidate(region: r, offset: o, maxLevel: a)) }
            }
        }
        return out
    }
}
