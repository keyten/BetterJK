# Rendering features

This page is a short user-facing reference for BetterJK rendering features. Performance labels are relative: **Zero**, **Light**, **Medium**, or **Heavy**.

# Colors & post-processing

### Tone mapping

**Performance: Zero.**

Changes how HDR brightness is converted to the final image. It affects every HDR map and is easiest to notice on bright skies, lamps, sabers, explosions and dark-to-bright transitions.

Tone mapping compresses the large HDR brightness range into the monitor range. BetterJK supports the legacy Rend2 curve, ACES fitted and an AgX-like curve.

- `r_hdr 0 | 1` — enables HDR rendering. Required.
- `r_toneMap 0 | 1` — enables tone mapping.
- `r_toneMapMode 0` — legacy Rend2 filmic curve.
- `r_toneMapMode 1` — ACES fitted.
- `r_toneMapMode 2` — AgX-like curve.
- `r_exposureCompensation <EV>` — makes the HDR image brighter or darker before tone mapping.
- `r_autoExposure 0 | 1` — automatically adapts exposure to scene brightness.
- `r_cameraExposure <value>` — manual camera exposure control.
- `r_toneMapDebug 1..5` — comparison, raw HDR and exposure debug views.

### Color grading LUTs

**Performance: Light.**

Changes the final palette, contrast and mood of a map. It works on any map; a `maps/<map>.cube` file can give a level its own grading automatically.

A 3D LUT is a small color lookup table. BetterJK reads the rendered color and replaces it with the LUT result.

- `r_colorGrading 0` — disable LUT grading.
- `r_colorGrading 1` — enable it.
- `r_colorGrading 2` — split-screen comparison.
- `r_colorGradingLut "<file>.cube"` — select a LUT manually. Empty uses the map LUT if present.
- `r_colorGradingLut "*identity"` — neutral LUT.
- `r_colorGradingIntensity 0..1` — LUT strength.

### Linear lighting

**Performance: Zero.**

Makes lighting and colors more physically correct. It can affect almost every surface on stock maps, especially dark areas, gradients and bright lights.

Light should be calculated in linear space, not directly in sRGB. This mode decodes the data before lighting.

- `r_linearLighting 0` — legacy Rend2 lighting.
- `r_linearLighting 1` — linear-space lighting. Requires HDR/tone mapping and `vid_restart`.

### HDR bloom

**Performance: Light.**

Creates soft glow around bright sabers, lamps, panels, explosions and sky areas. It is most visible in dark scenes with strong highlights.

The new bloom extracts bright HDR energy, builds a small blur pyramid and adds it back before tone mapping.

- `r_bloom -1` — legacy glow path.
- `r_bloom 0` — bloom off.
- `r_bloom 1` — HDR bloom.
- `r_bloomIntensity <value>` — overall bloom strength.
- `r_bloomThreshold <value>` — brightness where scene bloom starts.
- `r_bloomKnee <value>` — softness around the threshold.
- `r_bloomScatter <value>` — how widely bloom spreads.
- `r_bloomSceneIntensity <value>` — lets bright non-emissive HDR pixels bloom.
- `r_dynamicGlowPasses <count>` — controls the blur pyramid size.

### Velocity motion blur

**Performance: Medium.**

Adds short camera and object motion streaks. It is visible on every map while turning, running, jumping or watching moving characters. HUD and menus stay sharp.

The depth prepass stores movement between frames. The post-process samples along these velocity vectors, similar to a real camera exposure.

- `r_motionBlur 0 | 1` — enable motion blur. Requires HDR and `vid_restart`.
- `r_motionBlurShutterAngle <degrees>` — exposure length.
- `r_motionBlurReferenceFps <fps>` — reference FPS; `0` uses a real shutter angle.
- `r_motionBlurMaxPixels <pixels>` — maximum streak length at 1080p.
- `r_motionBlurQuality 0 | 1 | 2` — low / medium / high quality.
- `r_motionBlurSamples <count>` — sample override; `0` uses the quality preset.
- `r_motionBlurViewModelScale <value>` — blur amount for first-person hands/weapons.
- `r_motionBlurCutDistance <units>` — movement treated as a teleport.
- `r_motionBlurCutAngle <degrees>` — rotation treated as a camera cut.
- `r_motionBlurShutterScale <value>` — gameplay exposure multiplier.
- `r_motionBlurReset 1` — clear motion history.
- `r_motionBlurDebug 1..5` — velocity, camera/object motion, sample count and contribution views.

