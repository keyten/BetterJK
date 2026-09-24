/*
===========================================================================
Copyright (C) 2026 OpenJK contributors

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

/*
LTC area lights (r_ltcAreaLights), Forward+ only. See
docs/rend2-ltc-area-lights.md.

Area lights are ordinary dlight_t entries with areaType != DLIGHT_POINT, so
they ride the Forward+ importance sort and cluster lists unchanged: the
bounding sphere (origin = centre, radius = influence range) is the cull
volume. lightall shades them with LTC (USE_LTC, compiled in only when the
latched cvar is set). They never enter the legacy 32 light path, the legacy
Lights UBO (froxel fog) nor the shadow cube selection.

Sources, merged into the scene light list:
  map file    maps/<map>.arealights.json, loaded with the map, reloaded with
              r_reloadAreaLights; static lamps default to specular only
              (their diffuse light is already in the lightmap)
  scene API   RE_AddAreaLightToScene / RE_AddLineLightToScene (sabers),
              dynamic: diffuse + specular, diffuse feeds SSGI

The LUTs (tr_ltc_data.h) come from tools/ltcfit, never fitted at startup.
*/

#include "tr_local.h"
#include "json.h"
#include "tr_ltc_data.h"

#include <algorithm>
#include <string>
#include <unordered_map>
#include <vector>

// saber blade radiance per unit of saber color (r_ltcIntensityScale applies too)
#define SABER_AREA_RADIANCE		4.0f
#define AREALIGHT_MIN_RANGE		16.0f
#define AREALIGHT_MAX_RANGE		8192.0f

struct mapAreaLight_t
{
	int type;					// DLIGHT_RECT, DLIGHT_LINE
	vec3_t center;
	vec3_t right;
	vec3_t up;
	float halfWidth;
	float halfHeight;
	vec3_t color;				// radiance = color * intensity
	float intensity;
	float range;
	qboolean twoSided;
	int mode;					// AREAMODE_*
	char name[64];
};

enum
{
	AREAMODE_STATIC_SPECULAR,	// default: spec only unless r_ltcStaticDiffuse 1
	AREAMODE_STATIC_FULL,		// static, diffuse + specular (lamps missing from the lightmap)
	AREAMODE_DYNAMIC			// treated like a scene light (diffuse feeds SSGI)
};

static const char *s_modeNames[] = { "static_specular", "static_full", "dynamic" };

static struct
{
	std::vector<mapAreaLight_t> lights;
	char mapName[MAX_QPATH];
	qboolean active;			// latched per frame
	qboolean unitsChecked;
	qboolean unitsOk;
	int ltcModCount;
	int fplusModCount;
	int saberModCount;
	qhandle_t debugShader;
	int selected;				// map light highlighted by r_ltcDebug, -1 none
} s_al = { {}, "", qfalse, qfalse, qfalse, -1, -1, -1, 0, -1 };

qboolean R_AreaLightsActive( void )
{
	return s_al.active;
}

/*
============================================================

Frame state, dependencies

============================================================
*/

void R_AreaLightsBeginFrame( void )
{
	if ( !s_al.unitsChecked )
	{
		GLint units = 0;
		qglGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &units);
		s_al.unitsOk = (qboolean)(units > TB_LTC_AMPLITUDE);
		s_al.unitsChecked = qtrue;
	}

	const qboolean wanted = (qboolean)(r_ltcAreaLights->integer != 0);
	const qboolean fplus = R_ForwardPlusActive();

	// one message per change of the cvars involved, not per frame; only the
	// first missing dependency is reported
	if ( r_ltcAreaLights->modificationCount != s_al.ltcModCount ||
		r_forwardPlus->modificationCount != s_al.fplusModCount ||
		r_saberAreaLights->modificationCount != s_al.saberModCount )
	{
		s_al.ltcModCount = r_ltcAreaLights->modificationCount;
		s_al.fplusModCount = r_forwardPlus->modificationCount;
		s_al.saberModCount = r_saberAreaLights->modificationCount;

		if ( wanted && !s_al.unitsOk )
			ri.Printf(PRINT_WARNING, "LTC area lights need more than %d texture units, disabled\n", TB_LTC_AMPLITUDE + 1);
		else if ( wanted && !fplus )
			ri.Printf(PRINT_ALL, "LTC area lights require r_forwardPlus 1\n");
		else if ( !wanted && r_saberAreaLights->integer )
			ri.Printf(PRINT_ALL, "Saber area lights require r_ltcAreaLights 1\n");
	}

	s_al.active = (qboolean)(wanted && fplus && s_al.unitsOk && tr.ltcMatrixImage && tr.ltcAmplitudeImage);
}

float R_AreaLightsDebugParam( void )
{
	return s_al.active ? (float)Com_Clampi(0, 8, r_ltcDebug->integer) : 0.0f;
}

