// KBColor Kurulum: the setup assistant's window.

import AppKit
import SwiftUI

@MainActor
final class Model: ObservableObject {
    enum Phase {
        case start
        case running
        case final(Outcome)
        case probe(ProbeOutcome)
        case wizard
        case failed(String)
        case diagnosing
        case diagnosed(text: String, findings: [DiagFinding], file: URL?)
    }

    @Published var phase: Phase = .start
    @Published var log: [String] = []
    @Published var forceDiscovery = false
    @Published var outputParent = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    @Published var state: DiscoveryState? = DiscoveryState.load()
    @Published var probeReady = Probe.available
    @Published var message = ""

    // live test
    @Published var levelCandidates: [Candidate] = []
    @Published var colorCandidates: [Candidate] = []
    @Published var confirmedLevel: Candidate?
    @Published var confirmedColor: Candidate?
    @Published var testing: (kind: String, cand: Candidate, restore: [(Int, Int, UInt8)])?

    init() { if state != nil { phase = .wizard } }

    func pickDump() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Seç"
        p.message = "ACPI dökümünün (.aml dosyaları) olduğu klasörü seç"
        guard p.runModal() == .OK, let url = p.url else { return }
        run(dump: url, offsets: nil)
    }

    func pickOutput() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Seç"
        p.message = "Hazırlanan paketin kaydedileceği klasör"
        if p.runModal() == .OK, let url = p.url { outputParent = url }
    }

    func run(dump: URL, offsets: KeyboardOffsets?) {
        phase = .running
        log = []
        let force = forceDiscovery, out = outputParent
        Task.detached {
            let pipeline = Pipeline { line in Task { @MainActor in self.log.append(line) } }
            do {
                let r = try pipeline.run(dump: dump, outputParent: out, offsets: offsets, forceDiscovery: force)
                await MainActor.run {
                    switch r {
                    case .final(let o):
                        if offsets != nil { DiscoveryState.clear(); self.state = nil }
                        self.phase = .final(o)
                    case .probe(let p):
                        self.state = p.state
                        self.phase = .probe(p)
                    }
                }
            } catch {
                await MainActor.run { self.phase = .failed("\(error)") }
            }
        }
    }

    // MARK: wizard

    func refreshProbe() { probeReady = Probe.available }

    func takeSnapshot() {
        guard var s = state, let step = s.nextStep else { return }
        message = "Okunuyor…"
        guard let snap = Probe.snapshot() else { message = "Sonda okunamadı. SSDT-KBCP ve KBColor.kext yüklü mü?"; return }
        s.snapshots[step.id] = snap
        do { try s.save() } catch { message = "Kaydedilemedi: \(error)"; return }
        state = s
        message = "\(step.id) adımı kaydedildi."
        if s.nextStep == nil { analyze() }
    }

    func redo(_ id: String) {
        guard var s = state else { return }
        s.snapshots[id] = nil
        try? s.save()
        state = s
        levelCandidates = []; colorCandidates = []; confirmedLevel = nil; confirmedColor = nil
    }

    func analyze() {
        guard let s = state else { return }
        levelCandidates = Analysis.levelCandidates(s)
        colorCandidates = Analysis.colorCandidates(s)
        message = "Aday: \(levelCandidates.count) seviye, \(colorCandidates.count) renk adresi."
    }

    func current() -> [[UInt8]]? { Probe.read() }

    // Level test: write 0 (off). Colour test: write magenta, then rewrite the
    // level byte so the EC applies it.
    func startTest(_ kind: String, _ c: Candidate) {
        guard let now = current() else { message = "Sonda okunamadı."; return }
        var restore: [(Int, Int, UInt8)] = []
        var ok = true
        if kind == "level" {
            restore = [(c.region, c.offset, now[c.region][c.offset])]
            ok = Probe.write(region: c.region, offset: c.offset, value: 0)
        } else {
            for i in 0...2 { restore.append((c.region, c.offset + i, now[c.region][c.offset + i])) }
            ok = Probe.write(region: c.region, offset: c.offset, value: 0xFF)
                && Probe.write(region: c.region, offset: c.offset + 1, value: 0x00)
                && Probe.write(region: c.region, offset: c.offset + 2, value: 0xFF)
            if let l = confirmedLevel {
                let lv = now[l.region][l.offset]
                ok = ok && Probe.write(region: l.region, offset: l.offset, value: lv == 0 ? UInt8(l.maxLevel) : lv)
                restore.append((l.region, l.offset, lv))
            }
        }
        testing = (kind, c, restore)
        message = ok ? "" : "Yazma başarısız oldu."
    }

    func answer(_ yes: Bool) {
        guard let t = testing else { return }
        for (r, o, v) in t.restore { _ = Probe.write(region: r, offset: o, value: v) }
        if let l = confirmedLevel, t.kind == "color" {
            // reapply the level so the restored colour shows
            if let now = current() { _ = Probe.write(region: l.region, offset: l.offset, value: now[l.region][l.offset]) }
        }
        if yes {
            if t.kind == "level" { confirmedLevel = t.cand } else { confirmedColor = t.cand }
        } else {
            if t.kind == "level" { levelCandidates.removeAll { $0 == t.cand } } else { colorCandidates.removeAll { $0 == t.cand } }
        }
        testing = nil
    }

    func finish() {
        guard let s = state, let l = confirmedLevel, let c = confirmedColor else { return }
        var st = s
        let off = KeyboardOffsets(colorAddr: s.regions[c.region].base + UInt64(c.offset),
                                  levelAddr: s.regions[l.region].base + UInt64(l.offset), maxLevel: l.maxLevel)
        st.confirmed = off
        try? st.save()
        state = st
        outputParent = URL(fileURLWithPath: s.outputParent)
        run(dump: URL(fileURLWithPath: s.dumpFolder), offsets: off)
    }

    // Diagnostic report: optionally with config.plist, saved to the Desktop.
    func diagnose() {
        let a = NSAlert()
        a.messageText = "config.plist de kontrol edilsin mi?"
        a.informativeText = "EFI bölümündeki EFI/OC/config.plist dosyasını seçersen SSDT sırası, fan tuşu rename'i ve kext girdisi de kontrol edilir; dosyaların EFI'de olup olmadığına da bakılır. EFI bölümü bağlı değilse önce bağla."
        a.addButton(withTitle: "config.plist seç…")
        a.addButton(withTitle: "Atla")
        var config: URL?
        if a.runModal() == .alertFirstButtonReturn {
            let p = NSOpenPanel()
            p.allowedContentTypes = [.propertyList]
            p.message = "EFI/OC/config.plist dosyasını seç"
            if p.runModal() == .OK { config = p.url }
        }
        phase = .diagnosing
        log = []
        Task.detached {
            let d = Diagnostics(config: config) { line in Task { @MainActor in self.log.append(line) } }
            let text = d.run()
            let file = try? Diagnostics.save(text)
            await MainActor.run { self.phase = .diagnosed(text: text, findings: d.findings, file: file) }
        }
    }

    func cancelDiscovery() {
        DiscoveryState.clear()
        state = nil
        phase = .start
    }
}

