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

// Auto PBR (r_autoPBR): PBR parameters for legacy, diffuse-only materials.
//
// No new material system: CollapseStagesToLightall (tr_shader.cpp) still
// binds whiteImage as ORMS map when a lit lightall stage has no authored
// specular / packed map, and lightall.glsl decodes
//
//   ORMS *= u_SpecularScale.zwxy   ->   specularScale = (metal, spec, AO, rough)
//   F0 = mix(0.08 * spec, albedo, metal), roughness = mix(0.01, 1.0, rough)
//
// so a constant material is fully described by specularScale. The stage is
// classified once at registration (R_ClassifyMaterial, from its shader and
// diffuse names) and RB_IterateStagesGeneric swaps in the specularScale of
// the selected entry at draw time, so r_autoPBR switches at runtime without
// vid_restart or extra shader permutations. Stages with authored data
// (explicit map keywords, <diffuse>_specGloss / _rmo / _orm, or specularScale
// / roughness / gloss keywords) are never touched.
//
// The Python port of the classifier (tools/rend2_pbr_inventory.py) runs the
// same rules over the PK3s; keep the dictionaries and rule order in sync.

#include "tr_local.h"

/*
==============================================================================

MATERIAL DEFAULTS

==============================================================================
*/

typedef struct
{
	const char	*name;
	float		ao;
	float		roughness;		// perceptual, lightall uses mix(0.01, 1.0, roughness)
	float		metalness;
	float		specular;		// dielectric F0 = 0.08 * specular
	vec3_t		debugColor;		// r_autoPBRDebug 1
} materialDefaults_t;

// r_autoPBR 0: the current rend2 fallback, AO 1, rough 1, metal 0, F0 0.04
static const materialDefaults_t legacyDefaults =
	{ "legacy",  1.0f, 1.00f, 0.0f, 0.50f, { 0.30f, 0.30f, 0.30f } };

// r_autoPBR 1 uses MATCLASS_GENERIC for every legacy stage, r_autoPBR 2 the
// class of the stage. Conservative on purpose: rough enough that old diffuse
// textures with baked highlights do not look wet.
static const materialDefaults_t materialDefaults[MATCLASS_COUNT] = {
	//  name        AO     rough  metal  spec   debug color
	{ "generic",    1.0f,  0.85f, 0.0f,  0.50f, { 0.55f, 0.55f, 0.55f } },	// F0 0.04
	{ "metal",      1.0f,  0.55f, 0.9f,  0.50f, { 1.00f, 0.85f, 0.10f } },	// albedo is the reflectance
	{ "skin",       1.0f,  0.65f, 0.0f,  0.35f, { 1.00f, 0.50f, 0.40f } },	// F0 0.028
	{ "cloth",      1.0f,  0.95f, 0.0f,  0.50f, { 0.20f, 0.40f, 1.00f } },
	{ "leather",    1.0f,  0.72f, 0.0f,  0.50f, { 0.55f, 0.28f, 0.08f } },
	{ "plastic",    1.0f,  0.60f, 0.0f,  0.50f, { 0.15f, 0.90f, 0.30f } },	// plastic and rubber
	{ "hair",       1.0f,  0.80f, 0.0f,  0.50f, { 0.80f, 0.15f, 0.90f } },	// hair and fur
};

// r_autoPBRDebug colors of stages r_autoPBR does not change
static const vec3_t debugColorAuthored = { 1.0f, 1.0f, 1.0f };
static const vec3_t debugColorScalar   = { 0.55f, 0.95f, 1.0f };
// r_autoPBRDebug 2
static const vec3_t debugColorExplicit   = { 0.10f, 0.90f, 0.20f };
static const vec3_t debugColorDiscovered = { 0.10f, 0.80f, 0.90f };
static const vec3_t debugColorAuto       = { 1.00f, 0.55f, 0.05f };
static const vec3_t debugColorLegacy     = { 0.45f, 0.45f, 0.45f };

