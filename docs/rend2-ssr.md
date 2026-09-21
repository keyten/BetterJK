# Rend2: screen-space reflections

Hybrid reflections for opaque PBR materials: screen-space reflections (SSR) where the screen has the reflected
surface, the existing parallax corrected, roughness prefiltered cubemap reflections everywhere else. SSR
**replaces** part of the cubemap reflection, it is never added on top of it.

Code: `shared/rd-rend2/tr_ssr.cpp`, shaders `ssr_common.glsl` (library), `ssr_hiz.glsl`, `ssr_downsample.glsl`,
`ssr_trace.glsl`, `ssr_resolve.glsl`, `ssr_temporal.glsl`, `ssr_composite.glsl`, `ssr_debug.glsl`; material output
in `lightall.glsl`.

Off by default (`r_ssr 0`, latched): no resources are created, lightall is compiled exactly as before (the
preprocessed source without `USE_SSR` is identical to the previous one), renderFbo has its two old attachments and
the main pass is drawn in one piece. The image is unchanged.

## Before / after

**Before.** Rend2 is a forward renderer. `lightall.glsl` computes everything in one go, including the specular
image based lighting of `CalcIBLContribution`:

```
R        = reflect(-E, N) - (cubemapOrigin - viewOrigin + viewDir) / parallaxRadius   // parallax correction
radiance = textureLod(u_CubeMap, R, roughness * ROUGHNESS_MIPS)                        // prefiltered mips
radiance *= clamp(luma(lighting) / radiance.a, 0, 1)                                   // lighting scale
C        = radiance * W,   W = specularAO * EnvBRDF.x + EnvBRDF.y   (cloth: EnvBRDF.b)
out_Color += C
```

The cubemap of a surface is the closest one (`R_CubemapForPoint`, per BSP surface / per entity). Normals and
roughness only exist while the fragment is shaded; nothing is kept in screen space.

**After.** lightall still adds `C`. With `r_ssr 1` it also writes a small material buffer (three extra
attachments of renderFbo, no G-buffer). After the opaque surfaces of the view are drawn, the SSR passes find a
reflection ray hit with a confidence `c` and composite

```
color += c * (SSR radiance * W - C)
```

`c = 1`: the pixel shows the SSR under exactly the BRDF weight the cubemap reflection had (Fresnel, F0, EnvBRDF,
specular occlusion), and the cubemap part is removed. `c = 0`: the pixel stays as lightall wrote it, with the
cubemap reflection. Everything in between is a linear blend, so a miss is never black and never doubled.
Metalness is not a mask: `W` already holds F0 and the Fresnel response, so polished dielectrics reflect, rough
paint barely does, and pixels with a negligible `W` are not traced.

The equation is linear, which also makes it correct with MSAA: `C` and `W` are resolved by averaging the samples
(non-receiver samples count as 0), and adding the same delta to every sample equals the average of the per-sample
deltas.

## Material buffer (renderFbo attachments, only with `r_ssr 1`)

| attachment | image | format | contents |
|---|---|---|---|
| 0 | `renderImage` | RGBA16F / RGBA8 | scene color (unchanged) |
| 1 | `glowImage` | as color | glow (unchanged) |
| 2 | `ssrNormalImage` | RGB10_A2 | rg = octahedral world normal (after normal mapping), b = roughness (as lightall uses it), a = receiver |
| 3 | `ssrSpecularImage` | RGB10_A2 | rgb = sqrt(W) |
| 4 | `ssrCubemapImage` | RGBA16F | rgb = C (the cubemap reflection lightall added), a = view depth of the fragment |

- 10 bit octahedral normals: 8 bits give about 0.7 degrees of error, which shows as wobble in mirror floors (the
  reflection doubles the angle); 10 bits about 0.17 degrees.
- `W` is in [0, 1]; the square root keeps about 5% precision at dielectric values (0.02 - 0.04).
- `C` is HDR and needs a float format. Storing `C` and `W` (6 values) is the minimum for an exact replacement: the
  cubemap is chosen per surface with a per draw parallax, so it cannot be looked up again in screen space.
- The view depth in `.a` validates the data: a pixel is only a receiver when it matches the depth buffer (2% +
  1 unit). This rejects data of a surface later covered by a non-lightall surface (possible without the depth
  prepass) and the first person weapon (drawn with a hacked depth range).
- 16 extra bytes per pixel and sample.