/*
============================================================

Lookup tables

============================================================
*/

void R_CreateLtcImages( void )
{
	std::vector<uint16_t> data(LTC_LUT_SIZE * LTC_LUT_SIZE * 4);
	const float *tables[2] = { ltcTable1, ltcTable2 };
	const char *names[2] = { "*ltcMatrixLUT", "*ltcAmplitudeLUT" };
	image_t **images[2] = { &tr.ltcMatrixImage, &tr.ltcAmplitudeImage };
	for ( int t = 0; t < 2; t++ )
	{
		for ( size_t i = 0; i < data.size(); i++ )
			data[i] = FloatToHalf(tables[t][i]);
		*images[t] = R_CreateImage(
			names[t], (byte *)data.data(), LTC_LUT_SIZE, LTC_LUT_SIZE,
			IMGTYPE_COLORALPHA, IMGFLAG_NO_COMPRESSION | IMGFLAG_CLAMPTOEDGE, GL_RGBA16F);
	}
}

void RB_AreaLightsBindTextures( SamplerBindingsWriter& samplers )
{
	samplers.AddStaticImage(tr.ltcMatrixImage, TB_LTC_MATRIX);
	samplers.AddStaticImage(tr.ltcAmplitudeImage, TB_LTC_AMPLITUDE);
}

/*
============================================================

Map file

============================================================
*/

static qboolean R_JsonVec3( const char *obj, const char *end, const char *name, vec3_t out )
{
	const char *value = JSON_ObjectGetNamedValue(obj, end, name);
	if ( !value || JSON_ValueGetType(value, end) != JSONTYPE_ARRAY )
		return qfalse;
	const char *indexes[3];
	if ( JSON_ArrayGetIndex(value, end, indexes, 3) < 3 )
		return qfalse;
	for ( int i = 0; i < 3; i++ )
		out[i] = JSON_ValueGetFloat(indexes[i], end);
	return qtrue;
}

static float R_JsonFloat( const char *obj, const char *end, const char *name, float def )
{
	const char *value = JSON_ObjectGetNamedValue(obj, end, name);
	if ( !value || JSON_ValueGetType(value, end) != JSONTYPE_VALUE )
		return def;
	return JSON_ValueGetFloat(value, end);
}

static qboolean R_JsonBool( const char *obj, const char *end, const char *name, qboolean def )
{
	const char *value = JSON_ObjectGetNamedValue(obj, end, name);
	if ( !value || JSON_ValueGetType(value, end) != JSONTYPE_VALUE )
		return def;
	if ( *value == 't' )
		return qtrue;
	if ( *value == 'f' )
		return qfalse;
	return (qboolean)(JSON_ValueGetFloat(value, end) != 0.0f);
}

// default influence range: where the irradiance of the emitter seen face on
// drops to ~1% of its radiance (E ~ L * A / d^2), at least a bit beyond the
// emitter itself
static float R_AreaLightDefaultRange( const mapAreaLight_t *l )
{
	const float area = 4.0f * l->halfWidth * Q_max(l->halfHeight, 1.0f);
	const float radiance = Q_max(l->intensity * MAX(l->color[0], MAX(l->color[1], l->color[2])), 0.05f);
	const float range = sqrtf(area * radiance / 0.01f);
	return Com_Clamp(2.0f * Q_max(l->halfWidth, l->halfHeight) + AREALIGHT_MIN_RANGE, AREALIGHT_MAX_RANGE, range);
}

// right unit, up unit and perpendicular to right; false when degenerate
static qboolean R_AreaLightAxes( vec3_t right, vec3_t up )
{
	if ( VectorNormalize(right) < 1e-4f )
		return qfalse;
	VectorMA(up, -DotProduct(up, right), right, up);
	return (qboolean)(VectorNormalize(up) >= 1e-4f);
}

