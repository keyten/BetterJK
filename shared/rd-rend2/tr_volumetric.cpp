/*
===========================================================================
Copyright (C) 2013 - 2016, OpenJK contributors

This file is part of the OpenJK source code.

OpenJK is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License version 2 as
published by the Free Software Foundation.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, see <http://www.gnu.org/licenses/>.
===========================================================================
*/

// Froxel volumetric fog (r_volumetricFog 2), see docs/rend2-volumetric-fog.md.
//
// r_volumetricFog 1 (legacy) ray marches the static light grid per fogged
// surface. Mode 2 keeps the same media (the BSP fog volumes, their colors and
// depthForOpaque) but lights it with a camera aligned froxel volume:
//
//   inject     per froxel: extinction of the fog volumes containing it and
//              the light scattered towards the camera: baked light grid
//              without the sun, the sun (cascaded shadow maps) and the
//              dynamic lights (their shadow maps), Henyey-Greenstein phase.
//              Temporally filtered with the reprojected previous volume.
//   integrate  front to back along every froxel column: in-scattering and
//              transmittance up to the far side of each slice (Beer-Lambert,
//              the same discretisation as the legacy ray march).
//   composite  one full screen pass after the opaque layers (sort <= SS_FOG):
//              scene * transmittance + in-scattering at the depth buffer.
//              Transparent surfaces keep their fog pass / in-shader fog, with
//              the volume looked up at the fragment instead of ray marched.
//
// GL 3.2 has no compute shaders: every slice of a 3D texture is rendered
// with a full screen triangle into a framebuffer with that layer attached.
//
// Only the main view of the first world scene of a frame uses the volume;
// portals, mirrors, sky portals, the LA goggles and other scenes use the
// legacy fog path.

#include "tr_local.h"

#define FROXEL_MAX_SLICES 128
#define FROXEL_NEAR 8.0f
#define FROXEL_AUTO_FAR 4096.0f

// camera changes between two frames that invalidate the history
#define FROXEL_CUT_DISTANCE 256.0f
#define FROXEL_CUT_COS_ANGLE 0.2588f	// 75 degrees
#define FROXEL_CUT_FOV 0.15f			// relative

// light grid cells whose light comes from within ~10 degrees of the sun
// direction are sun, beyond ~25 degrees not
#define FROXEL_SUN_COS_OUTER 0.9063f	// cos(25)
#define FROXEL_SUN_COS_INNER 0.9848f	// cos(10)

// r_volumetricFogQuality 0, 1, 2: screen pixels per froxel and depth slices.
// Starting points, see docs/rend2-volumetric-fog.md (profiling).
static const int froxelQualityGridScale[] = { 16, 8, 8 };
static const int froxelQualitySlices[] = { 32, 48, 64 };

struct froxelState_t
{
	qboolean resources;
	int width, height, depth;

	// the volume of this frame
	qboolean frameActive;		// injected and integrated this frame
	qboolean frameUsable;		// lookups allowed this frame (built or frozen)
	int frameScene;				// scene of the frame that owns the volume
	int builtFrameNumber;
	qboolean built;				// GPU passes of this frame ran
	int current;				// froxelInjectImage written this frame
	int lightMask[FROXEL_MAX_SLICES];
	qboolean frameHeightFog;	// the volume of this frame has the height fog medium

	// the last froxelInjectImage the GPU passes actually wrote: the history
	// must not be an image whose build was skipped (never initialized or stale)
	int builtVolumeFrame;
	int builtVolumeImage;

	// the camera of the volume in froxelInjectImage[current]
	qboolean hasVolume;
	int volumeFrameNumber;
	const world_t *world;
	matrix_t viewProjection;
	vec3_t origin;
	vec3_t forward;
	float fovX, fovY;
	float nearZ, farZ;
	int debug;
	unsigned int frameIndex;

	// frozen froxel camera (r_volumetricFogFreeze)
	qboolean frozen;
	VolumetricFogBlock frozenBlock;
};

static froxelState_t s_vf;

qboolean R_VolumetricFroxelEnabled( void )
{
	return s_vf.resources;
}

/*
============================================================

Resources

============================================================
*/

void R_CreateVolumetricImages( int width, int height )
{
	Com_Memset(&s_vf, 0, sizeof(s_vf));
	s_vf.builtVolumeFrame = -1;
	s_vf.builtVolumeImage = -1;
	tr.froxelInjectImage[0] = tr.froxelInjectImage[1] = NULL;
	tr.froxelDynamicImage = NULL;
	tr.froxelIntegratedImage = NULL;
	tr.froxelCarryImage[0] = tr.froxelCarryImage[1] = NULL;
	tr.froxelTailImage = NULL;

	if ( r_volumetricFog->integer != 2 )
		return;

	const int quality = Com_Clampi(0, 2, r_volumetricFogQuality->integer);
	const int gridScale = r_volumetricFogGridScale->integer > 0 ?
		Com_Clampi(4, 32, r_volumetricFogGridScale->integer) : froxelQualityGridScale[quality];
	const int slices = r_volumetricFogSlices->integer > 0 ?
		Com_Clampi(16, FROXEL_MAX_SLICES, r_volumetricFogSlices->integer) : froxelQualitySlices[quality];

	s_vf.width = Q_max(1, (width + gridScale - 1) / gridScale);
	s_vf.height = Q_max(1, (height + gridScale - 1) / gridScale);
	s_vf.depth = slices;

	for ( int i = 0; i < 2; i++ )
	{
		tr.froxelInjectImage[i] = R_CreateImage3D(
			va("*froxelInject%d", i), NULL, s_vf.width, s_vf.height, s_vf.depth, GL_RGBA16F);
		tr.froxelCarryImage[i] = R_CreateImage(
			va("*froxelCarry%d", i), NULL, s_vf.width, s_vf.height, IMGTYPE_COLORALPHA,
			IMGFLAG_NO_COMPRESSION | IMGFLAG_CLAMPTOEDGE, GL_RGBA16F);
	}

	tr.froxelDynamicImage = R_CreateImage3D(
		"*froxelDynamic", NULL, s_vf.width, s_vf.height, s_vf.depth, GL_R11F_G11F_B10F);
	tr.froxelIntegratedImage = R_CreateImage3D(
		"*froxelIntegrated", NULL, s_vf.width, s_vf.height, s_vf.depth, GL_RGBA16F);
	tr.froxelTailImage = R_CreateImage(
		"*froxelTail", NULL, s_vf.width, s_vf.height, IMGTYPE_COLORALPHA,
		IMGFLAG_NO_COMPRESSION | IMGFLAG_CLAMPTOEDGE, GL_RGBA16F);

	s_vf.resources = qtrue;

	if ( !r_depthPrepass->integer )
		ri.Printf(PRINT_WARNING, "r_volumetricFog 2 needs r_depthPrepass 1, the legacy volumetric fog is used\n");

	ri.Printf(PRINT_ALL, "Froxel volumetric fog: %d x %d x %d froxels (%d pixels per froxel)\n",
		s_vf.width, s_vf.height, s_vf.depth, gridScale);
}