struct ContentView: View {
    @StateObject var m = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "keyboard").font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("KBColor Kurulum").font(.title2).bold()
                    Text("ACPI dökümünden bu dizüstüne özel SSDT, kext ve kurulum rehberi hazırlar.")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            switch m.phase {
            case .start: StartView(m: m)
            case .running: LogView(lines: m.log)
            case .final(let o): FinalView(m: m, o: o)
            case .probe(let p): ProbeView(m: m, p: p)
            case .wizard: WizardView(m: m)
            case .diagnosing: LogView(lines: m.log)
            case .diagnosed(let text, let findings, let file): DiagnosisView(m: m, text: text, findings: findings, file: file)
            case .failed(let e):
                VStack(alignment: .leading, spacing: 12) {
                    Label("Hazırlanamadı", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.headline)
                    Text(e).textSelection(.enabled)
                    LogView(lines: m.log)
                    Button("Baştan başla") { m.phase = m.state != nil ? .wizard : .start }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 600)
    }
}

struct StartView: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. ACPI dökümü").font(.headline)
            Text("Dökümün .aml dosyalarının (DSDT.aml, SSDT-*.aml) olduğu klasörü seç. Döküm almanın yolları:")
            VStack(alignment: .leading, spacing: 4) {
                Text("• OpenCore: config.plist → Misc → Debug → SysReport = True, açılıştan sonra EFI'deki SysReport/ACPI klasörü")
                Text("• Windows veya Linux: SSDTTime → \"Dump the current system's ACPI tables\"")
                Text("• Linux: sudo acpidump -b")
            }.font(.callout).foregroundStyle(.secondary)
            Text("Döküm, OpenCore yamaları uygulanmamış haliyle olmalı (SysReport bunu sağlar).")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Paket buraya kaydedilecek:")
                Text(m.outputParent.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Button("Değiştir…") { m.pickOutput() }
            }
            Toggle("Klavye adreslerini Windows ile keşfet (bilinen düzen bulunsa bile; ASUS)", isOn: $m.forceDiscovery)
            Button { m.pickDump() } label: {
                Label("Döküm klasörünü seç ve hazırla…", systemImage: "folder").padding(.horizontal, 8)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            Spacer()
            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "stethoscope").font(.title2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kurulumdan sonra sorun mu var?").font(.headline)
                        Text("Tanılama raporu; sistemi, KBColor.kext'i, ACPI açılış hatalarını ve istersen config.plist'i kontrol eder, sorunu özetler ve her şeyi masaüstüne tek bir dosya olarak kaydeder. Bu dosyayı forum konusuna ekleyebilirsin.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Tanılama raporu oluştur…") { m.diagnose() }
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct LogView: View {
    var lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(.callout, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { n in proxy.scrollTo(n - 1) }
        }
    }
}