static qboolean R_ParseAreaLight( const char *obj, const char *end, int index, const char *fileName, mapAreaLight_t *l )
{
	Com_Memset(l, 0, sizeof(*l));
	char type[32] = "rect";
	const char *value = JSON_ObjectGetNamedValue(obj, end, "type");
	if ( value )
		JSON_ValueGetString(value, end, type, sizeof(type));
	value = JSON_ObjectGetNamedValue(obj, end, "name");
	if ( value )
		JSON_ValueGetString(value, end, l->name, sizeof(l->name));

	if ( !Q_stricmp(type, "rect") )
	{
		l->type = DLIGHT_RECT;
		if ( !R_JsonVec3(obj, end, "center", l->center) ||
			!R_JsonVec3(obj, end, "right", l->right) ||
			!R_JsonVec3(obj, end, "up", l->up) )
		{
			ri.Printf(PRINT_WARNING, "%s: light %d: rect needs center, right and up\n", fileName, index);
			return qfalse;
		}
		if ( !R_AreaLightAxes(l->right, l->up) )
		{
			ri.Printf(PRINT_WARNING, "%s: light %d: degenerate right / up axes\n", fileName, index);
			return qfalse;
		}
		l->halfWidth = R_JsonFloat(obj, end, "halfWidth", 0.0f);
		l->halfHeight = R_JsonFloat(obj, end, "halfHeight", 0.0f);
		l->twoSided = R_JsonBool(obj, end, "twoSided", qfalse);
	}
	else if ( !Q_stricmp(type, "line") )
	{
		vec3_t start, stop;
		l->type = DLIGHT_LINE;
		if ( !R_JsonVec3(obj, end, "start", start) || !R_JsonVec3(obj, end, "end", stop) )
		{
			ri.Printf(PRINT_WARNING, "%s: light %d: line needs start and end\n", fileName, index);
			return qfalse;
		}
		VectorAdd(start, stop, l->center);
		VectorScale(l->center, 0.5f, l->center);
		VectorSubtract(stop, start, l->right);
		l->halfWidth = 0.5f * VectorNormalize(l->right);
		l->halfHeight = R_JsonFloat(obj, end, "radius", 1.0f);
		PerpendicularVector(l->up, l->right);
		l->twoSided = qtrue;
	}
	else
	{
		ri.Printf(PRINT_WARNING, "%s: light %d: unknown type \"%s\" (rect, line)\n", fileName, index, type);
		return qfalse;
	}

	if ( l->halfWidth <= 0.0f || l->halfHeight <= 0.0f )
	{
		ri.Printf(PRINT_WARNING, "%s: light %d: half sizes must be > 0\n", fileName, index);
		return qfalse;
	}

	if ( !R_JsonVec3(obj, end, "color", l->color) )
		VectorSet(l->color, 1.0f, 1.0f, 1.0f);
	l->intensity = R_JsonFloat(obj, end, "intensity", 1.0f);

	l->mode = AREAMODE_STATIC_SPECULAR;
	char mode[32] = "";
	value = JSON_ObjectGetNamedValue(obj, end, "mode");
	if ( value && JSON_ValueGetString(value, end, mode, sizeof(mode)) )
	{
		int m;
		for ( m = 0; m < (int)ARRAY_LEN(s_modeNames); m++ )
			if ( !Q_stricmp(mode, s_modeNames[m]) )
				break;
		if ( m == (int)ARRAY_LEN(s_modeNames) )
			ri.Printf(PRINT_WARNING, "%s: light %d: unknown mode \"%s\", static_specular used\n", fileName, index, mode);
		else
			l->mode = m;
	}

	l->range = R_JsonFloat(obj, end, "range", 0.0f);
	if ( l->range <= 0.0f )
		l->range = R_AreaLightDefaultRange(l);
	l->range = Com_Clamp(AREALIGHT_MIN_RANGE, AREALIGHT_MAX_RANGE, l->range);
	return qtrue;
}

static void R_LoadAreaLightFile( void )
{
	s_al.lights.clear();
	s_al.selected = -1;
	if ( !s_al.mapName[0] )
		return;

	char fileName[MAX_QPATH];
	Com_sprintf(fileName, sizeof(fileName), "maps/%s.arealights.json", s_al.mapName);

	union { char *c; void *v; } buffer;
	const int length = ri.FS_ReadFile(fileName, &buffer.v);
	if ( !buffer.c || length <= 0 )
		return;
	const char *end = buffer.c + length;

	const char *lights = nullptr;
	if ( JSON_ValueGetType(buffer.c, end) == JSONTYPE_OBJECT )
		lights = JSON_ObjectGetNamedValue(buffer.c, end, "lights");
	if ( !lights || JSON_ValueGetType(lights, end) != JSONTYPE_ARRAY )
	{
		ri.Printf(PRINT_WARNING, "%s: expected { \"lights\": [ ... ] }\n", fileName);
		ri.FS_FreeFile(buffer.v);
		return;
	}

	int index = 0;
	for ( const char *obj = JSON_ArrayGetFirstValue(lights, end); obj; obj = JSON_ArrayGetNextValue(obj, end), index++ )
	{
		if ( JSON_ValueGetType(obj, end) != JSONTYPE_OBJECT )
			continue;
		mapAreaLight_t l;
		if ( R_ParseAreaLight(obj, end, index, fileName, &l) )
			s_al.lights.push_back(l);
	}
	ri.FS_FreeFile(buffer.v);
	ri.Printf(PRINT_ALL, "%s: %d area lights\n", fileName, (int)s_al.lights.size());
}