# Materials & surface detail

### Auto PBR

**Performance: Zero.**

Makes old materials react more naturally to reflections and highlights. It affects legacy materials without authored PBR data on every map.

BetterJK guesses a material class from shader and texture names, then assigns reasonable roughness, metalness and reflectance.

- `r_autoPBR 0` — legacy Rend2 fallback.
- `r_autoPBR 1` — generic dielectric fallback.
- `r_autoPBR 2` — heuristic material classes.
- `r_autoPBRDebug 1` — show detected material classes.
- `r_autoPBRDebug 2` — show authored vs automatic parameters.
- `pbr_dumpMaterials` — print material/PBR information.

### Legacy material PBR conversion

**Performance: Light.**

Moves old shiny vertex-lit materials onto the per-pixel PBR path. It is most visible on materials that used `lightingSpecular` or environment-map shine.

The converter recognizes old shader tricks and keeps their masks as useful PBR roughness/metal information.

- `r_autoPBRConvert 0 | 1` — convert compatible legacy shiny shaders to per-pixel PBR. Requires `vid_restart`.

### Diffuse BRDF

**Performance: Zero.**

Changes the diffuse response of PBR materials under direct light. The difference is subtle but visible on rough surfaces and at grazing angles.

Lambert uses a simple diffuse model. Burley/Disney also considers roughness and viewing/light angles.

- `r_diffuseBRDF 0` — Lambert diffuse.
- `r_diffuseBRDF 1` — Burley/Disney diffuse.

### Physical emissive materials

**Performance: Zero.**

Lets materials emit real HDR radiance. It is useful for lamps, screens and glowing panels; SSGI and bloom can use the same emission.

Emission is added independently from reflected lighting and can have its own mask, color and intensity.

- `r_autoEmissive 0` — explicit emissive materials only.
- `r_autoEmissive 1` — also convert compatible legacy glow/additive stages.

Shader keywords:
- `emissiveMap <image>` — emission texture.
- `emissiveColor <r g b>` — emission color.
- `emissiveScale <value>` — emission intensity.

### Parallax Occlusion Mapping improvements

**Performance: Medium.**

Makes height-mapped surfaces look recessed or raised instead of flat. It is visible only on materials with POM/height data.

POM traces a short ray through the height map to find the visible virtual surface point.

- `r_parallaxMapping 0 | 1` — master POM switch.
- `r_pomAdaptiveSteps 0 | 1` — angle-dependent POM sample count.
- `r_pomMinSteps <count>` — samples at near-normal view angles.
- `r_pomMaxSteps <count>` — samples at grazing angles.
- `r_pomBinarySteps <count>` — final hit refinement.
- `r_pomFadeStart <distance>` — distance where POM starts fading.
- `r_pomFadeEnd <distance>` — distance where POM becomes normal mapping only.
- `r_pomDebug 1..8` — height, UV, hit, self-shadow, step and fade debug views.
- `r_pomDebugFreezeLight 0 | 1` — freeze light direction for debugging.

### POM self-shadowing

**Performance: Heavy.**

Adds tiny shadows inside POM relief. Bricks, cracks and panels can shadow themselves under the sun or nearby lights.

After POM finds the visible point, another ray is traced through the height field toward the light.

- `r_pomSelfShadow 0 | 1` — enable self-shadowing. Requires POM and `vid_restart`.
- `r_pomSelfShadowLights 0` — sun only.
- `r_pomSelfShadowLights 1` — sun + strongest local light.
- `r_pomSelfShadowLights 2` — sun + several strongest local lights.
- `r_pomSelfShadowLights 3` — all local lights.
- `r_pomSelfShadowMaxLocalLights <count>` — local-light limit for mode 2.
- `r_pomSelfShadowSteps <count>` — samples per shadow ray.
- `r_pomSelfShadowStrength <value>` — shadow strength.
- `r_pomSelfShadowBias <value>` — ray start bias.
- `r_pomSelfShadowSoftness <value>` — shadow hardness.

### Silhouette POM

**Performance: Heavy.**

Lets height-mapped surfaces change their actual visible outline and depth. It is useful for chipped stone, broken edges and deep relief viewed from the side.