func reveal(_ u: URL) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
func open(_ u: URL) { NSWorkspace.shared.open(u) }

struct FinalView: View {
    @ObservedObject var m: Model
    var o: Outcome
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let ok = o.tests.allSatisfy { $0.ok } && o.loadErrors.isEmpty
            Label(ok ? "Paket hazır, doğrulama hatasız" : "Paket hazır, ama doğrulamada hata var",
                  systemImage: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(ok ? .green : .orange)
            Text("\(o.result.vendor) · \(o.model)").foregroundStyle(.secondary)
            Text(o.result.features.joined(separator: " · ")).font(.callout)
            LogView(lines: m.log)
            HStack {
                Button("README'yi aç") { open(o.outputFolder.appendingPathComponent("README.html")) }.buttonStyle(.borderedProminent)
                Button("Finder'da göster") { reveal(o.outputFolder) }
                Spacer()
                Button("Yeni analiz") { m.phase = .start }
            }
        }
    }
}

struct ProbeView: View {
    @ObservedObject var m: Model
    var p: ProbeOutcome
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bu model için Windows yardımıyla keşif gerekiyor", systemImage: "magnifyingglass").font(.headline)
            Text("Klavye renk ve parlaklık adresleri dökümde yok. Geçici bir sonda paketi hazırlandı. README-kesif.html'deki adımlarla EFI'ye kur ve yeniden başlat. Bu uygulamayı açtığında keşif ekranı kaldığı yerden devam eder.")
            LogView(lines: m.log)
            HStack {
                Button("README-kesif'i aç") { open(p.outputFolder.appendingPathComponent("README-kesif.html")) }.buttonStyle(.borderedProminent)
                Button("Finder'da göster") { reveal(p.outputFolder) }
                Spacer()
                Button("Keşif ekranına geç") { m.phase = .wizard; m.refreshProbe() }
            }
        }
    }
}

