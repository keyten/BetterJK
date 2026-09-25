# r_skinSSS test assets

Optional, for two test characters only (no global mask authoring). See `docs/rend2-skin-sss.md`.

- `make_masks.ps1 -BaseDir <game base>` reads the diffuse textures from the PK3s and writes
  `pk3/models/players/.../*_sssmask.png`. White means scatters. It uses a YCbCr skin tone and
  luminance test, plus UV rectangles for the jedi_hf eye strip.
- `pk3/shaders/zz_skinsss_test.shader`: shader overrides that add `skinMask` to
  `kyle/kyle_head` (hair, ear and neck), `kyle/kyle_face` (beard and brows) and
  `jedi_hf/face`, `face_a`, `face_b` (painted eyes).
- `make_pk3.py` packs `pk3/` into `zz_skinsss_test.pk3`. It is not installed anywhere: copy it into
  `base/` to test, delete it to go back.
- `skinsss_ab.cfg`: capture binds (F8 A/B sequence, F5 debug views, F4 GPU timers).
