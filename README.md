# KBColor: keyboard light and fan control for hackintosh laptops

KBColor is a menu bar app with a small kext. It controls the keyboard backlight (colour, zones, effects, brightness) and the fan mode of gaming laptops running macOS through OpenCore.

**KBColor Kurulum**, the setup assistant, prepares KBColor for *your* laptop:

- It reads your ACPI dump and finds the firmware paths.
- It generates and compiles the SSDTs and the config.plist renames.
- It tests everything against your own tables.
- It writes a step-by-step README for your EFI.

> 🇹🇷 **Türkçe özet:** KBColor, OpenCore ile macOS çalıştıran oyun dizüstülerinde klavye ışığını (renk, bölge, efekt, parlaklık) ve fan modunu menü çubuğundan yönetir. **KBColor Kurulum** uygulamasını aç ve ACPI dökümünün olduğu klasörü seç. Uygulama gerekli yolları dökümden çıkarır, SSDT'leri ve config.plist rename'lerini hazırlar, hepsini senin tablolarınla `acpiexec` içinde dener ve EFI'ne yapman gerekenleri adım adım anlatan bir README.html yazar. Adresleri dökümde olmayan modellerde (ör. bazı ASUS TUF'lar), Windows'ta birkaç ayar ve yeniden başlatmayla adresleri bulup klavyede canlı onaylatan bir keşif modu var. Uygulama EFI'ne hiçbir şey yazmaz.

---

## Supported laptops

| Profile | Detected by | Features |
|---|---|---|
| **Acer Predator / Nitro** (PredatorSense) | `WMID.WMBH` with gaming-light calls `0x06` / `0x14`; EC fields `KBLE…`, `KB1R…KB4B` | 4-zone colour, effects (static, breathing, neon, wave, shifting, zoom), speed, direction, brightness 0–100 %, fan Normal / Turbo / Custom %, fan RPM, Turbo key |
| **ASUS TUF** (FX506 family EC) | `ATKD`, EC keyboard block, `FNGM` / `FRMS` / `FRS2`, Fn+F5 `_Qxx` | Colour, brightness through AsusSMC (Fn+↑/↓, Control Center), fan Silent / Normal / Turbo, fan RPM, Fn+F5 |
| **ASUS TUF, other EC layouts** | as above, colour bytes unknown | Same, after **Windows-assisted discovery** (below) |

Tested so far:

- **Acer Predator Helios 300 PH315-52** (i7-10750H). The package was generated from its dump and validated in `acpiexec`. Real-hardware testing is in progress.
- **ASUS TUF FX506LU / FX506LH.** This is where KBColor started; see [ASUS-TUF-FX506LU-Hackintosh](https://github.com/atlntq/ASUS-TUF-FX506LU-Hackintosh).

If your laptop is not detected, open an issue with your DSDT and SSDTs. A new profile is a detection function plus SSDT templates (see `setup/Sources/Profiles.swift`).

## Using the setup assistant

1. **Get an ACPI dump without OpenCore patches.** Any of these works:
   - OpenCore: set `Misc → Debug → SysReport` to `True` and boot once. The tables are in `SysReport/ACPI` on the EFI partition. Turn it off again afterwards.
   - Windows or Linux: [SSDTTime](https://github.com/corpnewt/SSDTTime), then "Dump the current system's ACPI tables".
   - Linux: `sudo acpidump -b`.
2. Download **KBColor Kurulum** from [Releases](../../releases) and open it. The app is ad-hoc signed, so macOS blocks it the first time. Open **System Settings → Privacy & Security**, click **Open Anyway** and confirm. On Sequoia, right-click → Open no longer bypasses this.
3. Click **Döküm klasörünü seç** and select the folder with the `.aml` files.
4. The assistant shows what it found (✓ / ! / ✗) and writes a folder (Desktop by default) containing:
   - `EFI/OC/ACPI/SSDT-KBLT.aml` and `SSDT-FANM.aml`
   - `EFI/OC/Kexts/KBColor.kext`
   - `KBColor.app`
   - `config-ekle.plist`, with the ACPI → Add, ACPI → Patch and Kernel → Add entries
   - `README.html`, the step-by-step EFI changes for this laptop together with the validation results
   - `kaynak/`, with the SSDT sources and the full `acpiexec` output
5. Back up your EFI, follow `README.html`, and reboot.

### What gets checked

- Rename Find/Replace bytes are taken from the method header in *your* AML, including its PkgLength, and must occur exactly once in the table.
- The generated SSDTs are loaded together with *all* your tables, with the renames applied, in `acpiexec`. Every method is then called with `_OSI("Darwin")`, as on macOS.
- Calls that go through the BIOS SMI handler (for example Acer fan behaviour) cannot be simulated. The README lists them under *things to confirm on real hardware*.

### Windows-assisted discovery

Some laptops keep the keyboard colour and level in EC RAM bytes that no ACPI method or field names. The vendor app in Windows writes them, and the EC keeps them across a restart. KBColor uses this to find them:

1. The assistant prepares a **temporary probe package**: `SSDT-KBCP` and the kext. You install it like any SSDT and reboot. The probe can read the candidate EC regions, and it can write single bytes, but only for the tests in step 4.
2. The assistant walks you through 4 steps:
   - red at max brightness
   - green at max brightness
   - blue at min brightness
   - light off

   For each step you set the light in Windows, reboot into macOS and click **Görüntü al**. Each snapshot is three reads a second apart, and bytes that change on their own (temperatures, counters) are ignored. Progress is saved across reboots.
3. The snapshots are compared to find the colour bytes and the level byte.
4. Each candidate is tested on the keyboard ("did the light go off?", "did it turn magenta?"). The old value is written back after every answer.
5. With confirmed offsets the final package is generated. Its README tells you to remove `SSDT-KBCP`. The final SSDTs have no raw EC access.

## The menu bar app

`KBColor.app` builds its menu from what the SSDTs implement (`KBCD.GCAP`). The menu can include:

- keyboard brightness
- effect, speed and direction
- colour for the whole keyboard or for one zone
- fan control, *Automatic* or *Manual*
- the fan modes
- sensors: CPU package and core temperatures, CPU / core / iGPU power, battery draw, fan RPM

Automatic fan control switches modes by CPU temperature with hysteresis, and the thresholds are set from the menu. Pressing the fan key, or picking a mode by hand, switches back to manual. Every mode change shows a HUD. Settings are saved and reapplied at login.

## How it fits together

```
KBColor.app ──IOKit properties──▶ KBColor.kext ──evaluate──▶ \_SB.KBCD (SSDT-KBLT / SSDT-FANM)
                                                                 │
                                                  vendor firmware: WMI method / EC fields
```

| Folder | What |
|---|---|
| `kext/` | `KBColor.kext`. It matches `KBCD0001` and forwards one property per call to a KBCD method: `Color`→`SCLR`, `ZoneColor`→`SZCL`, `Effect`→`SEFF`, `Brightness`→`SBRT`, `FanMode`→`SFAN`, `FanSpeed`→`SPCT`. `Refresh` publishes the state. It publishes `GCAP` as `Capabilities`. It is vendor-agnostic: methods a laptop lacks are never called. |
| `app/` | `KBColor.app`, the menu bar app. |
| `setup/Sources/ASL.swift` | Reader for `iasl -dl` output: devices, methods with their bodies, regions, and fields with bit offsets. |
| `setup/Sources/Profiles.swift` | Vendor profiles and SSDT templates. |
| `setup/Sources/Pipeline.swift` | Disassembly, compilation, renames, `acpiexec` validation and output. |
| `setup/Sources/Discovery.swift` | Probe SSDT, snapshots, analysis, live tests. |
| `setup/Sources/Readme.swift` | The generated README.html. |
| `setup/Sources/UI.swift` | SwiftUI window. |
| `shared/Diagnostics.swift` | Diagnostic report, used by both apps. |

`KBCD.GCAP` bits:

| Bit | Meaning |
|---|---|
| `0x001` | colour |
| `0x002` | 4 zones |
| `0x004` | effects |
| `0x008` | brightness through kext (0–100) |
| `0x010` | brightness through the system (AsusSMC) |
| `0x020` | fan modes |
| `0x040` | mode 2 = Silent |
| `0x080` | mode 2 = Custom % |
| `0x100` | fan RPM |
| `0x200` | fan key |
| bits 16–23 | fan key label: 1 = Fn+F5, 2 = Turbo key |

## Troubleshooting: diagnostic report

If something does not work after installing, create a **diagnostic report**. It is available in two places:
- the KBColor menu: *Tanılama raporu…*
- the KBColor Kurulum start screen: *Tanılama raporu oluştur…*

The report is read-only. It saves one text file on the Desktop, with a summary of the problems found (✗ / ! / ✓) on top, and covers:
- **System:** macOS, SMBIOS model, CPU, OpenCore version and boot-args.
- **ACPI and kext:** whether `\_SB.KBCD` exists, whether `KBColor.kext` is attached to it, which KBCD methods exist, and every value the kext publishes. Older kexts are handled too.
- **Kernel log of the current boot:** ACPI errors such as `AE_ALREADY_EXISTS` (the usual sign of a missing fan key rename) and unresolved names, plus the kext's own `KBColor:` lines (2.1.0 and later).
- **Optionally, your `EFI/OC/config.plist`:**
  - SSDT order (KBLT before FANM)
  - the `_Qxx → XQxx` rename
  - the kext entry
  - whether the files are in the EFI
  - a probe and the final SSDTs enabled at the same time

Attach the file to the [forum thread](https://osxinfo.net/konu/kbcolor-hackintosh-dizustuler-icin-klavye-isigi-ve-fan-kontrolu-acpi-dokumunden-ssdt-hazirlayan-kurulum-yardimcisiyla-asus-tuf-acer-predator.33539/) or to a GitHub issue. From the command line:

```bash
"KBColor Kurulum.app/Contents/MacOS/KBColorKurulum" --diagnose [path/to/config.plist]
```

## Building

You need Xcode, or its command line tools, and a [MacKernelSDK](https://github.com/acidanthera/MacKernelSDK) checkout:

```bash
MACKERNELSDK=/path/to/MacKernelSDK ./build.sh
```

This builds `build/KBColor.kext`, `build/KBColor.app` and `build/KBColor Kurulum.app`. The setup assistant bundles the kext, the app, and `iasl` and `acpiexec` from [ACPICA](https://github.com/acpica/acpica), taken from `/usr/local/bin` or `$ACPICA_BIN`.

There is also a command line mode for testing:

```bash
"build/KBColor Kurulum.app/Contents/MacOS/KBColorKurulum" --test-analysis
```
```bash
"build/KBColor Kurulum.app/Contents/MacOS/KBColorKurulum" --cli <dump folder> <output folder> [--discover] [--offsets COLOR,LEVEL,MAX]
```

## Status

- The Acer and ASUS paths are tested end to end from real dumps through the CLI, including `acpiexec` validation.
- The live part of discovery (probe, snapshots, write tests) and Acer's SMI-based fan / Turbo LED calls still need confirmation on real hardware.
- Lighting effects exist only where the firmware provides them (Acer). The ASUS TUF EC has a static colour only.

## Credits

- [ACPICA](https://github.com/acpica/acpica): `iasl` and `acpiexec`, under the BSD-3-Clause / GPL-2.0 dual license. See `tools/ACPICA-LICENSE.txt`.
- The Acer fan behaviour values follow the Linux `acer-wmi` driver.
- [MacKernelSDK](https://github.com/acidanthera/MacKernelSDK) by Acidanthera.
