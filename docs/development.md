# Kūrimas

## Struktūra

```
Sources/IPSWKit/       IPSW: ZIP64, BuildManifest, IMG4/IM4P, LZFSE/LZSS, DeviceTree, UDIF, GPT,
                       APFS skaitymas ir tomų rašymas
Sources/EmulatorKit/   Backend'ai, suderinamumas, padengimas, QEMU paleidimas, VNC, shared cache
                       pataisos, emuliuoto iOS nustatymai
Sources/ipsw-emu/      CLI
App/IOSEmul/           SwiftUI programa
qemu/patches/inferno/  QEMUAppleSilicon patch'ai
qemu/keymaps/          QEMU VNC klaviatūros išdėstymai
scripts/               QEMU build'ai, SideStore šaltinis, CI analizės įrankiai
research/devicetrees/  13 SoC DeviceTree inventoriai
distribution/          Ikona ir whats-new.md
.github/workflows/     ci, ipa, boot-test, rootfs-probe, dt-survey
```

## Kompiliavimas

Reikia macOS su Xcode 16.

```sh
swift test
brew install xcodegen
scripts/build-qemu-ios.sh                                       # JIT QEMU → App/Frameworks
QEMU_IOS_OUT=build-qemu-tci-out scripts/build-qemu-ios.sh --tci   # interpretatorius
xcodegen generate && open IOSEmul.xcodeproj
```

IPA workflow abu QEMU sudeda į vieną IPA. Interpretatorius įdedamas kaip
`qemu-aarch64-softmmu-tci.framework`, o `QEMURunner` variklį pasirenka paleidimo metu.

## Pakeitimų žurnalas

Jei pakeitimas pasiekia programą (`App/`, `Sources/IPSWKit`, `Sources/EmulatorKit`, `qemu/`),
tame pačiame commit'e įrašyk eilutę į [`distribution/whats-new.md`](../distribution/whats-new.md).
Rašyk paprastai: ką vartotojas pastebės, o ne kaip tai padaryta. Tos pačios dienos pakeitimai eina
po vienu `## YYYY-MM-DD`, o nauja diena pradedama viršuje. IPA workflow naujausius skyrius parodo
SideStore „What's New“ ir Rolling release puslapyje. CI, testų ir dokumentacijos pakeitimai ten
nerašomi.

## CLI

```sh
ipsw-emu inspect firmware.ipsw                                  # identitetai, suderinamumas, padengimas
ipsw-emu dt firmware.ipsw --product iPhone12,1 --path /arm-io   # DeviceTree mazgas
ipsw-emu boot firmware.ipsw --work vm --product iPhone12,1 --mode direct --seconds 600 \
  [--force-backend inferno-t8030] [--qemu-debug guest_errors] [--skip-setup 1] \
  [--monitor "info registers; x /16wx 0x…"] [--qemu-args "-accel tcg,split-wx=on"]
ipsw-emu apfs-add-volume disk.img --role data|preboot|xart …
ipsw-emu apfs-dump disk.img
```

`boot` mašiną paruošia lygiai taip pat, kaip programa. Tada QEMU veikia ne ilgiau nei `--seconds`.
Baigus išvedamas toliausias etapas, panika, visų CPU registrai ir `--monitor` komandų rezultatai.

## Boot test

`Boot test` workflow (Actions → Run workflow) bootina tikrus IPSW macOS'e. Įvestys:

- `product`, `versions`, `modes` (`direct`, `auto`);
- `force_backend`;
- `qemu_debug` (pvz., `guest_errors` arba `trace:pci_nvme_io_cmd`);
- `seconds`;
- `monitor`: QEMU monitoriaus komandos, paleidžiamos pasibaigus laikui;
- `qemu_args`;
- `after`: shell komandos po boot'o;
- `tci`: interpretatoriaus build'as, kaip telefone be JIT.

Pagalbiniai scenarijai. Dauguma jų veikia tik macOS, kai QEMU jau sustojęs:

| Scenarijus | Ką daro |
|---|---|
| `ci-mount-volume.sh` | Prijungia vieną emuliuoto disko APFS tomą tik skaitymui |
| `ci-guest-log.sh` | Emuliuoto iOS unified log (`log show` su predikatu) |
| `ci-dsc-disass.sh` | dyld shared cache: funkcijų disasembleris, eilutės, xref'ai, simboliai |
| `ci-patch-dsc.sh` | Bandomieji shared cache pataisymai diske |
| `ci-kernel-disass.sh` | Branduolio kodas aplink adresus (mašina bootina su `kaslr-off`) |
| `ci-symbolicate-stackshot.sh` | iOS crash ir stackshot ataskaitų simbolizavimas |
| `ci-sample-pc.py` | Kas pusę sekundės renka CPU būseną (EL0, EL1, laukimas) ir dažniausius PC |
| `ci-touch-test.py` | Lietimai per VNC kaip programoje, `screendump`, ekrano pokyčio matavimas su ASCII vaizdu |
| `xref.py` | Branduolio kodas, kuris skaito ar rašo kintamąjį `pmemsave` atminties kopijoje |
| `adt.py` | Neapdorotas Apple DeviceTree |
| `dt-survey.py`, `gen-inferno-coverage.py` | DeviceTree inventoriai ir padengimo lentelė |

## QEMU patch'ai

Bazė: QEMUAppleSilicon, `INFERNO_REV` iš `scripts/build-qemu-ios.sh`.

| # | Ką daro |
|---|---|
| 0001, 0008 | QEMU kaip biblioteka iOS (UTM pagrindu), libucontext |
| 0002, 0006, 0007 | Simuliuotas SEP: be duomenų šifravimo, iš anksto įkeltas SEPOS, pranešimų žurnalas |
| 0003 | Išvestinio build'o debranding'as |
| 0004, 0005 | iOS JIT rašymo apsauga, `statfs` antraštės |
| 0009 | T8030 NVRAM kintamieji (`nvram-vars`) |
| 0010–0014 | A12 DeviceTree T8030 mašinoje: DART, PCIe SID, MIPI DSI, APRR registrai, CPU mazgai |
| 0015 | ANS NVMe „tunnel“ komandų žurnalas |
| 0016 | iOS 26+ (TXM) JIT per StikDebug `brk #0xf00d` |
| 0017–0019 | Interpretatoriaus build'as: `Int128` dydis, 128 bitų atomikai, be disasemblerio |
| 0020 | Tuščia effaceable saugykla laikoma suformatuota (iOS 14) |
| 0021 | SEP simuliatoriaus žurnale – AppleSEPKeyStore užklausų baitai |
| 0022 | `nvram-vars` galioja tik pirmam startui |
| 0023 | SEP simuliatorius: įrenginys „atrakintas nuo paleidimo, be kodo“, be keybag'o įrašymo ciklo |
| 0024 | Ekrano valdiklis (ADP v4): 60 Hz vsync ir be prisijungusio VNC kliento |
| 0025 | „none“ garso išvestis kaupia guest'o garsą žiede, iš kurio programa groja per AVAudioEngine (`qemu_ios_audio_read`) |
| 0026 | Lietimo ekranas: koordinatės apribojamos jutiklio ribomis (apatinio krašto lietimai buvo už ekrano) |
| 0027 | Lietimo ekrano srautas `-d guest_errors` žurnale (`MT-SPI:`): HBPP, feature report'ai, paketai, pirštų pėdsakai |