Ordinary POM cannot leave the original triangle. Silhouette POM builds a small shell around selected surfaces and ray-traces the height field inside it.

- `r_pomSilhouette 0 | 1` — master switch. Requires POM and `vid_restart`.
- `r_pomSilhouetteDistance <units>` — distance where shell rendering stops.
- `r_pomSilhouetteFade <units>` — transition width to ordinary POM.
- `r_pomSilhouetteSteps <count>` — normal-angle ray samples.
- `r_pomSilhouetteMaxSteps <count>` — grazing-angle sample limit.
- `r_pomSilhouetteBinarySteps <count>` — final hit refinement.
- `r_pomSilhouetteViewDependence <value>` — how strongly sample count grows at grazing angles.
- `r_pomSilhouetteShadows 0 | 1` — displaced shells cast sun shadows.
- `r_pomSilhouetteContactShadows 0 | 1` — contact shadows on shell pixels.
- `r_pomSilhouetteDebug 1..11` — shell, walls, depth, ray count and comparison views.
- `r_autoPomSilhouetteMode 0 | 1` — automatically use silhouette POM on ordinary POM materials.
- `r_pomSilhouetteInfo` — print shell statistics.
- `r_autoPomSilhouette 1 | 0` — enable/disable automatic mode globally.
- `r_autoPomSilhouette <shader> 1 | 0 | default` — override one shader; `*` can be used as a prefix.
- `r_autoPomSilhouette list` — list current-map candidates and active shells.
- `r_autoPomSilhouette clear` — remove per-shader overrides.

# Lighting & shadows

### GTAO

**Performance: Medium.**

Adds small-scale ambient shadows in corners, wall/floor contacts, under props and around nearby geometry. It works on every normal world view.

GTAO reconstructs geometry from the depth buffer and estimates how much nearby geometry blocks indirect light.

- `r_aoMode -1` — follow old `r_ssao`.
- `r_aoMode 0` — AO off.
- `r_aoMode 1` — legacy SSAO.
- `r_aoMode 2` — GTAO.
- `r_aoApply -1` — automatic AO application.
- `r_aoApply 0` — legacy AO application.
- `r_aoApply 1` — indirect-light-only AO.
- `r_aoMultiBounce 0 | 1` — keep more indirect light on bright surfaces.
- `r_aoLightmapFraction <value>` — baked-light fraction treated as indirect.
- `r_gtaoQuality 0..3` — low / medium / high / ultra.
- `r_gtaoHalfRes 0 | 1` — full or half resolution. Requires restart when changed.
- `r_gtaoRadius <units>` — world-space AO radius.
- `r_gtaoFalloff <value>` — distance falloff.
- `r_gtaoThickness <value>` — thin-object compensation.
- `r_gtaoPower <value>` — AO strength/contrast.
- `r_gtaoDenoise 0..3` — denoise passes.
- `r_aoCompare 0 | 1` — SSAO/GTAO split screen.
- `r_debugAO 1..10` — AO/depth/normal/contact-shadow debug views.

### Screen-space contact shadows

**Performance: Medium.**

Adds small sun shadows that shadow maps can miss, such as feet touching the ground and thin edges. It is mainly visible on sunlit maps.

The renderer walks a short ray through the depth buffer toward the sun and checks for nearby blockers.

- `r_contactShadows 0 | 1` — enable contact shadows.
- `r_contactShadowLength <units>` — maximum ray length.
- `r_contactShadowSteps <count>` — ray samples.
- `r_contactShadowThickness <units>` — assumed occluder thickness.
- `r_contactShadowStrength <value>` — shadow strength.
- `r_contactShadowSoft 0 | 1` — first-hit or softer weighted mode.

### Forward+ dynamic lighting

**Performance: Light.**

Allows many more dynamic lights in the same area. It is most visible during combat with several sabers, blasters and explosions.

The screen is split into tiles and depth slices. Each pixel checks only lights assigned to its small 3D cluster.

- `r_forwardPlus 0` — legacy dynamic lighting.
- `r_forwardPlus 1` — clustered Forward+ lighting.
- `r_forwardPlusTileSize <pixels>` — tile size.
- `r_forwardPlusSlices <count>` — logarithmic depth slices.
- `r_forwardPlusNearSlice <units>` — first-slice depth.
- `r_forwardPlusMaxLightsPerCluster <count>` — per-cluster light limit.
- `r_dynamicShadowMaxLights <count>` — strongest dynamic lights allowed to use shadow cubes.
- `r_forwardPlusDebug 1..9` — tile, slice, light-count, overflow and volume views. Requires restart.
- `r_forwardPlusDebugLight <index>` — select a light for debug mode 9.
- `r_forwardPlusStats` — print Forward+ statistics.
- `r_forwardPlusBenchmark [frames]` — benchmark Forward+.

