# Rend2: froxel volumetric fog

A new volumetric fog mode, `r_volumetricFog 2`: the BSP fog volumes lit in a camera aligned froxel volume by the
baked light grid, the sun (with its cascaded shadow maps) and the dynamic lights (with their shadow maps), with a
Henyey-Greenstein phase function and temporal reprojection. The legacy mode `r_volumetricFog 1` is kept unchanged
as the fallback, and is still used by every view that has no froxel volume (portals, mirrors, sky portal, LA
goggles, UI scenes).

Code: `shared/rd-rend2/tr_volumetric.cpp`; shaders `volumetric_common.glsl` (library), `volumetric_inject.glsl`,
`volumetric_integrate.glsl`, `volumetric_composite.glsl`, `volumetric_debug.glsl`; froxel branches (`USE_FROXEL_FOG`)
in `fogpass.glsl`, `generic.glsl`, `surface_sprites.glsl`.

Off by default. With `r_volumetricFog 0` or `1` no resources are created, the library is not inserted and
`USE_FROXEL_FOG` is not defined: the preprocessed sources of the fog pass, generic and surface sprite programs are
identical to the previous ones (160 permutations compared), and every draw is submitted as before.

## Old system (`r_volumetricFog 1`)

- **What the volumetric light map holds.** `world->volumetricLightMaps[0]` (`R_BuildLightGridTexture`,
  `tr_bsp.cpp`) is a 3D texture with one texel per BSP light grid cell (`lightGridBounds`, default cell 64 x 64 x
  128 units). Each texel is the non directional merge of the cell's baked light: `max(ambient, direct)` of light
  style 0 for LDR grids (`GL_RGB8`, `GL_SRGB8` with forced linear light), `ambient + direct` for HDR grids
  (`GL_RGB16F`). The light direction (`latLong`) is dropped.
- **Static.** It is built once at map load and never updated.
- **Relation to the light grid.** Same data, same layout; the fog shaders map a world position to texture
  coordinates with `u_LightGridOrigin = lightGridOrigin - 0.5 * lightGridSize` and
  `u_LightGridCellInverseSize = lightGridInverseSize` divided by the texture size.
- **Lights it contains:** everything q3map2 baked into the grid: static lights, the sky / sun light (shadowed at
  the resolution of the grid cells), bounce / ambient. All isotropic.
- **Lights it does not contain:** dynamic lights (sabers, blaster bolts, explosions, muzzle flashes, force
  effects), the actual sun direction, the cascaded sun shadows, the dynamic light shadow maps, entities, anything
  that changes at runtime. No phase function.
- **Rendering.** Every fogged surface gets a fog pass (`RB_FogPass`, `fogpass.glsl`) that ray marches the light
  map from the camera (or the fog plane) to the fragment with `r_volumetricFogSamples` steps, and blends
  `ONE, ONE_MINUS_SRC_ALPHA`: `color * T + S`. Generic (non lightall) stages and surface sprites do the same in
  their own shader (`u_FogColorMask`). A global fog gets a plane at the top of the world and a "fog cap" quad at
  `depthForOpaque` for the sky. Extinction: `depthToOpaque = -ln(1.5 / 255) / depthForOpaque * volumetricFogScale
  * r_volumetricFogScale` per unit.

## New system (`r_volumetricFog 2`)

```
frame: shadow views (sun cascades, dynamic light cubes)          [unchanged]
main view:
  depth prepass -> screen-space AO                               [unchanged]
  froxel inject      N slices: media, baked + sun (+ history) | dynamic lights
  froxel integrate   N slices: front to back, S and T per slice
  main pass: layers <= SS_FOG (opaque, sky, decals, see-through, banners, fog faces)
             (SSR after the opaque layer, as before)
             froxel composite: color = color * T + S, glow = glow * T   (from the depth buffer)
             layers > SS_FOG: fog passes / in-shader fog look up the volume at the fragment
post process: bloom, tone mapping, ...                           [unchanged]
```

The media are exactly the legacy ones: only the BSP fog volumes (and the global fog) have an extinction, so maps
without fog are not turned into a haze (and a map without fog volumes skips the froxel passes entirely). Light
that is identical in both modes (baked, isotropic, `g = 0`) gives the same in-scattering as the legacy ray march:
the phase function is normalized to 1 for isotropic scattering and the integration uses the same
discretisation (see Integration).

### Froxel grid

- `Fx = ceil(width / gridScale)`, `Fy = ceil(height / gridScale)`, `Fz = slices`; x, y cover the main view.
- Slices are exponential in view depth (distance along the view forward axis):
  `B(k) = near * (far / near)^(k / Fz)`, slice k spans `[B(k), B(k+1)]`, slice 0 starts at the camera.
  `near = 8` units, `far = r_volumetricFogFar` (0 = 4096). With 48 slices every slice is 13.9% deeper than the
  previous one: ~1 unit thick at 8 units, ~14 at 100, ~140 at 1000.
