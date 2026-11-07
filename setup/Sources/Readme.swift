// README.html for the user's own laptop: what was found, how it was tested,
// and the exact EFI changes, step by step.

import Foundation

enum Readme {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func code(_ s: String) -> String { "<code>\(esc(s))</code>" }
    static func pre(_ s: String) -> String { "<pre><code>\(esc(s))</code></pre>" }

    static func html(_ o: Outcome) -> String {
        let r = o.result
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        var b = ""

        b += "<h1>KBColor kurulumu: \(esc(o.model))</h1>"
        b += "<p class=\"lead\">\(esc(r.vendor)) profiliyle, bu bilgisayarın kendi ACPI dökümünden üretildi (\(esc(date))).</p>"
        b += "<ul class=\"chips\">" + r.features.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"

        b += "<div class=\"warn\"><strong>Başlamadan önce EFI'nin yedeğini al.</strong> EFI klasörünü bir USB belleğe "
        b += "kopyala; bilgisayar açılmazsa USB'den açıp eski EFI'ye dönebilirsin. Bu yardımcı EFI'ne hiçbir şey yazmadı, "
        b += "aşağıdaki değişiklikleri sen yapacaksın.</div>"

        // Steps
        b += "<h2>Kurulum adımları</h2><ol class=\"steps\">"
        b += "<li><strong>EFI bölümünü bağla.</strong> OpenCore Configurator, MountEFI ya da Terminal ile:"
        b += pre("diskutil list") + "Listede <em>EFI</em> türündeki bölümün adını bul (çoğunlukla " + code("disk0s1") + "), sonra:"
        b += pre("sudo diskutil mount disk0s1") + "</li>"

        if o.removeProbe {
            b += "<li><strong>Keşif sondasını kaldır.</strong> EFI'deki " + code("EFI/OC/ACPI/SSDT-KBCP.aml") + " dosyasını sil ve "
            b += "config.plist'te ACPI → Add içindeki SSDT-KBCP girdisini kaldır. Sonda yalnızca adresleri bulmak içindi; "
            b += "son SSDT'lerle birlikte kalırsa aynı cihazı iki kez tanımlar ve açılışta hata verir. KBColor.kext yerinde kalır, "
            b += "yenisiyle değiştir.</li>"
        }
        b += "<li><strong>ACPI dosyalarını kopyala.</strong> Bu klasördeki " + code("EFI/OC/ACPI/") + " içinden "
        b += r.tables.map { code("\($0.name).aml") }.joined(separator: " ve ")
        b += " dosyalarını EFI bölümündeki " + code("EFI/OC/ACPI/") + " klasörüne kopyala.</li>"

        b += "<li><strong>Kext'i kopyala.</strong> " + code("EFI/OC/Kexts/KBColor.kext") + " klasörünü EFI'deki "
        b += code("EFI/OC/Kexts/") + " içine kopyala."
        if !r.extraKexts.isEmpty {
            b += " Ayrıca şunlar da EFI'de olmalı: " + r.extraKexts.map { esc($0) }.joined(separator: ", ") + "."
        }
        b += "</li>"

        b += "<li><strong>config.plist'i ProperTree ile aç</strong> (" + code("EFI/OC/config.plist") + "). "
        b += "Aynı pencerede bu klasördeki " + code("config-ekle.plist") + " dosyasını da açarsan girdileri oradan "
        b += "kopyalayıp yapıştırabilirsin. Değerler aşağıda da yazıyor.</li>"

        b += "<li><strong>ACPI → Add</strong> listesine şu girdileri <em>bu sırayla</em> ekle (sıra önemli: "
        b += "SSDT-FANM, SSDT-KBLT'nin oluşturduğu cihaza ekleme yapıyor):"
        b += "<div class=\"table-wrap\"><table><tr><th>Path</th><th>Enabled</th><th>Comment</th></tr>"
        for t in r.tables { b += "<tr><td>\(code("\(t.name).aml"))</td><td>True</td><td>KBColor: \(esc(t.name))</td></tr>" }
        b += "</table></div>"
        b += "<p class=\"small\">ProperTree'nin <em>OC Snapshot</em> özelliğini kullanırsan girdileri alfabetik sıraya dizer "
        b += "(FANM, KBLT'nin önüne geçer); snapshot'tan sonra sırayı elle düzelt.</p></li>"

        if !o.patches.isEmpty {
            b += "<li><strong>ACPI → Patch</strong> listesine şu yeniden adlandırmaları ekle. Find/Replace değerleri "
            b += "bu bilgisayarın DSDT'sinden hesaplandı ve tabloda yalnızca bir kez geçtiği doğrulandı:"
            b += "<div class=\"table-wrap\"><table><tr><th>Comment</th><th>Find (Data)</th><th>Replace (Data)</th>"
            b += "<th>Count</th><th>TableSignature</th></tr>"
            for p in o.patches {
                b += "<tr><td>\(esc("\(p.rename.method.short) → \(p.rename.newName)"))<br><span class=\"small\">\(esc(p.rename.reason))</span></td>"
                b += "<td>\(code(p.find.hexString))</td><td>\(code(p.replace.hexString))</td><td>1</td>"
                b += "<td>\(code(p.signature))"
                if let oem = p.oemTableID { b += "<br>OemTableId \(code(oem.hexString))" }
                b += "</td></tr>"
            }
            b += "</table></div>Diğer alanlar boş veya 0 kalır, Enabled = True.</li>"
        }

        b += "<li><strong>Kernel → Add</strong> listesine KBColor.kext girdisini ekle:"
        b += "<div class=\"table-wrap\"><table><tr><th>BundlePath</th><th>ExecutablePath</th><th>PlistPath</th><th>Arch</th></tr>"
        b += "<tr><td>\(code("KBColor.kext"))</td><td>\(code("Contents/MacOS/KBColor"))</td><td>\(code("Contents/Info.plist"))</td><td>x86_64</td></tr>"
        b += "</table></div>Lilu'ya bağımlı değil; listedeki yeri önemli değil.</li>"

        b += "<li><strong>Kaydet ve yeniden başlat.</strong> Açılış takılırsa OpenCore menüsünde USB'deki yedek EFI'yi seç "
        b += "ve eklenen girdileri kapat (Enabled = False).</li>"

        b += "<li><strong>Kext'in yüklendiğini kontrol et:</strong>"
        b += pre("ioreg -l -w0 -c KBColor | grep -E '\"(Capabilities|FanMode|CPUFanRPM|Effect|Brightness|Color)\"'")
        b += "Satırlar görünüyorsa SSDT'ler ve kext çalışıyor.</li>"

        b += "<li><strong>Uygulamayı kur.</strong> " + code("KBColor.app") + " dosyasını Uygulamalar klasörüne at ve aç "
        b += "Uygulama imzasız olduğu için macOS ilk açılışta engeller: Sistem Ayarları → Gizlilik ve Güvenlik'te "
        b += "en alttaki KBColor satırında <em>Yine de Aç</em>'a bas ve onayla (bir kez). Sequoia'da sağ tık → Aç artık yetmiyor. "
        b += "Menü çubuğundaki sıcaklık simgesinden "
        b += "\"Açılışta başlat\"ı işaretle.</li></ol>"

        // What was found
        b += "<h2>Dökümde bulunanlar</h2><ul class=\"checks\">"
        for c in r.checks {
            let cls = c.level == .ok ? "ok" : c.level == .warn ? "w" : "f"
            let sym = c.level == .ok ? "✓" : c.level == .warn ? "!" : "✗"
            b += "<li class=\"\(cls)\"><span>\(sym)</span>\(esc(c.text))</li>"
        }
        b += "</ul>"
        if !o.skipped.isEmpty {
            b += "<p class=\"small\">Analize alınmayan tablolar: " + o.skipped.map { esc($0) }.joined(separator: "; ") + "</p>"
        }

        // Validation
        let allOK = o.tests.allSatisfy { $0.ok } && o.loadErrors.isEmpty
        b += "<h2>Doğrulama</h2>"
        b += "<p>Üretilen SSDT'ler senin tablolarınla (rename'ler uygulanmış halde) " + code("acpiexec") + " içinde "
        b += "yüklendi ve her metot macOS'taki gibi (" + code("_OSI(\"Darwin\")") + ") çağrıldı. "
        b += allOK ? "<strong>Hepsi hatasız çalıştı.</strong>" : "<strong>Hata veren çağrılar var, kurmadan önce geliştiriciye bildir.</strong>"
        b += "</p><div class=\"table-wrap\"><table><tr><th>Çağrı</th><th>Sonuç</th></tr>"
        for t in o.tests {
            b += "<tr><td>\(code(t.command))</td><td class=\"\(t.ok ? "ok" : "f")\">\(t.ok ? "✓" : "✗") \(esc(t.detail))</td></tr>"
        }
        b += "</table></div>"
        for e in o.loadErrors { b += "<p class=\"f\">✗ Yükleme hatası: \(esc(e))</p>" }
        b += "<p class=\"small\">Tam çıktı: " + code("kaynak/acpiexec-dogrulama.txt") + ". Simülasyon EC'yi gerçekte "
        b += "çalıştırmaz; donanımda denenmesi gerekenler aşağıda.</p>"

        if !r.hardwareNotes.isEmpty {
            b += "<h2>Gerçek donanımda kontrol edilecekler</h2><ul>"
            for n in r.hardwareNotes { b += "<li>\(esc(n))</li>" }
            b += "</ul>"
        }

        b += "<h2>Sorun olursa</h2><p>Şu iki çıktıyı ve bu klasördeki " + code("kaynak/") + " klasörünü gönder:</p>"
        b += pre("ioreg -l -w0 -c KBColor")
        b += pre("log show --last 5m --predicate 'sender == \"KBColor\" OR eventMessage CONTAINS \"ACPI\"' | tail -50")

        b += "<h2>Bu klasörde</h2><div class=\"table-wrap\"><table>"
        b += "<tr><td>\(code("EFI/OC/ACPI/"))</td><td>EFI'ye kopyalanacak SSDT'ler</td></tr>"
        b += "<tr><td>\(code("EFI/OC/Kexts/KBColor.kext"))</td><td>EFI'ye kopyalanacak kext</td></tr>"
        b += "<tr><td>\(code("KBColor.app"))</td><td>Menü çubuğu uygulaması</td></tr>"
        b += "<tr><td>\(code("config-ekle.plist"))</td><td>config.plist'e eklenecek girdiler</td></tr>"
        b += "<tr><td>\(code("kaynak/"))</td><td>SSDT kaynakları (.dsl) ve doğrulama çıktısı</td></tr>"
        b += "</table></div>"

        return page(title: "KBColor kurulumu", body: b)
    }

