# Rend2: screen-space ambient occlusion and contact shadows

Rend2 is a forward renderer with a depth prepass. Screen-space AO and contact shadows are computed right after
the depth prepass of a world view, in fullscreen fragment passes (GLSL 1.50, no compute shaders), and the main
pass (`lightall.glsl`) of the same view samples the result through `u_SSAOMap` (`TB_SSAOMAP`):

- `r` = ambient occlusion (visibility, 1 = unoccluded)
- `g` = sun contact shadow visibility (1 = lit)

Code: `shared/rd-rend2/tr_ao.cpp`, shaders `gtao_depth.glsl`, `gtao.glsl`, `gtao_denoise.glsl`,
`ao_composite.glsl`, `ao_debug.glsl`; application in `lightall.glsl`.

Everything is off by default (`r_ssao 0`, `r_aoMode -1`, `r_contactShadows 0`): no resources are created, no
shader permutation changes, the image is unchanged.

## Render pass order (per world view)

1. Depth prepass (`RB_RenderDepthOnly`). With MSAA the main view depth is now resolved into
   `tr.renderDepthImage` before AO runs (the old SSAO read the previous frame's depth with MSAA).
2. `RB_RenderScreenSpaceLighting` (tr_ao.cpp), only for views rendered into `tr.renderFbo` with a plain
   perspective projection: not for sky portals, mirrors/portals (oblique near plane), cubemap or shadow views.
   - legacy SSAO (`r_aoMode 1`): `renderDepth -> hdrDepth -> ssao -> depthBlur x2 -> screenSsao`, unchanged
   - GTAO (`r_aoMode 2`):
     1. `gtao_depth` LINEARIZE: `renderDepth -> aoDepth` mip 0 (linear view depth, half or full resolution)
     2. `gtao_depth`: `aoDepth` mips 1..3 (farthest-weighted average)
     3. `gtao`: main pass `-> gtao[0]` (visibility + reconstructed normal)
     4. `gtao_denoise` x `r_gtaoDenoise`, ping-pong `gtao[0] <-> gtao[1]`
   - `ao_composite` (full resolution) `-> screenAo`: AO (legacy bilinear / GTAO depth-aware upsampled /
     split screen) and the contact shadow ray march. Skipped for plain legacy SSAO without contact shadows:
     lightall then samples `screenSsao` directly, exactly as before.
3. Main pass: lightall applies AO and contact shadows.
4. Post processing; `r_debugAO` overlays are drawn at its end.

Views without a result (no depth prepass, sky portal, ...) bind the white image (previously they could read a
stale SSAO map of another view).

## GTAO

Horizon-based ambient occlusion after Jimenez et al. 2016 ("Practical Real-Time Strategies for Accurate Indirect
Occlusion"), structured like Intel's XeGTAO (MIT license, notice kept in `gtao.glsl`) but written for this
renderer, not a port:

- **Input**: the depth buffer and the projection matrix (`P[0], P[5], P[8], P[9]` for positions,
  `P[10], P[14]` for linear depth). View space: x right, y up, z = distance along the view direction.
- **Depth prefilter**: linear depth at half resolution picks the closest or the farthest of the 2x2 source
  depths in a checkerboard, so both sides of silhouettes survive for upsampling. Three more mips are built with
  a weighted average that prefers the farthest depth; distant samples read coarser mips (XeGTAO's
  `log2(offset) - 3.3`), which keeps large radii cache friendly and makes thin foreground objects fade out of the
  coarse levels instead of producing halos. First person weapon pixels (`RF_DEPTHHACK`, depth <= 0.3) are marked
  invalid: they get no AO and never occlude.
- **Normals**: reconstructed from depth. For each axis the neighbour whose depth is best predicted by linear
  extrapolation of the next pixel is used, so the derivative never spans a depth discontinuity. Only
  `ReconstructNormal()` in `gtao.glsl` would change to use real surface normals later.
- **Main pass**: for each pixel, `slices` directions spread over 180 degrees; along both sides of each direction
  `steps` depth samples with a quadratic distribution out to the projected effect radius. The maximum horizon
  cosine per side (with a distance falloff towards the radius, and optional thin-occluder compensation) gives
  two horizon angles, clamped to the hemisphere around the normal projected into the slice, and the
  cosine-weighted visibility of the slice is integrated analytically. Visibility = average over slices, then
  `pow(visibility, r_gtaoPower)`.
- **Noise**: a fixed 4x4 ordered pattern rotates the slices and offsets the steps. Every 4x4 block contains all
  rotations and the denoiser covers exactly that footprint, so there is no temporal shimmer without TAA.
- **Denoise**: 3x3 edge-aware passes with tap distance 1, 2, 4. Weights: binomial kernel x distance of the
  neighbour to the center's tangent plane (sloped floors blur fully, steps and silhouettes do not) x normal
  similarity. Sky and weapon pixels are skipped.
- **Upsampling** (half resolution): the 2x2 bilinear footprint of each full resolution pixel, each texel weighted
  by how well its tangent plane predicts the pixel's position; falls back to the best matching texel on edges.
  Never a plain bilinear blur across geometry edges.

## Contact shadows

In `ao_composite.glsl`, for the sun only (`r_sunlightMode 1/2`, map with sun shadows):

1. view position from the full resolution depth;
2. the sun direction in view space;
3. the ray starts off the receiver by 1.5 pixel footprints (+0.1 units) to avoid self-shadowing;
4. `r_contactShadowSteps` samples over `r_contactShadowLength` units, jittered by the 4x4 pattern (no banding);
5. each sample is projected to the screen and compared with the depth buffer;
6. a hit needs the ray to be behind the depth buffer by more than a bias (1.5 pixel footprints) and less than
   `r_contactShadowThickness` (+2 pixel footprints): farther behind means the ray passes behind a foreground
   object, not through an occluder;
7. the first hit gives the occlusion, faded out over the second half of the ray; rays leaving the view stop
   (unknown occluders), and occlusion fades out within 5% of the screen edges.

lightall: `sunShadow = cascadeShadow * contactShadow * N.L`. With `r_sunlightMode 1` this modulates the
lightmap like the cascaded shadows already do, with mode 2 it scales the real-time sun. Contact shadows only
add near-field detail; they do not replace the shadow map.

## AO application (lightall)

AO represents lost indirect light. Two applications are available (`r_aoApply`):

| | legacy (0) | indirect-only (1) |
|---|---|---|
| ambient term (entities, light left over from lightmaps/vertex light) | x AO | x AO (multi-bounce) |
| baked lightmap / vertex light | - | x `mix(1, AO, r_aoLightmapFraction)` |
| cubemap reflections | specular x AO | specular occlusion (Lagarde 2014) |
| sun, dynamic lights, light grid directed light | - | - |
| material AO (ORM texture) | min(material, screen) | min(material, screen) |

Default `-1`: legacy for legacy SSAO (bit exact with the old output), indirect-only for GTAO. JKA lightmaps
contain direct and bounced light together, so AO attenuates only a share of them (`r_aoLightmapFraction`),
otherwise GTAO would be invisible on world surfaces or act like a shadow.

Multi-bounce (`r_aoMultiBounce`, Jimenez 2016 fit): bright and colored surfaces keep more light in creases
instead of turning dirty black.

## Cvars

| Cvar | Default | Description |
|---|---|---|
| `r_aoMode` | -1 | -1 = follow `r_ssao` (legacy), 0 = off, 1 = legacy SSAO, 2 = GTAO |
| `r_ssao` | 0 | legacy switch (latched), unchanged; `r_ssao 2` still shows its old debug overlay |
| `r_aoApply` | -1 | -1 auto, 0 legacy application, 1 indirect-only |
| `r_aoCompare` | 0 | cheat. Split screen: legacy SSAO + legacy application left, GTAO + indirect-only right |
| `r_aoMultiBounce` | 1 | multi-bounce approximation (indirect-only application) |
| `r_aoLightmapFraction` | 0.5 | share of baked light attenuated by AO (indirect-only application) |
| `r_gtaoQuality` | 2 | preset, see below |
| `r_gtaoHalfRes` | 1 | latched. 1 = half resolution + depth-aware upsampling, 0 = full resolution |
| `r_gtaoRadius` | 32 | effect radius, world units |
| `r_gtaoFalloff` | 0.6 | falloff range as a fraction of the radius |
| `r_gtaoThickness` | 0.2 | thin occluder compensation (0 = solid occluders, higher = fewer halos behind objects) |
| `r_gtaoPower` | 1.5 | visibility exponent |
| `r_gtaoDenoise` | 2 | denoise passes, 0-3 |
| `r_contactShadows` | 0 | sun contact shadows |
| `r_contactShadowLength` | 16 | ray length, world units |
| `r_contactShadowSteps` | 12 | ray steps |
| `r_contactShadowThickness` | 6 | assumed occluder thickness, world units |
| `r_contactShadowStrength` | 0.85 | 0..1 |
| `r_debugAO` | 0 | cheat, debug views, see below |

GPU resources (and the `USE_SSAO` define in the shaders) exist when `r_ssao`, `r_aoMode > 0` or
`r_contactShadows` is set when the renderer starts; switching between modes afterwards is immediate, turning the
feature on from nothing needs `vid_restart` (a warning is printed). All of it needs `r_depthPrepass 1`.

Quality presets (`r_gtaoQuality`), depth taps per pixel = slices x steps x 2:

| Value | Slices | Steps per side | Taps |
|---|---|---|---|
| 0 low | 1 | 3 | 6 |
| 1 medium | 2 | 4 | 16 |
| 2 high (default) | 3 | 6 | 36 |
| 3 ultra | 6 | 8 | 96 |

## New textures and FBOs

| Image | Format | Size | FBO |
|---|---|---|---|
| `*screenSsao` (legacy, was `GL_R8`) | `GL_RG8`, r = AO, g = 1 | 1/2 | `_screenssao` |
| `*aoDepth` | `GL_R32F`, 4 mips | 1/2 or 1 | `_aoDepth0..3` (one per mip) |
| `*gtao0`, `*gtao1` | `GL_RGBA8`, r = visibility, gba = normal | 1/2 or 1 | `_gtao0`, `_gtao1` |
| `*screenAo` | `GL_RG8`, r = AO, g = contact | 1 | `_screenAo` |

`*hdrDepth` / `_hdrDepth` and the `_quarter` FBOs are used by legacy SSAO as before.

## Debug views (`r_debugAO`, cheat)

| Value | View |
|---|---|
| 1 | raw legacy SSAO (computed even in GTAO mode) |
| 2 | raw GTAO (denoiser skipped) |
| 3 | denoised GTAO (before upsampling) |
| 4 | reconstructed view normals |
| 5 | linear depth (log scale; weapon red, sky blue) |
| 6 | contact shadows only |
| 7 | cascade shadow only (lightall) |
| 8 | cascade x contact shadow (lightall) |
| 9 | final ambient visibility incl. material AO and multi-bounce (lightall) |
| 10 | the AO map lighting used |

Views 7-9 are written by lightall on lit surfaces and skip tone mapping, bloom and sun rays; other surfaces
(sky, effects) keep their normal shading.

## A/B comparison

```
r_aoMode 1; r_aoApply -1        // legacy SSAO, legacy application (identical to before)
r_aoMode 2                      // GTAO
r_aoCompare 1                   // split screen legacy | GTAO
r_aoMode 2; r_aoApply 0         // GTAO with the old application
r_contactShadows 1              // toggle contact shadows (0/1)
r_debugAO 3 / 6 / 8 / 9         // inspect buffers
r_speeds 100                    // GPU timings: "AO legacy SSAO", "AO GTAO depth", "AO GTAO main",
                                // "AO GTAO denoise", "AO composite/contact"
```

Start with `r_aoMode 2` (or `r_contactShadows 1`) in the config, or `vid_restart` after setting it.

## Screen-space limitations

- Only what is visible in the depth buffer occludes: off-screen or hidden occluders, back faces and the inside of
  thin objects are unknown (AO and contact shadows fade out at screen edges instead of popping).
- Depth has no thickness: thin objects in front of a surface occlude as if they were solid
  (`r_gtaoThickness`, contact thickness limit mitigate this).
- Transparent / non-depth-writing surfaces (glass, effects, most foliage cards with alpha blending) neither
  receive nor cast AO/contact shadows.
- No AO in mirrors/portals and sky portals, cubemap captures, or for the first person weapon.
- Contact shadows: primary sun only; not for dynamic/point lights; the result is binary per pixel with an
  ordered 4x4 jitter, visible as fine dithering on shadow edges up close.
- Half resolution GTAO loses detail on sub-2-pixel features; use `r_gtaoHalfRes 0` for them.
- Lightmaps already contain large scale occlusion; `r_aoLightmapFraction` is an artistic, not a physical,
  split between direct and bounced baked light.

## Possible improvements (not implemented)

- Bent normals from the GTAO slices (average unoccluded direction) for direction-aware cubemap/ambient lookups.
- Temporal accumulation (the velocity buffer exists for `r_smaa 2`): fewer taps per frame, stable 16 x 4x4
  rotations over time.
- True normals from the depth prepass (an extra RG16 target) instead of depth reconstruction.
- Contact shadows for the strongest dynamic light; per-light screen-space shadows.
- A 5-level depth mip chain with a separate pass for very large radii, and a quality preset per resolution.
- Specular occlusion from the bent cone (Jimenez 2016 "GTSO").
- AO for the ambient part of `generic.glsl` vertex-lit surfaces.
