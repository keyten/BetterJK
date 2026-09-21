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

// Screen-space reflections (r_ssr), blended with the cubemap reflections.
//
// lightall keeps adding the parallax corrected, roughness prefiltered
// cubemap reflection C = cubemap radiance * W to the scene, W being the
// specular IBL weight (F0 * EnvBRDF.x + EnvBRDF.y, with specular occlusion).
// With r_ssr it also writes three extra attachments of renderFbo (only
// opaque lightall stages, see RB_WritesSSRMaterial and GL_SetSSRAuxWrite):
//
//   2 ssrNormalImage   RGB10_A2  rg = octahedral world normal, b = roughness, a = receiver
//   3 ssrSpecularImage RGB10_A2  rgb = sqrt(W)
//   4 ssrCubemapImage  RGBA16F   rgb = C, a = view depth (validates the data)
//
// The main pass of a view is split after the opaque sort (RB_SubmitRenderPass).
// There RB_RenderSSR traces the opaque HDR scene and replaces a part of the
// cubemap reflection:
//
//   color += confidence * (SSR radiance * W - C)
//
// so a reliable hit shows the screen-space reflection instead of the cubemap
// one (never both), and a miss keeps the cubemap reflection unchanged. Decals,
// fog and blended surfaces are drawn afterwards, on top of the result.
//
//   resolve   MSAA: color, depth and the material attachments
//   copy      opaque scene color -> ssrColor mip 0, mips 1.. (roughness blur)
//   depth     hardware depth -> ssrHiZ mip 0 (linear), mips 1.. (closest depth)
//   trace     ray march (linear or Hi-Z), full or half res -> ssrTrace
//   resolve   hit -> radiance from the color pyramid (cone of the roughness),
//             depth/normal aware upsampling -> ssrResolve (premultiplied)
//   temporal  optional, reprojected history -> ssrHistory[current]
//   composite additive signed delta into color 0 of renderFbo
//
// r_ssr 0 creates none of it: renderFbo, lightall and the pass are unchanged.
// See docs/rend2-ssr.md.

#include "tr_local.h"

// Resources (and USE_SSR in the GLSL header) are decided when the renderer
// builds its GPU shaders, see R_CreateSSRImages
static qboolean s_ssrResources = qfalse;
static qboolean s_ssrTemporalResources = qfalse;

struct ssrQualityPreset_t
{
	const char *name;
	int steps;		// linear march steps, Hi-Z: iterations / 3
	int refineSteps;
	int halfRes;
	int hiZ;
};

static const ssrQualityPreset_t ssrQualityPresets[] =
{
	{ "low",    16, 4, 1, 0 },
	{ "medium", 24, 5, 1, 1 },
	{ "high",   40, 6, 0, 1 },
	{ "ultra",  64, 8, 0, 1 },
};

// camera cuts reset the temporal history
#define SSR_CUT_DISTANCE	192.0f
#define SSR_CUT_COS_ANGLE	0.8191520f	// cos(35 deg)
#define SSR_CUT_FOV			1.0f

// specular weights below this are not traced (nothing visible to replace)
#define SSR_MIN_WEIGHT		0.004f

struct ssrHistoryState_t
{
	qboolean valid;
	unsigned frameNumber;
	const world_t *world;
	vec3_t origin;
	vec3_t forward;
	float fovX;
	float fovY;
	int viewport[4];
	matrix_t viewProjection;
	int current;			// history image written last
};

static ssrHistoryState_t s_history;

// state of the last traced view, for r_ssrDebug
static struct
{
	unsigned frameNumber;
	image_t *finalImage;
	float traceScale;
	float maxDistance;
	qboolean valid;
} s_debug;

qboolean R_SSRResourcesEnabled( void )
{
	return s_ssrResources;
}

qboolean R_SSRWantsVelocity( void )
{
	return s_ssrTemporalResources;
}

/*
============================================================

Resources

============================================================
*/

static void R_SSRImageFilter( image_t *image, int maxLevel, qboolean linear )
{
	GL_Bind(image);
	qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
	qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, maxLevel);
	if ( linear )
	{
		qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
			maxLevel > 0 ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR);
		qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	}
	else
	{
		qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
			maxLevel > 0 ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST);
		qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	}
}

static image_t *R_SSRCreateMipImage(
	const char *name, int width, int height, int internalFormat,
	GLenum format, GLenum type, int numLevels, qboolean linear )
{
	image_t *image = R_CreateImage(
		name, NULL, width, height, IMGTYPE_COLORALPHA,
		IMGFLAG_NO_COMPRESSION | IMGFLAG_CLAMPTOEDGE | IMGFLAG_MUTABLE,
		internalFormat);

	GL_Bind(image);
	for ( int level = 1; level < numLevels; level++ )
	{
		qglTexImage2D(
			GL_TEXTURE_2D, level, internalFormat,
			Q_max(1, width >> level), Q_max(1, height >> level), 0,
			format, type, NULL);
	}
	R_SSRImageFilter(image, numLevels - 1, linear);
	return image;
}

