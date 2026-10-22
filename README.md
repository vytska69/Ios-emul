# iOS Emul

iOS/iPadOS programa, kuri importuoja iPhone / iPad / iPod `.ipsw` failą, jį išanalizuoja, parenka
tinkamą emuliuojamą mašiną ir paleidžia ją per QEMU, o svečio ekraną rodo programoje (VNC) su
lietimo įvestimi.

## Ką palaiko (ir ko ne)

Universalaus „bet kurio IPSW“ emuliatoriaus nėra ir negali būti be darbo kiekvienam SoC: kiekvienam
Apple lustui reikia atskirai emuliuoti pertraukimų valdiklį (AIC), laikmačius, PMGR, SEP, NVMe/NAND
ir ekrano grandinę. Todėl programa veikia per **backend'us**: kiekvienas IPSW gauna suderinamumo
ataskaitą su konkrečia priežastimi, kodėl jis paleidžiamas ar ne.

| Backend | Įrenginiai | iOS | Šaltinis |
|---|---|---|---|
| `inferno-t8030` | iPhone 11 (A13); 11 Pro / Pro Max / SE 2 eksperimentiškai | 14 palaikoma; 13, 15–18, 26 eksperimentinės | [QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon), modifikuotas |
| `inferno-s8000` | iPhone 6s / 6s Plus (A9) | 9–15 eksperimentinės | QEMUAppleSilicon, modifikuotas |
| `qemu-ios` | iPod touch 1G / 2G | iPhoneOS 1.x–2.x | [devos50/qemu-ios](https://github.com/devos50/qemu-ios) |

Visi kiti IPSW (A14+, M serijos iPad'ai ir t. t.) importuojami ir išanalizuojami, bet pažymimi
„Unsupported“ su paaiškinimu. Naują mašiną galima pridėti įgyvendinus `EmulatorBackend` ir
užregistravus ją `BackendRegistry`.

## Struktūra

```
Sources/IPSWKit/       IPSW analizė: ZIP64 skaitytuvas, BuildManifest/Restore.plist,
                       IMG4/IM4P (DER), LZFSE ir LZSS dekompresija, įrenginių/SoC bazė
Sources/EmulatorKit/   Backend'ai, suderinamumo ataskaita, hardware padengimas, QEMU paleidimas, VNC
Sources/ipsw-emu/      CLI: inspect / boot (naudoja boot testų CI)
qemu/patches/          Patch'ai Inferno QEMU (iOS embedding: shared lib + libucontext)
App/IOSEmul/           SwiftUI programa (biblioteka, IPSW informacija, VM ekranas)
scripts/build-qemu-ios.sh  Patch'into Inferno kryžminis kompiliavimas iOS'ui (per UTM dependency skriptą)
scripts/dt-survey.py   DeviceTree hardware inventorius iš IPSW be viso failo parsisiuntimo
project.yml            XcodeGen projekto aprašas
```

## Be kompiuterio

- **Įdiegimas:** GitHub Actions workflow `IPA` sukompiliuoja QEMU iOS'ui ir programą į `IOSEmul.ipa`
  (artefaktas). Ją telefone įsidiegsi per TrollStore arba SideStore.
- **iOS įdiegimas į VM:** numatytas režimas „Install directly“ IPSW root failų sistemą (APFS
  atvaizdą) įrašo tiesiai į virtualų NVMe diską ir bootina be restore, todėl `idevicerestore` ir
  kompiuterio nereikia. Restore per ramdisk lieka kaip alternatyva.

## Matavimas: kiek toli bootina

- `Boot test` workflow parsisiunčia tikrus IPSW, bootina juos per `ipsw-emu` ir suvestinėje parodo
  toliausiai pasiektą etapą (XNU → IOKit → root → launchd → SpringBoard) ir panic'o eilutę.
- `DeviceTree survey` workflow iš kiekvieno SoC naujausio IPSW per HTTP range nuskaito tik
  DeviceTree ir išsaugo hardware inventorių `research/devicetrees/`. Pagal jį rašomos naujos mašinos.
- `ipsw-emu inspect <ipsw>` parodo suderinamumą ir hardware padengimą lokaliai (macOS).

## Kompiliavimas

Reikia macOS su Xcode 15+.

```sh
swift test                       # IPSWKit / EmulatorKit testai
brew install xcodegen
scripts/build-qemu-ios.sh        # QEMU fork'ai → App/Frameworks (ilgai trunka)
xcodegen generate
open IOSEmul.xcodeproj
```

`scripts/build-qemu-ios.sh --tci` sukompiliuoja TCG interpretatorių vietoj JIT: veikia be JIT
leidimo, bet ~5–10 kartų lėčiau.

## Apribojimai, kuriuos reikia žinoti

- **JIT.** iOS neleidžia vykdomosios atminties be specialių teisių. Greitam QEMU reikia programą
  įdiegti su development profiliu ir paleisti su JIT įjungikliu (debugger, SideStore/AltJIT,
  TrollStore). Kitaip naudokite `--tci` versiją.
- **Vienas VM per paleidimą.** QEMU laiko globalią būseną, o iOS neleidžia kurti procesų, todėl po
  VM sustabdymo programą reikia paleisti iš naujo.
- **Failai, kurių nėra IPSW.** SEP ROM, iPod boot ROM ir AP ticket'as gaunami iš savo įrenginio ar
  įrankių; programa juos leidžia pasirinkti ir paaiškina, kam jie reikalingi.
- **Restore.** Pirmas Inferno paleidimas bootina restore ramdisk; pačiam iOS įdiegimui į virtualų
  NVMe reikia paleisti `idevicerestore` iš kompiuterio per USB-over-TCP (žr. Inferno dokumentaciją).
- Naudokite tik savo teisėtai turimą programinę įrangą ir laikykitės Apple licencijos sąlygų.
- Apple mašinų modeliai paimti iš QEMUAppleSilicon (GPLv3/AGPLv3) ir modifikuoti patch'ais iš
  `qemu/patches/inferno/`. Tai išvestinis build'as: pagal upstream branding sąlygas jame nėra jų
  paveikslėlio ir „ChefKiss Inferno“ pavadinimo, o šis projektas nėra su ChefKiss susijęs ar jų remiamas.
