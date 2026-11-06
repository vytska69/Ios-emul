# Būsena

Kiekvienas IPSW matuojamas tuo pačiu keliu: branduolys, IOKit, sistemos diskas, launchd,
SpringBoard. `Boot test` workflow tai daro macOS CI su tikrais IPSW, o programa telefone eina tuo
pačiu keliu.

## Įrenginiai

| Įrenginys, iOS | Kur pasiekia | Kas stabdo |
|---|---|---|
| iPhone 11 (A13), 14.0, tiesioginis įdiegimas | Su „Skip setup“: pagrindinis ekranas, atsidaro programėlės (pirmas startas apie 8 min.). Be jo: sąrankos ekranas „Hello“ (pirmas startas apie 20 min., po perkrovimo – 2–20 min.) | Garsas, Wi-Fi, greitis (žr. žemiau) |
| iPhone 11, 14.0, restore režimas | Restore ramdisk iki `launchd` | Reikia restore šeimininko (USB per TCP) |
| iPhone 6s / 6s Plus (A9), 15.8 | IOKit: AIC, AES, SPI, I2C, PCIe, NVMe | „Kernel data abort“ po `AppleSynopsysMIPIDSIController::start` |
| iPhone XR (A12), 14.0, ant iPhone 11 mašinos | Mašina susikuria, MMU įsijungia | Panika `rtclock` inicializacijoje, dar prieš serial išvestį |
| iPod touch 1G / 2G | iPhoneOS 1.x–2.x tik macOS | `qemu-ios` dar nekompiliuojamas į IPA |

Telefone (iPhone 16e, iOS 27.2, JIT per StikDebug) iPhone 11 mašina pasiekia tą patį kaip CI: su
„Skip setup“ atsidaro pagrindinis ekranas ir Settings programėlė.

## Mašinos

| Backend | Įrenginiai | iOS |
|---|---|---|
| `inferno-t8030` | iPhone 11. Eksperimentiškai: 11 Pro / Pro Max / SE 2. iPhone XR tik su `--force-backend` | Išbandyta 14. Eksperimentiškai: 13, 15–18, 26 |
| `inferno-s8000` | iPhone 6s / 6s Plus, visada 2 GB RAM | Eksperimentiškai: 9–15. 15.8 pasiekia IOKit |
| `qemu-ios` | iPod touch 1G / 2G | iPhoneOS 1.x–2.x, tik macOS |

## iPhone 11, iOS 14: atviri klausimai

- **Sąranka.** Vien `SetupDone` sąrankos nepraleidžia: jei `SetupVersion` ≤ 10,
  `Internal_BYSetupAssistantNeedsToRun` rodo „upgrade mini buddy“, t. y. tą patį „Hello“.
  `ForceNoBuddy` skaitomas tik vidiniuose Apple build'uose. Todėl „Skip setup“ įrašo
  `SetupVersion = 11` ir pataiso tris SetupAssistant funkcijas, kad jos grąžintų NO
  (`SharedCachePatches.skipSetupByBuild`). CI tai veikia: iOS išsiunčia
  `com.apple.purplebuddy.setupdone`, ir rodomas užrakinimo ekranas.
- **Lietimai veikia (CI).** iOS 14 `AppleGenericMultitouchDecider` be autentifikacijos
  koprocesoriaus paleidžia `agm-secondary` tvarkyklę `AppleGenericMultitouchHIDSPI`, kurios
  startas su Inferno `mt-spi` nepavyksta. Tiesioginis įdiegimas DeviceTree'e `agm-secondary`
  pakeičia į `AppleHIDTransportDeviceSPI`. Ši tvarkyklė valdiklio programinę įrangą gauna iš
  `fud` (AppleFirmwareUpdateKext, žymė `mtfw`), todėl įdiegimas Preboot tome įrašo
  `usr/standalone/firmware/FUD/Multitouch.img4` (IPSW IM4P be manifesto). Nepersonalizuotą
  vaizdą branduolys priima su `skipFWValidation=1` ir trimis `KernelPatches`: argumentas taikomas
  visoms užklausoms, o AIDImageDownloader XML skaito už IMG4 antraščių. Pataisų vietas programa
  randa pati pagal greta esančias branduolio eilutes, todėl jos nepririštos prie build'o.
  Tada HBPP įkelia programinę įrangą, valdiklis praneša „Device ready“, ir perbraukimas aukštyn
  atidaro pagrindinį ekraną. Kalibravimo (`multi-touch-calibration`) nėra, tvarkyklė naudoja
  numatytąjį. VNC klientas turi atsiųsti SetEncodings, kitaip QEMU pelę laiko santykine.