void R_LoadAreaLights( const char *mapName )
{
	Q_strncpyz(s_al.mapName, mapName ? mapName : "", sizeof(s_al.mapName));
	R_LoadAreaLightFile();
}

void R_ClearAreaLights( void )
{
	s_al.lights.clear();
	s_al.mapName[0] = '\0';
	s_al.selected = -1;
	s_al.debugShader = 0;
	s_al.unitsChecked = qfalse;
}

void R_ReloadAreaLights_f( void )
{
	if ( !tr.world )
	{
		ri.Printf(PRINT_ALL, "r_reloadAreaLights: no map loaded\n");
		return;
	}
	R_LoadAreaLightFile();
	if ( s_al.lights.empty() )
		ri.Printf(PRINT_ALL, "maps/%s.arealights.json: none loaded\n", s_al.mapName);
}

/*
============================================================

Scene

============================================================
*/



static dlight_t *R_AddAreaDlight( int type, const vec3_t center, const vec3_t right, const vec3_t up,
	float halfWidth, float halfHeight, float range, const vec3_t radiance, int flags, int id )
{
	dlight_t *dl = R_AllocSceneDlight();
	if ( !dl )
		return nullptr;
	VectorCopy(center, dl->origin);
	VectorCopy(radiance, dl->color);
	// the cull sphere must hold every point the window reaches
	dl->radius = range + sqrtf(halfWidth * halfWidth + halfHeight * halfHeight);
	dl->areaType = type;
	dl->areaFlags = flags;
	dl->areaId = id;
	VectorCopy(right, dl->areaRight);
	VectorCopy(up, dl->areaUp);
	dl->halfWidth = halfWidth;
	dl->halfHeight = halfHeight;
	return dl;
}

static int R_MapLightFlags( const mapAreaLight_t *l )
{
	int flags = l->twoSided ? AREALIGHT_TWO_SIDED : 0;
	if ( l->mode == AREAMODE_DYNAMIC )
		flags |= AREALIGHT_DYNAMIC;
	else if ( l->mode == AREAMODE_STATIC_SPECULAR && !r_ltcStaticDiffuse->integer )
		flags |= AREALIGHT_SPECULAR_ONLY;
	return flags;
}

static int R_NearestMapLight( const vec3_t point )
{
	int best = -1;
	float bestDist = 1e30f;
	for ( int i = 0; i < (int)s_al.lights.size(); i++ )
	{
		const float d = Distance(point, s_al.lights[i].center);
		if ( d < bestDist )
		{
			bestDist = d;
			best = i;
		}
	}
	return best;
}

static void R_AreaLightsDebugPolys( const refdef_t *fd );

// map lights of a world scene, nearest r_ltcMaxLights first (their spheres
// decide which surfaces they reach; mirrors and portals see the rest of the
// map, so no view frustum cut here: Forward+ culls per view)
void R_AddAreaLightsToScene( const refdef_t *fd )
{
	if ( !s_al.active || (fd->rdflags & RDF_NOWORLDMODEL) || !tr.world )
		return;

	s_al.selected = -1;
	if ( r_ltcDebug->integer && !s_al.lights.empty() )
	{
		const int want = r_ltcDebugLight->integer;
		s_al.selected = want < 0 ? R_NearestMapLight(fd->vieworg) :
			(want < (int)s_al.lights.size() ? want : -1);
	}

	const int maxLights = Com_Clampi(0, MAX_RENDER_DLIGHTS, r_ltcMaxLights->integer);
	const int numLights = (int)s_al.lights.size();
	std::vector<std::pair<float, int>> order;
	order.reserve(numLights);
	for ( int i = 0; i < numLights; i++ )
	{
		const mapAreaLight_t *l = &s_al.lights[i];
		const float extent = l->range + sqrtf(l->halfWidth * l->halfWidth + l->halfHeight * l->halfHeight);
		order.push_back(std::make_pair(Distance(fd->vieworg, l->center) - extent, i));
	}
	const int count = Q_min(maxLights, numLights);
	std::partial_sort(order.begin(), order.begin() + count, order.end());

	const float scale = Q_max(r_ltcIntensityScale->value, 0.0f);
	for ( int k = 0; k < count; k++ )
	{
		const int i = order[k].second;
		const mapAreaLight_t *l = &s_al.lights[i];
		vec3_t radiance;
		VectorScale(l->color, l->intensity * scale, radiance);
		int flags = R_MapLightFlags(l);
		if ( i == s_al.selected )
			flags |= AREALIGHT_SELECTED;
		if ( !R_AddAreaDlight(l->type, l->center, l->right, l->up, l->halfWidth, l->halfHeight,
				l->range, radiance, flags, i) )
		{
			break;
		}
	}

	R_AreaLightsDebugPolys(fd);
}

