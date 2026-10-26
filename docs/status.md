# Būsena

Kiekvienas IPSW matuojamas tuo pačiu keliu: branduolys, IOKit, sistemos diskas, launchd,
SpringBoard. `Boot test` workflow tai daro macOS CI su tikrais IPSW, o programa telefone eina tuo
pačiu keliu.

## Įrenginiai

| Įrenginys, iOS | Kur pasiekia | Kas stabdo |
|---|---|---|
| iPhone 11 (A13), 14.0, tiesioginis įdiegimas | Sąrankos ekranas „Hello“. Pirmas startas trunka apie 20 min., po perkrovimo – 2–20 min. | Sąranka (žr. žemiau) |
| iPhone 11, 14.0, restore režimas | Restore ramdisk iki `launchd` | Reikia restore šeimininko (USB per TCP) |
| iPhone 6s / 6s Plus (A9), 15.8 | IOKit: AIC, AES, SPI, I2C, PCIe, NVMe | „Kernel data abort“ po `AppleSynopsysMIPIDSIController::start` |
| iPhone XR (A12), 14.0, ant iPhone 11 mašinos | Mašina susikuria, MMU įsijungia | Panika `rtclock` inicializacijoje, dar prieš serial išvestį |
| iPod touch 1G / 2G | iPhoneOS 1.x–2.x tik macOS | `qemu-ios` dar nekompiliuojamas į IPA |

Telefone (iPhone 16e, iOS 27.2, JIT per StikDebug) iPhone 11 mašina pasiekia tą patį „Hello“ ekraną
kaip CI.

## Mašinos

| Backend | Įrenginiai | iOS |
|---|---|---|
| `inferno-t8030` | iPhone 11. Eksperimentiškai: 11 Pro / Pro Max / SE 2. iPhone XR tik su `--force-backend` | Išbandyta 14. Eksperimentiškai: 13, 15–18, 26 |
| `inferno-s8000` | iPhone 6s / 6s Plus, visada 2 GB RAM | Eksperimentiškai: 9–15. 15.8 pasiekia IOKit |
| `qemu-ios` | iPod touch 1G / 2G | iPhoneOS 1.x–2.x, tik macOS |

## iPhone 11, iOS 14: atviri klausimai

- **Sąranka.** `SetupDone` sąrankos nepraleidžia, nes emuliuotas iPhone neaktyvuotas.
  `BYSetupAssistantNeedsToRun` (SetupAssistant.framework) pirmiausia tikrina `ForceNoBuddy`, todėl
  „Skip setup“ įrašo ir jį. CI patikrinimas dar vyksta.
- **Lietimai.** Lietimo ekranas (Inferno `mt-spi`) prijungtas, ir QEMU jį laiko absoliučia pele.
  Telefone bakstelėjimai veikia. CI matavime perbraukimas aukštyn „Hello“ ekrano dar nepakeitė
  (`scripts/ci-touch-test.py`).
- **Mygtukai.** Inferno mygtukus skaito tik iš F klavišų: F3 ir F4 – garsas, F5 – šoninis,
  F6 – Home. Šoninis mygtukas iOS pasiekia.
- **Reta panika.** Maždaug 1 iš 8 antrų startų baigiasi „Kernel data abort“ ties
  `AppleANS2NVMeController::start`. Priežastis dar nežinoma.
- **Interpretatorius telefone uždaro programą.** CI jis veikia.
- **Greitis.** ~78 % laiko CPU praleidžia branduolyje, ~22 % – vartotojo erdvėje. Apie trečdalis
  mėginių – laukimas (`wfi`). Brangiausia dalis – iOS programinis ekrano piešimas.

## Kaip tiesioginis įdiegimas pasiekia userland

iOS įrašoma tiesiai iš IPSW. Išskleidžiamas UDIF atvaizdas, parašomas GPT su 4 KiB blokais, į APFS
konteinerį įrašomi Preboot, xART ir Data tomai, o `fstab` pritaikomas. Pirmame starte:

- **Effaceable** (patch 0020). Tuščia saugykla laikoma suformatuota, todėl `mobile_obliterator`
  įrašo `BAG1` ir `Dkey` lockerius.
- **Data tomas.** Jis yra 1 slot'e (`disk0s1s2`), kaip tikrame iPhone.
- **Data šifravimas.** iOS naują Data tomą kuria su SEP media raktu (AKS ref-key, SEP komanda 0x22).
  Simuliuotas SEP to nemoka, todėl pirmame starte Data prijungiamas mount-phase-1
  (`vol.fs_passno` 1 DeviceTree fstab'e). Tada trynimas tomo nenaikina, o sukuria katalogus ir
  `systembag.kb`.
- **NVRAM** (patch 0022). `oblit-inprogress` nustatomas tik pirmam startui.
- **Spinlock'ai.** Be `slto_us=100000000` userland'e kyla „Ticket spinlock timeout“ panika.
- **Kas išjungta.** Kad startas būtų greitesnis, išjungti `datamigrator` ir `CommCenter` (modemo
  nėra), o SpringBoard watchdog'as nebežudo lėtai startuojančių procesų.

Ekranas. Be AGX GPU nėra nei Metal, nei OpenGL ES, todėl QuartzCore piešia `CA::OGL::SWContext`.
Įdiegimas pataiso 5 dyld shared cache instrukcijas (`Sources/EmulatorKit/SharedCachePatches.swift`):

- MobileIcons ikonas mažina be CoreImage;
- CoreImage veikia be OpenGL ES;
- AsynchronousDispatcher apsieina be `stop_timer`;
- ekrano paviršiai kuriami be AGX suspaudimo (`&BGA`).

Kiekviena pataisa prieš įrašymą tikrina originalius baitus.

Simuliuotas SEP neatsako į dalį AppleSEPKeyStore komandų: 0x22 (ref-key), 0x2A, 0x4D ir 0x0B.