### Screen-space global illumination

**Performance: Heavy.**

Makes dynamic and emissive light bounce from nearby visible surfaces. Saber color can spill onto nearby walls and objects.

SSGI shoots screen-space rays and samples dynamic/emissive lighting at the hit points.

- `r_ssgi 0 | 1` — enable SSGI. Requires `vid_restart`.
- `r_ssgiSource 0` — dynamic lights + emissive. Recommended.
- `r_ssgiSource 1` — emissive only.
- `r_ssgiSource 2` — full scene lighting; experimental.
- `r_ssgiIntensity <value>` — indirect-light strength.
- `r_ssgiQuality 0..3` — low / medium / high / ultra.
- `r_ssgiRays <count>` — rays per traced pixel; `0` uses preset.
- `r_ssgiSteps <count>` — trace iterations; `0` uses preset.
- `r_ssgiMaxDistance <units>` — maximum bounce distance.
- `r_ssgiThickness <units>` — depth-buffer surface thickness.
- `r_ssgiTemporal 0 | 1` — temporal accumulation.
- `r_ssgiHistoryWeight <value>` — history strength.
- `r_ssgiDenoise -1..4` — denoise passes.
- `r_ssgiHalfResolution -1 | 0 | 1` — automatic / full / half resolution.
- `r_ssgiHiZ -1 | 0 | 1` — automatic / normal / hierarchical tracing.
- `r_ssgiEmissiveScale <value>` — physical emissive contribution.
- `r_ssgiGlowScale <value>` — legacy glow contribution.
- `r_ssgiCompare 0 | 1` — split-screen comparison.
- `r_ssgiDebug 1..10` — hit, history, source and final-light views.
- `r_ssgiFreezeHistory 0 | 1` — freeze temporal history.

### Directional diffuse ambient

**Performance: Light.**

Makes ambient light less flat. Different sides of models and surfaces can receive different ambient color and brightness.

Runtime cubemap probes are converted into directional diffuse information and used to modulate BSP light-grid ambient.

- `r_diffuseIBL 0 | 1` — enable directional ambient. Requires restart.
- `r_diffuseIBLStrength <value>` — modulation strength.
- `r_diffuseIBLDebug 1..5` — irradiance, factor, old/new ambient and selected probe.

### LTC area lights

**Performance: Medium.**

Makes long and large lamps produce correctly shaped highlights instead of behaving like point lights. Saber blades can also become line lights.

LTC integrates the BRDF over a rectangle or line using small precomputed lookup tables instead of many samples.

- `r_ltcAreaLights 0 | 1` — enable area lights. Requires Forward+ and `vid_restart`.
- `r_ltcIntensityScale <value>` — global area-light brightness.
- `r_ltcStaticDiffuse 0 | 1` — also add diffuse for static-specular lights.
- `r_ltcMaxLights <count>` — maximum map area lights used in one scene.
- `r_ltcAutoAreaLights 0` — no automatic lamp detection.
- `r_ltcAutoAreaLights 1` — confident lamp shapes.
- `r_ltcAutoAreaLights 2` — also accept looser fits.
- `r_saberAreaLights 0 | 1` — saber blades become line lights.
- `r_ltcDebug 1..8` — specular, diffuse, source, bounds, axes and ID views.
- `r_ltcDebugLight <id>` — select one map light; `-1` means nearest.
- `r_reloadAreaLights` — reload map area-light data or rerun auto detection.
- `r_ltcList` — list loaded area lights.
- `r_ltcNearest` — print the nearest area light.
- `r_extractAreaLights` — export automatically detected candidates.

### Sun Shadows 2.0

**Performance: Medium.**

Makes outdoor sun shadows more stable, softer and more natural. It is most visible on outdoor maps, foliage and long character shadows.

BetterJK stabilizes cascaded shadow maps, blends cascade transitions and can use PCSS for contact-hardening shadows.