- **Slaptažodis (išspręsta).** Simuliuoto SEP keystore praneša užrakto būseną, kuri nėra 3
  („disabled“, t. y. slaptažodžio nėra), todėl SpringBoard (`-[SBFMobileKeyBag
  _queue_setHasPasscodeIfNecessary:]`) manė, kad slaptažodis nustatytas. MobileKeyBag
  `MKBGetDeviceLockState` ir `MKBGetDeviceLockStateInfo` dabar grąžina 3, o SpringBoardFoundation
  slaptažodžio nežymi; perbraukimas aukštyn atidaro pagrindinį ekraną.
- **Sąranka be „Skip setup“ (išspręsta).** Po perbraukimo „Hello“ ekrane `backboardd` lūždavo
  QuartzCore `AsynchronousDispatcher::stop_timer` ir `release_iosurface`, nes be Metal
  `renderer()` yra null. Abi vietos pataisytos.
- **Garsas (iOS pusė veikia; galutinai patikrinti programoje).** Inferno garso mazgai paliekami
  DeviceTree'e (patch'ai 0031–0032). Kodeko DSP programinė įranga (`AudioCodecFirmware`, 'acfw')
  dedama į Preboot FUD; branduolys ją skaito praleisdamas IMG4 antraštes ir laukia jos 60 s, ne
  2 s. VirtualAudio (APFS suspaustas failas; pataisomas per `CompressedFilePatch`): įrenginiai
  įsileidžiami prieš pirmą maršrutą, inicializacija nebenutrūksta nepavykus maršrutui,
  „Application Processor“ prievadas (`pap `) prijungiamas, o papildomi VAD, kuriems reikia
  nesamos aparatūros (haptika `pact`, AOP mikrofonas `phki`), laikomi neprivalomais. Tada
  sukuriamas numatytasis VAD, o MCA gauna garsą (CI: „tx dma … peak 4244“). MCA (patch 0035) garsą
  siunčia į QEMU audio nepriklausomai nuo įrašymo kanalo, 48 kHz.
- **Disko vieta (išspręsta).** IPSW atvaizdo APFS konteineris yra 8 GB (laisvos vietos likdavo
  ~200 MB). Įdiegimas jį išplečia per visą 32 GiB NVMe skaidinį (`APFSContainer.grow`): naujos
  blokų grupės pridedamos laisvos, o vidinė sritis (internal pool, kurioje laikomi blokų sąrašai
  ir žemėlapiai) perkeliama ir padidinama iki 3 × (grupių + sąrašų) blokų, kaip ją išdėsto
  `newfs_apfs`. `fsck_apfs` erdvės tvarkyklę priima, Data tome laisva ~25 GB.
- **Mygtukai.** Inferno mygtukus skaito tik iš F klavišų: F3 ir F4 – garsas, F5 – šoninis,
  F6 – Home. Šoninis mygtukas iOS pasiekia.
- **Reta panika.** Maždaug 1 iš 8 antrų startų baigiasi „Kernel data abort“ ties
  `AppleANS2NVMeController::start`. Priežastis dar nežinoma.