- Beyond `far` the medium of the last slice is extrapolated analytically (tail texture), so distant walls and the
  sky of a global fog are fogged like before.
- Presets (`r_volumetricFogQuality`), **starting points, not profiled yet**:

| quality | pixels per froxel | slices | 1920x1080 grid | froxels | volume memory |
|---|---|---|---|---|---|
| 0 low | 16 | 32 | 120 x 68 x 32 | 0.26 M | 7.3 MB |
| 1 medium (default) | 8 | 48 | 240 x 135 x 48 | 1.56 M | 43.5 MB |
| 2 high | 8 | 64 | 240 x 135 x 64 | 2.07 M | 58.1 MB |

  `r_volumetricFogGridScale` / `r_volumetricFogSlices` override the preset (latched). Draws per frame: `2 * slices
  + 1`.

### Froxel data

| texture | format | size | contents |
|---|---|---|---|
| `froxelInjectImage[2]` | RGBA16F 3D | Fx Fy Fz | rgb = emission of the baked light and the sun, `extinction * albedo * L_in`; a = extinction per unit. Temporally filtered; the two images are this frame and the history (ping-pong) |
| `froxelDynamicImage` | R11G11B10F 3D | Fx Fy Fz | emission of the dynamic lights, this frame only |
| `froxelIntegratedImage` | RGBA16F 3D | Fx Fy Fz | rgb = in-scattering S, a = transmittance T, between the camera and the far side `B(k+1)` of slice k |
| `froxelCarryImage[2]` | RGBA16F 2D | Fx Fy | integration state between two slices (ping-pong, no feedback loop) |
| `froxelTailImage` | RGBA16F 2D | Fx Fy | radiance (emission / extinction) and extinction of the last slice |
| `world->volumetricStaticGrid` | RGBA16F 3D | light grid | baked light without the sun (rgb), sun fraction (a, debug) |
| `world->volumetricSunGrid` | RGBA16F 3D | light grid | baked sun part |

Emission (not radiance) is stored because it is linear in the medium: blending two frames of emission and
extinction is correct at fog boundaries and under jitter.

### Pipeline without compute shaders

Rend2 runs on a GL 3.2 core context: no compute shaders, no image load / store. Every slice of a 3D texture is
rendered with a full screen triangle into a framebuffer with that layer attached (`glFramebufferTextureLayer`),
one draw per slice. The integration carries its running state in a 2D texture ping-pong, because sampling another
layer of the texture that is being rendered to is a feedback loop in GL.

## Injection (`volumetric_inject.glsl`)

Per froxel, one slice per draw:

1. **Position.** The baked light and the sun are sampled at a jittered position (Halton 2, 3, 5 over 8 frames, a
   full froxel wide) when temporal accumulation is on, the dynamic lights at the froxel center.
2. **Medium.** Sum of the extinction of the fog volumes that contain the point: their axial bounds and the plane
   of their visible side (the same `inFog` test as `CalcFog`); the global fog everywhere below its cap plane.
   Albedo = extinction weighted fog color. The height fog and the density noise are in; future local density volumes go into
   `FroxelMedium`.
3. **Baked light.** `volumetricStaticGrid` at the point, isotropic, `* r_volumetricFogStaticScale`.
4. **Sun.** Phase `4 pi HG(g, dot(sunDir, viewDir))`, `* r_volumetricFogSunScale`:
   - with cascaded shadow maps this frame (`VPF_USESUNLIGHT`): `sunRadiance * shadow`, blended to the baked sun
     part at the far end of the last cascade (same fade as lightall);
   - without them: the baked sun part `volumetricSunGrid`.
5. **Dynamic lights.** The lights of this slice (`u_LightMask`, see culling) with lightall's attenuation
   `clamp(0.5 * r^2 / d^2 - 0.5)`, phase `4 pi HG(g, dot(toLight, viewDir))`, their shadow map (see Shadows),
   `* r_volumetricFogDlightScale`. The dynamic light system is the only source: sabers, bolts, explosions are
   volumetric exactly when game code adds a dynamic light for them. There are no spot / projected lights in the
   renderer.
6. **Temporal filter** of baked + sun (see Temporal). The dynamic light emission is written to its own volume
   without history.

### Light grid split by the sun direction (`R_BuildVolumetricLightGrid`)

The legacy light map merges the baked sun with everything else; adding a realtime sun on top would count it
twice. At map load (mode 2 only), every grid cell is split with the light direction of the cell:

```
s      = smoothstep(cos 25, cos 10, dot(cellDir, sunDir))     // 0 when the map has no sun shader
sun    = min(s * direct, legacyMerge)
static = legacyMerge - sun                                     // static + sun == legacy value
```

The realtime sun radiance is the 90th percentile luminance of the sunlit cells (`s > 0.5`, at least 16 cells), with
their average color, so light beams have the brightness the map was compiled with. Without sunlit cells the
refdef sun color is used.