- `r_sunShadowMode 0` — legacy sun shadows.
- `r_sunShadowMode 1` — stabilized Shadows 2.0. Requires `vid_restart`.
- `r_sunShadowAlphaCasters 0 | 1` — proper cutout/foliage sun shadows.
- `r_shadowCascadeBlend <value>` — cascade transition width.
- `r_shadowDepthBias <units>` — constant receiver bias.
- `r_shadowNormalBias <value>` — normal-direction bias.
- `r_shadowSlopeBias <value>` — slope-dependent bias.
- `r_shadowReceiverBiasClamp <units>` — maximum receiver correction.
- `r_shadowPcss 0 | 1` — enable PCSS.
- `r_shadowPcssQuality 0..2` — low / high / ultra.
- `r_shadowSunAngularDiameter <degrees>` — apparent sun size.
- `r_shadowPcssMaxPenumbra <units>` — maximum penumbra size.
- `r_shadowDebug 1..11` — cascades, depth, PCSS, point-shadow and Ghoul2 views.

# Player & model lighting

### Multi-point / per-pixel BSP light-grid lighting

**Performance: Light in mode 1, Medium in mode 2.**

Improves lighting across characters and other entities. A character's head and feet can receive different lighting instead of one sample for the whole model.

BetterJK can take several CPU samples or let fragments sample the BSP 3D light grid directly.

- `r_entityLightGrid 0` — legacy lighting.
- `r_entityLightGrid 1` — three CPU light-grid samples.
- `r_entityLightGrid 2` — per-fragment GPU sampling.
- `r_entityLightGridDebug 1..9` — ambient, direct, direction, grid cell and mode comparison views.

### Skin subsurface scattering

**Performance: Light in mode 1, Medium in mode 2.**

Makes organic skin look softer under strong lighting, especially faces near sabers or side lights. Eyes, armor and cloth stay sharp.

Mode 1 uses wrapped diffuse. Mode 2 separates skin diffuse light and blurs it with a skin-like RGB diffusion profile.

- `r_skinSSS 0` — off.
- `r_skinSSS 1` — cheap wrapped-diffuse approximation.
- `r_skinSSS 2` — screen-space diffusion. Requires HDR and `vid_restart`.
- `r_skinSSSMixed 0 | 1` — also process mixed `*_head` textures. Requires restart.
- `r_skinSSSStrength 0..1` — scattering strength.
- `r_skinSSSWidth <mm>` — diffusion radius.
- `r_skinSSSQuality 0..2` — 11 / 17 / 25 taps.
- `r_skinSSSWrap <value>` — wrapped-diffuse width for mode 1.
- `r_skinSSSFollowSurface <value>` — edge stopping strength.
- `r_skinSSSTransmission <value>` — cheap back-light transmission.
- `r_skinSSSCompare 0 | 1` — split-screen comparison.
- `r_skinSSSDebug 1..8` — classification, skin light, blur and radius views.
- `skinsss_list` — list skin classification.
- `skinsss_kernel` — print the diffusion kernel.

### Character shadow improvements

**Performance: Light.**

Improves Ghoul2 character self-shadowing under sun and dynamic lights. It affects characters on maps using those shadow types.

These controls improve shadow LOD selection, dynamic-light bias and short contact-shadow filtering.

- `r_shadowCasterLod 0` — choose Ghoul2 LOD from the shadow view.
- `r_shadowCasterLod 1` — use camera-view LOD for shadow casting.
- `r_dlightShadowBias 0` — legacy dynamic-light bias.
- `r_dlightShadowBias 1` — texel-scaled normal/slope bias.
- `r_shadowCasterStats 0 | 1` — print Ghoul2 shadow caster/LOD statistics.
- `r_shadowDebug 11` — Ghoul2 receiver debug view.

# Reflections

### Screen-space reflections

**Performance: Medium; Heavy at high/ultra quality.**

Adds true scene reflections to glossy PBR surfaces. Characters, walls and architecture can appear in shiny floors. Off-screen or rough reflections fall back to cubemaps.

SSR follows the reflection ray through the current frame's depth buffer and replaces the corresponding cubemap reflection when the hit is reliable.