- **Interpretatorius telefone uždaro programą.** CI jis veikia.
- **Greitis.** Ramiai: ~71 % mėginių branduolyje, ~26 % vartotojo erdvėje, ~38 % – laukimas
  (`wfi`). Tempiant pagrindinį ekraną (CI, `scripts/ci-fps.py`): 3–6 kadrai/s, o be lietimo
  ekranas perpiešiamas 16–25 kartus per sekundę. Tempiant piešimas užima didelę vartotojo erdvės dalį: be
  hiperkvietimų dar lieka CoreAnimation rastrizatoriaus karkasas (`scanline`, `sample_texture`,
  `scan_convert`, apie 9 %) ir `circle_sampler`. QEMU pusėje (patch'ai 0061–0092):
  - be BQL: laikrodžiai, IPI būsena, ERET, užmaskuoti pertraukimai, sinchroninės išimtys,
    laikmačių registrai (0061–0066); `wfe`/`yield` neišeina iš `cpu_exec` (0074);
  - TB paieška (`QEMU_JC_STATS=1` skaičiuoja): branduolio kodo šuoliai tarp puslapių sujungiami
    tiesiai (0069), šuolių podėlis nebeišvalomas kiekvieną kartą, kai TB invaliduojamas (0071);
    kartu su `QEMU_STABLE_CHAIN_USER=1` (0070, bibliotekoms) – apie trečdaliu mažiau paieškų;
  - netiesioginiai šuoliai (`br`, `blr`, `ret`, `retab`…) šuolių podėlį tikrina pačiame sugeneruotame
    kode ir helperio nekviečia, kai pataiko (0085, `QEMU_INLINE_LOOKUP=0` išjungia): hosto `sample` A/B
    tempiant – TB paieškos dalis 26 % → 16 %;
    abu podėlio keliai tikrinami tiesiai (0086); Apple CPU modelis be BTI, kurio A12–A14 neturi (0087,
    `QEMU_APPLE_BTI=1` grąžina): dingo `guarded_page_check`/`guarded_page_br` helperiai (~2 % hosto laiko);
  - GXF dvigubi EL1 registrai (`TPIDR`, `ELR`, `SPSR`, `ESR`, `FAR`) skaitomi/rašomi tiesiai iš
    sugeneruoto kodo be `lookup_cp_reg` + `get_cp_reg64` (0088, `QEMU_GXF_DIRECT=0` išjungia);
  - vartotojo TLB perjungiant TTBR0 nebeišmetamas: iki 8 adresų erdvių TLB laikomi atskirai ir
    grąžinami (0089, `QEMU_ASID_TLB=0` išjungia), o TLB nebesusitraukia žemiau 4096 įrašų (0091,
    `QEMU_TLB_MIN_BITS`); `QEMU_ASID_TLB_STATS=1` (0090) skaičiuoja: vartotojo TLB užpildymų
    vienam perjungimui 135 → 99 (minimumas) → 62 (su laikomais TLB);
  - išbandyta ir išjungta pagal nutylėjimą (A/B nebuvo greičiau): pertraukimų priėmimas be BQL
    (0067, `QEMU_IRQ_TAKE_NOBQL=1`), TLBI su patvirtinimu (0072, `QEMU_TLBI_ACK=1`), grįžimas į
    `cpu_exec` be BQL po „kick“ (0075, `QEMU_MTTCG_FAST=1`); didesnis šuolių podėlis (0073)
    atšauktas – daugiau nepataikymų.

  CI kompiuteriai (3 branduoliai, 4 emuliuoti procesoriai) labai triukšmingi: to paties paleidimo
  įkrova svyruoja 400–650 s, todėl sprendžiama tik pagal A/B tame pačiame darbe.

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
- **Kas išjungta.** Kad startas būtų greitesnis, išjungtas `CommCenter` (modemo nėra), o
  SpringBoard watchdog'as nebežudo lėtai startuojančių procesų. `datamigrator` išjungiamas tik tada,
  kai pašalinamos programos nediegiamos (jas įdiegia jo `SystemAppMigrator`).

Ekranas. Be AGX GPU nėra nei Metal, nei OpenGL ES, todėl QuartzCore piešia `CA::OGL::SWContext`.
Įdiegimas pataiso dyld shared cache instrukcijas (`Sources/EmulatorKit/SharedCachePatches.swift`):

- MobileIcons ikonas mažina be CoreImage;
- CoreImage veikia be OpenGL ES;
- AsynchronousDispatcher apsieina be `stop_timer` ir Metal renderer'io (`release_iosurface`);
- ekrano paviršiai kuriami be AGX suspaudimo (`&BGA`);
- MobileKeyBag ir SpringBoardFoundation praneša, kad slaptažodžio nėra.

Kiekviena pataisa prieš įrašymą tikrina originalius baitus.

Simuliuotas SEP neatsako į dalį AppleSEPKeyStore komandų: 0x22 (ref-key), 0x2A, 0x4D ir 0x0B.