void R_CreateVolumetricFBOs( void )
{
	tr.froxelInjectFbo = NULL;
	tr.froxelIntegrateFbo = NULL;
	tr.froxelCompositeFbo = NULL;

	if ( !s_vf.resources )
		return;

	// injection: one layer of froxelInjectImage[current] and of the dynamic
	// light volume, attached per slice
	tr.froxelInjectFbo = FBO_Create("_froxelInject", s_vf.width, s_vf.height);
	FBO_Bind(tr.froxelInjectFbo);
	qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
		tr.froxelInjectImage[0]->texnum, 0, 0);
	qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1,
		tr.froxelDynamicImage->texnum, 0, 0);
	glState.currentFBO->colorImage[0] = tr.froxelInjectImage[0];
	glState.currentFBO->colorBuffers[0] = tr.froxelInjectImage[0]->texnum;
	glState.currentFBO->colorImage[1] = tr.froxelDynamicImage;
	glState.currentFBO->colorBuffers[1] = tr.froxelDynamicImage->texnum;
	{
		const GLenum bufs[2] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1 };
		qglDrawBuffers(2, bufs);
	}
	R_CheckFBO(tr.froxelInjectFbo);

	// integration: a layer of the integrated volume, the carried state and
	// (last slice) the tail
	tr.froxelIntegrateFbo = FBO_Create("_froxelIntegrate", s_vf.width, s_vf.height);
	FBO_Bind(tr.froxelIntegrateFbo);
	qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
		tr.froxelIntegratedImage->texnum, 0, 0);
	glState.currentFBO->colorImage[0] = tr.froxelIntegratedImage;
	glState.currentFBO->colorBuffers[0] = tr.froxelIntegratedImage->texnum;
	FBO_AttachTextureImage(tr.froxelCarryImage[0], 1);
	FBO_AttachTextureImage(tr.froxelTailImage, 2);
	{
		const GLenum bufs[3] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2 };
		qglDrawBuffers(3, bufs);
	}
	R_CheckFBO(tr.froxelIntegrateFbo);

	// Clear every volume once: the images are created without data, and a
	// lookup of a volume that was never built must see no fog, not garbage
	// (NaN would be fed back by the temporal filter forever).
	{
		const float zero[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
		const float noFog[4] = { 0.0f, 0.0f, 0.0f, 1.0f };

		GL_SetViewportAndScissor(0, 0, s_vf.width, s_vf.height);

		FBO_Bind(tr.froxelInjectFbo);
		for ( int k = 0; k < s_vf.depth; k++ )
		{
			for ( int i = 0; i < 2; i++ )
			{
				qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
					tr.froxelInjectImage[i]->texnum, 0, k);
				qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1,
					tr.froxelDynamicImage->texnum, 0, k);
				qglClearBufferfv(GL_COLOR, 0, zero);
				qglClearBufferfv(GL_COLOR, 1, zero);
			}
		}
		qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
			tr.froxelInjectImage[0]->texnum, 0, 0);
		qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1,
			tr.froxelDynamicImage->texnum, 0, 0);

		FBO_Bind(tr.froxelIntegrateFbo);
		for ( int k = 0; k < s_vf.depth; k++ )
		{
			qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
				tr.froxelIntegratedImage->texnum, 0, k);
			qglClearBufferfv(GL_COLOR, 0, noFog);
		}
		qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
			tr.froxelIntegratedImage->texnum, 0, 0);
		for ( int i = 0; i < 2; i++ )
		{
			qglFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1,
				GL_TEXTURE_2D, tr.froxelCarryImage[i]->texnum, 0);
			qglClearBufferfv(GL_COLOR, 1, noFog);
		}
		qglFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1,
			GL_TEXTURE_2D, tr.froxelCarryImage[0]->texnum, 0);
		qglClearBufferfv(GL_COLOR, 2, zero);	// tail: no medium beyond far
	}

	// composite: color and glow of renderFbo only, the sampled depth must not
	// be attached
	tr.froxelCompositeFbo = FBO_Create("_froxelComposite", tr.renderFbo->width, tr.renderFbo->height);
	FBO_Bind(tr.froxelCompositeFbo);
	if ( tr.msaaResolveFbo )
	{
		for ( int i = 0; i < 2; i++ )
		{
			qglFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i,
				GL_RENDERBUFFER, tr.renderFbo->colorBuffers[i]);
			glState.currentFBO->colorBuffers[i] = tr.renderFbo->colorBuffers[i];
		}
	}
	else
	{
		FBO_AttachTextureImage(tr.renderImage, 0);
		FBO_AttachTextureImage(tr.glowImage, 1);
	}
	{
		const GLenum bufs[2] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1 };
		qglDrawBuffers(2, bufs);
	}
	R_CheckFBO(tr.froxelCompositeFbo);
}

/*
============================================================

Light grid split by the sun direction

============================================================
*/

static float R_VolumetricSRGBToLinear( float c )
{
	return (c <= 0.04045f) ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
}

static float R_VolumetricSmoothstep( float edge0, float edge1, float x )
{
	const float t = Com_Clamp(0.0f, 1.0f, (x - edge0) / (edge1 - edge0));
	return t * t * (3.0f - 2.0f * t);
}

static int R_VolumetricCompareFloats( const void *a, const void *b )
{
	const float fa = *(const float *)a;
	const float fb = *(const float *)b;
	return (fa < fb) ? -1 : ((fa > fb) ? 1 : 0);
}