The direction of a grid cell is a mix of all its lights, so a lamp straight above can look like a high sun. The
injection therefore trusts the baked sun part only where the cascades see the sun somewhere in the grid cell (4
extra cascade lookups at the cell corners): deep in shadow (indoors) it stays baked light and is not darkened.

Offline check on the stock maps (`maps/*.bsp` with fog, sun from the sky shader):

| map | sun | sunlit cells | sun share of the grid energy | realtime sun radiance (luma) |
|---|---|---|---|---|
| hoth2 | yes | 274 344 / 1 044 126 | 46.0% | 0.573 |
| vjun1 | yes | 230 931 / 1 001 520 | 39.0% | 0.724 |
| mp/duel9 | yes | 103 615 / 496 800 | 73.5% | 0.642 |
| mp/ffa2 | yes | 34 773 / 122 766 | 66.3% | 0.646 |
| taspir1 | yes | 15 945 / 52 155 | 53.0% | 0.937 |
| t2_trip | yes | 11 428 / 1 047 540 | 2.2% | 0.576 |
| kor1, t2_rancor, mp/ctf1, ... | no | 0 | 0% (static == legacy) | - |

## Shadows in the volume

- **Sun.** The existing cascades (`sunShadowArrayImage`, `refdef->sunShadowMvp`): the first cascade whose
  interior (minus a PCF margin) contains the point, as `sunShadow()` in lightall. Constant depth bias (no normal
  to offset along). One hardware filtered tap with temporal accumulation (the jittered sample positions average
  to soft, stable beam edges), four taps without it. Fog behind a wall gets no direct sun: the wall is in the
  shadow map.
- **Dynamic lights.** The existing cube shadow maps (`pointShadowArrayImage`, `r_dlightMode 2`, `sampleCube` /
  depth as lightall), 4 taps in a fixed pattern around the light direction, the sample moved slightly towards the
  light. `r_volumetricFogDlightShadows 0` disables them.
- No new shadow maps are rendered.

## Height fog (ground haze)

An optional second medium, evaluated in `FroxelMedium` next to the fog volumes (no extra texture, no extra pass).
Its extinction depends on the world z only, so it is anchored in the world and reprojects like the rest of the
volume. Off by default (`r_volumetricFogHeight 0`): mode 2 is then unchanged, and a map without fog
volumes still builds no volume at all.

```
h        = p.z - r_volumetricFogHeightBase
sigma0   = -ln(1.5 / 255) / r_volumetricFogHeightOpaque * volumetricFogScale * r_volumetricFogScale
sigma(h) = sigma0 * min(exp(-h / r_volumetricFogHeightFalloff), r_volumetricFogHeightMax)
                  * (1 - smoothstep(top - fade, top, h))       top = r_volumetricFogHeightTop (0: no cutoff)
                                                                fade = min(falloff, top)
medium   = fog volumes + height fog: extinctions add, albedo = extinction weighted average
```

Units: extinction per world unit, the same conversion as the fog volumes. `r_volumetricFogHeightOpaque` is a
`fogParms` depthForOpaque: the distance through the medium at the base height after which the transmittance is
1.5/255. There is no separate density scale. Below the base the density grows up to `HeightMax` times the base
density (1 = flat layer below the base). The color is a `fogParms` color (sRGB, converted like the fog volumes).

The base height is set to the lowest floor of the map whenever it loads (`R_SetHeightFogBase`, tr_bsp.cpp: the
lowest point of the visible opaque world surfaces, planar ones only when they face up; the world bounds if there
is none); change the cvar afterwards to move it.

Lighting is the one of the fog volumes (baked grid, sun + cascades, dynamic lights + their shadows, HG phase,
temporal filter, bloom). The global fog stays a fog volume medium; the height fog adds to it and never replaces it.
Transparent surfaces after `SS_FOG` outside every fog volume look the volume up when the height fog is on
(`RB_VolumetricHeightFogSurface`: generic `USE_FOG` permutation, fog pass, surface sprites).

### `r_vfog` console command

Adds this medium to any map (a map without BSP fog volumes has no froxel passes, so no light beams, until it
has a medium). A front end to the `r_volumetricFogHeight*` cvars, so the values are archived:

```
r_vfog                          state and warnings (needs r_volumetricFog 2, r_depthPrepass 1)
r_vfog help
r_vfog on | off | reset
r_vfog opaque 2500 falloff 600 color 0.75 0.8 0.85   any keys, switches the medium on
       keys: opaque <u>, falloff <u>, color <r g b>, base <z> | auto, top <u>, max <scale>
r_vfog uniform 4000 [r g b]     uniform haze (falloff 65536, no ceiling)
```

The sky: a finite falloff leaves almost no medium at the sky distance, so the sky stays clear behind the beams;
a uniform haze continues to the sky through the tail and fogs it like the legacy fog cap.