- `r_ssr 0 | 1` — enable SSR. Requires specular mapping and `vid_restart`.
- `r_ssrQuality 0..3` — low / medium / high / ultra.
- `r_ssrSteps <count>` — trace-step override.
- `r_ssrRefineSteps <count>` — hit refinement.
- `r_ssrMaxDistance <units>` — maximum ray length.
- `r_ssrThickness <units>` — assumed depth-buffer thickness.
- `r_ssrMaxRoughness <value>` — roughness where SSR fully fades to cubemaps.
- `r_ssrEdgeFade <value>` — screen-edge fade band.
- `r_ssrHalfRes -1 | 0 | 1` — automatic / full / half resolution.
- `r_ssrHiZ -1 | 0 | 1` — automatic / normal / hierarchical tracing.
- `r_ssrTemporal 0 | 1` — temporal accumulation. Requires restart.
- `r_ssrTemporalWeight <value>` — history strength.
- `r_ssrStrength <value>` — SSR replacement strength.
- `r_ssrCompare 0 | 1` — cubemap-only vs SSR split screen.
- `r_ssrDebug 1..11` — material, hit, confidence and final-reflection views.
- `r_ssrEmitters 0 | 1` — analytic saber/blaster/effect reflections.
- `r_ssrEmitterIntensity <value>` — effect-reflection brightness.
- `r_ssrEmitterMaxRoughness <value>` — roughness limit for effect reflections.

# Volumetric lighting & fog

### Froxel volumetric fog

**Performance: Heavy.**

Adds true 3D illuminated fog. Sun and dynamic lights can illuminate the air, and BSP fog volumes become spatially lit.

The camera volume is split into small 3D froxels. BetterJK calculates density and light in them, then integrates the volume toward the camera.

- `r_volumetricFog 0` — off.
- `r_volumetricFog 1` — legacy light-grid ray-marched fog.
- `r_volumetricFog 2` — froxel volumetric fog. Requires `vid_restart`.
- `r_volumetricFogQuality 0..2` — low / medium / high.
- `r_volumetricFogGridScale <pixels>` — manual froxel screen size; `0` uses preset.
- `r_volumetricFogSlices <count>` — depth-slice override.
- `r_volumetricFogFar <units>` — covered distance.
- `r_volumetricFogAnisotropy <value>` — scattering directionality.
- `r_volumetricFogTemporal 0 | 1` — temporal reprojection.
- `r_volumetricFogHistoryWeight <value>` — history strength.
- `r_volumetricFogSunScale <value>` — sun scattering strength.
- `r_volumetricFogDlightScale <value>` — dynamic-light scattering strength.
- `r_volumetricFogStaticScale <value>` — baked light-grid scattering strength.
- `r_volumetricFogDlightShadows 0 | 1` — dynamic-light shadowing in fog.
- `r_volumetricFogBloom <value>` — send bright fog into bloom.
- `r_volumetricFogDefaultScale <value>` — default density multiplier.
- `r_volumetricFogScale <value>` — temporary density multiplier.
- `r_volumetricFogSamples <count>` — sample count for legacy mode 1.
- `r_volumetricFogReset 1` — clear history.
- `r_volumetricFogFreeze 0 | 1` — freeze the volume.
- `r_volumetricFogDebug 1..15` — density, lighting, shadow, history and noise views.
- `r_vfog` — print current volumetric-fog state.

### Exponential height fog

**Performance: Light additional cost; requires froxel fog.**

Adds low ground haze to any map, even without authored fog volumes.

Density is strongest around a base world height and falls exponentially upward.

- `r_volumetricFogHeight 0 | 1` — enable height fog.
- `r_volumetricFogHeightOpaque <units>` — base-level opaque distance.
- `r_volumetricFogHeightBase <z>` — base world height.
- `r_volumetricFogHeightFalloff <units>` — vertical falloff.
- `r_volumetricFogHeightMax <value>` — maximum density below the base.
- `r_volumetricFogHeightTop <units>` — optional soft upper cutoff.
- `r_volumetricFogHeightColor "r g b"` — scattering color.

### Volumetric fog noise

**Performance: Light additional cost; requires froxel fog.**

Breaks uniform fog into world-space patches and moving mist.

The fog density is multiplied by one or two procedural noise layers that can drift with wind.