/*
=================
R_BuildVolumetricLightGrid

The legacy volumetric light map merges the ambient and directed light of
every light grid cell (volumetricLightMaps[0], R_BuildLightGridTexture). The
directed part contains the baked sun, which the froxel fog lights in real
time with the cascaded shadow maps. Split the merged value in two textures
with the same layout, so that static + sun == the legacy value:

  sun    = the directed light of cells lit from the sun direction
  static = everything else (ambient, other lights)

The realtime sun radiance is estimated from the sunlit cells, so the beams
have the brightness the map was compiled with.
=================
*/
void R_BuildVolumetricLightGrid( world_t *world )
{
	world->volumetricStaticGrid = NULL;
	world->volumetricSunGrid = NULL;
	world->volumetricHasSunCells = qfalse;
	VectorClear(world->volumetricSunRadiance);

	if ( r_volumetricFog->integer != 2 || !world->lightGridData || world->numGridArrayElements <= 0 )
		return;

	const int numCells = world->numGridArrayElements;
	if ( numCells != world->lightGridBounds[0] * world->lightGridBounds[1] * world->lightGridBounds[2] )
	{
		ri.Printf(PRINT_WARNING, "R_BuildVolumetricLightGrid: light grid size mismatch, no sun split\n");
	}

	const qboolean splitSun = tr.sunParsed;
	vec3_t sunDir;
	VectorCopy(tr.sunDirection, sunDir);
	VectorNormalize(sunDir);

	uint16_t *staticData = (uint16_t *)Z_Malloc(numCells * sizeof(uint16_t) * 4, TAG_TEMP_WORKSPACE, qtrue);
	uint16_t *sunData = (uint16_t *)Z_Malloc(numCells * sizeof(uint16_t) * 4, TAG_TEMP_WORKSPACE, qtrue);
	float *sunLuma = (float *)Z_Malloc(numCells * sizeof(float), TAG_TEMP_WORKSPACE, qtrue);
	int numSunCells = 0;
	vec3_t sunColorSum = { 0.0f, 0.0f, 0.0f };

	for ( int i = 0; i < numCells; i++ )
	{
		const mgrid_t *data = world->lightGridData + world->lightGridArray[i];
		vec3_t ambient, direct, total;

		if ( world->hdrLightGrid )
		{
			const float *hdrData = world->hdrLightGrid + (i * 6);
			for ( int c = 0; c < 3; c++ )
			{
				ambient[c] = hdrData[c];
				direct[c] = hdrData[c + 3];
				total[c] = ambient[c] + direct[c];
			}
		}
		else
		{
			for ( int c = 0; c < 3; c++ )
			{
				ambient[c] = data->ambientLight[0][c] / 255.0f;
				direct[c] = data->directLight[0][c] / 255.0f;
				if ( tr.forcedLinearLight )
				{
					// the legacy texture is GL_SRGB8 then
					ambient[c] = R_VolumetricSRGBToLinear(ambient[c]);
					direct[c] = R_VolumetricSRGBToLinear(direct[c]);
				}
				total[c] = MAX(ambient[c], direct[c]);
			}
		}

		float sunFraction = 0.0f;
		if ( splitSun )
		{
			// direction towards the light, as R_SetupEntityLightingGrid
			const float lat = data->latLong[1] * (2.0f * M_PI / 255.0f);
			const float lng = data->latLong[0] * (2.0f * M_PI / 255.0f);
			vec3_t cellDir;
			cellDir[0] = cosf(lat) * sinf(lng);
			cellDir[1] = sinf(lat) * sinf(lng);
			cellDir[2] = cosf(lng);
			sunFraction = R_VolumetricSmoothstep(
				FROXEL_SUN_COS_OUTER, FROXEL_SUN_COS_INNER, DotProduct(cellDir, sunDir));
		}

		vec3_t sun;
		for ( int c = 0; c < 3; c++ )
			sun[c] = MIN(sunFraction * direct[c], total[c]);

		staticData[i * 4 + 0] = FloatToHalf(total[0] - sun[0]);
		staticData[i * 4 + 1] = FloatToHalf(total[1] - sun[1]);
		staticData[i * 4 + 2] = FloatToHalf(total[2] - sun[2]);
		staticData[i * 4 + 3] = FloatToHalf(sunFraction);

		sunData[i * 4 + 0] = FloatToHalf(sun[0]);
		sunData[i * 4 + 1] = FloatToHalf(sun[1]);
		sunData[i * 4 + 2] = FloatToHalf(sun[2]);
		sunData[i * 4 + 3] = FloatToHalf(1.0f);

		const float luma = 0.2126f * sun[0] + 0.7152f * sun[1] + 0.0722f * sun[2];
		if ( sunFraction > 0.5f && luma > 0.0f )
		{
			sunLuma[numSunCells++] = luma;
			VectorAdd(sunColorSum, sun, sunColorSum);
		}
	}

	world->volumetricStaticGrid = R_CreateImage3D(
		"*volumetricStaticGrid", (byte *)staticData,
		world->lightGridBounds[0], world->lightGridBounds[1], world->lightGridBounds[2],
		GL_RGBA16F);
	world->volumetricSunGrid = R_CreateImage3D(
		"*volumetricSunGrid", (byte *)sunData,
		world->lightGridBounds[0], world->lightGridBounds[1], world->lightGridBounds[2],
		GL_RGBA16F);

	// realtime sun radiance: 90th percentile of the sunlit cells, with their
	// average color. A handful of cells is not a sun.
	if ( numSunCells >= 16 )
	{
		qsort(sunLuma, numSunCells, sizeof(float), R_VolumetricCompareFloats);
		const float percentile = sunLuma[(numSunCells * 9) / 10];
		const float sumLuma = 0.2126f * sunColorSum[0] + 0.7152f * sunColorSum[1] + 0.0722f * sunColorSum[2];
		if ( sumLuma > 0.0f )
		{
			VectorScale(sunColorSum, percentile / sumLuma, world->volumetricSunRadiance);
			world->volumetricHasSunCells = qtrue;
		}
	}

	ri.Printf(PRINT_DEVELOPER, "Froxel fog light grid: %d cells, %d sunlit, sun radiance %.3f %.3f %.3f\n",
		numCells, numSunCells, world->volumetricSunRadiance[0],
		world->volumetricSunRadiance[1], world->volumetricSunRadiance[2]);

	Z_Free(sunLuma);
	Z_Free(sunData);
	Z_Free(staticData);
}

/*
============================================================

Per frame constants (front end, RB_UpdateConstants)

============================================================
*/

