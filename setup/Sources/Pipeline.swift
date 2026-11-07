// The setup pipeline: read the dump, disassemble, pick a profile, generate
// and compile the SSDTs, work out the renames from the AML bytes, test
// everything in acpiexec against the user's own tables, and write the output
// folder (EFI files, KBColor.app, config-ekle.plist, README.html).
//
// Nothing here touches the user's EFI.

import Foundation

struct SetupError: Error, CustomStringConvertible {
    var description: String
    init(_ s: String) { description = s }
}

struct Table {
    var url: URL           // copy in the work folder
    var original: String   // file name in the user's folder
    var signature: String
    var oemID: String
    var tableID: String
    var bytes: Data
}

struct PatchInfo {
    var rename: Rename
    var find: Data
    var replace: Data
    var signature: String
    var oemTableID: Data?   // only for SSDTs
}

struct TestResult { var command: String; var ok: Bool; var detail: String }

enum RunKind { case final(Outcome), probe(ProbeOutcome) }

struct ProbeOutcome {
    var model: String
    var result: Result
    var state: DiscoveryState
    var tests: [TestResult]
    var outputFolder: URL
}

struct Outcome {
    var model: String
    var result: Result
    var patches: [PatchInfo]
    var tests: [TestResult]
    var loadErrors: [String]
    var outputFolder: URL
    var skipped: [String]
    var removeProbe = false
}

final class Pipeline {
    let log: (String) -> Void
    let fm = FileManager.default
    let work: URL

    init(log: @escaping (String) -> Void) {
        self.log = log
        work = fm.temporaryDirectory.appendingPathComponent("KBColorSetup-\(UUID().uuidString)")
    }

    deinit { try? fm.removeItem(at: work) }

    // MARK: tools

