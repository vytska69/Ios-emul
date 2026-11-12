# Būsena

Kiekvienas IPSW matuojamas tuo pačiu keliu: branduolys, IOKit, sistemos diskas, launchd,
SpringBoard. `Boot test` workflow tai daro macOS CI su tikrais IPSW, o programa telefone eina tuo
pačiu keliu.

## Įrenginiai

| Įrenginys, iOS | Kur pasiekia | Kas stabdo |
|---|---|---|
| iPhone 11 (A13), 14.0, tiesioginis įdiegimas | Su „Skip setup“: pagrindinis ekranas, programėlės, valdymo centras, Spotlight, garsas (CI: ekranas per ~6–8 min.). Be jo: sąrankos ekranas „Hello“ | Greitis, garso traškesiai, tinklo nėra (žr. žemiau) |
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
- **Garsas (veikia; traškesiai, kai emuliacija vėluoja).** Inferno garso mazgai paliekami
  DeviceTree'e (patch'ai 0031–0032). Kodeko DSP programinė įranga (`AudioCodecFirmware`, 'acfw')
  dedama į Preboot FUD; branduolys ją skaito praleisdamas IMG4 antraštes ir laukia jos 60 s, ne
  2 s. VirtualAudio (APFS suspaustas failas; pataisomas per `CompressedFilePatch`): įrenginiai
  įsileidžiami prieš pirmą maršrutą, inicializacija nebenutrūksta nepavykus maršrutui,
  „Application Processor“ prievadas (`pap `) prijungiamas, o papildomi VAD, kuriems reikia
  nesamos aparatūros (haptika `pact`, AOP mikrofonas `phki`), laikomi neprivalomais. Tada
  sukuriamas numatytasis VAD, o MCA gauna garsą (CI: „tx dma … peak 4244“). MCA (patch 0035) garsą
  siunčia į QEMU audio nepriklausomai nuo įrašymo kanalo, 48 kHz. CI įraše (`wavcapture`) skambučio
  melodija girdima visa. iOS garso žiedas trumpas (~18 ms ratas), todėl kai emuliuotas iOS vėluoja,
  dalis blokų būna dar neužpildyti: jie praleidžiami su 1,3 ms perėjimu (0103). Įrenginio sustabdymas
  ar vėlesnis skaitymas (0099–0102) iOS garsą nutraukdavo, todėl išjungti. Programa telefone garsą
  kaupia buferyje ir groja tokiu greičiu, kokiu iOS jį gamina (laiko tempimas be tono pokyčio).
  AudioToolbox `override_iobuffer_duration` (com.apple.coreaudio) išbandytas: 100 ms traškesių
  nesumažino, su 50 ms garso nebuvo visai.
- **Garsas per USB (bandoma).** Vietoj MCA iOS gali groti į QEMU `usb-audio` (USB host režimu,
  `-device usb-audio,bus=usb-bus.1,port=1`). Taip garsą stumia pati iOS, kaip vphone-cli virtio-snd,
  todėl neužpildytų blokų nėra. Reikėjo: xHCI „Set Latency Tolerance“ komandos (0115), pavėluotų
  izochroninių TD vykdymo iš karto (0116) ir branduolio pataisų `AppleUSBXHCIIsochronousRequest::link`
  (lėtai paruošta TD grandinė nebeišmetama kaip `kIOReturnIsoTooOld`). CI: iOS garsą nukreipia į
  USB įrenginį ir skambučio melodija groja, bet ateina tik ~230 iš 1000 paketų per sekundę
  (`QEMU_USB_AUDIO_STATS=1`, 0117): emuliuotas iOS nespėja ruošti 1 ms paketų, todėl melodija trumpa,
  o kartais srautas nutrūksta („immediate error on write“). Išbandyta ir nepadėjo: didesnis QEMU
  buferis (2 s), TD vykdymas iškart (0118, `QEMU_XHCI_ISO_ASAP=1`: iOS žiedas ištuštėja), USB 2.0
  `usb-audio,hs=on` su 4 ms paketais (0119: `AppleUSBAudio` tokio intervalo nepriima). Programoje
  garsas lieka per MCA. Klaviatūra ir USB garsas kartu dar neveikia: pro QEMU `usb-hub` iOS
  įrenginių neatpažįsta.
