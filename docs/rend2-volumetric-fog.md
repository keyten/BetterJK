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
   Albedo = extinction weighted fog color. Future height fog, noise and local density volumes go into
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

Views 2 to 5 keep only that light term in the injection, so the scene behind the overlay also shows it. Changing
the view resets the history. `r_volumetricFogFreeze 1` keeps the froxel volume and its camera: move away to see
the frozen frustum (outside it there is no fog).

GPU timings: `r_speeds 100` lists "Froxel fog inject", "Froxel fog integrate" and "Froxel fog composite" with the
other GPU timed blocks (GL timestamp queries).

## GPU cost

Not measured yet (the renderer has not been run with this mode). Expected shape: injection dominates (one full
screen triangle per slice at froxel resolution; cost grows with the number of fog volumes, the lights of the
slice and the cascade lookups), integration is a few texture fetches per froxel, the composite is one full screen
pass. Maps without fog volumes do no froxel work at all. Profile with `r_speeds 100` on low / medium / high before
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
- Not run in game yet: correctness is verified by builds, offline compilation of every changed / new shader on
  the Intel and NVIDIA drivers, the legacy source comparison and the numeric checks above.

## Possible improvements (not implemented)

- Height fog and noise modulated density in `FroxelMedium`, local density volumes.
- Per tile light lists instead of per slice masks.
- Depth aware (minimum depth per froxel column) skipping of hidden froxels.
- Blue noise instead of a Halton cycle for the jitter.