void R_CreateSSRImages( int width, int height, int hdrFormat )
{
	// GPU shaders are kept over a map change (only a vid_restart rebuilds
	// them). They were compiled with or without USE_SSR, so keep what they
	// expect; r_ssr is latched anyway.
	if ( !tr.textureColorShader[0].program )
	{
		s_ssrResources = (qboolean)(r_ssr->integer != 0);
		if ( s_ssrResources && !r_specularMapping->integer )
			ri.Printf(PRINT_WARNING, "r_ssr: r_specularMapping is off, no material has specular reflections\n");
		s_ssrTemporalResources = (qboolean)(s_ssrResources && r_ssrTemporal->integer);
	}

	Com_Memset(&s_history, 0, sizeof(s_history));
	Com_Memset(&s_debug, 0, sizeof(s_debug));

	tr.ssrNormalImage = NULL;
	tr.ssrSpecularImage = NULL;
	tr.ssrCubemapImage = NULL;
	tr.ssrColorImage = NULL;
	tr.ssrHiZImage = NULL;
	tr.ssrTraceImage = NULL;
	tr.ssrResolveImage = NULL;
	for ( int i = 0; i < 2; i++ )
	{
		tr.ssrHistoryImage[i] = NULL;
		tr.ssrHistoryGeomImage[i] = NULL;
	}

	if ( !s_ssrResources )
		return;

	const int flags = IMGFLAG_NO_COMPRESSION | IMGFLAG_CLAMPTOEDGE;

	// material attachments of renderFbo (MSAA: resolve targets)
	tr.ssrNormalImage = R_CreateImage(
		"*ssrNormal", NULL, width, height, IMGTYPE_COLORALPHA, flags, GL_RGB10_A2);
	tr.ssrSpecularImage = R_CreateImage(
		"*ssrSpecular", NULL, width, height, IMGTYPE_COLORALPHA, flags, GL_RGB10_A2);
	tr.ssrCubemapImage = R_CreateImage(
		"*ssrCubemap", NULL, width, height, IMGTYPE_COLORALPHA, flags, GL_RGBA16F);
	R_SSRImageFilter(tr.ssrNormalImage, 0, qfalse);
	R_SSRImageFilter(tr.ssrSpecularImage, 0, qfalse);
	R_SSRImageFilter(tr.ssrCubemapImage, 0, qfalse);

	// opaque scene color pyramid, same format as renderFbo color 0 (the MSAA
	// resolve blit needs identical formats)
	const qboolean floatColor = (qboolean)(hdrFormat == GL_RGBA16F);
	tr.ssrColorImage = R_SSRCreateMipImage(
		"*ssrColor", width, height, hdrFormat,
		GL_RGBA, floatColor ? GL_HALF_FLOAT : GL_UNSIGNED_BYTE, SSR_COLOR_MIPS, qtrue);

	// mip 0: linear view depth, mips: closest depth of the 2x2 texels
	tr.ssrHiZImage = R_SSRCreateMipImage(
		"*ssrHiZ", width, height, GL_R32F, GL_RED, GL_FLOAT, SSR_HIZ_MIPS, qfalse);

	// full size, half resolution tracing uses the lower left quarter
	tr.ssrTraceImage = R_CreateImage(
		"*ssrTrace", NULL, width, height, IMGTYPE_COLORALPHA, flags, GL_RGBA16);
	R_SSRImageFilter(tr.ssrTraceImage, 0, qfalse);

	tr.ssrResolveImage = R_CreateImage(
		"*ssrResolve", NULL, width, height, IMGTYPE_COLORALPHA, flags, GL_RGBA16F);
	R_SSRImageFilter(tr.ssrResolveImage, 0, qfalse);

	if ( s_ssrTemporalResources )
	{
		for ( int i = 0; i < 2; i++ )
		{
			tr.ssrHistoryImage[i] = R_CreateImage(
				va("*ssrHistory%d", i), NULL, width, height, IMGTYPE_COLORALPHA,
				flags, GL_RGBA16F);
			R_SSRImageFilter(tr.ssrHistoryImage[i], 0, qtrue);

			tr.ssrHistoryGeomImage[i] = R_CreateImage(
				va("*ssrHistoryGeom%d", i), NULL, width, height, IMGTYPE_COLORALPHA,
				flags, GL_RGBA16F);
			R_SSRImageFilter(tr.ssrHistoryGeomImage[i], 0, qfalse);
		}
	}

	GL_SelectTexture(0);
}