void RE_AddAreaLightToScene( const vec3_t center, const vec3_t right, const vec3_t up,
	float halfWidth, float halfHeight, float range, float r, float g, float b, int twoSided )
{
	if ( !tr.registered || !s_al.active || halfWidth <= 0.0f || halfHeight <= 0.0f )
		return;
	vec3_t axisRight, axisUp;
	VectorCopy(right, axisRight);
	VectorCopy(up, axisUp);
	if ( !R_AreaLightAxes(axisRight, axisUp) )
		return;
	vec3_t radiance;
	VectorSet(radiance, r, g, b);
	VectorScale(radiance, Q_max(r_ltcIntensityScale->value, 0.0f), radiance);
	range = Com_Clamp(AREALIGHT_MIN_RANGE, AREALIGHT_MAX_RANGE, range);
	R_AddAreaDlight(DLIGHT_RECT, center, axisRight, axisUp, halfWidth, halfHeight, range, radiance,
		AREALIGHT_DYNAMIC | (twoSided ? AREALIGHT_TWO_SIDED : 0), -1);
}

/*
A line emitter (saber blade). Returns qfalse when the renderer does not take
it (area lights inactive, r_saberAreaLights 0, no room): the caller then adds
its old point light, so the two never light the same frame twice.
*/
qboolean RE_AddLineLightToScene( const vec3_t start, const vec3_t end, float radius,
	float range, float r, float g, float b )
{
	if ( !tr.registered || !s_al.active || !r_saberAreaLights->integer )
		return qfalse;

	vec3_t center, axis, up;
	VectorAdd(start, end, center);
	VectorScale(center, 0.5f, center);
	VectorSubtract(end, start, axis);
	const float halfLength = 0.5f * VectorNormalize(axis);
	if ( halfLength < 0.25f )
		return qfalse;
	PerpendicularVector(up, axis);

	vec3_t radiance;
	VectorSet(radiance, r, g, b);
	VectorScale(radiance, SABER_AREA_RADIANCE * Q_max(r_ltcIntensityScale->value, 0.0f), radiance);
	range = Com_Clamp(AREALIGHT_MIN_RANGE, AREALIGHT_MAX_RANGE, range);
	return (qboolean)(R_AddAreaDlight(DLIGHT_LINE, center, axis, up, halfLength,
		Com_Clamp(0.25f, 16.0f, radius), range, radiance,
		AREALIGHT_DYNAMIC | AREALIGHT_TWO_SIDED, -1) != nullptr);
}

/*
============================================================

Debug: r_ltcDebug 6 outlines, 7 normals (polygons, seen through walls);
the other views are in lightall (LtcDebugColor)

============================================================
*/

qhandle_t RE_RegisterShaderFromImage( const char *name, const int *lightmapIndexes, const byte *styles, image_t *image, qboolean mipRawImage );

static void R_DebugSegment( const refdef_t *fd, const vec3_t a, const vec3_t b, const byte *rgba, float width )
{
	vec3_t dir, toEye, side;
	VectorSubtract(b, a, dir);
	VectorSubtract(a, fd->vieworg, toEye);
	CrossProduct(dir, toEye, side);
	if ( VectorNormalize(side) < 1e-6f )
		return;
	const float w = width * (0.35f + 0.0015f * VectorLength(toEye));
	VectorScale(side, w, side);

	polyVert_t verts[4];
	VectorSubtract(a, side, verts[0].xyz);
	VectorAdd(a, side, verts[1].xyz);
	VectorAdd(b, side, verts[2].xyz);
	VectorSubtract(b, side, verts[3].xyz);
	for ( int i = 0; i < 4; i++ )
	{
		verts[i].st[0] = verts[i].st[1] = 0.5f;
		Com_Memcpy(verts[i].modulate, rgba, 4);
	}
	RE_AddPolyToScene(s_al.debugShader, 4, verts, 1);
}