const char *R_MaterialClassName( materialClass_t cls )
{
	if ( cls < 0 || cls >= MATCLASS_COUNT )
		return "?";
	return materialDefaults[cls].name;
}

static const materialDefaults_t *R_AutoPBRDefaults( const shaderStage_t *stage )
{
	switch ( r_autoPBR->integer )
	{
		case 1:
			return &materialDefaults[MATCLASS_GENERIC];
		case 2:
			return &materialDefaults[stage->materialClass];
		default:
			return &legacyDefaults;
	}
}

qboolean R_AutoPBRSpecularScale( const shaderStage_t *stage, vec4_t out )
{
	if ( stage->pbrSource != PBR_SOURCE_LEGACY || !r_autoPBR->integer )
		return qfalse;

	const materialDefaults_t *m = R_AutoPBRDefaults( stage );
	out[0] = m->metalness;
	out[1] = m->specular;
	out[2] = m->ao;
	out[3] = m->roughness;
	return qtrue;
}

qboolean R_AutoPBRDebugColor( const shaderStage_t *stage, vec4_t out )
{
	const vec_t *color;

	if ( !r_autoPBRDebug->integer || stage->pbrSource == PBR_SOURCE_NONE )
		return qfalse;

	if ( r_autoPBRDebug->integer == 2 )
	{
		switch ( stage->pbrSource )
		{
			case PBR_SOURCE_EXPLICIT:
				color = debugColorExplicit;
				break;
			case PBR_SOURCE_DISCOVERED:
				color = debugColorDiscovered;
				break;
			case PBR_SOURCE_SCALAR:
				color = debugColorScalar;
				break;
			default:
				color = r_autoPBR->integer ? debugColorAuto : debugColorLegacy;
				break;
		}
	}
	else
	{
		switch ( stage->pbrSource )
		{
			case PBR_SOURCE_EXPLICIT:
			case PBR_SOURCE_DISCOVERED:
				color = debugColorAuthored;
				break;
			case PBR_SOURCE_SCALAR:
				color = debugColorScalar;
				break;
			default:
				// the heuristic class, also while r_autoPBR is 0 or 1
				color = materialDefaults[stage->materialClass].debugColor;
				break;
		}
	}

	VectorCopy( color, out );
	out[3] = 1.0f;
	return qtrue;
}

/*
==============================================================================

CLASSIFICATION

==============================================================================
*/

typedef struct
{
	const char		*token;
	materialClass_t	cls;
} materialToken_t;

