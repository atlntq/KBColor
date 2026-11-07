// Entry point: the SwiftUI app, or a command line mode for testing.
//
//   KBColorKurulum --cli <dump folder> <output parent> [--discover] [--offsets COLOR,LEVEL,MAX]
//   KBColorKurulum --test-analysis

import Foundation

func cliMain(_ a: [String]) -> Int32 {
    if a.contains("--test-analysis") { return testAnalysis() }
    guard a.count >= 4 else { print("kullanım: --cli <döküm> <çıktı> [--discover] [--offsets C,L,M]"); return 2 }
    var offsets: KeyboardOffsets?
    if let i = a.firstIndex(of: "--offsets"), i + 1 < a.count {
        let p = a[i + 1].split(separator: ",").map { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0 }
        offsets = KeyboardOffsets(colorAddr: p[0], levelAddr: p[1], maxLevel: Int(p[2]))
    }
    let pipeline = Pipeline { print($0) }
    do {
        switch try pipeline.run(dump: URL(fileURLWithPath: a[2]), outputParent: URL(fileURLWithPath: a[3]),
                                offsets: offsets, forceDiscovery: a.contains("--discover")) {
        case .final(let o): print("SONUÇ: final \(o.outputFolder.path)")
        case .probe(let p): print("SONUÇ: keşif \(p.outputFolder.path)"); DiscoveryState.clear()
        }
        return 0
    } catch {
        print("HATA: \(error)")
        return 1
    }
}

// Synthetic snapshots: colour at 0x2B, level at 0x24 (max 3), a temperature
// byte at 0x30 that moves between reads, and a byte at 0x50 that happens to
// look like a colour channel in one step only.
func testAnalysis() -> Int32 {
    var s = DiscoveryState(model: "test", profile: "t", dumpFolder: "", outputParent: "",
                           regions: [ProbeRegion(path: "\\X.ERM2", base: 0xFE708B00, length: 0x100)], steps: keyboardSteps)
    let colors: [String: [UInt8]] = ["A": [0xFF, 0, 0], "B": [0, 0xFF, 0], "C": [0, 0, 0x55], "D": [0, 0, 0xFF]]
    let levels: [String: UInt8] = ["A": 3, "B": 3, "C": 1, "D": 0]
    for id in ["A", "B", "C", "D"] {
        var reads: [[[UInt8]]] = []
        for r in 0..<3 {
            var b = [UInt8](repeating: 0x11, count: 0x100)
            b[0x24] = levels[id]!
            b[0x2B...0x2D] = colors[id]![...]
            b[0x30] = UInt8(40 + r)
            b[0x50] = id == "A" ? 0xFF : 0x11
            reads.append([b])
        }
        s.snapshots[id] = reads
    }
    let c = Analysis.colorCandidates(s), l = Analysis.levelCandidates(s)
    print("renk adayları:", c.map { String(format: "0x%X", $0.offset) }, "seviye adayları:", l.map { String(format: "0x%X (max %d)", $0.offset, $0.maxLevel) })
    let ok = c.map(\.offset) == [0x2B] && l.map(\.offset) == [0x24] && l.first?.maxLevel == 3
    print(ok ? "TEST GEÇTİ" : "TEST KALDI")
    return ok ? 0 : 1
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1].hasPrefix("--") {
    exit(cliMain(CommandLine.arguments))
}
SetupApp.main()
