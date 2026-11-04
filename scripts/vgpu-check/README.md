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

Afininiai `image_sampler<XRGB8/ARGB8, …, 0,0,0,1>` ir `tex_color_matrix_4x4_bias` (`0051`):

```
gcc -O2 -ffp-contract=off -o t2 affine_colormatrix_harness.c -lm
python3 check_affine_colormatrix.py
```

Rezultatas 2026-11-02: 150 atvejų, 0 skirtingų pikselių.

`image_sampler<ARGB8, nearest>`, `tex_multiply_color`, `Blend::Mode<DarkenSover>::blend` (`0053`):

```
gcc -O2 -ffp-contract=off -o t3 nearest_multiply_darken_harness.c -lm
python3 check_nearest_multiply_darken.py
```

Rezultatas 2026-11-02: 150 atvejų, 0 skirtingų pikselių.

`image_sampler<ARGB8, 0,1,0,1>` (kraštai prispausti, `0057`):

```
gcc -O2 -ffp-contract=off -o t4 clamp_argb8_harness.c -lm
python3 check_clamp_argb8.py
```

Rezultatas 2026-11-03: 200 atvejų, 0 skirtingų pikselių.

Bilinijinis maišymas host NEON (`0062`) prieš skaliarinę versiją (paleisti AArch64 kompiuteryje):

```
cc -O2 -o bilerp bilerp_neon_check.c && ./bilerp
```

vImage `vAlpha_Blend_Premultiplied_BGRA_8888_CV_vec` (hypercall 11, `0076`): originalas Unicorn'e prieš
`valpha_ref.c` (tą patį kodą kaip QEMU), atsitiktiniai pločiai (ir aplink 8 kartotinius), eilučių
užpildai ir prisotinančios reikšmės:

```
cc -O2 -shared -fPIC -o valpha_ref.so valpha_ref.c
python3 check_valpha.py 300
```

Rezultatas 2026-11-04: 300 atvejų, 10878 pikseliai, 0 skirtumų.

`scanline` ciklas, verčiantis iš anksto padaugintus taškus nepermatomais (hypercall 13, `0078`):

```
cc -O2 -ffp-contract=off -shared -fPIC -o unpremul_ref.so unpremul_ref.c
python3 check_unpremul.py 300
```

Rezultatas 2026-11-04: 38824 taškai (keturi konstantų rinkiniai), 0 skirtumų.

`scanline` šviesumo kreivės ciklas (hypercall 14, `0079`):

```
cc -O2 -ffp-contract=off -shared -fPIC -o lum_ref.so lum_ref.c -lm
python3 check_lum.py 400
```

Rezultatas 2026-11-04: 9279 taškai, atsitiktiniai koeficientai ir svoriai, 0 skirtumų.