    func tool(_ name: String) throws -> URL {
        if let u = Bundle.main.url(forResource: name, withExtension: nil), fm.isExecutableFile(atPath: u.path) { return u }
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: u.path) { return u }
        }
        throw SetupError("\(name) bulunamadı (uygulamanın içinde olmalıydı)")
    }

    @discardableResult
    func run(_ exe: URL, _ args: [String], cwd: URL, input: String? = nil) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        if input != nil { p.standardInput = inPipe }
        try p.run()
        if let input {
            inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: steps

    func loadTables(from folder: URL) throws -> ([Table], [String]) {
        let dumpDir = work.appendingPathComponent("dump")
        try fm.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        let files = (try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
            .filter { ["aml", "dat", "bin"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var tables: [Table] = [], skipped: [String] = []
        for f in files {
            guard let d = try? Data(contentsOf: f), d.count >= 36 else { continue }
            let sig = String(decoding: d[0..<4], as: UTF8.self)
            guard sig == "DSDT" || sig == "SSDT" else { continue }
            func str(_ r: Range<Int>) -> String {
                String(decoding: d[r], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            }
            let oem = str(10..<16), tid = str(16..<24)
            // Tables a previous KBColor install injected through OpenCore.
            if sig == "SSDT" && ["KBLT", "FANM"].contains(tid) {
                skipped.append("\(f.lastPathComponent) (\(oem) \(tid): önceki bir KBColor kurulumundan, analize alınmadı)")
                continue
            }
            let name = String(format: "%@%02d.aml", sig == "DSDT" ? "DSDT" : "SSDT", tables.count)
            let dst = dumpDir.appendingPathComponent(name)
            try d.write(to: dst)
            tables.append(Table(url: dst, original: f.lastPathComponent, signature: sig, oemID: oem, tableID: tid, bytes: d))
        }
        guard tables.contains(where: { $0.signature == "DSDT" }) else {
            throw SetupError("Klasörde DSDT bulunamadı. ACPI dökümünün .aml dosyalarının olduğu klasörü seç.")
        }
        tables.sort { ($0.signature == "DSDT" ? 0 : 1) < ($1.signature == "DSDT" ? 0 : 1) }
        return (tables, skipped)
    }

    func disassemble(_ tables: [Table]) throws -> Namespace {
        let iasl = try tool("iasl")
        let dir = tables[0].url.deletingLastPathComponent()
        let (status, _) = try run(iasl, ["-dl", "-da"] + tables.map { $0.url.lastPathComponent }, cwd: dir)
        let ns = Namespace()
        for t in tables {
            var dsl = t.url.deletingPathExtension().appendingPathExtension("dsl")
            if status != 0 || !fm.fileExists(atPath: dsl.path) {
                // Fall back to one table at a time.
                let single = dir.appendingPathComponent("single", isDirectory: true)
                try? fm.createDirectory(at: single, withIntermediateDirectories: true)
                try run(iasl, ["-dl", "-p", single.appendingPathComponent(t.url.deletingPathExtension().lastPathComponent).path,
                               t.url.path], cwd: dir)
                dsl = single.appendingPathComponent(t.url.deletingPathExtension().lastPathComponent + ".dsl")
            }
            guard let text = try? String(contentsOf: dsl, encoding: .utf8) else {
                log("  ! \(t.original) açılamadı, atlandı")
                continue
            }
            ns.parse(text, table: t.url.lastPathComponent)
        }
        return ns
    }

    func compile(_ table: GeneratedTable, into dir: URL) throws -> URL {
        let iasl = try tool("iasl")
        let src = dir.appendingPathComponent(table.name + ".dsl")
        try table.dsl.write(to: src, atomically: true, encoding: .utf8)
        let (status, out) = try run(iasl, ["-p", dir.appendingPathComponent(table.name).path, src.path], cwd: dir)
        let aml = dir.appendingPathComponent(table.name + ".aml")
        guard status == 0, fm.fileExists(atPath: aml.path) else {
            throw SetupError("\(table.name) derlenemedi:\n" + out.split(separator: "\n").filter { $0.contains("Error") }.joined(separator: "\n"))
        }
        return aml
    }

    // Method header in AML: 0x14, PkgLength (1-4 bytes), NameSeg, flags.
    func patch(for r: Rename, tables: [Table], ns: Namespace) throws -> PatchInfo {
        guard let m = ns.methods[r.method], let t = tables.first(where: { $0.url.lastPathComponent == m.table }) else {
            throw SetupError("\(r.method.short) tablosu bulunamadı")
        }
        if ns.methods[r.method.parent.child(r.newName)] != nil {
            throw SetupError("\(r.method.parent.short).\(r.newName) zaten var. Döküm OpenCore yamalarıyla mı alındı? Yamasız döküm gerekli.")
        }
        let name = Array(r.method.last.utf8), bytes = [UInt8](t.bytes)
        var found: [UInt8]?
        var i = 0
        while i + 4 <= bytes.count {
            if Array(bytes[i..<i + 4]) == name, i + 4 < bytes.count {
                for k in 1...4 where i - k - 1 >= 0 {
                    let lead = bytes[i - k]
                    if bytes[i - k - 1] == 0x14 && Int(lead >> 6) == k - 1 && (k == 1 || lead & 0x30 == 0) {
                        found = Array(bytes[(i - k - 1)...(i + 4)])
                        break
                    }
                }
                if found != nil { break }
            }
            i += 1
        }
        guard let find = found else { throw SetupError("\(r.method.short) için AML'de metot başlığı bulunamadı") }
        var count = 0
        var j = 0
        while j + find.count <= bytes.count {
            if bytes[j] == find[0] && Array(bytes[j..<j + find.count]) == find { count += 1 }
            j += 1
        }
        guard count == 1 else { throw SetupError("\(r.method.short) rename deseni \(t.original) içinde \(count) kez geçiyor (1 olmalı)") }
        var rep = find
        rep[find.count - 5] = UInt8(ascii: "X")  // first byte of the name (name + flags end the header)
        return PatchInfo(rename: r, find: Data(find), replace: Data(rep), signature: t.signature,
                         oemTableID: t.signature == "SSDT" ? t.bytes[16..<24] : nil)
    }

    // Loads the user's tables (with the renames applied) plus the generated
    // SSDTs in acpiexec, as macOS would, and runs the profile's calls.
    func validate(tables: [Table], generated: [URL], patches: [PatchInfo], tests: [TestCall]) throws -> ([TestResult], [String]) {
        let acpiexec = try tool("acpiexec")
        let dir = work.appendingPathComponent("validate")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String] = []
        for t in tables {
            var d = t.bytes
            for p in patches where p.signature == t.signature && (p.oemTableID == nil || p.oemTableID == t.bytes[16..<24]) {
                if let r = d.range(of: p.find) { d.replaceSubrange(r, with: p.replace) }
            }
            let u = dir.appendingPathComponent(t.url.lastPathComponent)
            try d.write(to: u)
            files.append(u.lastPathComponent)
        }
        for g in generated {
            try fm.copyItem(at: g, to: dir.appendingPathComponent(g.lastPathComponent))
        }
        func errors(_ out: String) -> Set<String> {
            Set(out.split(separator: "\n").map(String.init).filter {
                ($0.contains("Error") || $0.contains("AE_")) && !$0.contains("Evaluation of")
            }.map { $0.replacingOccurrences(of: #"\(\d{8}/[^)]*\)"#, with: "", options: .regularExpression) })
        }
        let (_, base) = try run(acpiexec, ["-di"] + files, cwd: dir, input: "quit\n")
        let script = "osi install Darwin\n" + tests.map { $0.command }.joined(separator: "\n") + "\nquit\n"
        let (_, out) = try run(acpiexec, ["-di"] + files + generated.map { $0.lastPathComponent }, cwd: dir, input: script)
        try out.write(to: work.appendingPathComponent("acpiexec.txt"), atomically: true, encoding: .utf8)
        let loadErrors = errors(out).subtracting(errors(base)).sorted()

        // acpiexec echoes "- <command>" before each one.
        var results: [TestResult] = []
        let chunks = out.components(separatedBy: "\n- ")
        for t in tests {
            let chunk = chunks.first { $0.hasPrefix(t.command) } ?? ""
            let lines = chunk.split(separator: "\n").map(String.init)
            let failed = lines.first { $0.contains("failed with status") || ($0.contains("AE_") && !$0.contains("Outstanding")) }
            let value = lines.first { $0.contains("[Integer]") || $0.contains("[Buffer]") }?.trimmingCharacters(in: .whitespaces)
                ?? (lines.contains { $0.contains("No object was returned") } ? "değer döndürmedi" : "")
            results.append(TestResult(command: t.command.replacingOccurrences(of: "execute ", with: ""),
                                      ok: chunk.isEmpty ? false : failed == nil,
                                      detail: failed ?? (chunk.isEmpty ? "çalıştırılamadı" : value)))
        }
        return (results, loadErrors)
    }

    // MARK: main entry

    func run(dump: URL, outputParent: URL, offsets: KeyboardOffsets? = nil, forceDiscovery: Bool = false) throws -> RunKind {
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        log("Tablolar okunuyor: \(dump.path)")
        let (tables, skipped) = try loadTables(from: dump)
        log("  \(tables.count) tablo (\(tables.filter { $0.signature == "SSDT" }.count) SSDT)")
        for s in skipped { log("  - atlandı: \(s)") }
        let dsdt = tables[0]
        let model = "\(dsdt.oemID) \(dsdt.tableID)".trimmingCharacters(in: .whitespaces)
        log("DSDT: \(model). Tablolar açılıyor (iasl)…")
        let ns = try disassemble(tables)
        log("  \(ns.devices.count) cihaz, \(ns.methods.count) metot, \(ns.fields.count) alan okundu")

        var result: Result?
        var profile: Profile?
        for p in allProfiles {
            if let r = p.analyze(ns, offsets: offsets, forceDiscovery: forceDiscovery) { result = r; profile = p; break }
        }
        guard let result else {
            throw SetupError("Bu dizüstü için profil yok. Desteklenenler: " + allProfiles.map { $0.name }.joined(separator: ", ")
                             + ". DSDT'yi geliştiriciye gönderirsen profil eklenebilir.")
        }
        log("Profil: \(result.vendor)")
        for c in result.checks { log("  \(c.level == .ok ? "✓" : c.level == .warn ? "!" : "✗") \(c.text)") }
        if let regions = result.discovery {
            return .probe(try probe(model: model, profile: profile!.name, result: result, regions: regions,
                                    tables: tables, dump: dump, outputParent: outputParent))
        }
        if result.caps == 0 || result.checks.contains(where: { $0.level == .fail }) {
            throw SetupError("Bu modelde KBColor'ın ihtiyaç duyduğu arayüz eksik (yukarıdaki ✗ satırları).")
        }

        let out = uniqueFolder(outputParent.appendingPathComponent("KBColor-\(model.replacingOccurrences(of: " ", with: "-"))"))
        let acpiDir = out.appendingPathComponent("EFI/OC/ACPI"), kextDir = out.appendingPathComponent("EFI/OC/Kexts")
        let srcDir = out.appendingPathComponent("kaynak")
        for d in [acpiDir, kextDir, srcDir] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }

        log("SSDT'ler derleniyor…")
        var amls: [URL] = []
        for t in result.tables {
            let aml = try compile(t, into: srcDir)
            try fm.copyItem(at: aml, to: acpiDir.appendingPathComponent(aml.lastPathComponent))
            amls.append(aml)
            log("  ✓ \(t.name).aml")
        }

        var patches: [PatchInfo] = []
        for r in result.renames {
            let p = try patch(for: r, tables: tables, ns: ns)
            patches.append(p)
            log("  ✓ rename \(r.method.short) → \(r.newName): \(p.find.hexString) → \(p.replace.hexString) (\(p.signature), tek eşleşme)")
        }

        log("Doğrulama: senin tablolarınla acpiexec içinde çalıştırılıyor…")
        let (tests, loadErrors) = try validate(tables: tables, generated: amls, patches: patches, tests: result.tests)
        for t in tests { log("  \(t.ok ? "✓" : "✗") \(t.command)  \(t.detail)") }
        for e in loadErrors { log("  ✗ yükleme: \(e)") }
        try? fm.copyItem(at: work.appendingPathComponent("acpiexec.txt"), to: srcDir.appendingPathComponent("acpiexec-dogrulama.txt"))
        for t in amls { try? fm.removeItem(at: t) }

        for name in ["KBColor.kext", "KBColor.app"] {
            if let u = Bundle.main.url(forResource: name, withExtension: nil) {
                try fm.copyItem(at: u, to: (name.hasSuffix(".kext") ? kextDir : out).appendingPathComponent(name))
            } else {
                log("  ! \(name) uygulamanın içinde yok, kopyalanmadı")
            }
        }

        let outcome = Outcome(model: model, result: result, patches: patches, tests: tests, loadErrors: loadErrors,
                              outputFolder: out, skipped: skipped, removeProbe: offsets != nil)
        try configSnippet(outcome).write(to: out.appendingPathComponent("config-ekle.plist"))
        try Readme.html(outcome).write(to: out.appendingPathComponent("README.html"), atomically: true, encoding: .utf8)
        log("Hazır: \(out.path)")
        return .final(outcome)
    }

    // Discovery, part 1: the temporary probe package.
    func probe(model: String, profile: String, result: Result, regions: [ProbeRegion], tables: [Table],
               dump: URL, outputParent: URL) throws -> ProbeOutcome {
        let out = uniqueFolder(outputParent.appendingPathComponent("KBColor-Kesif-\(model.replacingOccurrences(of: " ", with: "-"))"))
        let acpiDir = out.appendingPathComponent("EFI/OC/ACPI"), kextDir = out.appendingPathComponent("EFI/OC/Kexts")
        let srcDir = out.appendingPathComponent("kaynak")
        for d in [acpiDir, kextDir, srcDir] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        log("Keşif sondası (SSDT-KBCP) derleniyor…")
        let aml = try compile(GeneratedTable(name: "SSDT-KBCP", dsl: probeSSDT(regions)), into: srcDir)
        try fm.copyItem(at: aml, to: acpiDir.appendingPathComponent("SSDT-KBCP.aml"))
        let calls = [TestCall(command: "execute \\_SB.KBCD.ECRN")] + regions.indices.map { TestCall(command: "execute \\_SB.KBCD.ECRD \($0)") }
            + [TestCall(command: "execute \\_SB.KBCD.ECWR 0x00000000")]
        let (tests, loadErrors) = try validate(tables: tables, generated: [aml], patches: [], tests: calls)
        for t in tests { log("  \(t.ok ? "✓" : "✗") \(t.command)  \(t.detail)") }
        for e in loadErrors { log("  ✗ yükleme: \(e)") }
        try? fm.removeItem(at: aml)
        guard tests.allSatisfy({ $0.ok }) && loadErrors.isEmpty else { throw SetupError("Sonda tablosu doğrulamadan geçmedi.") }
        if let u = Bundle.main.url(forResource: "KBColor.kext", withExtension: nil) {
            try fm.copyItem(at: u, to: kextDir.appendingPathComponent("KBColor.kext"))
        }
        let state = DiscoveryState(model: model, profile: profile, dumpFolder: dump.path, outputParent: outputParent.path,
                                   regions: regions, steps: keyboardSteps)
        try state.save()
        let o = ProbeOutcome(model: model, result: result, state: state, tests: tests, outputFolder: out)
        let add: [[String: Any]] = [["Comment": "KBColor: SSDT-KBCP (GEÇİCİ keşif sondası)", "Enabled": true, "Path": "SSDT-KBCP.aml"]]
        let kext: [String: Any] = ["Arch": "x86_64", "BundlePath": "KBColor.kext", "Comment": "KBColor", "Enabled": true,
                                   "ExecutablePath": "Contents/MacOS/KBColor", "MaxKernel": "", "MinKernel": "",
                                   "PlistPath": "Contents/Info.plist"]
        try PropertyListSerialization.data(fromPropertyList: ["ACPI": ["Add": add], "Kernel": ["Add": [kext]]], format: .xml, options: 0)
            .write(to: out.appendingPathComponent("config-ekle.plist"))
        try Readme.probeHTML(o).write(to: out.appendingPathComponent("README-kesif.html"), atomically: true, encoding: .utf8)
        log("Keşif paketi hazır: \(out.path)")
        return o
    }

    func uniqueFolder(_ u: URL) -> URL {
        var c = u, n = 2
        while fm.fileExists(atPath: c.path) { c = URL(fileURLWithPath: u.path + "-\(n)"); n += 1 }
        return c
    }

    func configSnippet(_ o: Outcome) throws -> Data {
        let add: [[String: Any]] = o.result.tables.map {
            ["Comment": "KBColor: \($0.name)", "Enabled": true, "Path": "\($0.name).aml"]
        }
        let patch: [[String: Any]] = o.patches.map { p in
            ["Base": "", "BaseSkip": 0, "Comment": "KBColor: \(p.rename.method.short) to \(p.rename.newName) (\(p.rename.reason))",
             "Count": 1, "Enabled": true, "Find": p.find, "Limit": 0, "Mask": Data(), "OemTableId": p.oemTableID ?? Data(),
             "Replace": p.replace, "ReplaceMask": Data(), "Skip": 0, "TableLength": 0, "TableSignature": Data(p.signature.utf8)]
        }
        let kext: [String: Any] = ["Arch": "x86_64", "BundlePath": "KBColor.kext", "Comment": "KBColor", "Enabled": true,
                                   "ExecutablePath": "Contents/MacOS/KBColor", "MaxKernel": "", "MinKernel": "",
                                   "PlistPath": "Contents/Info.plist"]
        let root: [String: Any] = ["ACPI": ["Add": add, "Patch": patch], "Kernel": ["Add": [kext]]]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}
