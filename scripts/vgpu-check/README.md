# Virtualaus GPU funkcijų tikrinimas

Kiekviena QuartzCore piešimo funkcija, kurią emuliatorius vykdo pats (hiperkvietimas, žr.
`docs/virtual-gpu.md`), lyginama su originaliu iOS kodu: originalūs funkcijos baitai paleidžiami
ARM emuliatoriuje Unicorn, o C versija – šiame kompiuteryje. Abiem pateikiami tie patys
atsitiktiniai duomenys, ir lyginamas kiekvienas pikselis.

- `image_sampler_argb8_18A373.bin` – `image_sampler<ARGB8_Host, unsigned, true, true, true, true>`
  baitai (0x183720c2c–0x183720f18, su šuolių lentele) iš iOS 14.0 (18A373) shared cache.
- `image_sampler_harness.c` – C versija (ta pati kaip `0050` pataisoje) su netikra atmintimi.

```
pip install unicorn
gcc -O2 -ffp-contract=off -o samptest image_sampler_harness.c -lm
python3 check_image_sampler.py 0 1 3 4 5   # kraštų režimų baitai; 2 (atan2f) netikrinamas
```

Rezultatas 2026-11-02: 200 atvejų, 0 skirtingų pikselių.