/*
=================
R_AttachSSRRenderTargets

Called by FBO_Init with fbo bound: the material attachments 2..4 of
renderFbo (multisample renderbuffers with MSAA) and of the MSAA resolve FBO.
=================
*/
void R_AttachSSRRenderTargets( FBO_t *fbo, int multisample )
{
	if ( !s_ssrResources || !fbo )
		return;

	if ( multisample )
	{
		FBO_CreateBuffer(fbo, GL_RGB10_A2, 2, multisample);
		FBO_CreateBuffer(fbo, GL_RGB10_A2, 3, multisample);
		FBO_CreateBuffer(fbo, GL_RGBA16F, 4, multisample);
	}
	else
	{
		FBO_AttachTextureImage(tr.ssrNormalImage, 2);
		FBO_AttachTextureImage(tr.ssrSpecularImage, 3);
		FBO_AttachTextureImage(tr.ssrCubemapImage, 4);
	}
}

static FBO_t *R_SSRCreateLevelFBO( const char *name, image_t *image, int level )
{
	const int w = Q_max(1, image->width >> level);
	const int h = Q_max(1, image->height >> level);
	FBO_t *fbo = FBO_Create(name, w, h);

	FBO_Bind(fbo);
	qglFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
		GL_TEXTURE_2D, image->texnum, level);
	glState.currentFBO->colorImage[0] = image;
	glState.currentFBO->colorBuffers[0] = image->texnum;
	qglDrawBuffer(GL_COLOR_ATTACHMENT0);
	R_CheckFBO(fbo);
	return fbo;
}

void R_CreateSSRFBOs( void )
{
	for ( int i = 0; i < SSR_COLOR_MIPS; i++ )
		tr.ssrColorFbo[i] = NULL;
	for ( int i = 0; i < SSR_HIZ_MIPS; i++ )
		tr.ssrHiZFbo[i] = NULL;
	tr.ssrTraceFbo = NULL;
	tr.ssrResolveFbo = NULL;
	tr.ssrHistoryFbo[0] = tr.ssrHistoryFbo[1] = NULL;
	tr.ssrCompositeFbo = NULL;

	if ( !s_ssrResources )
		return;

	for ( int i = 0; i < SSR_COLOR_MIPS; i++ )
		tr.ssrColorFbo[i] = R_SSRCreateLevelFBO(va("_ssrColor%d", i), tr.ssrColorImage, i);

	for ( int i = 0; i < SSR_HIZ_MIPS; i++ )
		tr.ssrHiZFbo[i] = R_SSRCreateLevelFBO(va("_ssrHiZ%d", i), tr.ssrHiZImage, i);

	tr.ssrTraceFbo = R_SSRCreateLevelFBO("_ssrTrace", tr.ssrTraceImage, 0);
	tr.ssrResolveFbo = R_SSRCreateLevelFBO("_ssrResolve", tr.ssrResolveImage, 0);

	if ( s_ssrTemporalResources )
	{
		for ( int i = 0; i < 2; i++ )
		{
			tr.ssrHistoryFbo[i] = FBO_Create(
				va("_ssrHistory%d", i), tr.ssrHistoryImage[i]->width, tr.ssrHistoryImage[i]->height);
			FBO_Bind(tr.ssrHistoryFbo[i]);
			FBO_AttachTextureImage(tr.ssrHistoryImage[i], 0);
			FBO_AttachTextureImage(tr.ssrHistoryGeomImage[i], 1);
			const GLenum bufs[2] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1 };
			qglDrawBuffers(2, bufs);
			R_CheckFBO(tr.ssrHistoryFbo[i]);
		}
	}

	// color 0 of renderFbo only: the composite must not touch the glow and
	// material attachments, and must not have the sampled depth attached
	tr.ssrCompositeFbo = FBO_Create("_ssrComposite", tr.renderFbo->width, tr.renderFbo->height);
	FBO_Bind(tr.ssrCompositeFbo);
	if ( tr.msaaResolveFbo )
	{
		qglFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
			GL_RENDERBUFFER, tr.renderFbo->colorBuffers[0]);
		glState.currentFBO->colorBuffers[0] = tr.renderFbo->colorBuffers[0];
	}
	else
	{
		FBO_AttachTextureImage(tr.renderImage, 0);
	}
	qglDrawBuffer(GL_COLOR_ATTACHMENT0);
	R_CheckFBO(tr.ssrCompositeFbo);

	// the context starts with all color masks enabled
	glState.ssrAuxWrite = true;
	GL_ResetSSRAuxWrite();
}

/*
============================================================

Color masks of the material attachments

============================================================
*/

void GL_SetSSRAuxWrite( bool enable )
{
	if ( !s_ssrResources || glState.ssrAuxWrite == enable )
		return;

	const GLboolean mask = enable ? GL_TRUE : GL_FALSE;
	for ( int i = 2; i <= 4; i++ )
		qglColorMaski(i, mask, mask, mask, mask);
	glState.ssrAuxWrite = enable;
}

// after a qglColorMask call (which sets the masks of all draw buffers)
void GL_ResetSSRAuxWrite( void )
{
	if ( !s_ssrResources )
		return;

	glState.ssrAuxWrite = true;
	GL_SetSSRAuxWrite(false);
}