// material words, valid in any path (rule 1: file name, rule 5: directories).
// Whole tokens only: "metalgrate" does not match, "metal_grate" does.
static const materialToken_t materialTokens[] = {
	{ "hair", MATCLASS_HAIR }, { "hairs", MATCLASS_HAIR }, { "beard", MATCLASS_HAIR },
	{ "ponytail", MATCLASS_HAIR }, { "braid", MATCLASS_HAIR }, { "braids", MATCLASS_HAIR },
	{ "mustache", MATCLASS_HAIR }, { "fur", MATCLASS_HAIR },

	{ "leather", MATCLASS_LEATHER }, { "belt", MATCLASS_LEATHER }, { "belts", MATCLASS_LEATHER },
	{ "holster", MATCLASS_LEATHER }, { "boot", MATCLASS_LEATHER }, { "boots", MATCLASS_LEATHER },
	{ "glove", MATCLASS_LEATHER }, { "gloves", MATCLASS_LEATHER },

	{ "cloth", MATCLASS_CLOTH }, { "fabric", MATCLASS_CLOTH }, { "robe", MATCLASS_CLOTH },
	{ "robes", MATCLASS_CLOTH }, { "cape", MATCLASS_CLOTH }, { "cloak", MATCLASS_CLOTH },
	{ "tunic", MATCLASS_CLOTH }, { "skirt", MATCLASS_CLOTH }, { "sleeve", MATCLASS_CLOTH },
	{ "sleeves", MATCLASS_CLOTH }, { "scarf", MATCLASS_CLOTH }, { "pants", MATCLASS_CLOTH },
	{ "shirt", MATCLASS_CLOTH }, { "carpet", MATCLASS_CLOTH }, { "rug", MATCLASS_CLOTH },
	{ "curtain", MATCLASS_CLOTH }, { "banner", MATCLASS_CLOTH }, { "flag", MATCLASS_CLOTH },
	{ "tapestry", MATCLASS_CLOTH },

	// "armor" alone is not metal: most JKA armour is trooper plastic
	{ "rubber", MATCLASS_PLASTIC }, { "plastic", MATCLASS_PLASTIC }, { "hose", MATCLASS_PLASTIC },
	{ "tire", MATCLASS_PLASTIC }, { "armor", MATCLASS_PLASTIC }, { "armour", MATCLASS_PLASTIC },
	{ "helmet", MATCLASS_PLASTIC },

	{ "metal", MATCLASS_METAL }, { "metl", MATCLASS_METAL }, { "steel", MATCLASS_METAL },
	{ "iron", MATCLASS_METAL }, { "chrome", MATCLASS_METAL }, { "grate", MATCLASS_METAL },
	{ "grating", MATCLASS_METAL }, { "pipe", MATCLASS_METAL }, { "pipes", MATCLASS_METAL },
	{ "rivet", MATCLASS_METAL }, { "aluminum", MATCLASS_METAL }, { "brass", MATCLASS_METAL },
	{ "copper", MATCLASS_METAL }, { "bronze", MATCLASS_METAL }, { "gold", MATCLASS_METAL },
	{ "silver", MATCLASS_METAL }, { "hilt", MATCLASS_METAL },
};

// models/players/<dir> with one material for the whole character (rule 3)
static const materialToken_t characterDirs[] = {
	// droids: bare / painted metal bodies
	{ "droids", MATCLASS_METAL }, { "assassin_droid", MATCLASS_METAL },
	{ "saber_droid", MATCLASS_METAL }, { "gonk", MATCLASS_METAL }, { "mouse", MATCLASS_METAL },
	{ "probe", MATCLASS_METAL }, { "protocol", MATCLASS_METAL }, { "r2d2", MATCLASS_METAL },
	{ "r5d2", MATCLASS_METAL }, { "remote_sp", MATCLASS_METAL }, { "remote", MATCLASS_METAL },
	{ "sentry", MATCLASS_METAL }, { "interrogator", MATCLASS_METAL }, { "mark1", MATCLASS_METAL },
	// vehicles: painted hulls are a dielectric coating
	{ "atst", MATCLASS_PLASTIC }, { "lambdashuttle", MATCLASS_PLASTIC },
	{ "tie_bomber", MATCLASS_PLASTIC }, { "tie_fighter", MATCLASS_PLASTIC },
	{ "x-wing", MATCLASS_PLASTIC }, { "z-95", MATCLASS_PLASTIC }, { "swoop", MATCLASS_PLASTIC },
	// armoured troopers: plastic-like shells, not metal
	{ "stormtrooper", MATCLASS_PLASTIC }, { "shadowtrooper", MATCLASS_PLASTIC },
	{ "snowtrooper", MATCLASS_PLASTIC }, { "stormpilot", MATCLASS_PLASTIC },
	{ "swamptrooper", MATCLASS_PLASTIC }, { "hazardtrooper", MATCLASS_PLASTIC },
	{ "rockettrooper", MATCLASS_PLASTIC }, { "boba_fett", MATCLASS_PLASTIC },
	// furry creatures
	{ "chewbacca", MATCLASS_HAIR }, { "wampa", MATCLASS_HAIR }, { "tauntaun", MATCLASS_HAIR },
	// naked scaly / leathery creatures (clothed aliens such as trandoshan or
	// noghri go through the body part rule instead)
	{ "rancor", MATCLASS_SKIN }, { "mutant_rancor", MATCLASS_SKIN }, { "howler", MATCLASS_SKIN },
	{ "sand_creature", MATCLASS_SKIN },
	// fully wrapped
	{ "tusken", MATCLASS_CLOTH },
	// not a character
	{ "rocks", MATCLASS_GENERIC },
};