## Heterogeneous density (world space noise)

Optional, off by default (`r_volumetricFogNoise 0`: every medium stays homogeneous and mode 2 is unchanged). The
extinction of the selected media is multiplied by a world anchored noise field; nothing else changes. The light
(baked grid, sun, dynamic lights) is not modulated: voids, clumps and broken beams come only from the changed
scattering and extinction (emission = extinction * albedo * light).

```
sigma(p) = sigma_plain(p) + m(p) * sigma_noisy(p)        noisy: the media selected by r_volumetricFogNoise
m(p)     = N_M(lod_M) f(n_M; c_M) * N_D(lod_D) f(n_D; c_D)       (detail factor only when c_D > 0)
f(n; c)  = (1 + c) n^c
n_M      = noise.r at  p / P_M - wind_M                            P_M = r_volumetricFogNoiseScale
n_D      = noise.g at  R_z(30 deg) p / P_D + (0.37, 0.61, 0.23) - wind_D   P_D = r_volumetricFogNoiseDetailScale
lod      = max(log2(sliceThickness(depth) * 64 / P) - 1, 0)
```

- **Mean.** The texels of both channels are uniformly distributed over 0..255 (histogram equalized), and
  `E[(1 + c) n^c] = 1` for a uniform n and any c: the modulation keeps the average extinction (the mean optical
  depth). Trilinear filtering and the mips lower the variance of n, so the CPU measures `E[f]` of the real filtered
  texture at lod 0, 0.5, ..., 6 (32768 low discrepancy positions, the same trilinear / mip blend as the GPU) and
  divides it out (`N`). Macro and detail are independent fields, so their product keeps the mean too.
- **Contrast.** `c = 0` gives m = 1, the original homogeneous density. `c = 1` gives a density from 0 to 2x (voids
  and clumps). `c = 3` gives sparse clumps up to 4x. With `c <= 1` the standard deviation of m is at most 0.57.
- **Anti-aliasing.** The mip level follows the froxel: one level sharper than the slice thickness (the jittered
  positions of the temporal filter average the rest). Far froxels see prefiltered noise with a lower contrast and
  the same mean, so distant fog tends to homogeneous instead of shimmering. Medium preset (48 slices, far 4096):
  macro (4096) lod 0 up to ~900 units, 1.1 at 2000, 2.2 at 4096; detail (900) 1.3 at 500, 3.3 at 2000.
- **World anchoring.** The texture coordinates are world positions (no camera, froxel or screen coordinates). The
  noise is sampled at the jittered position of the baked + sun term (the temporal filter supersamples it inside
  the froxel) and at the froxel center for the dynamic lights (no history, stable).

### Noise texture

| | |
|---|---|
| image | `tr.froxelNoiseImage` (`*froxelNoise`), 3D, 64 x 64 x 64, `GL_RGBA8`, full mip chain (7 levels), `GL_REPEAT`, `LINEAR_MIPMAP_LINEAR` |
| r | macro field |
| g | detail field (independent seed) |
| b, a | unused (0) |
| memory | 1 MiB + mips = 1.14 MiB of VRAM; CPU copy of both channels with their mips 0.57 MiB (static, kept for the mean tables) |
| created | at renderer init with `r_volumetricFog 2` only (`R_CreateVolumetricImages`), no asset |
| CPU cost | generation ~120 ms once per process (the CPU copy survives `vid_restart`); mean table ~50 ms per channel, only when its contrast changes |

Generation (`R_NoiseGenerateField`, deterministic, fixed seeds): per channel, a tileable gradient (Perlin) noise
FBM of 3 octaves with lattice periods 4, 8 and 16 cells per tile (weights 1, 0.5, 0.25, quintic fade, 12 edge
gradients from an integer hash of the lattice point modulo the period, so the tile wraps). Each octave is shifted
by its own fraction of a cell, otherwise the lattice points of the three octaves (where gradient noise is 0)
coincide and form a visible grid. Then rank based histogram equalization: every value 0..255 is taken by exactly
1024 texels. `R_CreateImage3D` gained a `flags` argument (default `IMGFLAG_CLAMPTOEDGE`, as before for every other
caller): without it the wrap is repeat, and `IMGFLAG_MIPMAP` allocates the mip chain (`glGenerateMipmap`).

### Media

`r_volumetricFogNoise` is a bit mask: 1 height fog, 2 BSP fog volumes, 4 the global fog. The flag of each fog
volume travels in `fogMaxs[i].w`. There are no local density volumes in the renderer yet. With 0, or with both
contrasts at 0, the injection takes a uniform branch and samples nothing.

### Wind and the temporal filter

`r_volumetricFogNoiseWind "x y z"` (units per second, default 0) moves the noise:
`wind offset = fract(wind * t / P)` per octave, computed in double precision from the renderer time and wrapped
to the tile (the detail wind is rotated like its coordinates). With no wind the noise is completely static in
the world. The weather system's wind is not used (it is gusty, and exists only with weather effects).