/*
============================================================

GPU timers (r_speeds 100), same bookkeeping as RB_BeginTimedBlock

============================================================
*/

static int RB_SSRBeginTimer( const char *name )
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

static void RB_SSREndTimer( int handle )
{
	if ( handle < 0 )
		return;

	gpuFrame_t *frame = &backEndData->frames[backEndData->realFrameNumber % MAX_FRAMES];
	gpuTimer_t *timer = frame->timers + frame->numTimers++;
	frame->timedBlocks[handle].endTimer = timer->queryName;
	qglQueryCounter(timer->queryName, GL_TIMESTAMP);
}

/*
============================================================

View

============================================================
*/

/*
=================
RB_SSRBeginView

Called by RB_BeginDrawingView with the view's target bound. Decides if the
view gets screen-space reflections and clears the material attachments.
=================
*/
void RB_SSRBeginView( void )
{
	backEnd.ssrView = qfalse;

	if ( !s_ssrResources )
		return;

	const viewParms_t& viewParms = backEnd.viewParms;
	if ( viewParms.flags & (VPF_DEPTHSHADOW | VPF_NOCUBEMAPS) )
		return;

	// the reconstruction needs an unmodified perspective projection of a
	// view rendered into renderFbo: no sky portals, mirrors/portals (oblique
	// near plane), cubemap or shadow views
	if ( viewParms.isSkyPortal || viewParms.isPortal )
		return;
	if ( viewParms.targetFbo != NULL && viewParms.targetFbo != tr.renderFbo )
		return;
	if ( glState.currentFBO != tr.renderFbo )
		return;
	if ( !tr.world || (backEnd.refdef.rdflags & (RDF_NOWORLDMODEL | RDF_HYPERSPACE)) )
		return;
	if ( backEnd.framePostProcessed )
		return;

	// SSR at zero strength without debug views is the legacy look: skip
	// the work (the split screen compare still needs it)
	if ( r_ssrStrength->value <= 0.0f && !r_ssrDebug->integer && !r_ssrCompare->integer )
		return;

	backEnd.ssrView = qtrue;

	// receiver = 0, depth = 0 (never matches: not a receiver)
	const vec4_t clearNormal = { 0.5f, 0.5f, 1.0f, 0.0f };
	GL_SetSSRAuxWrite(true);
	qglClearBufferfv(GL_COLOR, 2, clearNormal);
	qglClearBufferfv(GL_COLOR, 3, colorBlack);
	const vec4_t clearCubemap = { 0.0f, 0.0f, 0.0f, 0.0f };
	qglClearBufferfv(GL_COLOR, 4, clearCubemap);
	GL_SetSSRAuxWrite(false);
}

qboolean RB_SSRActive( void )
{
	return (qboolean)(backEnd.ssrView && !backEnd.depthFill && !backEnd.refractionFill);
}

/*
============================================================

Passes

============================================================
*/

struct ssrViewInfo_t
{
	vec4_t projection;	// P[0], P[5], P[8], P[9]
	vec4_t depthParams;	// P[14], P[10], zFar, view space size of one pixel at depth 1
	vec4_t viewport;	// view rectangle in texture coordinates
	matrix_t worldToView;
	matrix_t viewToWorld;
	matrix_t viewProjection;
};

static void RB_SSRSetViewUniforms( shaderProgram_t *sp, const ssrViewInfo_t& info )
{
	GLSL_SetUniformVec4(sp, UNIFORM_SSRPROJECTION, info.projection);
	GLSL_SetUniformVec4(sp, UNIFORM_SSRDEPTHPARAMS, info.depthParams);
	GLSL_SetUniformVec4(sp, UNIFORM_SSRVIEWPORT, info.viewport);
	GLSL_SetUniformMatrix4x4(sp, UNIFORM_SSRWORLDTOVIEW, info.worldToView, 1);
}

static void RB_SSRBeginPass( FBO_t *fbo, shaderProgram_t *sp, int width, int height, uint32_t stateBits = GLS_DEPTHTEST_DISABLE )
{
	FBO_Bind(fbo);
	GL_SetViewportAndScissor(0, 0, width, height);
	GL_State(stateBits);
	GL_Cull(CT_TWO_SIDED);
	GLSL_BindProgram(sp);
}

static void RB_SSRTexelSize( vec4_t out, int srcWidth, int srcHeight, int dstWidth, int dstHeight )
{
	VectorSet4(out,
		1.0f / Q_max(1, srcWidth), 1.0f / Q_max(1, srcHeight),
		1.0f / Q_max(1, dstWidth), 1.0f / Q_max(1, dstHeight));
}

static void RB_SSRSetLevelRange( image_t *image, int tmu, int baseLevel, int maxLevel )
{
	GL_BindToTMU(image, tmu);
	GL_SelectTexture(tmu);
	qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, baseLevel);
	qglTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, maxLevel);
}