// body part words of organic characters (rule 4), matched last token first
static const materialToken_t partTokens[] = {
	{ "head", MATCLASS_SKIN }, { "face", MATCLASS_SKIN }, { "forehead", MATCLASS_SKIN },
	{ "eyes", MATCLASS_SKIN }, { "eye", MATCLASS_SKIN }, { "eyesmouth", MATCLASS_SKIN },
	{ "mouth", MATCLASS_SKIN }, { "teeth", MATCLASS_SKIN }, { "hand", MATCLASS_SKIN },
	{ "hands", MATCLASS_SKIN }, { "neck", MATCLASS_SKIN }, { "skin", MATCLASS_SKIN },
	{ "flesh", MATCLASS_SKIN }, { "caps", MATCLASS_SKIN }, { "cap", MATCLASS_SKIN },

	{ "torso", MATCLASS_CLOTH }, { "legs", MATCLASS_CLOTH }, { "leg", MATCLASS_CLOTH },
	{ "hips", MATCLASS_CLOTH }, { "lower", MATCLASS_CLOTH }, { "coat", MATCLASS_CLOTH },
	{ "jacket", MATCLASS_CLOTH }, { "vest", MATCLASS_CLOTH }, { "uniform", MATCLASS_CLOTH },
	{ "cuff", MATCLASS_CLOTH }, { "cuffs", MATCLASS_CLOTH }, { "clothes", MATCLASS_CLOTH },
	{ "hood", MATCLASS_CLOTH }, { "flap", MATCLASS_CLOTH }, { "dress", MATCLASS_CLOTH },
	{ "collar", MATCLASS_CLOTH }, { "tentacles", MATCLASS_SKIN }, { "lekku", MATCLASS_SKIN },
};

// models/weapons2/<dir> that are not metal (rule 2)
static const materialToken_t weaponDirs[] = {
	{ "noweap", MATCLASS_GENERIC }, { "tusken_staff", MATCLASS_GENERIC },
	{ "noghri_stick", MATCLASS_GENERIC },
};

static const materialToken_t *FindToken( const materialToken_t *table, size_t count, const char *token )
{
	for ( size_t i = 0; i < count; i++ )
	{
		if ( !Q_stricmp( table[i].token, token ) )
			return &table[i];
	}
	return NULL;
}

#define MAX_NAME_TOKENS 32
#define MAX_TOKEN_CHARS_AUTOPBR 32

typedef struct
{
	int		count;
	char	token[MAX_NAME_TOKENS][MAX_TOKEN_CHARS_AUTOPBR];
} nameTokens_t;