- `r_volumetricFogNoise 0` — homogeneous fog.
- `r_volumetricFogNoise 1` — noise height fog.
- `r_volumetricFogNoise 2` — noise BSP fog.
- `r_volumetricFogNoise 4` — noise global fog. Bits can be combined.
- `r_volumetricFogNoiseScale <units>` — macro-noise size.
- `r_volumetricFogNoiseContrast <value>` — macro-noise contrast.
- `r_volumetricFogNoiseDetailScale <units>` — detail-noise size.
- `r_volumetricFogNoiseDetailContrast <value>` — detail-noise strength.
- `r_volumetricFogNoiseWind "x y z"` — noise movement in world units per second.

# Rain & wet surfaces

### Weather chunk culling

**Performance: Zero; usually improves performance.**

Does not change the intended image. It avoids drawing rain, snow and other weather chunks outside the camera.

The existing 3x3 weather field is split into world-space chunks that can be frustum-culled independently.

- `r_weatherCull 0` — draw all nine chunks.
- `r_weatherCull 1` — skip invisible chunks.
- `r_weatherDebugChunks 1` — visualize chunk bounds/mapping.
- `r_weatherDebugChunks 2` — also print detailed AABBs.

### Modern rain streaks

**Performance: Light.**

Makes rain look like lit physical streaks instead of simple additive particles. It is visible on maps using rain or heavy rain.

Length and width follow velocity and wind. The streaks receive lighting and fade near surfaces.

- `r_rainStreaks 0` — legacy rain.
- `r_rainStreaks 1` — modern streaks.
- `r_rainStreakWidth <value>` — width.
- `r_rainStreakLength <value>` — length multiplier.
- `r_rainOpacity <value>` — opacity.
- `r_rainLighting 0` — fixed legacy-like brightness.
- `r_rainLighting 1` — use BSP light-grid/sun lighting.
- `r_rainDebug 1..5` — coverage, distance, lighting, contact and variation views.

### Rain wetness

**Performance: Light.**

Makes rain-exposed surfaces darker, smoother and more reflective. Roofs block the effect; characters and props can also get wet.

BetterJK reuses the weather occlusion map to tell which pixels are exposed, then changes PBR response according to the detected material class.

- `r_weatherWetness 0 | 1` — enable wet materials. Requires `vid_restart`.
- `r_weatherWetStrength 0..1` — overall wetness.
- `r_weatherWetRoughness <value>` — material-specific smoothing scale.
- `r_weatherWetDarkening <value>` — material-specific darkening scale.
- `r_weatherWetNormal <value>` — material-specific normal flattening scale.
- `r_weatherWetEntityFacing <value>` — wetness of vertical character/prop faces.
- `r_weatherWetBias <units>` — occlusion depth bias.
- `r_weatherWetnessDebug 1..20` — exposure, material, puddle, height and ripple views.

### Procedural puddles

**Performance: Light.**

Creates standing water on flat, rain-exposed world surfaces without changing the BSP.

Rain exposure, surface slope and world-space noise create the puddle mask. PBR reflections then work automatically.

- `r_weatherPuddles 0 | 1` — enable puddles. Requires wetness.
- `r_puddleCoverage 0..1` — approximate covered fraction.
- `r_puddleRoughness <value>` — water roughness.
- `r_puddleSlope "min max"` — surface slope range.
- `r_puddleScale <units>` — puddle pattern size.

### Height-aware puddles

**Performance: Light.**

Makes puddles fill cracks and low parts of height-mapped materials before raised parts.

The same material height map used by POM becomes a tiny terrain map for the water level.

- `r_puddleHeight 0 | 1` — use material height data.
- `r_puddleHeightSoftness <value>` — small water-line transition width.
- `r_puddleHeightFill <value>` — move the virtual water level up/down.

### Puddle ripples

**Performance: Light.**

Adds expanding rain rings to puddles. They distort SSR, cubemaps and direct-light highlights.

The shader creates procedural world-space rings and uses their slope to perturb the water normal.

- `r_puddleRipples 0 | 1` — enable ripples.
- `r_puddleRippleStrength <value>` — normal/slope strength.
- `r_puddleRippleScale <units>` — ring cell size.
- `r_puddleRippleRate <value>` — ring cycles per second.
- `r_weatherWetnessDebug 17..20` — ripple height, normal, mask and final normal.

### Rain impact splashes

**Performance: Medium in heavy rain.**

Creates short crown/spray splashes exactly where rain reaches a surface.

The GPU rain simulation detects when a drop crosses the weather depth map and stores one short-lived impact per fall.