static void RB_SSRBuildViewInfo( ssrViewInfo_t& info )
{
	const viewParms_t& viewParms = backEnd.viewParms;
	const float *proj = viewParms.projectionMatrix;

	VectorSet4(info.projection, proj[0], proj[5], proj[8], proj[9]);
	VectorSet4(info.depthParams, proj[14], proj[10], viewParms.zFar,
		2.0f / (proj[0] * Q_max(1, viewParms.viewportWidth)));
	VectorSet4(info.viewport,
		viewParms.viewportX / (float)tr.renderFbo->width,
		viewParms.viewportY / (float)tr.renderFbo->height,
		viewParms.viewportWidth / (float)tr.renderFbo->width,
		viewParms.viewportHeight / (float)tr.renderFbo->height);

	// SSR view space: x right, y up, z forward (as tr_ao.cpp)
	vec3_t right, up, forward;
	VectorScale(viewParms.ori.axis[1], -1.0f, right);
	VectorCopy(viewParms.ori.axis[2], up);
	VectorCopy(viewParms.ori.axis[0], forward);
	VectorNormalize(right);
	VectorNormalize(up);
	VectorNormalize(forward);
	const float *o = viewParms.ori.origin;

	// column major
	float *m = info.worldToView;
	m[0] = right[0]; m[4] = right[1]; m[8]  = right[2]; m[12] = -DotProduct(right, o);
	m[1] = up[0];    m[5] = up[1];    m[9]  = up[2];    m[13] = -DotProduct(up, o);
	m[2] = forward[0]; m[6] = forward[1]; m[10] = forward[2]; m[14] = -DotProduct(forward, o);
	m[3] = 0.0f;     m[7] = 0.0f;     m[11] = 0.0f;     m[15] = 1.0f;

	float *v = info.viewToWorld;
	v[0] = right[0];   v[1] = right[1];   v[2]  = right[2];   v[3]  = 0.0f;
	v[4] = up[0];      v[5] = up[1];      v[6]  = up[2];      v[7]  = 0.0f;
	v[8] = forward[0]; v[9] = forward[1]; v[10] = forward[2]; v[11] = 0.0f;
	v[12] = o[0];      v[13] = o[1];      v[14] = o[2];       v[15] = 1.0f;

	Matrix16Multiply(proj, viewParms.world.modelViewMatrix, info.viewProjection);
}

// MSAA: resolve depth and the material attachments. Color is resolved by the
// copy into the pyramid.
static void RB_SSRResolveInputs( void )
{
	if ( !tr.msaaResolveFbo )
		return;

	// blits are clipped by the scissor rectangle
	GL_SetViewportAndScissor(0, 0, tr.renderFbo->width, tr.renderFbo->height);
	FBO_FastBlit(tr.renderFbo, NULL, tr.msaaResolveFbo, NULL, GL_DEPTH_BUFFER_BIT, GL_NEAREST);

	GL_SetSSRAuxWrite(true);
	for ( int i = 2; i <= 4; i++ )
		FBO_FastBlitIndexed(tr.renderFbo, tr.msaaResolveFbo, i, i, GL_COLOR_BUFFER_BIT, GL_NEAREST);
	GL_SetSSRAuxWrite(false);
}

static void RB_SSRBuildDepth( const ssrViewInfo_t& info, int numLevels )
{
	shaderProgram_t *sp = &tr.ssrHiZShader[0];
	RB_SSRBeginPass(tr.ssrHiZFbo[0], sp, tr.ssrHiZFbo[0]->width, tr.ssrHiZFbo[0]->height);
	GL_BindToTMU(tr.renderDepthImage, TB_COLORMAP);
	RB_SSRSetViewUniforms(sp, info);
	RB_InstantTriangle();

	// closest depth mips. Sampling is restricted to the source level while
	// rendering the next one, which avoids a feedback loop
	sp = &tr.ssrHiZShader[1];
	GLSL_BindProgram(sp);
	for ( int level = 1; level < numLevels; level++ )
	{
		FBO_t *fbo = tr.ssrHiZFbo[level];
		FBO_Bind(fbo);
		GL_SetViewportAndScissor(0, 0, fbo->width, fbo->height);
		RB_SSRSetLevelRange(tr.ssrHiZImage, TB_SHADOWMAPARRAY, level - 1, level - 1);
		RB_InstantTriangle();
	}
	RB_SSRSetLevelRange(tr.ssrHiZImage, TB_SHADOWMAPARRAY, 0, SSR_HIZ_MIPS - 1);
}