The history clamp works on radiance (emission / extinction), which a moving density does not change, so it cannot
catch the drift. The history weight of the noisy media is lowered instead, so that the lag of the temporal filter
stays under a tenth of the finest noise feature (`P / 16` of the finest active octave):

```
lag      = |wind| dt w / (1 - w)  <=  lambda = 0.1 P_finest / 16
w_noise  = min(w, lambda / (lambda + |wind| dt))          dt = frame time, clamped to [1/240, 1/15] s
w_froxel = mix(w, w_noise, noisy share of the froxel's extinction)
```

At 60 fps with `w = 0.9`: winds up to ~32 u/s keep the full weight. At 128 u/s the weight is 0.90 macro only and
0.73 with detail (lag 19 / 6 units). At 512 u/s it is 0.75 / 0.40. Media without noise keep the full weight in
every case. Changing the mask, a scale or a contrast resets the history.

### Samples and cost

| settings | noise fetches per froxel |
|---|---|
| `r_volumetricFogNoise 0` or no noisy medium at the froxel | 0 |
| macro only (default contrasts) | 1, +1 in slices with dynamic lights |
| macro + detail | 2, +2 in slices with dynamic lights |

The medium at the froxel center (the dynamic light term) is now evaluated only in slices that have dynamic lights,
which saves one `FroxelMedium` call per froxel elsewhere with or without noise (the output is identical). Each
fetch is an explicit lod `textureLod` of a 1 MiB texture, plus one `pow` and a table lookup.

**Timings: not measured** (the game has not been run with this change). Procedure: `r_speeds 100`, "Froxel fog
inject", stationary camera on a fog map, 1920x1080. For each quality preset, compare three runs:
`r_volumetricFogNoise 0`; `r_volumetricFogNoise 7`; `r_volumetricFogNoise 7` with
`r_volumetricFogNoiseDetailContrast 1`.

| preset | inject, noise off | macro | macro + detail |
|---|---|---|---|
| low | | | |
| medium | | | |
| high | | | |

### Repetition

Macro period 4096 by default, the same as the default froxel far: across the whole volume one tile is seen at most
once. Beyond that, mip levels 2 and higher have removed most of the contrast of the finer octaves. Within a tile
there are 4 x 4 x 4 coarse cells: features from ~1024 down to ~256 units. The detail field has a period of 900 (a
non integer ratio of 4.55 to the macro), is rotated by 30 degrees around z and offset, so the product has no short
common period and no shared axis. A top down 16384 x 16384 render of macro x detail shows no obvious tiling, while
macro alone at 8192 wide (2048 period, the first default) did: that is why the default is 4096. Along z a tile
is also 4096 high, and a thin height fog slab crosses a single layer.

### Debug views

| view | shows |
|---|---|
| 13 | m(p) at the scene surface, per pixel, finest mip, world space (no froxels): black 0, white 1, yellow to red 1 to 4 |
| 14 | extinction of the froxel at the scene depth, the injection drops the noise (base sigma), heat of 512 units of it on the view 1 scale |
| 15 | as 14 with the noise (modulated sigma) |

Optical depth is view 1 and the final scattering is view 6 or 9. Views 11 and 12 split the media with the noise.
**World space vs camera grid:** set `r_volumetricFogFreeze 1` and move. The frozen volume keeps its froxel
grid, and inside it the pattern of view 15 must stay at the same world place as view 13 (which has no froxels at
all). A pattern that follows the old frustum's cells, or the screen, is a grid artefact.

## Integration (`volumetric_integrate.glsl`)

Front to back over the slices of every froxel column, with the medium constant inside a slice:

```
length = (B(k+1) - B(k)) * |ray|                     // path length along the froxel's ray
Ts     = exp(-extinction * length)
S     += T * (emission / extinction) * (1 - Ts)      // extinction -> 0: emission * length
T     *= Ts
```

This is the discretisation of the legacy ray march (`color += light * T * (1 - exp(-z))`), so extinction is in
the same units as `depthToOpaque` and fog maps keep their density. Checked numerically against the exact
homogeneous solution: the largest absolute error of S or T after the trilinear lookup is 0.0006 (depthForOpaque
256 to 4096, distances 20 to 3000).

## Temporal reprojection

- Every froxel center is projected with the froxel camera of the history volume (the main view projection
  without the SMAA T2x jitter; kept on the CPU, independent of the velocity buffer). Its view depth gives the
  history slice. Outside the previous volume (disocclusion at the frustum edges): no history.
- `current = mix(current, history, weight)`, `weight = r_volumetricFogHistoryWeight` (0.9).
- The radiance of the history (emission / extinction) is clamped to `[current / 4, current * 4]`, so light that
  changed (moving entity shadows, switched lights) does not ghost for long.