- **Disko vieta (išspręsta).** IPSW atvaizdo APFS konteineris yra 8 GB (laisvos vietos likdavo
  ~200 MB). Įdiegimas jį išplečia per visą 32 GiB NVMe skaidinį (`APFSContainer.grow`): naujos
  blokų grupės pridedamos laisvos, o vidinė sritis (internal pool, kurioje laikomi blokų sąrašai
  ir žemėlapiai) perkeliama ir padidinama iki 3 × (grupių + sąrašų) blokų, kaip ją išdėsto
  `newfs_apfs`. `fsck_apfs` erdvės tvarkyklę priima, Data tome laisva ~25 GB.
- **Mygtukai (šoninis veikia).** Inferno mygtukus skaito iš F klavišų: F3 ir F4 – garsas, F5 –
  šoninis, F6 – Home. SMC pranešimą `AppleSMCPMU::_smcNotifyCallout` paverčia HID įvykiu
  (1 → 0x0C/0x30, 2 → 0x0C/0xE9, 3 → 0x0C/0xEA) ir perduoda paslaugai iš DeviceTree
  `function-pmu_button` (AppleM68Buttons). AppleM68Buttons pradinę būseną vieną kartą perskaito iš
  `bVUP`/`bVDN`/`bHLD` (1 = nuspaustas). Inferno jas grąžindavo apverstas, todėl iOS laikė visus
  mygtukus nuspaustus ir paspaudimų nepaisė. QEMU 0130: mygtukai skaitomi teisingai, o šoninis
  įjungimo metu laikomas nuspaustas ir atleidžiamas po 3 s. Be to iOS po įkrovos ekrano neįjungia
  („dark boot“: SpringBoard backlight factor 0, kol nepaspaustas šoninis). Dabar F5 užrakina ir
  pažadina ekraną, įkrova trunka kaip anksčiau. Garso mygtukai keičia garsumą (iOS žurnale
  `Volume Change by delta '-0.062500' was Accepted`, garso langas pasirodo po ~1,5 s), ilgas
  šoninio paspaudimas kviečia Siri. Eksperimentams `QEMU_BUTTONS_FLIP` (0–5),
  žurnalas `QEMU_SMC_LOG=1`.
- **USB klaviatūra (veikia).** iOS USB prievadas veikia kaip host (`AppleEmbeddedUSBArbitrator-force-usbhost=1`),
  QEMU prijungia `usb-kbd`. Reikėjo: prievado maitinimo ir paleidimo branduolio pataisų,
  `IOUSBHostDevice::setConfigurationGated` srovės patikros praleidimo (skirstytuvas emuliuotame
  prievade niekada neatsako), QEMU 0110 (xHCI linijos 1–2 nebuvo nuleidžiamos, todėl kildavo
  pertraukimų audra ir „Spinlock timeout“ panika; prievado perkrovimas dabar trunka 10 ms) ir
  0112 (F1–F10 lieka mygtukams). Prijungus klaviatūrą, ekraninė klaviatūra dingsta, o raidės
  rašomos (CI: Spotlight „hellohi“). Išjungiama `--usb-keyboard 0` arba programos nustatymu.
- **Reta panika.** Maždaug 1 iš 8 antrų startų baigiasi „Kernel data abort“ ties
  `AppleANS2NVMeController::start`. Priežastis dar nežinoma.