// generic 4x4 inverse (column major), false if singular
static qboolean R_VolumetricInvertMatrix( const float *m, float *out )
{
	float inv[16];
	inv[0] = m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10];
	inv[4] = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10];
	inv[8] = m[4]*m[9]*m[15] - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9];
	inv[12] = -m[4]*m[9]*m[14] + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9];
	inv[1] = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10];
	inv[5] = m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10];
	inv[9] = -m[0]*m[9]*m[15] + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9];
	inv[13] = m[0]*m[9]*m[14] - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9];
	inv[2] = m[1]*m[6]*m[15] - m[1]*m[7]*m[14] - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7] - m[13]*m[3]*m[6];
	inv[6] = -m[0]*m[6]*m[15] + m[0]*m[7]*m[14] + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7] + m[12]*m[3]*m[6];
	inv[10] = m[0]*m[5]*m[15] - m[0]*m[7]*m[13] - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7] - m[12]*m[3]*m[5];
	inv[14] = -m[0]*m[5]*m[14] + m[0]*m[6]*m[13] + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6] + m[12]*m[2]*m[5];
	inv[3] = -m[1]*m[6]*m[11] + m[1]*m[7]*m[10] + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7] + m[9]*m[3]*m[6];
	inv[7] = m[0]*m[6]*m[11] - m[0]*m[7]*m[10] - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7] - m[8]*m[3]*m[6];
	inv[11] = -m[0]*m[5]*m[11] + m[0]*m[7]*m[9] + m[4]*m[1]*m[11] - m[4]*m[3]*m[9] - m[8]*m[1]*m[7] + m[8]*m[3]*m[5];
	inv[15] = m[0]*m[5]*m[10] - m[0]*m[6]*m[9] - m[4]*m[1]*m[10] + m[4]*m[2]*m[9] + m[8]*m[1]*m[6] - m[8]*m[2]*m[5];

	const float det = m[0]*inv[0] + m[1]*inv[4] + m[2]*inv[8] + m[3]*inv[12];
	if ( fabsf(det) < 1e-30f )
		return qfalse;

	const float invDet = 1.0f / det;
	for ( int i = 0; i < 16; i++ )
		out[i] = inv[i] * invDet;
	return qtrue;
}

static float R_VolumetricHalton( unsigned int index, unsigned int base )
{
	float result = 0.0f;
	float f = 1.0f;
	while ( index > 0 )
	{
		f /= (float)base;
		result += f * (float)(index % base);
		index /= base;
	}
	return result;
}

// view distance of the near side of slice k (slice 0 starts at the camera)
static float R_VolumetricSliceDistance( int k, float nearZ, float farZ, int numSlices )
{
	if ( k <= 0 )
		return 0.0f;
	return nearZ * powf(farZ / nearZ, (float)k / (float)numSlices);
}

// dynamic lights overlapping each slice of the main view frustum
static void R_VolumetricCullLights( const viewParms_t *view, const trRefdef_t *refdef, const vec3_t forward )
{
	const int numLights = MIN(refdef->num_dlights, MAX_DLIGHTS);
	for ( int k = 0; k < s_vf.depth; k++ )
	{
		const float sliceNear = R_VolumetricSliceDistance(k, s_vf.nearZ, s_vf.farZ, s_vf.depth);
		const float sliceFar = R_VolumetricSliceDistance(k + 1, s_vf.nearZ, s_vf.farZ, s_vf.depth);
		unsigned int mask = 0;

		for ( int i = 0; i < numLights; i++ )
		{
			const dlight_t *dl = refdef->dlights + i;
			const float radius = dl->radius;
			if ( radius <= 0.0f )
				continue;

			vec3_t delta;
			VectorSubtract(dl->origin, view->ori.origin, delta);
			const float depth = DotProduct(delta, forward);
			if ( depth + radius < sliceNear || depth - radius > sliceFar )
				continue;

			qboolean inside = qtrue;
			for ( int p = 0; p < 4; p++ )
			{
				const cplane_t *plane = &view->frustum[p];
				if ( DotProduct(dl->origin, plane->normal) - plane->dist < -radius )
				{
					inside = qfalse;
					break;
				}
			}

			if ( inside )
				mask |= 1u << i;
		}

		s_vf.lightMask[k] = (int)mask;
	}
}

/*
=================
R_VolumetricHeightFog

Height fog medium (r_volumetricFogHeight 1, off by default), world anchored:

  sigma(p) = sigma0 * min(exp(-(p.z - base) / falloff), maxScale) * cutoff
  sigma0   = -ln(1.5 / 255) / r_volumetricFogHeightOpaque * volumetricFogScale

sigma0 is converted from a depthForOpaque distance exactly like the BSP fog
volumes below, so both media share one unit (extinction per world unit).
False (and a zero base extinction) when off.
=================
*/
static qboolean R_VolumetricHeightFog( vec4_t fog, vec4_t color, vec4_t top )
{
	VectorSet4(fog, 0.0f, 0.0f, 0.0f, 0.0f);
	VectorSet4(color, 0.0f, 0.0f, 0.0f, 0.0f);
	VectorSet4(top, 0.0f, 0.0f, 0.0f, 0.0f);

	const float opaque = r_volumetricFogHeightOpaque->value;
	if ( !r_volumetricFogHeight->integer || opaque <= 0.0f )
		return qfalse;

	const float extinction = (-logf(1.5f / 255.0f)) / opaque *
		tr.volumetricFogScale * r_volumetricFogScale->value;
	if ( extinction <= 0.0f )
		return qfalse;

	const float falloff = MAX(1.0f, r_volumetricFogHeightFalloff->value);
	const float maxScale = MAX(1.0f, r_volumetricFogHeightMax->value);
	VectorSet4(fog, extinction, r_volumetricFogHeightBase->value, 1.0f / falloff, logf(maxScale));

	// albedo in the fogParms convention (R_LoadFogs, ParseShader)
	vec3_t albedo = { 0.7f, 0.75f, 0.8f };
	sscanf(r_volumetricFogHeightColor->string, "%f %f %f", &albedo[0], &albedo[1], &albedo[2]);
	for ( int c = 0; c < 3; c++ )
	{
		albedo[c] = Com_Clamp(0.0f, 1.0f, albedo[c]);
		if ( tr.linearLight )
			albedo[c] = (float)sRGBtoRGB(albedo[c]);
		albedo[c] *= tr.identityLight;
	}

	// soft cutoff: fades out over the last falloff (at most the whole layer)
	const float topHeight = MAX(0.0f, r_volumetricFogHeightTop->value);
	VectorSet4(color, albedo[0], albedo[1], albedo[2], topHeight - MIN(falloff, topHeight));
	VectorSet4(top, topHeight, 0.0f, 0.0f, 0.0f);
	return qtrue;
}

static const viewParms_t *R_VolumetricMainView( void )
{
	for ( int i = tr.numCachedViewParms - 1; i >= 0; i-- )
	{
		if ( tr.cachedViewParms[i].viewParmType == VPT_MAIN )
			return &tr.cachedViewParms[i];
	}
	return NULL;
}

