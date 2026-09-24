# Rend2 HDR bloom (task 4)

`r_bloom -1` is the default and preserves the old `r_dynamicGlow*` pipeline: glow MRT, downscale/upscale, then an LDR composite after tone mapping. `r_bloom 0` disables that composite. `r_bloom 1` selects the new HDR path and is independent of `r_dynamicGlow`. It requires `r_hdr 1` and tone mapping (`r_toneMap` or `r_forceToneMap`); otherwise it produces no bloom. No shader or asset changes are required to switch modes. Existing `glow` shader stages and task-3 `emissiveMap` / `emissiveScale` write the same dedicated glow MRT. For a small emissive region, use an emissive texture mask: a legacy full-surface glow stage still blooms its full stage by design.

Modern order: HDR scene + dedicated emissive/glow MRT -> emissive prefilter plus optional soft-knee scene extraction -> existing multi-resolution downsample/upscale -> add blurred linear HDR before the shared main/refraction output transform -> exposure -> tone map -> grading LUT -> sRGB output. Gamma-lit legacy maps decode the bloom source to linear and re-encode the sum into their original scene-buffer domain before the existing output transform; HDR-lightmap scenes stay linear. The modern pyramid is read from level 1 (half resolution), so it contributes a halo rather than a sharp copy of emission. Scene extraction defaults to **off**, preventing ordinary bright diffuse whites from automatically becoming bloom sources.

| Cvar | Default | Meaning |
| --- | ---: | --- |
| `r_bloom` | `-1` | `-1` legacy, `0` off, `1` HDR bloom |
| `r_bloomIntensity` | `0.15` | Linear HDR halo strength |
| `r_bloomThreshold` | `2.0` | Scene-linear threshold for optional scene extraction |
| `r_bloomKnee` | `0.5` | Soft-knee width relative to threshold |
| `r_bloomScatter` | `0.7` | Per-level additive upsample strength |
| `r_bloomSceneIntensity` | `0` | Optional bright-scene contribution; keep at 0 for emissive-only bloom |

`r_dynamicGlowPasses` still controls the pyramid length (at least 2 in HDR mode). The older `r_dynamicGlowBloom`, `r_dynamicGlowIntensity`, and `r_dynamicGlowSoft` apply only to legacy mode.

For an A/B comparison on an HDR map: `r_hdr 1; r_toneMap 1; r_dynamicGlow 1; r_bloom -1` for the original effect, then `r_bloom 1` for HDR emissive bloom. To test thresholded scene highlights, add `r_bloomSceneIntensity 0.1`; tune `r_bloomThreshold` and `r_bloomKnee` before increasing scene intensity. Set `r_bloom -1` to restore the original path without restarting or changing assets.

Visual validation remains necessary in-game for lightsabers, blaster bolts, bright screens, indicator lights, lamps, bright sky, strongly lit white surfaces, and refractive surfaces. Automated compilation does not establish visual parity. This task was implemented without launching the game or capturing screenshots, as requested.