- `r_rainSplashes 0 | 1` — enable impact detection/splashes.
- `r_rainSplashSize <units>` — splash radius.
- `r_rainSplashLifetime <ms>` — lifetime.
- `r_rainSplashOpacity <value>` — opacity.
- `r_rainSplashDebug 1` — impact points.
- `r_rainSplashDebug 2` — accepted/rejected crossings.
- `r_rainSplashDebug 3` — recent trajectories.

# Foliage

### Automatic foliage classification

**Performance: Zero.**

Lets the renderer recognize leaf, plant and normal MD3 surfaces. By itself it changes no image, but it enables other foliage systems.

The classification uses model, surface and material names, so stock vegetation can gain semantics without asset changes.

- `r_autoFoliage 0` — off.
- `r_autoFoliage 1` — conservative stock-safe classification.
- `r_autoFoliage 2` — broader experimental classification.
- `r_autoFoliageDebug 1` — show classified surfaces.
- `r_autoFoliageDebug 2` — also show uncertain candidates.
- `r_printAutoFoliage [filter]` — print detected foliage surfaces.

### Auto grass geometry

**Performance: Medium.**

Stops surface-sprite grass from rotating with the camera or disappearing edge-on. It is mainly visible on Yavin grass.

Each original billboard can become two or three fixed world-space cards sharing one root.

- `r_autoGrass 0` — legacy grass.
- `r_autoGrass 1` — two-card cross.
- `r_autoGrass 2` — three-card tuft.
- `r_autoGrass 3` — three cards near, two far.
- `r_autoGrassLodDist <units>` — third-card fade distance in mode 3.
- `r_autoGrassWidth <value>` — card width multiplier.
- `r_autoGrassDebug 1..6` — card ID, direction and LOD views.

### Coherent foliage wind

**Performance: Light.**

Makes grass sway in travelling gusts instead of synchronized circles.

A world-space procedural wind field gives nearby blades shared gusts and smaller local variation.

- `r_foliageWind 0` — legacy sway.
- `r_foliageWind 1` — coherent breeze.
- `r_foliageWindStrength <value>` — global strength.
- `r_foliageWindSpeed <value>` — animation speed.
- `r_foliageWindDirection <degrees>` — wind yaw.
- `r_foliageWindDebug 1` — exaggerated strength.
- `r_foliageWindDebug 2` — color by bend.
- `r_foliageWindDebug 3` — freeze time.
- `r_foliageWindDebug 4` — visualize large gusts.

### Leaf flutter

**Performance: Light.**

Adds subtle rustling to leaf/vine cards while keeping trunks and branches still. It is designed mainly for stock Yavin trees.

Only surfaces classified as leaves move; a slower band moves the card and a faster band adds small shape/normal changes.

- `r_leafFlutter 0 | 1` — enable flutter. Requires `r_autoFoliage >= 1`.
- `r_leafFlutterStrength <value>` — motion amplitude.
- `r_leafFlutterSpeed <value>` — animation speed.
- `r_leafFlutterNormal <value>` — lighting-normal wobble.
- `r_leafFlutterDebug` — bit mask: 1 exaggerate, 2 freeze, 4 highlight, 8 displacement color.

### Plant root wind

**Performance: Light.**

Makes larger plant models such as ferns bend gently from their root.

Plants are treated as stems attached to a fixed base and bent using the shared foliage wind direction/speed.

- `r_plantWind 0..4` — root-bend strength. Requires automatic foliage classification.
- `r_foliageWindDirection <degrees>` — shared direction.
- `r_foliageWindSpeed <value>` — shared speed.

### Character / foliage interaction

**Performance: Medium.**

Makes grass and ferns bend away from the player and nearby NPCs.

The game sends a small list of character capsules to the renderer. Vegetation vertices bend away from nearby capsules; there is no persistent per-plant physics state.

- `r_foliageInteraction 0 | 1` — enable interaction.
- `r_foliageInteractionStrength <value>` — bend strength.
- `r_foliageInteractionRadius <value>` — collider radius multiplier.
- `r_foliageInteractionMax <count>` — collider limit per frame.
- `r_foliageInteractionNPC 0` — player only.
- `r_foliageInteractionNPC 1` — player + nearby NPCs/players.
- `r_foliageInteractionDebug` — bit mask for colliders, exaggeration, contact heat, freeze and player-only views.
- `r_foliageInteractors` — print current foliage colliders.