    // Discovery, part 1: install the probe, then follow the steps in the app.
    static func probeHTML(_ o: ProbeOutcome) -> String {
        var b = "<h1>KBColor keşif paketi: \(esc(o.model))</h1>"
        b += "<p class=\"lead\">\(esc(o.result.vendor)) profili. Bu modelde klavye renk ve parlaklık adresleri ACPI dökümünde yazmıyor. "
        b += "Adresler, Windows'ta yapacağın birkaç ayar ve yeniden başlatmayla bulunacak.</p>"
        b += "<div class=\"warn\"><strong>EFI'nin yedeğini al.</strong> Bu paket geçicidir: adresler kesinleşince kurulum yardımcısı "
        b += "son paketi hazırlayacak ve bu sondayı kaldırmanı söyleyecek.</div>"
        b += "<h2>1. Sondayı kur</h2><ol class=\"steps\">"
        b += "<li>EFI bölümünü bağla (" + code("diskutil list") + ", sonra " + code("sudo diskutil mount disk0s1") + ").</li>"
        b += "<li>" + code("EFI/OC/ACPI/SSDT-KBCP.aml") + " dosyasını EFI'deki " + code("EFI/OC/ACPI/") + " içine, "
        b += code("EFI/OC/Kexts/KBColor.kext") + " klasörünü " + code("EFI/OC/Kexts/") + " içine kopyala.</li>"
        b += "<li>ProperTree ile config.plist'e ekle (değerler " + code("config-ekle.plist") + " içinde):"
        b += "<div class=\"table-wrap\"><table><tr><th>Yer</th><th>Girdi</th></tr>"
        b += "<tr><td>ACPI → Add</td><td>" + code("SSDT-KBCP.aml") + ", Enabled = True</td></tr>"
        b += "<tr><td>Kernel → Add</td><td>" + code("KBColor.kext") + " (ExecutablePath " + code("Contents/MacOS/KBColor") + ")</td></tr>"
        b += "</table></div>Daha önce kurulmuş bir KBColor SSDT-KBLT / SSDT-FANM varsa keşif boyunca kapat (Enabled = False).</li>"
        b += "<li>Kaydet, yeniden başlat. macOS açılınca KBColor Kurulum uygulamasını aç: keşif ekranı kaldığı yerden devam eder.</li></ol>"
        b += "<h2>2. Windows adımları</h2><p>Her adımda: Windows'ta ayarı yap, <strong>yeniden başlatıp macOS'a dön</strong>, "
        b += "KBColor Kurulum'da <em>Görüntü al</em>'a bas. Kapatıp açmak yerine yeniden başlat (EC ayarı korunur).</p><ol>"
        for s in o.state.steps { b += "<li>\(esc(s.text))</li>" }
        b += "</ol>"
        b += "<h2>3. Onay ve son paket</h2><p>Dört görüntüden sonra uygulama adayları bulur ve klavyede canlı dener; "
        b += "her denemeden sonra eski değer geri yazılır. Senin onayladığın adreslerle son paket ve kurulum README'si hazırlanır.</p>"
        b += "<h2>Sondanın taradığı EC bölgeleri</h2><div class=\"table-wrap\"><table><tr><th>Bölge</th><th>Adres</th><th>Boyut</th></tr>"
        for r in o.state.regions {
            b += "<tr><td>\(code(r.path))</td><td>\(code(String(format: "0x%llX", r.base)))</td><td>\(r.length) bayt</td></tr>"
        }
        b += "</table></div><p class=\"small\">Sonda bu bölgeleri yalnızca okur; yazma sadece onay testlerinde, senin başlattığın "
        b += "denemelerde ve aday adreslere yapılır. Doğrulama çıktısı: " + code("kaynak/") + ".</p>"
        return page(title: "KBColor keşif", body: b)
    }

