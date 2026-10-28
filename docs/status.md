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
Įdiegimas pataiso dyld shared cache instrukcijas (`Sources/EmulatorKit/SharedCachePatches.swift`):

- MobileIcons ikonas mažina be CoreImage;
- CoreImage veikia be OpenGL ES;
- AsynchronousDispatcher apsieina be `stop_timer` ir Metal renderer'io (`release_iosurface`);
- ekrano paviršiai kuriami be AGX suspaudimo (`&BGA`);
- MobileKeyBag ir SpringBoardFoundation praneša, kad slaptažodžio nėra.

Kiekviena pataisa prieš įrašymą tikrina originalius baitus.

Simuliuotas SEP neatsako į dalį AppleSEPKeyStore komandų: 0x22 (ref-key), 0x2A, 0x4D ir 0x0B.