/*
=================
RB_UpdateVolumetricConstants

Decides if this scene builds (or reuses) the froxel volume and appends the
VolumetricFog block. Every scene gets a block, inactive ones with
viewOrigin.w = 0.
=================
*/
void RB_UpdateVolumetricConstants( gpuFrame_t *frame, const trRefdef_t *refdef )
{
	tr.volumetricFogUboOffset = -1;
	if ( !s_vf.resources )
		return;

	VolumetricFogBlock block = {};
	const int frameNumber = backEndData->realFrameNumber;
	const viewParms_t *view = R_VolumetricMainView();

	if ( s_vf.builtFrameNumber != frameNumber )
	{
		// a new frame
		s_vf.frameActive = qfalse;
		s_vf.frameUsable = qfalse;
		s_vf.built = qfalse;
	}
	else
	{
		// another scene of a frame that already owns the volume
		tr.volumetricFogUboOffset = RB_AppendConstantsData(frame, &block, sizeof(block));
		return;
	}

	vec4_t heightFog, heightFogColor, heightFogTop;
	const qboolean heightFogOn = R_VolumetricHeightFog(heightFog, heightFogColor, heightFogTop);
	s_vf.frameHeightFog = qfalse;

	const qboolean worldView = (qboolean)(
		view != NULL &&
		tr.world != NULL &&
		(tr.world->numfogs > 1 || heightFogOn) &&	// no fog volume, no height fog: nothing to do
		tr.renderFbo != NULL &&
		!(refdef->rdflags & (RDF_NOWORLDMODEL | RDF_HYPERSPACE)) &&
		!refdef->doLAGoggles &&
		r_depthPrepass->integer &&
		r_drawfog->integer &&
		view->targetFbo == NULL);

	if ( !worldView )
	{
		tr.volumetricFogUboOffset = RB_AppendConstantsData(frame, &block, sizeof(block));
		return;
	}

	s_vf.builtFrameNumber = frameNumber;
	s_vf.frameScene = frame->currentScene;
	s_vf.frameHeightFog = heightFogOn;

	// projection of the rendered view; the froxel camera drops the SMAA T2x
	// jitter (written to P[2] and P[6], see R_GatherFrameViews)
	matrix_t renderViewProjection, froxelProjection, froxelViewProjection;
	Matrix16Multiply(view->projectionMatrix, view->world.modelViewMatrix, renderViewProjection);
	Matrix16Copy(view->projectionMatrix, froxelProjection);
	froxelProjection[2] = 0.0f;
	froxelProjection[6] = 0.0f;
	Matrix16Multiply(froxelProjection, view->world.modelViewMatrix, froxelViewProjection);

	vec3_t forward, right, up;
	VectorCopy(view->ori.axis[0], forward);
	VectorScale(view->ori.axis[1], -1.0f, right);
	VectorCopy(view->ori.axis[2], up);
	VectorNormalize(forward);
	VectorNormalize(right);
	VectorNormalize(up);

	const float nearZ = FROXEL_NEAR;
	float farZ = (r_volumetricFogFar->value > 0.0f) ? r_volumetricFogFar->value : FROXEL_AUTO_FAR;
	farZ = MAX(farZ, nearZ * 4.0f);

	// the frozen volume keeps its camera (r_volumetricFogFreeze)
	const qboolean freeze = (qboolean)(r_volumetricFogFreeze->integer && s_vf.hasVolume && s_vf.world == tr.world);
	if ( freeze && !s_vf.frozen )
	{
		s_vf.frozen = qtrue;
	}
	else if ( !freeze )
	{
		s_vf.frozen = qfalse;
	}

	// sky distance: the legacy fog cap of a global fog sits at depthForOpaque
	float skyDistance = view->zFar;
	if ( tr.world->globalFog )
		skyDistance = MAX(skyDistance, tr.world->globalFog->parms.depthForOpaque);

	matrix_t invRenderViewProjection;
	if ( !R_VolumetricInvertMatrix(renderViewProjection, invRenderViewProjection) )
		Matrix16Identity(invRenderViewProjection);

	vec4_t viewport;
	VectorSet4(viewport,
		view->viewportX / (float)tr.renderFbo->width,
		view->viewportY / (float)tr.renderFbo->height,
		view->viewportWidth / (float)tr.renderFbo->width,
		view->viewportHeight / (float)tr.renderFbo->height);

	if ( s_vf.frozen )
	{
		block = s_vf.frozenBlock;
		Matrix16Copy(invRenderViewProjection, block.invViewProjection);
		VectorCopy4(viewport, block.viewport);
		block.sliceParams[3] = skyDistance;
		block.debugParams[0] = (float)r_volumetricFogDebug->integer;
		block.debugParams[1] = r_volumetricFogBloom->value;
		block.debugParams[2] = 1.0f;

		s_vf.frameActive = qfalse;
		s_vf.frameUsable = qtrue;
		tr.volumetricFogUboOffset = RB_AppendConstantsData(frame, &block, sizeof(block));
		return;
	}

	// history
	const int debug = r_volumetricFogDebug->integer;
	const qboolean temporal = (qboolean)(r_volumetricFogTemporal->integer != 0);
	qboolean historyValid = (qboolean)(
		temporal &&
		s_vf.hasVolume &&
		s_vf.volumeFrameNumber + 1 == frameNumber &&
		s_vf.builtVolumeFrame + 1 == frameNumber &&	// the previous volume was really built
		s_vf.builtVolumeImage == s_vf.current &&		// and is the history image of this frame
		s_vf.world == tr.world &&
		s_vf.nearZ == nearZ &&
		s_vf.farZ == farZ &&
		s_vf.debug == debug &&
		!r_volumetricFogReset->integer &&
		tr.temporalHistoryValid);
	if ( historyValid )
	{
		if ( Distance(s_vf.origin, view->ori.origin) > FROXEL_CUT_DISTANCE ||
			DotProduct(s_vf.forward, forward) < FROXEL_CUT_COS_ANGLE ||
			fabsf(s_vf.fovX - view->fovX) > FROXEL_CUT_FOV * s_vf.fovX ||
			fabsf(s_vf.fovY - view->fovY) > FROXEL_CUT_FOV * s_vf.fovY )
		{
			historyValid = qfalse;
		}
	}
	if ( r_volumetricFogReset->integer )
		ri.Cvar_Set("r_volumetricFogReset", "0");

	Matrix16Copy(historyValid ? s_vf.viewProjection : froxelViewProjection, block.prevViewProjection);

	s_vf.current ^= 1;
	s_vf.frameActive = qtrue;
	s_vf.frameUsable = qtrue;
	s_vf.hasVolume = qtrue;
	s_vf.volumeFrameNumber = frameNumber;
	s_vf.world = tr.world;
	Matrix16Copy(froxelViewProjection, s_vf.viewProjection);
	VectorCopy(view->ori.origin, s_vf.origin);
	VectorCopy(forward, s_vf.forward);
	s_vf.fovX = view->fovX;
	s_vf.fovY = view->fovY;
	s_vf.nearZ = nearZ;
	s_vf.farZ = farZ;
	s_vf.debug = debug;
	s_vf.frameIndex++;

	R_VolumetricCullLights(view, refdef, forward);

	// froxel camera
	const float *P = froxelProjection;
	Matrix16Copy(froxelViewProjection, block.viewProjection);
	Matrix16Copy(invRenderViewProjection, block.invViewProjection);
	VectorSet4(block.viewOrigin, view->ori.origin[0], view->ori.origin[1], view->ori.origin[2], 1.0f);
	VectorSet4(block.viewForward, forward[0], forward[1], forward[2], 0.0f);
	for ( int c = 0; c < 3; c++ )
	{
		block.rayForward[c] = forward[c] + right[c] * (P[8] / P[0]) + up[c] * (P[9] / P[5]);
		block.rayRight[c] = right[c] / P[0];
		block.rayUp[c] = up[c] / P[5];
	}
	VectorCopy4(viewport, block.viewport);
	VectorSet4(block.sliceParams, nearZ, farZ, log2f(farZ / nearZ), skyDistance);
	VectorSet4(block.gridSize, (float)s_vf.width, (float)s_vf.height, (float)s_vf.depth, (float)(s_vf.frameIndex & 1023));

	// jitter inside the froxel, a new position every frame (8 frame cycle)
	if ( temporal )
	{
		const unsigned int i = (s_vf.frameIndex & 7) + 1;
		VectorSet4(block.jitter,
			R_VolumetricHalton(i, 2) - 0.5f,
			R_VolumetricHalton(i, 3) - 0.5f,
			R_VolumetricHalton(i, 5) - 0.5f,
			1.0f);
	}

	VectorSet4(block.temporalParams,
		historyValid ? r_volumetricFogHistoryWeight->value : 0.0f,
		historyValid ? 1.0f : 0.0f,
		0.0f,
		4.0f);	// history radiance clamped to [current / 4, current * 4]

	VectorSet4(block.lightParams,
		Com_Clamp(-0.9f, 0.9f, r_volumetricFogAnisotropy->value),
		r_volumetricFogSunScale->value,
		r_volumetricFogDlightScale->value,
		r_volumetricFogStaticScale->value);

	// sun: realtime with the cascaded shadow maps rendered for this view,
	// otherwise the baked sun part of the light grid
	const qboolean splitGrid = (qboolean)(tr.world->volumetricStaticGrid != NULL);
	const qboolean csm = (qboolean)(splitGrid && (view->flags & VPF_USESUNLIGHT) && tr.sunShadowArrayImage != NULL);
	vec3_t sunColor;
	if ( tr.world->volumetricHasSunCells )
		VectorCopy(tr.world->volumetricSunRadiance, sunColor);
	else
		VectorCopy(refdef->sunCol, sunColor);
	VectorSet4(block.sunColor, sunColor[0], sunColor[1], sunColor[2], csm ? 1.0f : 0.0f);
	VectorSet4(block.sunDirection, refdef->sunDir[0], refdef->sunDir[1], refdef->sunDir[2], splitGrid ? 1.0f : 0.0f);

	// light grid, as the legacy fog pass: origin half a cell below, texture
	// coordinates = (p - origin) * inverseSize / bounds
	if ( tr.world->lightGridData )
	{
		vec3_t sampleOrigin;
		VectorMA(tr.world->lightGridOrigin, -0.5f, tr.world->lightGridSize, sampleOrigin);
		VectorSet4(block.gridOrigin, sampleOrigin[0], sampleOrigin[1], sampleOrigin[2], tr.world->lightGridSize[2]);
		for ( int c = 0; c < 3; c++ )
			block.gridScale[c] = tr.world->lightGridInverseSize[c] / (float)MAX(1, tr.world->lightGridBounds[c]);
		block.gridScale[3] = tr.world->lightGridSize[0];	// horizontal cell size
	}

	const qboolean dlightShadows = (qboolean)(
		r_volumetricFogDlightShadows->integer &&
		r_dlightMode->integer >= 2 &&
		tr.pointShadowArrayImage != NULL);
	VectorSet4(block.shadowParams,
		r_shadowCascadeZFar->value,
		(float)r_shadowMapSize->integer,
		dlightShadows ? 1.0f : 0.0f,
		0.0002f);	// cascade depth bias (normalized depth)

	VectorSet4(block.debugParams, (float)debug, r_volumetricFogBloom->value, 0.0f, 0.0f);

	// height fog medium, added to the fog volumes by the injection
	VectorCopy4(heightFog, block.heightFog);
	VectorCopy4(heightFogColor, block.heightFogColor);
	VectorCopy4(heightFogTop, block.heightFogTop);

	// media: every fog volume of the map, as the Fogs block (volumetric units)
	int numFogs = tr.world->numfogs - 1;
	numFogs = Com_Clampi(0, MAX_GPU_FOGS, numFogs);
	block.numFogs = numFogs;
	for ( int i = 0; i < numFogs; i++ )
	{
		const fog_t *fog = tr.world->fogs + i + 1;
		const float extinction = (-logf(1.5f / 255.0f)) / fog->parms.depthForOpaque *
			tr.volumetricFogScale * r_volumetricFogScale->value;
		VectorSet4(block.fogColor[i], fog->color[0], fog->color[1], fog->color[2], extinction);
		VectorCopy4(fog->surface, block.fogPlane[i]);
		VectorSet4(block.fogMins[i], fog->bounds[0][0], fog->bounds[0][1], fog->bounds[0][2], fog->hasSurface ? 1.0f : 0.0f);
		VectorSet4(block.fogMaxs[i], fog->bounds[1][0], fog->bounds[1][1], fog->bounds[1][2], 0.0f);
	}

	s_vf.frozenBlock = block;
	tr.volumetricFogUboOffset = RB_AppendConstantsData(frame, &block, sizeof(block));
}