Only opaque lightall stages write the attachments (`RenderState::ssrAux`, set by `RB_WritesSSRMaterial` in
tr_shade.cpp: lightall program, no blending or ONE/ZERO, no color mask, SSR view). All other draws have them
masked with `glColorMaski` (`GL_SetSSRAuxWrite`): a shader that does not write an output leaves undefined values.
`GL_State` re-masks them after every `qglColorMask` (which sets the masks of all draw buffers), as do the raw
`qglColorMask` calls of the depth prepass and the anaglyph code. Stages without per-pixel lighting or without a
specular map write "not a receiver" (lightall has no specular reflections there either).

With `r_cubeMapping 0`, or on surfaces without a cubemap, `C = 0` and `W` is still computed (the EnvBRDF LUT is
bound for lightall whenever SSR is on): SSR adds reflections where there were none, and a miss keeps the old
look.

## Render pass order (main world view, `r_ssr 1`)

1. `RB_BeginDrawingView`: clears color/depth/glow as before; `RB_SSRBeginView` decides whether the view gets SSR
   (only views rendered into renderFbo with a plain perspective projection: not portals/mirrors (oblique near
   plane), sky portals, cubemap or shadow views, no `RDF_NOWORLDMODEL`/hyperspace) and clears attachments 2-4.
2. Depth prepass (+ velocity), screen-space AO / contact shadows: unchanged.
3. Main pass, **opaque part**: `RB_SubmitRenderPass` sorts the draw items as before and splits at the first item
   of a later sort, or of the fog pass stage of the opaque sort (see `RB_CreateSortKey`).
4. `RB_RenderSSR` (once per view):
   1. MSAA: resolve depth into `renderDepthImage` and attachments 2-4 into their textures
   2. `ssrColor` mip 0 = copy of color 0 (resolves MSAA), mips 1-6: 4x4 box downsample (`ssr_downsample`)
   3. `ssrHiZ` mip 0 = linear view depth (`ssr_hiz` LINEARIZE); with Hi-Z tracing also mips 1-6 = closest depth
   4. trace (`ssr_trace`, full or half resolution) -> `ssrTrace`
   5. resolve (`ssr_resolve`, full resolution) -> `ssrResolve`
   6. optional temporal accumulation (`ssr_temporal`) -> `ssrHistory[current]`
   7. composite (`ssr_composite`) into color 0 through `ssrCompositeFbo` (color 0 only: the glow and material
      attachments stay untouched and the sampled depth is not attached)
5. Main pass, **the rest**: decals, see-through, blended surfaces, fog passes, sun, flares - on top of the hybrid
   result.
6. Post processing unchanged; `r_ssrDebug 1-6` overlays at its end.

SSR therefore samples the opaque HDR scene before tone mapping (in the same space lightall writes: scene linear
with HDR lightmaps / `r_linearLighting`, display encoded otherwise - the same space as the cubemap reflection it
replaces), without particles or glass in it.

### Buffers of the passes

| image | format | size |
|---|---|---|
| `ssrColor` | as renderImage, 7 mips | full |
| `ssrHiZ` | R32F, 7 mips | full |
| `ssrTrace` | RGBA16 (hit uv 1/65535, distance, confidence) | full (half resolution uses a quarter) |
| `ssrResolve` | RGBA16F (premultiplied radiance, confidence) | full |
| `ssrHistory[2]`, `ssrHistoryGeom[2]` | RGBA16F | full, only with `r_ssrTemporal 1` |

## Tracing

- View space position from depth (`P[0], P[5], P[8], P[9], P[10], P[14]`), the normal from attachment 2, `R =
  reflect(-V, N)`. The ray starts slightly above the surface and is clipped in front of the near plane (rays
  towards and behind the camera) and to the view rectangle.
- The view space ray is projected to the screen; its screen position and 1 / depth are linear in screen space,
  so the steps are spread evenly over the covered pixels (McGuire & Mara 2014) with a per pixel jitter
  (interleaved gradient noise, changing per frame).
- A crossing: the ray segment reaches behind a depth buffer surface but not further than its assumed thickness,
  `r_ssrThickness * (1 + z / 512)`. It is refined with `r_ssrRefineSteps` binary search steps.
- Hi-Z (`r_ssrHiZ`, from `r_ssrQuality` medium): walks the closest depth mips. Cells the ray passes entirely in
  front of are skipped at once and the walk climbs a level; near surfaces it descends to single pixels. Long rays
  over open floors need a few dozen iterations instead of hundreds of pixels. Behind thin objects it has to walk
  pixel by pixel (thickness), the iteration budget is `3 * steps`.