static void R_AreaLightsDebugPolys( const refdef_t *fd )
{
	const int mode = r_ltcDebug->integer;
	if ( mode != 6 && mode != 7 )
		return;
	if ( !s_al.debugShader )
		s_al.debugShader = RE_RegisterShaderFromImage("*ltcDebugLines", lightmaps2d, stylesDefault, tr.whiteImage, qfalse);

	// every area light of the scene so far (map lights and dynamic ones)
	extern int r_numdlights;
	extern int r_firstSceneDlight;
	for ( int i = r_firstSceneDlight; i < r_numdlights; i++ )
	{
		const dlight_t *dl = &backEndData->dlights[i];
		if ( dl->areaType == DLIGHT_POINT )
			continue;
		const qboolean selected = (qboolean)((dl->areaFlags & AREALIGHT_SELECTED) != 0);
		byte rgba[4] = { 255, 220, 40, 220 };	// map lights yellow
		if ( dl->areaFlags & AREALIGHT_DYNAMIC )
		{
			rgba[1] = 120;	// dynamic orange
			rgba[2] = 20;
		}
		if ( selected )
			rgba[1] = rgba[2] = 255;
		const float width = selected ? 2.0f : 1.0f;

		vec3_t R, U, corners[4];
		VectorScale(dl->areaRight, dl->halfWidth, R);
		VectorScale(dl->areaUp, dl->halfHeight, U);
		if ( dl->areaType == DLIGHT_LINE )
			VectorClear(U);
		for ( int c = 0; c < 4; c++ )
		{
			VectorMA(dl->origin, (c == 0 || c == 1) ? -1.0f : 1.0f, R, corners[c]);
			VectorMA(corners[c], (c == 0 || c == 3) ? -1.0f : 1.0f, U, corners[c]);
		}

		if ( mode == 6 )
		{
			for ( int c = 0; c < 4; c++ )
				R_DebugSegment(fd, corners[c], corners[(c + 1) & 3], rgba, width);
			// influence bounds of the selected light: three great circles
			if ( selected )
			{
				const byte ring[4] = { 255, 255, 255, 90 };
				const int segments = 32;
				for ( int axis = 0; axis < 3; axis++ )
					for ( int s = 0; s < segments; s++ )
					{
						vec3_t p[2];
						for ( int e = 0; e < 2; e++ )
						{
							const float a = 2.0f * M_PI * (s + e) / segments;
							vec3_t o = { 0.0f, 0.0f, 0.0f };
							o[(axis + 1) % 3] = cosf(a) * dl->radius;
							o[(axis + 2) % 3] = sinf(a) * dl->radius;
							VectorAdd(dl->origin, o, p[e]);
						}
						R_DebugSegment(fd, p[0], p[1], ring, 1.0f);
					}
			}
		}
		else
		{
			// emitting normal (both ways when two sided), right (red), up (green)
			vec3_t normal, tip;
			CrossProduct(dl->areaRight, dl->areaUp, normal);
			const float len = Com_Clamp(8.0f, 64.0f, 0.25f * dl->radius);
			VectorMA(dl->origin, len, normal, tip);
			if ( dl->areaType != DLIGHT_LINE )
				R_DebugSegment(fd, dl->origin, tip, rgba, width);
			if ( (dl->areaFlags & AREALIGHT_TWO_SIDED) && dl->areaType != DLIGHT_LINE )
			{
				VectorMA(dl->origin, -len, normal, tip);
				R_DebugSegment(fd, dl->origin, tip, rgba, width * 0.5f);
			}
			const byte red[4] = { 255, 40, 40, 220 }, green[4] = { 40, 255, 40, 220 };
			VectorMA(dl->origin, dl->halfWidth, dl->areaRight, tip);
			R_DebugSegment(fd, dl->origin, tip, red, 0.75f);
			if ( dl->areaType != DLIGHT_LINE )
			{
				VectorMA(dl->origin, dl->halfHeight, dl->areaUp, tip);
				R_DebugSegment(fd, dl->origin, tip, green, 0.75f);
			}
		}
	}
}

/*
============================================================

Console

============================================================
*/

static void R_PrintMapLight( int i )
{
	const mapAreaLight_t *l = &s_al.lights[i];
	ri.Printf(PRINT_ALL,
		"%3d %-5s %-15s centre (%.1f %.1f %.1f) half %.1f x %.1f range %.0f color (%.2f %.2f %.2f) x %.2f%s %s\n",
		i, l->type == DLIGHT_LINE ? "line" : "rect", s_modeNames[l->mode],
		l->center[0], l->center[1], l->center[2], l->halfWidth, l->halfHeight, l->range,
		l->color[0], l->color[1], l->color[2], l->intensity, l->twoSided ? " two sided" : "", l->name);
}

void R_AreaLightsList_f( void )
{
	ri.Printf(PRINT_ALL, "maps/%s.arealights.json: %d lights, r_ltcAreaLights %s\n",
		s_al.mapName, (int)s_al.lights.size(), s_al.active ? "active" : "inactive");
	for ( int i = 0; i < (int)s_al.lights.size(); i++ )
		R_PrintMapLight(i);
}

void R_AreaLightsNearest_f( void )
{
	const int i = R_NearestMapLight(tr.refdef.vieworg);
	if ( i < 0 )
	{
		ri.Printf(PRINT_ALL, "no area lights on this map\n");
		return;
	}
	ri.Printf(PRINT_ALL, "nearest area light (%.0f units, r_ltcDebugLight %d shows it):\n",
		Distance(tr.refdef.vieworg, s_al.lights[i].center), i);
	R_PrintMapLight(i);
}