UniformBlockBinding RB_GetVolumetricFogBlockUniformBinding( void )
{
	const byte currentFrameScene = backEndData->currentFrame->currentScene;
	UniformBlockBinding binding = {};
	binding.ubo = backEndData->currentFrame->ubo[currentFrameScene];
	binding.block = UNIFORM_BLOCK_VOLUMETRIC_FOG;
	binding.offset = (tr.volumetricFogUboOffset == -1) ? 0 : tr.volumetricFogUboOffset;
	return binding;
}

/*
============================================================

Views and draws

============================================================
*/

/*
=================
RB_VolumetricBeginView

Called by RB_BeginDrawingView: does this view use the froxel volume?
=================
*/
void RB_VolumetricBeginView( void )
{
	backEnd.volumetricView = qfalse;
	backEnd.volumetricComposited = qfalse;

	if ( !s_vf.resources || !s_vf.frameUsable )
		return;

	const viewParms_t& viewParms = backEnd.viewParms;
	if ( viewParms.viewParmType != VPT_MAIN || viewParms.isPortal || viewParms.isSkyPortal )
		return;
	if ( viewParms.flags & VPF_DEPTHSHADOW )
		return;
	if ( backEndData->currentFrame->currentScene != s_vf.frameScene )
		return;
	if ( glState.currentFBO != tr.renderFbo || backEnd.framePostProcessed )
		return;
	if ( backEnd.refdef.rdflags & (RDF_NOWORLDMODEL | RDF_HYPERSPACE) )
		return;

	backEnd.volumetricView = qtrue;
}