- Ray length: `r_ssrMaxDistance`, down to 35% towards `r_ssrMaxRoughness`.
- Roughness: the cone of the GGX lobe (alpha = roughness^2, as in the cubemap prefilter, taken as a Phong lobe)
  gives the blur footprint at the hit; the resolve samples the color pyramid at `log2(footprint in pixels)`. Mirror
  surfaces are sharp, rough ones blurred, and the sharpness matches the cubemap mip they blend with. Above
  `r_ssrMaxRoughness` only the cubemap is used (smooth fade from 70% of it).

### Confidence

Product of: hit ambiguity (ray depth vs surface depth / thickness), back facing hits (hit normal facing away from
the ray), screen edge fade (`r_ssrEdgeFade`), end of the ray, rays back towards the camera, grazing views (the ray
skims its own normal mapped surface), roughness fade, `r_ssrStrength`. Misses, rays leaving the screen, sky (no
depth), the first person weapon (hacked depth range: neither receiver nor hit), and hits closer than twice the
start offset (self intersection) have 0.

### Half resolution

One ray per 2x2 block (the lower left pixel). The resolve upsamples from the four nearest trace texels weighted
by bilinear position, depth similarity and normal similarity (`pow(dot, 8)`), and fetches the radiance per
sample, so reflections do not leak across silhouettes.

### Temporal accumulation (`r_ssrTemporal 1`, latched)

Creates the velocity buffer (as SMAA T2x / motion blur do) and two history buffers. Each receiver is reprojected
with the velocity of the depth prepass when available (moving doors, NPCs), otherwise with the previous camera.
The history is rejected off screen, on disocclusion (previous depth vs the depth the point would have), on a
different normal (dot < 0.9) or roughness (> 0.1), and after a cut: frame gap, map change, viewport change,
camera move > 192 units, rotation > 35 degrees, FOV change > 1 degree, or (with `r_motionBlur`) a reset of the
motion blur history (`tr.temporalHistoryValid`, which also covers `r_motionBlurReset`). The history is clamped to the YCoCg range of
the 3x3 neighborhood of the current frame, and its weight (`r_ssrTemporalWeight`) halves with large motion.
Accumulation is optional; the SSR is stable without it (the jitter then just changes the sample positions each
frame).

## Cvars

| cvar | default | |
|---|---|---|
| `r_ssr` | 0 | archive, latch. 1 = hybrid SSR + cubemap reflections |
| `r_ssrQuality` | 1 | 0 low (16 steps, half res, linear), 1 medium (24, half res, Hi-Z), 2 high (40, full res, Hi-Z), 3 ultra (64, full res, Hi-Z) |
| `r_ssrSteps` | 0 | ray march steps (Hi-Z: iterations / 3), 0 = preset |
| `r_ssrRefineSteps` | 0 | binary search steps, 0 = preset (4, 5, 6, 8) |
| `r_ssrMaxDistance` | 1024 | max ray length, world units |
| `r_ssrThickness` | 8 | assumed surface thickness, world units (grows with distance) |
| `r_ssrMaxRoughness` | 0.6 | rougher surfaces use the cubemap only |
| `r_ssrEdgeFade` | 0.1 | screen edge fade band, fraction of the view |
| `r_ssrHalfRes` | -1 | -1 preset, 0 full, 1 half resolution rays |
| `r_ssrHiZ` | -1 | -1 preset, 0 linear, 1 hierarchical |
| `r_ssrTemporal` | 0 | archive, latch. temporal accumulation |
| `r_ssrTemporalWeight` | 0.9 | history weight |
| `r_ssrStrength` | 1 | confidence scale. 0 = cubemap only (and no SSR work unless a debug view or the compare is on) |
| `r_ssrCompare` | 0 | split screen: left half cubemap reflections only, right half hybrid |
| `r_ssrDebug` | 0 | cheat, see below |

## Debug views (`r_ssrDebug`)

Non-receiver pixels are black. 1-6 are drawn over the final image without tone mapping, 7-10 replace the scene
color of the view before the rest of the pass and go through the normal tone mapping.

| | |
|---|---|
| 1 | material normal (world, `* 0.5 + 0.5`) |
| 2 | roughness |
| 3 | specular reflectance W (F0 * EnvBRDF.x + EnvBRDF.y with specular occlusion) |
| 4 | ray hit (green, brighter = more confident) / miss (red); non-receivers dark gray |
| 5 | hit distance (blue near, red at `r_ssrMaxDistance`) |
| 6 | final confidence (after temporal accumulation) |
| 7 | raw SSR radiance |
| 8 | cubemap reflection C |
| 9 | final hybrid reflection `C + c * (SSR * W - C)` |
| 10 | replaced part `abs(c * (SSR * W - C))` |

