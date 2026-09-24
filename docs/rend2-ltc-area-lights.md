# rend2 LTC area lights (`r_ltcAreaLights`)

Rectangle and line (saber) area lights shaded with Linearly Transformed Cosines.
**Forward+ only**: the legacy 32-light `dlightBits` path is untouched. Off by default.

Status (2026-09-25): implemented and built (MSVC: rend2 SP/MP, both engines, cgame, jagame, vanilla
renderers). The GLSL compiles and links on the Intel and NVIDIA drivers (240 lightall permutations:
LTC off, on, and on with debug). The LUT is checked against Monte Carlo. **The game has not been
launched yet**: the in-game checks, GPU timings and screenshots below are still to do.

## Cvars and commands

| cvar | default | |
|---|---|---|
| `r_ltcAreaLights` | 0 | archive, **latch** (vid_restart). The LTC code is only compiled into lightall when this is on |
| `r_ltcDebug` | 0 | cheat, latch. 1 specular, 2 diffuse, 3 source mode, 4 area lights per cluster, 5 influence bounds, 6 outlines, 7 normals / axes, 8 strongest light id |
| `r_ltcDebugLight` | -1 | map light highlighted in modes 5–7 (-1 = the nearest) |
| `r_ltcIntensityScale` | 1 | radiance multiplier for all area lights |
| `r_ltcStaticDiffuse` | 0 | also add diffuse for `static_specular` lights (their diffuse is normally baked) |
| `r_ltcMaxLights` | 64 | map lights per scene, nearest first (dynamic lights are not counted) |
| `r_saberAreaLights` | 0 | sabers light as lines instead of a point light |

There is no quality cvar, because the polygon integral takes no samples.

Commands:
- `r_reloadAreaLights` rereads the map file without restarting the map.
- `r_ltcList` lists the loaded lights with their IDs.
- `r_ltcNearest` shows the nearest light.
- `r_extractAreaLights` writes candidate lights (see below).

Dependency messages are printed once each time the cvars change, not every frame, and only the first
missing dependency is reported:
- "LTC area lights require r_forwardPlus 1": LTC stays inactive until Forward+ is turned on, then
  works without touching the cvar again.
- "Saber area lights require r_ltcAreaLights 1".
- "LTC area lights need more than 21 texture units".

## Data model and Forward+ integration

Area lights are `dlight_t` entries with extra fields: `areaType` (`DLIGHT_POINT`/`RECT`/`LINE`,
with DISK and SPOT reserved), `areaRight`, `areaUp`, `halfWidth`, `halfHeight`, `areaFlags` and
`areaId`.
- `origin` is the center. `color` is the emitted **radiance** (not normalized).
- `radius` is the cull sphere: range + half diagonal.
- The emitting side is `cross(right, up)`.

Flags: `AREALIGHT_TWO_SIDED`, `AREALIGHT_SPECULAR_ONLY`, `AREALIGHT_DYNAMIC`,
`AREALIGHT_SELECTED` (debug highlight).

They go through the unchanged Forward+ importance sort and sphere cluster culling
(`R_ForwardPlusLightRange`). The light buffer grows from 3 to 5 RGBA32F texels per light:

| texel | point light | area light |
|---|---|---|
| t0 | origin, radius | centre, influence range |
| t1 | color, 0 | radiance, type |
| t2 | shadow slot, 0, 0, 0 | -1, flags, halfWidth, halfHeight |
| t3 | – | right |
| t4 | – | up |

Point lights still fetch only 3 texels. Area lights are kept out of:
- shadow cube selection (they are unshadowed),
- `R_GetUboDlights` (the legacy Lights block, which is what froxel fog reads),
- flares.

**Physical evaluation vs culling.** The geometry itself does the falloff. `range` only drives a
smooth window, `(1 - (d/range)^4)^2`, measured from the closest point on the emitter, so the cull
radius is never visible. If a map light has no `range`, one is derived from where irradiance falls
below about 1% of radiance, and it is never less than the emitter size + 16.

## Shader formulas (lightall.glsl, `EvaluateAreaLight`)