static void RB_SSRBuildColorPyramid( void )
{
	// MSAA resolves here. Blits are clipped by the scissor rectangle
	GL_SetViewportAndScissor(0, 0, tr.renderFbo->width, tr.renderFbo->height);
	FBO_FastBlit(tr.renderFbo, NULL, tr.ssrColorFbo[0], NULL, GL_COLOR_BUFFER_BIT, GL_NEAREST);

	shaderProgram_t *sp = &tr.ssrDownsampleShader;
	for ( int level = 1; level < SSR_COLOR_MIPS; level++ )
	{
		FBO_t *fbo = tr.ssrColorFbo[level];
		RB_SSRBeginPass(fbo, sp, fbo->width, fbo->height);
		RB_SSRSetLevelRange(tr.ssrColorImage, TB_SPECULARMAP, level - 1, level - 1);

		vec4_t texelSize;
		const FBO_t *src = tr.ssrColorFbo[level - 1];
		RB_SSRTexelSize(texelSize, src->width, src->height, fbo->width, fbo->height);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRTEXELSIZE, texelSize);
		RB_InstantTriangle();
	}
	RB_SSRSetLevelRange(tr.ssrColorImage, TB_SPECULARMAP, 0, SSR_COLOR_MIPS - 1);
}

static void RB_SSRBindMaterial( void )
{
	GL_BindToTMU(tr.ssrNormalImage, TB_LIGHTMAP);
	GL_BindToTMU(tr.ssrSpecularImage, TB_NORMALMAP);
	GL_BindToTMU(tr.ssrCubemapImage, TB_DELUXEMAP);
	GL_BindToTMU(tr.ssrHiZImage, TB_SHADOWMAPARRAY);
}

// Temporal history of the main view: valid when the previous frame traced
// the same world from a nearby camera
static qboolean RB_SSRUpdateHistory( const ssrViewInfo_t& info )
{
	const viewParms_t& viewParms = backEnd.viewParms;
	const unsigned frameNumber = backEndData->realFrameNumber;

	qboolean valid = s_history.valid;
	if ( valid )
	{
		vec3_t forward;
		VectorCopy(viewParms.ori.axis[0], forward);
		VectorNormalize(forward);

		if ( s_history.frameNumber + 1 != frameNumber ||
			s_history.world != tr.world ||
			!tr.temporalHistoryValid ||
			s_history.viewport[0] != viewParms.viewportX ||
			s_history.viewport[1] != viewParms.viewportY ||
			s_history.viewport[2] != viewParms.viewportWidth ||
			s_history.viewport[3] != viewParms.viewportHeight ||
			Distance(s_history.origin, viewParms.ori.origin) > SSR_CUT_DISTANCE ||
			DotProduct(s_history.forward, forward) < SSR_CUT_COS_ANGLE ||
			fabsf(s_history.fovX - viewParms.fovX) > SSR_CUT_FOV ||
			fabsf(s_history.fovY - viewParms.fovY) > SSR_CUT_FOV )
		{
			valid = qfalse;
		}
	}

	return valid;
}

static void RB_SSRStoreHistory( const ssrViewInfo_t& info, int written )
{
	const viewParms_t& viewParms = backEnd.viewParms;

	s_history.valid = qtrue;
	s_history.frameNumber = backEndData->realFrameNumber;
	s_history.world = tr.world;
	VectorCopy(viewParms.ori.origin, s_history.origin);
	VectorCopy(viewParms.ori.axis[0], s_history.forward);
	VectorNormalize(s_history.forward);
	s_history.fovX = viewParms.fovX;
	s_history.fovY = viewParms.fovY;
	s_history.viewport[0] = viewParms.viewportX;
	s_history.viewport[1] = viewParms.viewportY;
	s_history.viewport[2] = viewParms.viewportWidth;
	s_history.viewport[3] = viewParms.viewportHeight;
	Com_Memcpy(s_history.viewProjection, info.viewProjection, sizeof(matrix_t));
	s_history.current = written;
}