A/B: `r_ssr 0` is the previous renderer; `r_ssrCompare 1` shows cubemap-only and hybrid side by side in the same
frame; `r_ssrDebug 8` vs `9` shows the reflection term alone. `build/ab/*-pressr.dll` (HEAD) vs `*-ssr.dll`.

GPU timers: `r_speeds 100` lists "SSR inputs", "SSR trace", "SSR resolve", "SSR temporal", "SSR composite".

## GPU cost

Not measured yet (the renderer has not been run with it). Expected order at 1920x1080 on an RTX 2060 class GPU,
from the work per pixel: material attachments ~0.1-0.2 ms (bandwidth of the extra 16 bytes per pixel and sample),
inputs (copy, 6 color mips, depth + Hi-Z) ~0.2 ms, trace ~0.3-0.5 ms at medium (half resolution, Hi-Z) and
~1-2 ms at high/ultra (full resolution), resolve ~0.1-0.3 ms, temporal ~0.15 ms, composite < 0.1 ms. Integrated
GPUs several times more; low/medium are meant for them. Use `r_speeds 100` for real numbers.

## Validation checklist

Built (MSVC SP/MP, gcc compiles all changed files); every new shader and the lightall variants (lightmap / light
vector / vertex lit, MR / SG / cloth, with and without `USE_SSR`, `USE_CUBEMAP`, `USE_SSAO`, shadows, skeletal /
vertex animation, parallax) compile and link on the Intel UHD and NVIDIA RTX 2060 drivers. Not yet run in game.
To check in game (`r_ssr 1`, `r_ssrCompare 1`, `r_ssrDebug 4/6/9/10`):

- polished metal (sharp, tinted by F0), rough metal (blurred, fades to the cubemap), painted metal and rough
  dielectrics (weak), glossy dielectric floors (strong at grazing angles only)
- characters reflected in floors; moving doors and NPCs (with and without `r_ssrTemporal`)
- saber / blaster: blended effects are not in the SSR (see limitations); the lit surfaces around them are
- screen edges (fade, no hard cut), long corridors (Hi-Z vs linear, `r_ssrMaxDistance`)
- vjun / wet looking maps: no double reflection where the confidence is high (`r_ssrDebug 10` vs `8`)
- MSAA on/off, `r_hdr` on/off, `r_cubeMapping` on/off, different resolutions / FOV, weapon in view (no SSR on it)

## Known limitations

- Screen space: only what is on screen and in the opaque part of the pass can be reflected. Particles, glass,
  saber blades and other blended surfaces are not in the SSR scene and are not hit (no depth); they fall back to
  the cubemap. Off-screen and occluded geometry too.
- Only the fog of the receiver is applied (fog passes draw after the composite); fog along the reflected ray is not.
- A multiplicative stage drawn after the PBR stage of the same shader (rare) is not included in `C`.
- The depth buffer only has the front faces: thin objects are thickened by `r_ssrThickness`, which can produce
  false hits behind them (reduced by the ambiguity term and the back facing test).
- MSAA: normals are averaged on silhouettes, silhouette pixels mostly fail the depth validation and keep the
  cubemap reflection.
- `r_hdr 0`: the scene buffer is 8 bit, the composite clamps (subtract pass, then add pass).
- The first person weapon is detected by its depth range; a weapon drawn without `RF_DEPTHHACK` would be a
  normal receiver/hit target.
- Only the main view of a scene gets SSR (not portals, mirrors, sky portals).
- Temporal reprojection uses the receiver's motion, not the motion of the reflected point; the neighborhood clamp
  hides most of the difference on glossy surfaces.

## Possible improvements (not implemented)

- Reflection parallax aware reprojection (reproject the hit point), and stochastic GGX ray directions with
  temporal + spatial denoising for physically correct rough reflections instead of the cone blur.
- Fog along the reflected ray; SSR for transparent surfaces (water, glass) in their own pass.
- Include blended emissive effects (saber blades) through a separate emissive-only buffer.
- Pack the material buffer tighter (R11G11B10F for `C`), or reuse the prepass for the normal.
- Depth pyramid shared with GTAO; compute shader tracing on GL 4.3+.
- Screen-space specular occlusion from the trace for the cubemap part that remains.