Inputs:
- The receiver tangent frame is (T1 in the N–V plane, T2, N).
- The quad corners relative to the receiver are `c∓R∓U`.
- FF = form factor, i.e. the cosine-weighted solid angle / π. It is computed with Hill's edge-vector
  rational fit, and horizon clipping uses the sphere approximation (LUT 2 `.w`).

Terms:
- **Specular**: `L · FF(M⁻¹·quad) · (F0·norm + (1−F0)·fresnel·sat(50·F0.g))`. The last factor is
  the same no-specular cut as `F_Schlick`.
- **Diffuse**: `L · albedo · FF(quad)`. This is the exact Lambert form factor, and it is skipped for
  `SPECULAR_ONLY`.
- **Cloth BRDF**: there is no second LUT. The Charlie lobe is evaluated at the closest point of the
  emitter, weighted by π·FF, because the lobe is wide and a separate table would not show.
- **Burley diffuse**: area diffuse uses Lambert (a small difference).
- **Line (saber)**: a ribbon one tube diameter wide, rebuilt per pixel to face the receiver (it has
  the same projected area as the tube). This gives an elongated highlight, not a sphere-like one.
  It is always two-sided.
- **One-sided emitters**: nothing reaches the receiver from behind the emitter plane, and nothing
  reaches the back of the emitter.
- **Vertex-lit (non-per-pixel) programs** get no area lights.

## LUT: source, generation, license

`tools/ltcfit/ltcfit.cpp` is our own fitter, written from Heitz et al. 2016 ("Real-Time
Polygonal-Light Shading with LTC") and Hill & Heitz 2016. It uses no code or data from the reference
implementation, so no third-party license applies. The papers are cited in the source.
- Model: GGX with height-correlated Smith, visible-normal importance sampling, and Nelder–Mead on
  (m11, m22, m13) with 2×32×32 MIS samples per texel. It runs in about 45 s on all cores.
- Output: `shared/rd-rend2/tr_ltc_data.h`, which is compiled in and uploaded as two 64×64 RGBA16F
  textures (units 20 and 21). Nothing is fitted at startup.
- **u axis** = `sqrt(alpha)`, where alpha is rend2's `roughness` (lightall uses it directly as the
  GGX alpha). **v axis** = `sqrt(1 − N·V)`. The texel centers use the usual
  `(size−1)/size, 0.5/size` scale and bias.
- Table 1: M⁻¹ normalized by `M⁻¹[1][1]`, as `(m00, m02, m20, m22)`.
- Table 2: `(norm, fresnel, 0, sphereFF/|F|)`. The `.w` channel is indexed by
  `(z·0.5+0.5, |F|)`.

Regenerate with:

```bash
g++ -O2 -std=c++17 -o ltcfit tools/ltcfit/ltcfit.cpp -lpthread && ./ltcfit shared/rd-rend2/tr_ltc_data.h
```

Self-test: build with `-DLTC_TEST_HEADER='"path/tr_ltc_data.h"'` and run `ltcfit -test`. It compares
200 random rectangles against a Monte Carlo reference:
- **diffuse**: 0.00% error,
- **specular**: 9.2% mean absolute error relative to the mean, concentrated in grazing or
  barely-overlapping cases where the values are tiny (typical for LTC fits),
- norm at alpha→0, normal incidence = 1.0000.

## Authoring: `maps/<map>.arealights.json`

A human-editable file, separate from the BSP. It can be packed in a PK3, and
`r_reloadAreaLights` reloads it live. See `docs/samples/example.arealights.json`.

Top level: `{ "lights": [ ... ] }`.

Rectangle fields:
- `type` `"rect"`
- `center`, `right`, `up`. `up` is re-orthogonalized, and the emitting side is `right × up`.
- `halfWidth`, `halfHeight`
- `color` (default 1 1 1) and `intensity` (default 1). Radiance = color × intensity.
- `range` (optional)
- `mode`:
  - `static_specular` (default): the stock lightmapped lamp gets specular only.
  - `static_full`: diffuse + specular.
  - `dynamic`: diffuse + specular, and the diffuse also feeds SSGI.
- `twoSided` (default false)
- `name`

Line fields: `type` `"line"`, `start`, `end`, `radius`, plus the same color / intensity / range /
mode fields.

## Stock asset discovery and extraction