/*
=================
RB_RenderSSR

Called by RB_SubmitRenderPass between the opaque sort and the rest of the
main pass of a view (RB_SSRActive), with renderFbo bound.
=================
*/
void RB_RenderSSR( void )
{
	if ( !RB_SSRActive() )
		return;

	FBO_t *oldFbo = glState.currentFBO;
	const viewParms_t& viewParms = backEnd.viewParms;

	R_PushDebugGroup(AL_STAGE, "SSR");

	ssrViewInfo_t info;
	RB_SSRBuildViewInfo(info);

	const ssrQualityPreset_t& quality =
		ssrQualityPresets[Com_Clampi(0, ARRAY_LEN(ssrQualityPresets) - 1, r_ssrQuality->integer)];
	const int steps = r_ssrSteps->integer > 0 ? r_ssrSteps->integer : quality.steps;
	const int refineSteps = r_ssrRefineSteps->integer > 0 ? r_ssrRefineSteps->integer : quality.refineSteps;
	const qboolean halfRes = (qboolean)(r_ssrHalfRes->integer >= 0 ? r_ssrHalfRes->integer : quality.halfRes);
	const qboolean hiZ = (qboolean)(r_ssrHiZ->integer >= 0 ? r_ssrHiZ->integer : quality.hiZ);
	const float maxDistance = r_ssrMaxDistance->value;
	const float traceScale = halfRes ? 2.0f : 1.0f;

	const int width = tr.renderFbo->width;
	const int height = tr.renderFbo->height;
	const int traceWidth = halfRes ? (width + 1) / 2 : width;
	const int traceHeight = halfRes ? (height + 1) / 2 : height;

	// inputs
	int timer = RB_SSRBeginTimer("SSR inputs");
	RB_SSRResolveInputs();
	RB_SSRBuildDepth(info, hiZ ? SSR_HIZ_MIPS : 1);
	RB_SSRBuildColorPyramid();
	RB_SSREndTimer(timer);

	// trace
	timer = RB_SSRBeginTimer("SSR trace");
	{
		shaderProgram_t *sp = &tr.ssrTraceShader[hiZ ? SSRDEF_TRACE_HIZ : SSRDEF_TRACE];
		RB_SSRBeginPass(tr.ssrTraceFbo, sp, traceWidth, traceHeight);
		RB_SSRBindMaterial();
		RB_SSRSetViewUniforms(sp, info);

		vec4_t texelSize, settings, settings2, settings3;
		RB_SSRTexelSize(texelSize, width, height, traceWidth, traceHeight);
		VectorSet4(settings,
			(float)Com_Clampi(1, 256, steps),
			(float)Com_Clampi(0, 16, refineSteps),
			maxDistance,
			r_ssrThickness->value);
		VectorSet4(settings2,
			r_ssrMaxRoughness->value,
			r_ssrEdgeFade->value,
			traceScale,
			(float)(backEndData->realFrameNumber & 63));
		VectorSet4(settings3,
			(float)(SSR_HIZ_MIPS - 1),
			SSR_MIN_WEIGHT,
			r_znear->value,
			(float)Com_Clampi(8, 1024, steps * 3));
		GLSL_SetUniformVec4(sp, UNIFORM_SSRTEXELSIZE, texelSize);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS, settings);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS2, settings2);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS3, settings3);
		RB_InstantTriangle();
	}
	RB_SSREndTimer(timer);

	// hit -> radiance
	timer = RB_SSRBeginTimer("SSR resolve");
	{
		shaderProgram_t *sp = &tr.ssrResolveShader;
		RB_SSRBeginPass(tr.ssrResolveFbo, sp, width, height);
		RB_SSRBindMaterial();
		GL_BindToTMU(tr.ssrColorImage, TB_SPECULARMAP);
		GL_BindToTMU(tr.ssrTraceImage, TB_SHADOWMAP);
		RB_SSRSetViewUniforms(sp, info);

		vec4_t texelSize, settings, settings2;
		RB_SSRTexelSize(texelSize, width, height, width, height);
		VectorSet4(settings, traceScale, maxDistance, (float)(SSR_COLOR_MIPS - 1), 0.0f);
		VectorSet4(settings2, r_ssrMaxRoughness->value, 0.0f, 0.0f, 0.0f);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRTEXELSIZE, texelSize);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS, settings);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS2, settings2);
		RB_InstantTriangle();
	}
	RB_SSREndTimer(timer);

	image_t *finalImage = tr.ssrResolveImage;

	// temporal accumulation
	if ( s_ssrTemporalResources && r_ssrTemporal->integer )
	{
		timer = RB_SSRBeginTimer("SSR temporal");

		const qboolean historyValid = RB_SSRUpdateHistory(info);
		const int previous = s_history.current;
		const int current = previous ^ 1;

		matrix_t reproject;
		Matrix16Multiply(historyValid ? s_history.viewProjection : info.viewProjection,
			info.viewToWorld, reproject);

		// the velocity buffer is written by the depth prepass of the first
		// scene of the frame
		const qboolean velocity = (qboolean)(
			tr.velocityImage != NULL &&
			r_depthPrepass->integer &&
			backEndData->currentFrame &&
			backEndData->currentFrame->currentScene == 0);

		shaderProgram_t *sp = &tr.ssrTemporalShader;
		RB_SSRBeginPass(tr.ssrHistoryFbo[current], sp, width, height);
		RB_SSRBindMaterial();
		GL_BindToTMU(tr.ssrResolveImage, TB_SHADOWMAP);
		GL_BindToTMU(tr.ssrHistoryImage[previous], TB_CUBEMAP);
		GL_BindToTMU(tr.ssrHistoryGeomImage[previous], TB_ENVBRDFMAP);
		GL_BindToTMU(velocity ? tr.velocityImage : tr.whiteImage, TB_SSAOMAP);
		RB_SSRSetViewUniforms(sp, info);
		GLSL_SetUniformMatrix4x4(sp, UNIFORM_SSRREPROJECT, reproject, 1);

		vec4_t texelSize, settings;
		RB_SSRTexelSize(texelSize, width, height, width, height);
		VectorSet4(settings,
			historyValid ? 1.0f : 0.0f,
			r_ssrTemporalWeight->value,
			velocity ? 1.0f : 0.0f,
			0.0f);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRTEXELSIZE, texelSize);
		GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS, settings);
		RB_InstantTriangle();

		RB_SSRStoreHistory(info, current);
		finalImage = tr.ssrHistoryImage[current];

		RB_SSREndTimer(timer);
	}

	// composite: replace the cubemap reflection where the SSR is reliable
	timer = RB_SSRBeginTimer("SSR composite");
	{
		const int debugView = r_ssrDebug->integer;
		const qboolean sceneDebug = (qboolean)(debugView >= 7 && debugView <= 10);
		const float splitX = r_ssrCompare->integer ?
			viewParms.viewportX + 0.5f * viewParms.viewportWidth : -1.0f;

		shaderProgram_t *sp = &tr.ssrCompositeShader;
		FBO_Bind(tr.ssrCompositeFbo);
		GL_SetViewportAndScissor(viewParms.viewportX, viewParms.viewportY,
			viewParms.viewportWidth, viewParms.viewportHeight);
		GL_Cull(CT_TWO_SIDED);
		GLSL_BindProgram(sp);
		RB_SSRBindMaterial();
		GL_BindToTMU(finalImage, TB_SHADOWMAP);
		RB_SSRSetViewUniforms(sp, info);

		vec4_t settings;
		const float strength = Com_Clamp(0.0f, 1.0f, r_ssrStrength->value);
		if ( sceneDebug )
		{
			GL_State(GLS_DEPTHTEST_DISABLE);
			VectorSet4(settings, strength, splitX, (float)debugView, 0.0f);
			GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS, settings);
			RB_InstantTriangle();
		}
		else if ( r_hdr->integer )
		{
			// float target: one signed additive pass
			GL_State(GLS_DEPTHTEST_DISABLE | GLS_SRCBLEND_ONE | GLS_DSTBLEND_ONE);
			VectorSet4(settings, strength, splitX, 0.0f, 0.0f);
			GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS, settings);
			RB_InstantTriangle();
		}
		else
		{
			// normalized target: blending clamps negative sources, subtract
			// the replaced cubemap part, then add the SSR part
			GL_State(GLS_DEPTHTEST_DISABLE | GLS_SRCBLEND_ONE | GLS_DSTBLEND_ONE);
			qglBlendEquation(GL_FUNC_REVERSE_SUBTRACT);
			VectorSet4(settings, strength, splitX, 0.0f, 1.0f);
			GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS, settings);
			RB_InstantTriangle();

			qglBlendEquation(GL_FUNC_ADD);
			VectorSet4(settings, strength, splitX, 0.0f, 2.0f);
			GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS, settings);
			RB_InstantTriangle();
		}
	}
	RB_SSREndTimer(timer);

	s_debug.frameNumber = backEndData->realFrameNumber;
	s_debug.finalImage = finalImage;
	s_debug.traceScale = traceScale;
	s_debug.maxDistance = maxDistance;
	s_debug.valid = qtrue;

	// once per view: the rest of the pass draws on top of the result
	backEnd.ssrView = qfalse;

	R_PushDebugGroup(AL_STAGE, "Mainpass");

	// back to the main pass of the view
	FBO_Bind(oldFbo);
	GL_SetProjectionMatrix(backEnd.viewParms.projectionMatrix);
	GL_SetViewportAndScissor(viewParms.viewportX, viewParms.viewportY,
		viewParms.viewportWidth, viewParms.viewportHeight);
	GL_SelectTexture(0);
}