/*
============================================================

r_extractAreaLights: candidate lights from the emissive surfaces of the
loaded map (surfacelight / q3map_surfacelight hints, glow stages), written to
maps/<map>.arealights.generated.json for review. Never loaded by itself and
never changes the map; rename it to <map>.arealights.json to use it.

Coplanar, connected triangles of the same shader form one candidate; the
rectangle is the bounding box in the plane along the principal axis. The
confidence is the covered fraction of that rectangle.

============================================================
*/

struct extractTri_t
{
	const shader_t *shader;
	vec3_t v[3];
	vec3_t normal;
	float area;
};

static int R_FindRoot( std::vector<int>& parent, int i )
{
	while ( parent[i] != i )
	{
		parent[i] = parent[parent[i]];
		i = parent[i];
	}
	return i;
}

static qboolean R_ShaderEmits( const shader_t *sh, qboolean *hinted )
{
	*hinted = (qboolean)(sh->surfaceLight > 0.0f);
	if ( sh->isSky || (sh->surfaceFlags & (SURF_SKY | SURF_NODRAW)) )
		return qfalse;
	if ( *hinted )
		return qtrue;
	for ( int s = 0; s < MAX_SHADER_STAGES; s++ )
		if ( sh->stages[s] && sh->stages[s]->active && sh->stages[s]->glow )
			return qtrue;
	return qfalse;
}