- **Dynamic lights have no history** (their own volume), so moving sabers, blaster bolts and explosions cannot
  leave trails. They are sampled at the froxel center with a fixed shadow pattern, so they need none.
- **History reset**: map change, no volume in the previous frame, camera move over 256 units, rotation over 75
  degrees, FOV change over 15%, near / far / debug view change, `r_volumetricFogReset 1` (game code, cleared by the
  renderer), the motion blur cut detection (`tr.temporalHistoryValid`, when `r_motionBlur` is on).
- "A volume in the previous frame" means one the GPU passes actually wrote (`RB_VolumetricBuild` records the
  frame and the image), not only one the constants planned: a skipped build (no draw surfaces, the view not on
  `renderFbo`, ...) must not turn a never written image into the history. The volumes are cleared at creation,
  and the inject pass drops a NaN / Inf history and never writes one, so a bad froxel cannot be fed back.
- **Draw buffers 2-4 are color masked by default when SSR is on** (`GL_ResetSSRAuxWrite` after every
  `qglColorMask`, the SSR material attachments of `renderFbo`). Any froxel pass that writes attachment 2 or
  higher, or clears it, must enable it with `GL_SetSSRAuxWrite(true)` and restore it. The integrate pass writes
  the tail there: without it the tail was never written, which on a first map is zeroed memory (no fog beyond
  far) and after a map change (the GL context is kept) recycled VRAM: black blurry froxel squares over the whole
  sky (seen on taspir1), history and light term independent, gone after `vid_restart`.
- Depth discontinuities: the froxel volume is world anchored and defined behind geometry too, so reprojection has
  no depth edges; the screen-space disocclusion case is the frustum edge above.
- Without temporal accumulation (`r_volumetricFogTemporal 0`): no jitter, froxel centers, 4 shadow taps.

## Composition

- **Opaque layers** (`sort <= SS_FOG`: opaque, sky, decals, see-through, banners, fog volume faces): one full
  screen pass after these layers, from the depth buffer: `color * T + S` into the HDR scene, before tone mapping
  (blend `ONE, SRC_ALPHA`, destination alpha kept). The first person view model is moved back from the depth
  hack range; the sky (depth 1) is at `max(zFar, depthForOpaque of the global fog)` like the legacy fog cap.
  Their per-surface fog passes, in-shader fog, the global fog cap and the inverted fog plane passes are skipped
  in the froxel view: the volume contains every fog along the ray, nothing is fogged twice.
- **Transparent layers** (`sort > SS_FOG`) keep the existing mechanism (fog pass with its blend, `u_FogColorMask`
  of generic stages, surface sprites) with `(S, 1 - T)` looked up at the fragment instead of the ray march.
  Additive surfaces are only attenuated, as before.
- **Bloom.** The composite attenuates the glow buffer by T like the legacy fog pass did. `r_volumetricFogBloom`
  (default 0) adds the bright part of the in-scattering (soft knee above 0.5) to the glow buffer, so light beams
  bloom and the dim haze does not. The HDR highpass of `r_dynamicGlowBloom` also sees the fogged scene.

## Cvars

| cvar | default | |
|---|---|---|
| `r_volumetricFog` | 0 | latched. 0 off, 1 legacy light grid ray march, **2 froxel volume** |
| `r_volumetricFogQuality` | 1 | latched. 0 low, 1 medium, 2 high (table above) |
| `r_volumetricFogGridScale` | 0 | latched. Screen pixels per froxel, 0 = preset |
| `r_volumetricFogSlices` | 0 | latched. Depth slices (16..128), 0 = preset |
| `r_volumetricFogFar` | 0 | Distance covered by the slices, 0 = 4096 |
| `r_volumetricFogAnisotropy` | 0.2 | HG g of sun and dynamic light scattering, -0.9..0.9. The baked light stays isotropic |
| `r_volumetricFogTemporal` | 1 | Temporal accumulation and jitter |
| `r_volumetricFogHistoryWeight` | 0.9 | Weight of the history, 0..0.98 |
| `r_volumetricFogSunScale` | 1 | Sun scattering multiplier (baked and realtime) |
| `r_volumetricFogDlightScale` | 1 | Dynamic light scattering multiplier |
| `r_volumetricFogStaticScale` | 1 | Baked light scattering multiplier |
| `r_volumetricFogDlightShadows` | 1 | Dynamic lights use their shadow maps (needs `r_dlightMode 2`) |
| `r_volumetricFogBloom` | 0 | Bright in-scattering added to the glow buffer |
| `r_volumetricFogReset` | 0 | Set by game code on camera cuts, cleared by the renderer |
| `r_volumetricFogDebug` | 0 | cheat, debug views below |
| `r_volumetricFogFreeze` | 0 | cheat, keep the volume and its camera |
| `r_volumetricFogHeight` | 0 | height fog on / off |
| `r_volumetricFogHeightOpaque` | 3000 | height fog: depthForOpaque at the base height (units) |
| `r_volumetricFogHeightBase` | 0 | height fog: world z of the base, set to the lowest floor on map load |
| `r_volumetricFogHeightFalloff` | 256 | height fog: scale height (density / e per this many units above the base) |
| `r_volumetricFogHeightMax` | 1 | height fog: maximum density below the base, multiple of the base density |
| `r_volumetricFogHeightTop` | 0 | height fog: soft cutoff height above the base, 0 = none |
| `r_volumetricFogHeightColor` | 0.7 0.75 0.8 | height fog: scattering color (albedo), as fogParms |
| `r_volumetricFogNoise` | 0 | density noise media mask: 1 height fog, 2 BSP fog volumes, 4 global fog |
| `r_volumetricFogNoiseScale` | 4096 | macro noise tile period (world units) |
| `r_volumetricFogNoiseContrast` | 1 | macro contrast c, 0..4 (0 = homogeneous) |
| `r_volumetricFogNoiseDetailScale` | 900 | detail noise tile period (world units) |
| `r_volumetricFogNoiseDetailContrast` | 0 | detail contrast, 0 = off (no second fetch) |
| `r_volumetricFogNoiseWind` | 0 0 0 | noise drift, world units per second |