- The parser now keeps `surfacelight` / `q3map_surfacelight` and `lightColor` / `q3map_lightRGB` in
  `shader_t` (`surfaceLight`, `surfaceLightColor`). Nothing renders from them, so legacy behavior is
  unchanged.
- `r_extractAreaLights` takes the loaded map's `SF_FACE`/`SF_TRIANGLES` surfaces whose shader has a
  surfacelight hint or a `glow` stage, skipping sky and nodraw.
- It groups coplanar, vertex-connected triangles of one shader (union-find), fits the plane bounding
  rectangle along the principal axis, and emits along the face normal.
- Confidence = covered fraction of that rectangle. `"review": true` marks confidence < 0.8 or
  glow-only (no surfacelight).
- Intensity is `surfacelight / 300`, clamped. That is only a starting point: q3map values are not
  radiance.
- It writes `maps/<map>.arealights.generated.json`. That file is never loaded automatically, and
  the BSP is never modified. Rename it to use it.

## Sabers

- cgame `CG_DoSaber` / `CG_DoSaberLight` (SP and MP) call `AddLineLightToScene(base, tip, radius/2,
  length·1.4, rgb)` when the `r_saberAreaLights` mirror is on.
- Each blade becomes its own line. Only if the renderer returns false is the old point light added,
  so the two are never both active.
- Blade radiance = saber color × 4 × `r_ltcIntensityScale` (`SABER_AREA_RADIANCE`, to be tuned in
  game).

API, chosen to stay compatible (`refexport_t` and `REF_API_VERSION` are **unchanged**, so the A/B
renderer DLLs keep loading):
- rend2 exports an optional `GetRefAreaLightAPI` symbol that returns `refAreaLightExport_t`
  (`AddAreaLightToScene`, `AddLineLightToScene`). The engines look it up (`reAreaLights`, NULL for
  other renderers).
- SP adds syscall `CG_R_ADDLINELIGHTTOSCENE` (appended). MP adds `cgameImport_t.ext.R_AddLineLightToScene`
  (appended; legacy VM cgame returns false).
- cgame only calls it when `r_saberAreaLights` is set, so an old engine with a new cgame stays safe
  unless that cvar is turned on.
- Using saber lines needs the rebuilt engine and game modules as well as the renderer.

## Interactions

- **SSGI**: only diffuse from non-spec-only lights is added to `g_ssgiDynamicDiffuse`; specular
  never is. Static spec-only lamps add nothing. The emissive lamp surface stays an SSGI source on
  its own.
- **SSR / cubemaps**: unchanged and additive. A surface shows both the direct LTC highlight and the
  reflection.
- **POM self shadow**: one ray towards the emitter center, weighted by the existing per-pixel light
  budget. Area lights are not in the budget ranking. This is an approximation; there are no
  per-corner rays.
- **Shadows**: none. LTC gives the BRDF integral, not area visibility. Static lamps rely on the
  lightmap. `DynamicLightReceiverVisibility` is the hook for later.
- **Volumetric fog**: area lights are not injected, because the fog reads the point-only legacy
  UBO. The type is in the light data for a later capsule approximation.

## Validation still to do in game

For each scene below, check with `r_ltcDebug 1/2/3/6/7`, and confirm that setting
`r_ltcAreaLights 0` + vid_restart returns the legacy image:
- a rectangle above glossy, rough, metallic and plastic floors;
- the back of a lamp and a lamp seen edge-on;
- a hangar light and multiple lights;
- a static lightmapped room (no double lighting);
- a saber near a wall and over a shiny floor, two sabers, and a moving saber;
- SSGI, SSR, POM and volumetric fog, each on and off.

GPU timing: compare `r_forwardPlusBenchmark` with LTC on and off (the table is still empty). Offline
compile cost of one lightall program with `USE_LTC`: +16% on Intel, within noise on NVIDIA, and zero
when off.

## Limitations

- The saber is a ribbon, not an exact line or tube integral.
- There are no area shadows and no volumetric scattering from area lights.
- The specular LUT has a 9% mean error at grazing angles.
- Vertex-lit surfaces are not lit by area lights.
- Extracted intensities need hand tuning.
- The `range` default is heuristic.