// Splits on everything but letters (/ _ - . digits ...) and on lower -> upper
// case changes, lowercases. Single letters are dropped.
static void TokenizeName( const char *s, nameTokens_t *out )
{
	char current[MAX_TOKEN_CHARS_AUTOPBR];
	int len = 0;
	char prev = 0;

	out->count = 0;
	for ( ;; s++ )
	{
		const char c = *s;
		const qboolean alpha = (qboolean)((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'));
		const qboolean camelBreak = (qboolean)(alpha && prev >= 'a' && prev <= 'z' && c >= 'A' && c <= 'Z');

		if ( (!alpha || camelBreak) && len > 0 )
		{
			if ( len > 1 && out->count < MAX_NAME_TOKENS )
			{
				current[len] = '\0';
				Q_strncpyz( out->token[out->count++], current, MAX_TOKEN_CHARS_AUTOPBR );
			}
			len = 0;
		}

		if ( !c )
			break;

		if ( alpha && len < MAX_TOKEN_CHARS_AUTOPBR - 1 )
			current[len++] = (char)tolower( c );
		prev = c;
	}
}

#define MAX_NAME_PARTS 8

typedef struct
{
	char	buffer[MAX_QPATH];
	int		count;
	char	*part[MAX_NAME_PARTS];	// directories, then the file name
} namePath_t;

static qboolean SplitPath( const char *name, namePath_t *out )
{
	if ( !name || !name[0] )
		return qfalse;

	COM_StripExtension( name, out->buffer, sizeof( out->buffer ) );
	out->count = 0;

	char *p = out->buffer;
	out->part[out->count++] = p;
	for ( ; *p; p++ )
	{
		if ( *p == '\\' )
			*p = '/';
		if ( *p == '/' && out->count < MAX_NAME_PARTS )
		{
			*p = '\0';
			out->part[out->count++] = p + 1;
		}
	}
	return qtrue;
}

static void SetClass( shaderStage_t *stage, materialClass_t cls, const char *reason, const char *token )
{
	stage->materialClass = cls;
	stage->materialReason = reason;
	stage->materialToken = token;
}

/*
===============
R_ClassifyMaterial

Heuristic material class from the shader name and the diffuse image name,
first hit wins, anything uncertain stays generic:

1. material word in the file name (hair, boots, robe, armor, metal, ...)
2. models/weapons2/...                         -> metal (a few staffs excluded)
3. models/players/<dir> with a single material  (droids metal, troopers and
                                                vehicles plastic, fur hair ...)
4. models/players/<organic>/<name>: body part word, last token first
                                    (head/face/hands -> skin, torso/legs -> cloth)
5. material word in a directory name
6. generic

Brightness or color of the diffuse texture is deliberately not used.
===============
*/
void R_ClassifyMaterial( shaderStage_t *stage, const char *shaderName, const char *diffuseName )
{
	namePath_t paths[2];
	nameTokens_t tokens;
	int numPaths = 0;

	SetClass( stage, MATCLASS_GENERIC, "no token", NULL );

	if ( SplitPath( shaderName, &paths[numPaths] ) )
		numPaths++;
	if ( SplitPath( diffuseName, &paths[numPaths] ) )
	{
		// same name as the shader (implicit shaders) only once
		char a[MAX_QPATH], b[MAX_QPATH];
		COM_StripExtension( shaderName ? shaderName : "", a, sizeof( a ) );
		COM_StripExtension( diffuseName, b, sizeof( b ) );
		if ( !numPaths || Q_stricmp( a, b ) )
			numPaths++;
	}

	// 1. material word in a file name
	for ( int i = 0; i < numPaths; i++ )
	{
		const namePath_t *path = &paths[i];
		TokenizeName( path->part[path->count - 1], &tokens );
		for ( int t = 0; t < tokens.count; t++ )
		{
			const materialToken_t *match = FindToken( materialTokens, ARRAY_LEN( materialTokens ), tokens.token[t] );
			if ( match )
			{
				SetClass( stage, match->cls, "name", match->token );
				return;
			}
		}
	}

	for ( int i = 0; i < numPaths; i++ )
	{
		const namePath_t *path = &paths[i];
		if ( path->count < 3 || Q_stricmp( path->part[0], "models" ) )
			continue;

		// 2. weapons
		if ( !Q_stricmp( path->part[1], "weapons2" ) )
		{
			const materialToken_t *match = FindToken( weaponDirs, ARRAY_LEN( weaponDirs ), path->part[2] );
			if ( match )
				SetClass( stage, match->cls, "weapon", match->token );
			else
				SetClass( stage, MATCLASS_METAL, "weapons2", NULL );
			return;
		}

		if ( path->count < 4 || Q_stricmp( path->part[1], "players" ) )
			continue;

		// 3. character archetype
		const materialToken_t *match = FindToken( characterDirs, ARRAY_LEN( characterDirs ), path->part[2] );
		if ( match )
		{
			SetClass( stage, match->cls, "character", match->token );
			return;
		}

		// 4. body part of an organic character, last token first
		//    (torso_01_hands is a hand texture)
		TokenizeName( path->part[path->count - 1], &tokens );
		for ( int t = tokens.count - 1; t >= 0; t-- )
		{
			match = FindToken( partTokens, ARRAY_LEN( partTokens ), tokens.token[t] );
			if ( match )
			{
				SetClass( stage, match->cls, "part", match->token );
				return;
			}
		}
	}

	// 5. material word in a directory
	for ( int i = 0; i < numPaths; i++ )
	{
		const namePath_t *path = &paths[i];
		for ( int d = 0; d < path->count - 1; d++ )
		{
			TokenizeName( path->part[d], &tokens );
			for ( int t = 0; t < tokens.count; t++ )
			{
				const materialToken_t *match = FindToken( materialTokens, ARRAY_LEN( materialTokens ), tokens.token[t] );
				if ( match )
				{
					SetClass( stage, match->cls, "dir", match->token );
					return;
				}
			}
		}
	}
}

/*
==============================================================================

pbr_dumpMaterials

==============================================================================
*/

static const char *PBRSourceName( const shaderStage_t *stage )
{
	switch ( stage->pbrSource )
	{
		case PBR_SOURCE_EXPLICIT:
			switch ( stage->specularType )
			{
				case SPEC_SPECGLOSS: return "authored:specMap";
				case SPEC_RMO:
				case SPEC_RMOS:      return "authored:rmoMap";
				case SPEC_MOXR:
				case SPEC_MOSR:      return "authored:moxrMap";
				default:             return "authored:ormMap";
			}
		case PBR_SOURCE_DISCOVERED:
			switch ( stage->specularType )
			{
				case SPEC_SPECGLOSS: return "authored:_specGloss";
				case SPEC_RMO:       return "authored:_rmo";
				default:             return "authored:_orm";
			}
		case PBR_SOURCE_SCALAR:
			return "authored:scalar";
		case PBR_SOURCE_LEGACY:
			return r_autoPBR->integer ? "auto" : "legacy";
		default:
			return "none";
	}
}

/*
===============
R_PBRDumpMaterials_f

pbr_dumpMaterials [used|all|auto|authored|<class>]

Lists the lit lightall stages of the registered shaders (this level and the
models loaded for it) with the parameters r_autoPBR currently gives them.
Default: only stages drawn since they were registered.
===============
*/
void R_PBRDumpMaterials_f( void )
{
	const char *filter = ri.Cmd_Argc() > 1 ? ri.Cmd_Argv( 1 ) : "used";
	const qboolean all = (qboolean)!Q_stricmp( filter, "all" );
	const qboolean usedOnly = (qboolean)!Q_stricmp( filter, "used" );
	const qboolean autoOnly = (qboolean)!Q_stricmp( filter, "auto" );
	const qboolean authoredOnly = (qboolean)!Q_stricmp( filter, "authored" );
	int classFilter = -1;
	int perClass[MATCLASS_COUNT] = {};
	int perSource[PBR_SOURCE_LEGACY + 1] = {};
	int listed = 0;

	if ( !all && !usedOnly && !autoOnly && !authoredOnly )
	{
		for ( int c = 0; c < MATCLASS_COUNT; c++ )
		{
			if ( !Q_stricmp( filter, materialDefaults[c].name ) )
				classFilter = c;
		}
		if ( classFilter < 0 )
		{
			ri.Printf( PRINT_ALL, "usage: pbr_dumpMaterials [used|all|auto|authored|generic|metal|skin|cloth|leather|plastic|hair]\n" );
			return;
		}
	}

	if ( !r_specularMapping->integer )
		ri.Printf( PRINT_ALL, S_COLOR_YELLOW "r_specularMapping is 0: lightall has no specular path, r_autoPBR has no effect\n" );

	ri.Printf( PRINT_ALL, "r_autoPBR %d. AO / rough / metal / F0 are the values lightall receives now.\n", r_autoPBR->integer );
	ri.Printf( PRINT_ALL, "%-4s %-44s %-20s %-8s %-18s %4s %5s %5s %6s  diffuse\n",
		"used", "shader", "source", "class", "reason", "AO", "rough", "metal", "F0" );

	for ( int i = 0; i < tr.numShaders; i++ )
	{
		const shader_t *sh = tr.shaders[i];
		for ( int s = 0; s < MAX_SHADER_STAGES; s++ )
		{
			const shaderStage_t *stage = sh->stages[s];
			if ( !stage || !stage->active || stage->pbrSource == PBR_SOURCE_NONE )
				continue;
			// lightstyle copies of a stage share its material
			if ( stage->rgbGen == CGEN_LIGHTMAPSTYLE )
				continue;

			const qboolean isLegacy = (qboolean)(stage->pbrSource == PBR_SOURCE_LEGACY);
			if ( usedOnly && !stage->pbrDrawn )
				continue;
			if ( autoOnly && !isLegacy )
				continue;
			if ( authoredOnly && isLegacy )
				continue;
			if ( classFilter >= 0 && (!isLegacy || stage->materialClass != classFilter) )
				continue;

			// what the shader decodes, see the header of this file
			vec4_t scale;
			if ( !R_AutoPBRSpecularScale( stage, scale ) )
				VectorCopy4( stage->specularScale, scale );

			char reason[64];
			if ( !isLegacy )
				Q_strncpyz( reason, "-", sizeof( reason ) );
			else if ( stage->materialToken )
				Com_sprintf( reason, sizeof( reason ), "%s:%s", stage->materialReason, stage->materialToken );
			else
				Q_strncpyz( reason, stage->materialReason ? stage->materialReason : "?", sizeof( reason ) );

			const image_t *diffuse = stage->bundle[TB_DIFFUSEMAP].image[0];
			if ( isLegacy || stage->pbrSource == PBR_SOURCE_SCALAR )
			{
				ri.Printf( PRINT_ALL, "%-4s %-44s %-20s %-8s %-18s %4.2f %5.2f %5.2f %6.3f  %s\n",
					stage->pbrDrawn ? "*" : "", sh->name, PBRSourceName( stage ),
					isLegacy ? R_MaterialClassName( stage->materialClass ) : "-", reason,
					scale[2], scale[3], scale[0], 0.08f * scale[1],
					diffuse ? diffuse->imgName : "-" );
			}
			else
			{
				// texture driven, the scale only multiplies the map
				ri.Printf( PRINT_ALL, "%-4s %-44s %-20s %-8s %-18s %4s %5s %5s %6s  %s (map %s)\n",
					stage->pbrDrawn ? "*" : "", sh->name, PBRSourceName( stage ), "-", reason,
					"map", "map", "map", "map",
					diffuse ? diffuse->imgName : "-",
					stage->bundle[TB_SPECULARMAP].image[0] ? stage->bundle[TB_SPECULARMAP].image[0]->imgName : "-" );
			}

			listed++;
			perSource[stage->pbrSource]++;
			if ( isLegacy )
				perClass[stage->materialClass]++;
		}
	}

	ri.Printf( PRINT_ALL, "%d stages: %d explicit maps, %d discovered maps, %d scalar keywords, %d legacy (auto PBR)\n",
		listed, perSource[PBR_SOURCE_EXPLICIT], perSource[PBR_SOURCE_DISCOVERED],
		perSource[PBR_SOURCE_SCALAR], perSource[PBR_SOURCE_LEGACY] );
	ri.Printf( PRINT_ALL, "legacy classes:" );
	for ( int c = 0; c < MATCLASS_COUNT; c++ )
		ri.Printf( PRINT_ALL, " %s %d", materialDefaults[c].name, perClass[c] );
	ri.Printf( PRINT_ALL, "\n" );
}