The existing `r_volumetricFogScale`, `r_volumetricFogDefaultScale` and the `volumetricFogScale` worldspawn key
scale the extinction in both modes; `r_volumetricFogSamples` only concerns the legacy ray march. Mode 2 needs
`r_depthPrepass 1` (also required by the sun shadows); otherwise the legacy fog is used.

Defaults are conservative: the scales are 1, the anisotropy is mild (0.2) and the baked light is isotropic.
Without sun shadow maps (`r_sunlightMode 0`), without dynamic lights and with `r_volumetricFogAnisotropy 0`,
mode 2 shows the legacy in-scattering of the baked light (static + baked sun == the legacy light map).

## Debug views (`r_volumetricFogDebug`, drawn over the frame)

| view | shows |
|---|---|
| 1 | density: optical depth between camera and scene (heat map, red = 4 or more) |
| 2 | sun in-scattering without shadows |
| 3 | sun in-scattering with shadows |
| 4 | dynamic light in-scattering |
| 5 | baked light in-scattering |
| 6 | in-scattering of all lights |
| 7 | transmittance |
| 8 | temporal history weight, average over the fogged froxels in front of the scene (dark red: no fog) |
| 9 | integrated volume: in-scattering over black, blue where the fog is opaque |
| 10 | froxel slice at the scene depth (heat), froxel grid lines |
| 11 | as 1, fog volumes only (the injection drops the height fog) |
| 12 | as 1, height fog only (the injection drops the fog volumes) |
| 13 | density noise m(p) at the scene surface (see Heterogeneous density) |
| 14 | froxel extinction at the scene depth without the noise |
| 15 | froxel extinction at the scene depth with the noise |

Views 2 to 5 keep only that light term in the injection, so the scene behind the overlay also shows it. Changing
the view resets the history. `r_volumetricFogFreeze 1` keeps the froxel volume and its camera: move away to see
the frozen frustum (outside it there is no fog).

GPU timings: `r_speeds 100` lists "Froxel fog inject", "Froxel fog integrate" and "Froxel fog composite" with the
other GPU timed blocks (GL timestamp queries).

## GPU cost

Not measured yet (the renderer has not been run with this mode). Expected shape: injection dominates (one full
screen triangle per slice at froxel resolution; cost grows with the number of fog volumes, the lights of the
slice and the cascade lookups), integration is a few texture fetches per froxel, the composite is one full screen
pass. Maps without fog volumes do no froxel work at all unless the height fog is on. The height fog adds one
`exp`, one `smoothstep` and a few ALU to each of the two `FroxelMedium` calls per froxel (a uniform branch when
off); it makes more froxels non-empty, so more of them take the light path. Profile with `r_speeds 100` on low / medium / high before
changing the presets.

## Validation checklist

Launch with `r_volumetricFog 2` (latched: `vid_restart`), `r_depthPrepass 1`, `r_sunlightMode 2` and
`r_dlightMode 2` for the shadowed paths. Compare with `r_volumetricFog 1` (A/B DLLs `build/ab/*-prevfog.dll`
vs `*-vfog.dll`).

