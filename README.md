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
| `inferno-t8030` | iPhone 11 (A13); 11 Pro / Pro Max / SE 2 eksperimentiškai | 14 palaikoma; 13, 15–18, 26 eksperimentinės | [ChefKiss Inferno](https://github.com/ChefKissInc/QEMUAppleSilicon) |
| `inferno-s8000` | iPhone 6s / 6s Plus (A9) | 9–15 eksperimentinės | Inferno |
| `qemu-ios` | iPod touch 1G / 2G | iPhoneOS 1.x–2.x | [devos50/qemu-ios](https://github.com/devos50/qemu-ios) |

Visi kiti IPSW (A14+, M serijos iPad'ai ir t. t.) importuojami ir išanalizuojami, bet pažymimi
„Unsupported“ su paaiškinimu. Naują mašiną galima pridėti įgyvendinus `EmulatorBackend` ir
užregistravus ją `BackendRegistry`.

## Struktūra

```
Sources/IPSWKit/       IPSW analizė: ZIP64 skaitytuvas, BuildManifest/Restore.plist,
                       IMG4/IM4P (DER), LZFSE ir LZSS dekompresija, įrenginių/SoC bazė
Sources/EmulatorKit/   Backend'ai, suderinamumo ataskaita, QEMU paleidimas, VNC klientas
App/IOSEmul/           SwiftUI programa (biblioteka, IPSW informacija, VM ekranas)
scripts/build-qemu-ios.sh  QEMU fork'ų kryžminis kompiliavimas iOS'ui kaip framework'ų
project.yml            XcodeGen projekto aprašas
```

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