/*
=================
RB_VolumetricFogMode

How a fogged draw of this sort gets its fog in the current view:
0 = legacy fog, 1 = froxel volume lookup, 2 = none (the composite after the
opaque layers applies it).
=================
*/
int RB_VolumetricFogMode( float sort )
{
	if ( !backEnd.volumetricView || backEnd.depthFill || backEnd.refractionFill )
		return 0;

	// the sort key keeps the integer part of the sort (RB_CreateSortKey)
	return ((int)sort <= SS_FOG) ? 2 : 1;
}

/*
=================
RB_VolumetricHeightFogSurface

The height fog is everywhere, not only inside the fog volumes: surfaces
without a fog volume (fogNum 0) that look the volume up themselves (layers
after SS_FOG) must be drawn with their fog path too. The layers up to SS_FOG
get it from the composite.
=================
*/
qboolean RB_VolumetricHeightFogSurface( float sort )
{
	return (qboolean)(s_vf.frameHeightFog && RB_VolumetricFogMode(sort) == 1);
}

void RB_VolumetricSetupFogDraw( int mode, UniformDataWriter& uniforms, SamplerBindingsWriter& samplers )
{
	if ( !s_vf.resources )
		return;

	uniforms.SetUniformInt(UNIFORM_FROXELFOGMODE, mode);
	if ( mode == 1 )
	{
		samplers.AddStaticImage(tr.froxelIntegratedImage, TB_CUBEMAP);
		samplers.AddStaticImage(tr.froxelTailImage, TB_ENVBRDFMAP);
	}
}

/*
============================================================

GPU passes

============================================================
*/

// GPU timers (r_speeds 100), same bookkeeping as RB_BeginTimedBlock
static int RB_VolumetricBeginTimer( const char *name )
{
	if ( !glRefConfig.timerQuery || r_speeds->integer != 100 )
		return -1;

	gpuFrame_t *frame = &backEndData->frames[backEndData->realFrameNumber % MAX_FRAMES];
	if ( tr.numTimedBlocks >= (MAX_GPU_TIMERS / 2) || frame->numTimers + 2 > MAX_GPU_TIMERS )
		return -1;

	const int handle = tr.numTimedBlocks++;
	gpuTimer_t *timer = frame->timers + frame->numTimers++;
	gpuTimedBlock_t *timedBlock = frame->timedBlocks + handle;
	timedBlock->beginTimer = timer->queryName;
	timedBlock->name = name;
	frame->numTimedBlocks++;

	qglQueryCounter(timer->queryName, GL_TIMESTAMP);
	return handle;
}

static void RB_VolumetricEndTimer( int handle )
{
	if ( handle < 0 )
		return;

	gpuFrame_t *frame = &backEndData->frames[backEndData->realFrameNumber % MAX_FRAMES];
	gpuTimer_t *timer = frame->timers + frame->numTimers++;
	frame->timedBlocks[handle].endTimer = timer->queryName;
	qglQueryCounter(timer->queryName, GL_TIMESTAMP);
}

static void RB_VolumetricViewViewport( void )
{
	GL_SetViewportAndScissor(backEnd.viewParms.viewportX, backEnd.viewParms.viewportY,
		backEnd.viewParms.viewportWidth, backEnd.viewParms.viewportHeight);
}

static void RB_VolumetricBindBlocks( void )
{
	const byte scene = backEndData->currentFrame->currentScene;
	const GLuint frameUbo = backEndData->currentFrame->ubo[scene];

	if ( tr.sceneUboOffset == -1 )
		RB_BindUniformBlock(tr.staticUbo, UNIFORM_BLOCK_SCENE, tr.defaultSceneUboOffset);
	else
		RB_BindUniformBlock(frameUbo, UNIFORM_BLOCK_SCENE, tr.sceneUboOffset);

	if ( tr.lightsUboOffset == -1 )
		RB_BindUniformBlock(tr.staticUbo, UNIFORM_BLOCK_LIGHTS, tr.defaultLightsUboOffset);
	else
		RB_BindUniformBlock(frameUbo, UNIFORM_BLOCK_LIGHTS, tr.lightsUboOffset);

	const UniformBlockBinding binding = RB_GetVolumetricFogBlockUniformBinding();
	RB_BindUniformBlock(binding.ubo, binding.block, binding.offset);
}