struct WizardView: View {
    @ObservedObject var m: Model
    var body: some View {
        if let s = m.state {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Keşif: \(s.model)").font(.headline)
                    Spacer()
                    Label(m.probeReady ? "Sonda yüklü" : "Sonda yüklü değil", systemImage: m.probeReady ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(m.probeReady ? .green : .orange)
                    Button("Yenile") { m.refreshProbe() }
                }
                if !m.probeReady {
                    Text("SSDT-KBCP ve KBColor.kext EFI'de değil ya da yüklenmemiş. Keşif paketindeki README-kesif.html'e göre kurup yeniden başlat.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("Windows adımları") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(s.steps, id: \.id) { step in
                            HStack(alignment: .top) {
                                Image(systemName: s.snapshots[step.id] != nil ? "checkmark.circle.fill" :
                                        step == s.nextStep ? "arrow.right.circle.fill" : "circle")
                                    .foregroundStyle(s.snapshots[step.id] != nil ? .green : .accentColor)
                                Text("\(step.id). \(step.text)").fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                if s.snapshots[step.id] != nil { Button("Yeniden al") { m.redo(step.id) }.controlSize(.small) }
                            }
                        }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let step = s.nextStep {
                    Text("Şimdi: \(step.text) Ardından yeniden başlatıp macOS'a dön ve aşağıdaki düğmeye bas. Ayarı Windows'ta yaptıysan ve şu an macOS'taysan hemen alabilirsin.")
                        .font(.callout)
                    Button("Görüntü al (\(step.id))") { m.takeSnapshot() }
                        .buttonStyle(.borderedProminent).disabled(!m.probeReady)
                } else {
                    TestPanel(m: m)
                }
                if !m.message.isEmpty { Text(m.message).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                HStack {
                    Button("Keşfi iptal et", role: .destructive) { m.cancelDiscovery() }
                    Spacer()
                }
            }
            .onAppear { m.refreshProbe(); if s.nextStep == nil { m.analyze() } }
        }
    }
}

struct TestPanel: View {
    @ObservedObject var m: Model
    var body: some View {
        GroupBox("Canlı onay") {
            VStack(alignment: .leading, spacing: 10) {
                if let t = m.testing {
                    Text(t.kind == "level" ? "Klavye ışığı söndü mü?" : "Klavye MOR (eflatun) oldu mu?").font(.headline)
                    HStack {
                        Button("Evet") { m.answer(true) }.buttonStyle(.borderedProminent)
                        Button("Hayır") { m.answer(false) }
                    }
                    Text("Cevap verince eski değer geri yazılır.").font(.caption).foregroundStyle(.secondary)
                } else if m.confirmedLevel == nil {
                    candidateRow("Parlaklık seviyesi", m.levelCandidates, kind: "level")
                } else if m.confirmedColor == nil {
                    Label("Seviye onaylandı", systemImage: "checkmark").foregroundStyle(.green)
                    candidateRow("Renk", m.colorCandidates, kind: "color")
                } else {
                    Label("Seviye ve renk adresleri onaylandı", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Button("Son paketi hazırla") { m.finish() }.buttonStyle(.borderedProminent)
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    func candidateRow(_ title: String, _ list: [Candidate], kind: String) -> some View {
        if let c = list.first, let s = m.state {
            Text("\(title) adayı: \(s.regions[c.region].path) +0x\(String(c.offset, radix: 16, uppercase: true))"
                 + (list.count > 1 ? " (\(list.count) aday)" : ""))
            Button(kind == "level" ? "Dene: ışığı söndür" : "Dene: klavyeyi mora boya") { m.startTest(kind, c) }
                .buttonStyle(.borderedProminent)
        } else {
            Text("\(title) için aday kalmadı. Bir adımı yeniden al (Windows'taki ayarın gerçekten kaydedildiğinden emin ol) ya da DSDT ve görüntüleri geliştiriciye gönder.")
                .foregroundStyle(.orange)
        }
    }
}

struct SetupApp: App {
    var body: some Scene {
        WindowGroup("KBColor Kurulum") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}

struct DiagnosisView: View {
    @ObservedObject var m: Model
    var text: String
    var findings: [DiagFinding]
    var file: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let fails = findings.filter { $0.level == .fail }.count
            Label(fails == 0 ? "Rapor hazır" : "Rapor hazır: \(fails) sorun bulundu",
                  systemImage: fails == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(fails == 0 ? .green : .orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(findings.sorted { order($0) < order($1) }.enumerated()), id: \.offset) { _, f in
                        HStack(alignment: .top, spacing: 8) {
                            Text(f.level.rawValue).bold().foregroundStyle(color(f.level)).frame(width: 14)
                            Text(f.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if let file { Text("Kaydedildi: \(file.path)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if let file { Button("Finder'da göster") { reveal(file) }.buttonStyle(.borderedProminent) }
                Button("Panoya kopyala") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Forum konusunu aç") { open(Diagnostics.forumURL) }
                Spacer()
                Button("Geri") { m.phase = m.state != nil ? .wizard : .start }
            }
        }
    }

    func order(_ f: DiagFinding) -> Int { [.fail: 0, .warn: 1, .info: 2, .ok: 3][f.level] ?? 4 }
    func color(_ l: DiagFinding.Level) -> Color { l == .fail ? .red : l == .warn ? .orange : l == .ok ? .green : .secondary }
}