- **„hw_lock_bit(): timed out“ (pataisyta).** `hw_lock_bit` ir `hw_lock_bit_nopreempt` užrakto laukia
  fiksuotą 0xc00000 tikų (0,52 s) laiką, ne `slto_us`. Kai hostas apkrautas, užraktą laikantis vCPU
  kartais tiek nevykdomas, ir įkrova baigdavosi panika (CPU 2, kviečiama iš 0xfffffff007a4ca68).
  Branduolio pataisa (`KernelPatches.swift`) visose 8 įterptose vietose `mov w2, #0xc00000` keičia į
  `#0xffff0000` (~3 min).
- **Interpretatorius telefone uždaro programą.** CI jis veikia.
- **Greitis.** Tempiant pagrindinį ekraną (CI, `scripts/ci-fps.py`): 3–6 kadrai/s iki 0085,
  ~6–9 kadrai/s dabar (CI labai triukšmingas); ekranas įsijungia per ~335–500 s. Hosto profilyje
  (`sample`, tempiant) didžiausios dalys: laukimas BQL (~20–25 %, laikas, ne CPU), sugeneruotas
  kodas (~20 %), MMU/TLB (~15 %), slankiojo kablelio helperiai (~10 %), TB paieška (~9 %).
  QEMU pusėje (patch'ai 0061–0133):
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
    grąžinami (0089, `QEMU_ASID_TLB=0` išjungia), o vartotojo TLB nebesusitraukia žemiau 4096 įrašų (0091, 0093 – tik vartotojo, kitaip įkrovoje užraktų laikas baigdavosi;
    `QEMU_TLB_MIN_BITS`); `QEMU_ASID_TLB_STATS=1` (0090) skaičiuoja: vartotojo TLB užpildymų
    vienam perjungimui 135 → 99 (minimumas) → 62 (su laikomais TLB);
  - ekrano atnaujinimas (`adp_v4_gfx_update`) nebelaukia, kol kiekvienas vCPU baigs TB
    (`run_on_cpu` po `snapshot_and_clear_dirty`; pagrindinė gija ten praleisdavo pusę laiko), o
    perpiešia ir ankstesniame kadre pakeistas eilutes (0094, `QEMU_ADP_SYNC=1` – kaip anksčiau);
  - laikomų TLB „dirty“ atstatymai kadrų buferiui kaupiami žurnale ir pritaikomi grąžinant (0095);
  - piešimo sampleriai (`affine`, `image_sampler_argb8`, `nearest`, `clamp`) kiekvienam pikselių srautui
    laiko paskutinio puslapio hosto rodyklę (0096): jų dalis hosto profilyje ~10 % → <1 %;
  - greitoji paieška ir tiesioginiams šuoliams į kitą puslapį (0097): lėtų paieškų 973 → 168 mln. (CPU0);
    vartotojo TLB išvalymas ar didelis vienos pusės intervalas išmeta tik tos pusės šuolių podėlio įrašus
    (0098): pilnų išvalymų 16962 → 346;
  - įdiegimas nustato Auto-Lock „Niekada“ (ManagedConfiguration `maxInactivity`), ekranas nebeužgęsta;
  - `wfe`/`yield` ciklas, besisukantis tame pačiame PC ilgiau nei 30 µs, kas kartą miega 20 µs (0104,
    `QEMU_WFE_SLEEP=0` išjungia): užrakto laikytojas gauna hosto branduolį; A/B abiem tvarkomis
    tempiant 4,4→6,1 ir 5,5→7,0 kadro/s;
  - vektorinis `float32` sudėjimas/atimtis/daugyba (`gvec_fadd_s` ir kt.) bendruoju atveju keturiomis
    juostomis hosto NEON, „inexact“ skaičiuojamas pačiame kelyje (0105–0106, `QEMU_FAST_FP=0` išjungia):
    `helper_gvec_fadd_s` profilyje 122 → 50;
  - garsas: kur vėluojanti dalis praleidžiama, 1,3 ms perėjimas vietoj šuolio (0103); laukti tos dalies
    (0101–0102, `QEMU_MCA_WAIT=1`) ar ją skaityti vėliau (0099, `QEMU_MCA_DELAY=1`) – iOS garsas nutrūkdavo;
  - šuolių podėlis 64K įrašų (0120; su 16K puslapiais maišos funkcija puslapiui skyrė tik 7 bitus),
    o TLB intervalo išvalymas virš 32 puslapių kelia tos pusės kartą užuot valęs po puslapį (0121):
    profilyje TB paieška 15,7 % → 11,6 %, `tlb_flush_range` 12,6 % → 0 %;
  - sisteminių registrų su patikra vykdymo metu aprašai (CNTVCT ir kt.) imami iš gijos podėlio, ne iš
    maišos lentelės (0126);
  - atidėtų IPI laikmatis (kas 64 µs, su BQL) veikia tik kai kuris nors IPI laukia, ne visą laiką
    (0131, `QEMU_IPI_TIMER_ALWAYS=1` grąžina): A/B abiem tvarkomis neutralu (3,8 prieš 3,8 ir 3,2 prieš
    3,8 kadro/s; antras paleidimas darbe dažniausiai greitesnis), bet mažiau pabudimų;
  - išbandyta ir išjungta pagal nutylėjimą (A/B nebuvo greičiau): `wfe` po `ldaxr` laukia, kol pasikeis
    užrakto žodis (0124, `QEMU_WFE_WATCH=1`; 5,7 prieš 5,6 ir 4,3 prieš 4,2 kadro/s), pertraukimų priėmimas be BQL
    (0067, `QEMU_IRQ_TAKE_NOBQL=1`), IPI siuntimo registrai be BQL (0132, `QEMU_IPI_RR_NOBQL=1`;
    lėčiau: 3,3 prieš 4,6 ir 3,5 prieš 4,5 kadro/s),
    laikmatis, kuris tik nusikelia vėliau, nežadina pagrindinio ciklo (0133, `QEMU_TIMER_LAZY_NOTIFY=1`;
    4 A/B po 15 raundų, vidurkis 3,24 prieš 3,99 kadro/s), TLBI su patvirtinimu (0072, `QEMU_TLBI_ACK=1`), grįžimas į
    `cpu_exec` be BQL po „kick“ (0075, `QEMU_MTTCG_FAST=1`); didesnis šuolių podėlis (0073)
    atšauktas – daugiau nepataikymų.

  `scripts/ci-fps.py` tempia tik į kairę ir atgal: tempiant į dešinę kartais atsidarydavo valdiklių
  puslapis su „Refreshed Widgets“ langu, ir likę raundai rodė 0 kadrų/s (taip buvo sugadintos kelios
  ankstesnės A/B medianos).

  Tame pačiame ekrane, toje pačioje būsenoje atskiri 10 s raundai svyruoja 2,7–9,1 kadro/s, todėl A/B
  daromi po 15 raundų, o `ci-fps.py` rodo ir vidurkį.

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
Dažniausias jo funkcijas hiperkvietimai vykdo QEMU pusėje ([virtual-gpu.md](virtual-gpu.md)).
Įdiegimas pataiso dyld shared cache instrukcijas (`Sources/EmulatorKit/SharedCachePatches.swift`):

- MobileIcons ikonas mažina be CoreImage;
- CoreImage veikia be OpenGL ES;
- AsynchronousDispatcher apsieina be `stop_timer` ir Metal renderer'io (`release_iosurface`);
- ekrano paviršiai kuriami be AGX suspaudimo (`&BGA`);
- MobileKeyBag ir SpringBoardFoundation praneša, kad slaptažodžio nėra.

Kiekviena pataisa prieš įrašymą tikrina originalius baitus.

Simuliuotas SEP neatsako į dalį AppleSEPKeyStore komandų: 0x22 (ref-key), 0x2A, 0x4D ir 0x0B.