| scene | where | what to look for | useful views |
|---|---|---|---|
| sun through a doorway | hoth2, vjun1, mp/duel9 | beams in fog, no sun behind walls, stable edges | 3, 2 vs 3 |
| bright exterior fog | hoth2, mp/ctf2 | brightness close to mode 1 with `r_volumetricFogAnisotropy 0` | 6, 5 |
| dark corridor with lights | t2_rogue, kor2 (black fog) | baked light like mode 1, dynamic lights visible | 5, 4 |
| saber in fog | any fog map, saber on | colored haze around the blade | 4 |
| moving saber | swing fast | no trail | 4, 8 |
| blaster bolt, explosion | fire at a wall in fog | short local haze, no trail | 4 |
| light behind a wall | dynamic light on the other side | no light leaking through (`r_dlightMode 2`) | 4 |
| camera through a fog boundary | walk into / out of a fog volume | smooth transition, no pop | 1, 7 |
| rapid turn | spin | no smearing; history drops at the frustum edge | 8 |
| teleport / cut | `setviewpos`, cinematics | history reset, no ghost frame | 8 |
| different FOV | `cg_fov 60 / 110`, zoom | same fog density, reset on large jumps | 1, 10 |
| legacy maps | `r_volumetricFog 1` and `0` | identical to before | - |
| height fog, flat outdoor | mp/ffa3, t1_surprise: `r_volumetricFogHeight 1` | haze along the ground, clear sky overhead | 12, 1 |
| height fog, camera above / inside | fly up (noclip), then back down | layer stays in place, no pop crossing the base | 12, 8 |
| height fog, sun rays | outdoor map with doorways, `r_sunlightMode 2` | shafts in the haze | 3 |
| height fog, saber / dlight | saber on inside the haze | colored glow like in fog volumes | 4 |
| height fog + fog volume | map with a fog volume near the ground | both visible, additive | 11, 12, 1 |
| height fog + global fog | map with a global fog | global fog unchanged with `r_volumetricFogHeight 0` | 11 |
| no fog map, defaults | any map without fog | no haze, no froxel timers in `r_speeds 100` | - |
| noise, stationary | fog map, `r_volumetricFogNoise 7` | clumps and voids, no crawling | 13, 15, 1 |
| noise, translation / rotation | walk, strafe, turn | the pattern stays in the world (compare with 13) | 15, 13 |
| noise, rapid movement | run and spin fast | no smearing beyond the unnoised fog | 15, 8 |
| noise, freeze | `r_volumetricFogFreeze 1`, move away | view 15 inside the frozen frustum matches view 13 | 15, 13 |
| noise, fog boundary | walk through a noisy BSP fog volume boundary | no pop, the boundary stays sharp | 15, 11 |
| noise, sun shaft | outdoor fog with doorways, `r_sunlightMode 2` | broken beams through clumps, no light change in voids | 3 |
| noise, saber | saber on in noisy fog | blade haze follows the density, no flicker | 4 |
| noise, wind | `r_volumetricFogNoiseWind "64 0 0"` | drift without trails; weight drops in 8 | 15, 8 |
| noise, temporal off / on | `r_volumetricFogTemporal 0 / 1` | same mean density; off = sharper, some aliasing far away | 1, 15 |
| noise, mean | `r_volumetricFogNoiseContrast 0` vs `1` / `3` | similar average fog (view 1 far away) | 1 |
| noise, repetition | open outdoor fog, look far | no visible tiling at typical distances | 15, 6 |
| noise timings | see Samples and cost | fill the table | - |

## Known limitations

- Only the main view of the first world scene has a volume; portals, mirrors, the sky portal and the LA goggles
  use the legacy fog in mode 2.
- Transparent surfaces outside every fog volume are not fogged even if a fog volume lies between them and the
  camera (same as the legacy fog, they get no fog pass). Opaque surfaces are fogged by the full ray.
- Froxel resolution: a fogged pixel takes the fog of its froxel column, so thin geometry in front of dense fog can
  show a slightly blurred fog edge (8 pixels at medium).
- The light grid split is a heuristic; `r_volumetricFogSunScale` / `StaticScale` balance it per map.
- The history of the view model region is reprojected like the world (the volume is world space).
- Moving fog volumes (brush entities) are not supported (neither are they in the legacy fog).
- Height fog: beyond `r_volumetricFogFar` the last slice extinction is extrapolated (constant along the ray);
  thin layers far away are limited by the slice depth; only mode 2 has it; one global layer set by cvars; the
  automatic base is the lowest floor, which can be a pit or a basement below the main ground level.
- Density noise: 64^3 tile. With the macro field alone the period (4096) can show on huge open views when the
  volume far is raised; turn the detail on or raise the scale. The same field modulates every noisy medium (no
  per medium scale). No local density volumes. A fast wind lowers the history weight of the noisy media (more
  jitter noise). The mean is kept within 1% (0.8% up to contrast 3, 1.2% at 4 between half mip levels): checked on
  the CPU with the same generator code and the GPU's filtering.
- Not run in game yet: correctness is verified by builds, offline compilation of every changed / new shader on
  the Intel and NVIDIA drivers, the legacy source comparison and the numeric checks above.

## Possible improvements (not implemented)

- Local density volumes, per map height fog / noise settings, per medium noise scale.
- Per tile light lists instead of per slice masks.
- Depth aware (minimum depth per froxel column) skipping of hidden froxels.
- Blue noise instead of a Halton cycle for the jitter.