/*
============================================================

Debug views

============================================================
*/

// r_ssrDebug 1-6: buffers drawn over the final image at the end of the post
// process chain (7-10 replace the scene color in RB_RenderSSR and go
// through the tone mapping)
void RB_SSRDebugOverlay( void )
{
	const int debugView = r_ssrDebug->integer;
	if ( !s_ssrResources || debugView < 1 || debugView > 6 )
		return;

	if ( !s_debug.valid || s_debug.frameNumber != backEndData->realFrameNumber || !s_debug.finalImage )
		return;

	FBO_Bind(NULL);
	GL_SetViewportAndScissor(0, 0, glConfig.vidWidth, glConfig.vidHeight);
	GL_State(GLS_DEPTHTEST_DISABLE);
	GL_Cull(CT_TWO_SIDED);

	shaderProgram_t *sp = &tr.ssrDebugShader;
	GLSL_BindProgram(sp);
	RB_SSRBindMaterial();
	GL_BindToTMU(tr.ssrTraceImage, TB_SHADOWMAP);
	GL_BindToTMU(s_debug.finalImage, TB_CUBEMAP);

	vec4_t settings;
	VectorSet4(settings, (float)debugView, s_debug.traceScale, s_debug.maxDistance, 0.0f);
	GLSL_SetUniformVec4(sp, UNIFORM_SSRSETTINGS, settings);

	RB_InstantTriangle();
	GL_SelectTexture(0);
}