void R_ExtractAreaLights_f( void )
{
	if ( !tr.world )
	{
		ri.Printf(PRINT_ALL, "r_extractAreaLights: no map loaded\n");
		return;
	}

	std::vector<extractTri_t> tris;
	for ( int s = 0; s < tr.world->numsurfaces; s++ )
	{
		const msurface_t *surf = &tr.world->surfaces[s];
		qboolean hinted;
		if ( !surf->shader || !surf->data || !R_ShaderEmits(surf->shader, &hinted) )
			continue;
		if ( *surf->data != SF_FACE && *surf->data != SF_TRIANGLES )
			continue;
		const srfBspSurface_t *bsp = (const srfBspSurface_t *)surf->data;
		if ( !bsp->verts || !bsp->indexes )
			continue;
		for ( int i = 0; i + 2 < bsp->numIndexes; i += 3 )
		{
			extractTri_t t;
			t.shader = surf->shader;
			for ( int k = 0; k < 3; k++ )
				VectorCopy(bsp->verts[bsp->indexes[i + k]].xyz, t.v[k]);
			vec3_t e1, e2;
			VectorSubtract(t.v[1], t.v[0], e1);
			VectorSubtract(t.v[2], t.v[0], e2);
			CrossProduct(e1, e2, t.normal);
			t.area = 0.5f * VectorNormalize(t.normal);
			if ( t.area > 0.01f )
				tris.push_back(t);
		}
	}

	// union triangles of one shader and plane sharing a vertex
	const int n = (int)tris.size();
	std::vector<int> parent(n);
	for ( int i = 0; i < n; i++ )
		parent[i] = i;
	std::unordered_map<std::string, int> firstAt;
	char key[256];
	for ( int i = 0; i < n; i++ )
	{
		const extractTri_t *t = &tris[i];
		const float dist = DotProduct(t->normal, t->v[0]);
		for ( int k = 0; k < 3; k++ )
		{
			Com_sprintf(key, sizeof(key), "%p %d %d %d %d %d %d %d", (const void *)t->shader,
				(int)floorf(t->normal[0] * 50.0f + 0.5f), (int)floorf(t->normal[1] * 50.0f + 0.5f),
				(int)floorf(t->normal[2] * 50.0f + 0.5f), (int)floorf(dist + 0.5f),
				(int)floorf(t->v[k][0] * 2.0f + 0.5f), (int)floorf(t->v[k][1] * 2.0f + 0.5f),
				(int)floorf(t->v[k][2] * 2.0f + 0.5f));
			auto it = firstAt.find(key);
			if ( it == firstAt.end() )
				firstAt[key] = i;
			else
				parent[R_FindRoot(parent, i)] = R_FindRoot(parent, it->second);
		}
	}

	std::unordered_map<int, std::vector<int>> groups;
	for ( int i = 0; i < n; i++ )
		groups[R_FindRoot(parent, i)].push_back(i);

	std::string out = "{\n\t\"generator\": \"r_extractAreaLights\",\n\t\"lights\": [\n";
	int numOut = 0, numReview = 0;
	for ( auto& group : groups )
	{
		const std::vector<int>& members = group.second;
		const shader_t *sh = tris[members[0]].shader;

		// plane: area weighted normal and centroid
		vec3_t normal = { 0, 0, 0 }, centroid = { 0, 0, 0 };
		float area = 0.0f;
		for ( int m : members )
		{
			const extractTri_t *t = &tris[m];
			VectorMA(normal, t->area, t->normal, normal);
			for ( int k = 0; k < 3; k++ )
				VectorMA(centroid, t->area / 3.0f, t->v[k], centroid);
			area += t->area;
		}
		if ( area < 16.0f || VectorNormalize(normal) < 1e-4f )
			continue;
		VectorScale(centroid, 1.0f / area, centroid);

		// principal axis in the plane (2x2 covariance of the vertices)
		vec3_t a1, a2;
		PerpendicularVector(a1, normal);
		CrossProduct(normal, a1, a2);
		float cxx = 0, cxy = 0, cyy = 0;
		for ( int m : members )
			for ( int k = 0; k < 3; k++ )
			{
				vec3_t d;
				VectorSubtract(tris[m].v[k], centroid, d);
				const float x = DotProduct(d, a1), y = DotProduct(d, a2);
				cxx += x * x; cxy += x * y; cyy += y * y;
			}
		const float angle = 0.5f * atan2f(2.0f * cxy, cxx - cyy);
		vec3_t right, up;
		VectorScale(a1, cosf(angle), right);
		VectorMA(right, sinf(angle), a2, right);
		CrossProduct(normal, right, up);		// cross(right, up) = normal: emits along the face normal

		float minR = 1e30f, maxR = -1e30f, minU = 1e30f, maxU = -1e30f;
		for ( int m : members )
			for ( int k = 0; k < 3; k++ )
			{
				vec3_t d;
				VectorSubtract(tris[m].v[k], centroid, d);
				minR = Q_min(minR, DotProduct(d, right)); maxR = Q_max(maxR, DotProduct(d, right));
				minU = Q_min(minU, DotProduct(d, up)); maxU = Q_max(maxU, DotProduct(d, up));
			}
		const float halfWidth = 0.5f * (maxR - minR), halfHeight = 0.5f * (maxU - minU);
		if ( halfWidth < 1.0f || halfHeight < 1.0f )
			continue;
		vec3_t center;
		VectorMA(centroid, 0.5f * (maxR + minR), right, center);
		VectorMA(center, 0.5f * (maxU + minU), up, center);
		VectorMA(center, 0.25f, normal, center);	// off the lamp surface itself

		const float confidence = Com_Clamp(0.0f, 1.0f, area / (4.0f * halfWidth * halfHeight));
		qboolean hinted;
		R_ShaderEmits(sh, &hinted);
		const qboolean review = (qboolean)(confidence < 0.8f || !hinted);

		vec3_t color = { 1.0f, 1.0f, 1.0f };
		if ( sh->surfaceLightColor[0] + sh->surfaceLightColor[1] + sh->surfaceLightColor[2] > 0.0f )
			VectorCopy(sh->surfaceLightColor, color);
		// q3map surfacelight is a light compiler value, not a radiance:
		// a starting point for hand tuning
		const float intensity = hinted ? Com_Clamp(0.1f, 20.0f, sh->surfaceLight / 300.0f) : 1.0f;

		char entry[1024];
		Com_sprintf(entry, sizeof(entry),
			"%s\t\t{\n"
			"\t\t\t\"type\": \"rect\",\n"
			"\t\t\t\"name\": \"%s\",\n"
			"\t\t\t\"center\": [%.2f, %.2f, %.2f],\n"
			"\t\t\t\"right\": [%.4f, %.4f, %.4f],\n"
			"\t\t\t\"up\": [%.4f, %.4f, %.4f],\n"
			"\t\t\t\"halfWidth\": %.2f,\n"
			"\t\t\t\"halfHeight\": %.2f,\n"
			"\t\t\t\"color\": [%.3f, %.3f, %.3f],\n"
			"\t\t\t\"intensity\": %.3f,\n"
			"\t\t\t\"mode\": \"static_specular\",\n"
			"\t\t\t\"twoSided\": false,\n"
			"\t\t\t\"surfacelight\": %.1f,\n"
			"\t\t\t\"confidence\": %.2f,\n"
			"\t\t\t\"review\": %s\n"
			"\t\t}",
			numOut ? ",\n" : "", sh->name,
			center[0], center[1], center[2], right[0], right[1], right[2], up[0], up[1], up[2],
			halfWidth, halfHeight, color[0], color[1], color[2], intensity, sh->surfaceLight,
			confidence, review ? "true" : "false");
		out += entry;
		numOut++;
		if ( review )
			numReview++;
	}
	out += "\n\t]\n}\n";

	char fileName[MAX_QPATH];
	Com_sprintf(fileName, sizeof(fileName), "maps/%s.arealights.generated.json", tr.world->baseName);
	ri.FS_WriteFile(fileName, out.c_str(), (int)out.size());
	ri.Printf(PRINT_ALL, "%s: %d candidates (%d marked for review) from %d emissive triangles\n",
		fileName, numOut, numReview, n);
}