/*
=================
RB_VolumetricBuild

Injection and integration of the froxel volume. Called after the depth
prepass of the main view: the shadow maps of this frame are rendered.
=================
*/
void RB_VolumetricBuild( void )
{
	if ( !backEnd.volumetricView || !s_vf.frameActive || s_vf.built )
		return;

	s_vf.built = qtrue;

	FBO_t *oldFbo = glState.currentFBO;
	const int current = s_vf.current;
	const int previous = current ^ 1;
	s_vf.builtVolumeFrame = s_vf.volumeFrameNumber;
	s_vf.builtVolumeImage = current;

	R_PushDebugGroup(AL_STAGE, "Froxel fog");
	GL_Cull(CT_TWO_SIDED);
	GL_State(GLS_DEPTHTEST_DISABLE);
	RB_VolumetricBindBlocks();

	// injection + temporal filter, one slice per draw
	int timer = RB_VolumetricBeginTimer("Froxel fog inject");
	{
		shaderProgram_t *sp = &tr.volumetricInjectShader;
		FBO_Bind(tr.froxelInjectFbo);
		GL_SetViewportAndScissor(0, 0, s_vf.width, s_vf.height);
		GLSL_BindProgram(sp);

		image_t *staticGrid = tr.world->volumetricStaticGrid ? tr.world->volumetricStaticGrid : tr.whiteImage3D;
		image_t *sunGrid = tr.world->volumetricSunGrid ? tr.world->volumetricSunGrid : tr.whiteImage3D;
		if ( !tr.world->volumetricStaticGrid && tr.world->volumetricLightMaps[0] )
			staticGrid = tr.world->volumetricLightMaps[0];

		GL_BindToTMU(tr.froxelInjectImage[previous], TB_COLORMAP);
		GL_BindToTMU(staticGrid, TB_LIGHTMAP);
		GL_BindToTMU(sunGrid, TB_NORMALMAP);
		if ( tr.sunShadowArrayImage )
			GL_BindToTMU(tr.sunShadowArrayImage, TB_SHADOWMAP);
		if ( tr.pointShadowArrayImage )
			GL_BindToTMU(tr.pointShadowArrayImage, TB_SHADOWMAPARRAY);

		for ( int k = 0; k < s_vf.depth; k++ )
		{
			qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
				tr.froxelInjectImage[current]->texnum, 0, k);
			qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1,
				tr.froxelDynamicImage->texnum, 0, k);
			GLSL_SetUniformInt(sp, UNIFORM_FROXELSLICE, k);
			GLSL_SetUniformInt(sp, UNIFORM_LIGHTMASK, s_vf.lightMask[k]);
			RB_InstantTriangle();
		}
	}
	RB_VolumetricEndTimer(timer);

	// front to back integration, one slice per draw
	timer = RB_VolumetricBeginTimer("Froxel fog integrate");
	{
		shaderProgram_t *sp = &tr.volumetricIntegrateShader;
		FBO_Bind(tr.froxelIntegrateFbo);
		GL_SetViewportAndScissor(0, 0, s_vf.width, s_vf.height);
		GLSL_BindProgram(sp);
		GL_BindToTMU(tr.froxelInjectImage[current], TB_COLORMAP);
		GL_BindToTMU(tr.froxelDynamicImage, TB_NORMALMAP);

		const GLenum bufs[3] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2 };
		for ( int k = 0; k < s_vf.depth; k++ )
		{
			const int carryWrite = k & 1;
			qglFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
				tr.froxelIntegratedImage->texnum, 0, k);
			qglFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1,
				GL_TEXTURE_2D, tr.froxelCarryImage[carryWrite]->texnum, 0);
			qglDrawBuffers((k == s_vf.depth - 1) ? 3 : 2, bufs);

			GL_BindToTMU(tr.froxelCarryImage[carryWrite ^ 1], TB_LIGHTMAP);
			GLSL_SetUniformInt(sp, UNIFORM_FROXELSLICE, k);
			RB_InstantTriangle();
		}
	}
	RB_VolumetricEndTimer(timer);

	FBO_Bind(oldFbo);
}

qboolean RB_VolumetricCompositeActive( void )
{
	return (qboolean)(
		backEnd.volumetricView &&
		!backEnd.volumetricComposited &&
		!backEnd.depthFill &&
		!backEnd.refractionFill &&
		(s_vf.built || s_vf.frozen));
}

/*
=================
RB_VolumetricComposite

Fog of everything drawn so far (sort <= SS_FOG, the sky included) from the
depth buffer: color * T + S, glow * T. Called by RB_SubmitRenderPass with
renderFbo bound.
=================
*/
void RB_VolumetricComposite( void )
{
	if ( !RB_VolumetricCompositeActive() )
		return;

	backEnd.volumetricComposited = qtrue;

	FBO_t *oldFbo = glState.currentFBO;
	const int timer = RB_VolumetricBeginTimer("Froxel fog composite");

	// MSAA: the depth texture is the resolve target
	if ( tr.msaaResolveFbo )
	{
		// blits are clipped by the scissor rectangle
		GL_SetViewportAndScissor(0, 0, tr.renderFbo->width, tr.renderFbo->height);
		FBO_FastBlit(tr.renderFbo, NULL, tr.msaaResolveFbo, NULL, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
	}

	shaderProgram_t *sp = &tr.volumetricCompositeShader;
	FBO_Bind(tr.froxelCompositeFbo);
	RB_VolumetricViewViewport();
	GL_Cull(CT_TWO_SIDED);
	// color * T + S (source alpha = T), glow * T. The destination alpha is
	// kept: GL_State only masks all channels, so mask alpha directly and
	// restore the full mask GL_State assumes afterwards.
	GL_State(GLS_DEPTHTEST_DISABLE | GLS_SRCBLEND_ONE | GLS_DSTBLEND_SRC_ALPHA);
	qglColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_FALSE);
	GLSL_BindProgram(sp);
	RB_VolumetricBindBlocks();
	GL_BindToTMU(tr.renderDepthImage, TB_COLORMAP);
	GL_BindToTMU(tr.froxelIntegratedImage, TB_CUBEMAP);
	GL_BindToTMU(tr.froxelTailImage, TB_ENVBRDFMAP);
	RB_InstantTriangle();
	qglColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	GL_ResetSSRAuxWrite();

	RB_VolumetricEndTimer(timer);

	FBO_Bind(oldFbo);
	RB_VolumetricViewViewport();
}

/*
=================
RB_VolumetricDebugOverlay

r_volumetricFogDebug views, drawn over the tone mapped frame
=================
*/
void RB_VolumetricDebugOverlay( void )
{
	if ( !s_vf.resources || !r_volumetricFogDebug->integer || !s_vf.frameUsable )
		return;
	if ( backEnd.refdef.rdflags & (RDF_NOWORLDMODEL | RDF_HYPERSPACE) )
		return;

	shaderProgram_t *sp = &tr.volumetricDebugShader;
	FBO_Bind(NULL);
	GL_SetViewportAndScissor(0, 0, glConfig.vidWidth, glConfig.vidHeight);
	GL_Cull(CT_TWO_SIDED);
	GL_State(GLS_DEPTHTEST_DISABLE);
	GLSL_BindProgram(sp);
	RB_VolumetricBindBlocks();

	// MSAA: renderDepthImage holds the resolved depth of the main view
	GL_BindToTMU(tr.renderDepthImage, TB_COLORMAP);
	GL_BindToTMU(tr.froxelInjectImage[s_vf.current], TB_LIGHTMAP);
	GL_BindToTMU(tr.froxelDynamicImage, TB_NORMALMAP);
	GL_BindToTMU(tr.froxelIntegratedImage, TB_CUBEMAP);
	GL_BindToTMU(tr.froxelTailImage, TB_ENVBRDFMAP);
	RB_InstantTriangle();
}