    static func page(title: String, body: String) -> String {
        #"""
        <!doctype html>
        <html lang="tr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\#(esc(title))</title>
        <style>
          :root { --bg:#fafaf9; --fg:#1c1917; --muted:#57534e; --line:#e7e5e4; --card:#fff; --code-bg:#f5f5f4;
                  --ok:#15803d; --w:#b45309; --f:#b91c1c; --warn-bg:#fffbeb; --warn-line:#f59e0b; }
          @media (prefers-color-scheme: dark) {
            :root { --bg:#1c1917; --fg:#f5f5f4; --muted:#a8a29e; --line:#3a3532; --card:#24201e; --code-bg:#2c2725;
                    --ok:#4ade80; --w:#fbbf24; --f:#f87171; --warn-bg:#2a2214; --warn-line:#d97706; }
          }
          * { box-sizing: border-box; }
          body { margin:0; background:var(--bg); color:var(--fg);
                 font:16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
          main { max-width:860px; margin:0 auto; padding:40px 16px 64px; }
          h1 { font-size:1.8rem; line-height:1.25; margin:0 0 6px; }
          h2 { font-size:1.25rem; margin:40px 0 12px; padding-bottom:6px; border-bottom:1px solid var(--line); }
          .lead, .small { color:var(--muted); }
          .small { font-size:.85rem; }
          code { font:.88em ui-monospace, SFMono-Regular, Menlo, monospace; background:var(--code-bg); padding:1px 5px;
                 border-radius:4px; overflow-wrap:anywhere; }
          pre { background:var(--code-bg); border:1px solid var(--line); border-radius:8px; padding:10px 14px;
                overflow-x:auto; margin:8px 0 12px; }
          pre code { background:none; padding:0; }
          .table-wrap { overflow-x:auto; border:1px solid var(--line); border-radius:8px; background:var(--card); margin:10px 0; }
          table { border-collapse:collapse; width:100%; font-size:.92rem; }
          th, td { text-align:left; padding:8px 12px; border-bottom:1px solid var(--line); vertical-align:top; }
          tr:last-child td { border-bottom:none; }
          th { font-weight:600; color:var(--muted); font-size:.82rem; }
          ol.steps > li { margin:14px 0; }
          .chips { display:flex; flex-wrap:wrap; gap:8px; padding:0; list-style:none; margin:8px 0 20px; }
          .chips li { font-size:.85rem; border:1px solid var(--line); border-radius:999px; padding:2px 10px; background:var(--card); }
          .checks { list-style:none; padding:0; }
          .checks li { display:flex; gap:10px; margin:6px 0; }
          .checks li span { font-weight:700; width:1em; flex:none; }
          .ok, .checks .ok span { color:var(--ok); }
          .w, .checks .w span { color:var(--w); }
          .f, .checks .f span { color:var(--f); }
          .checks li { color:var(--fg); }
          .warn { background:var(--warn-bg); border-left:4px solid var(--warn-line); border-radius:6px; padding:12px 16px; margin:16px 0; }
        </style>
        </head>
        <body><main>
        \#(body)
        </main></body>
        </html>
        """#
    }
}
