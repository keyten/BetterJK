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

// Parser for .cube 3D LUT files (Adobe/Resolve format). No engine
// dependencies, so it can be tested on its own.

#pragma once

#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#define CUBE_LUT_MIN_SIZE 2
#define CUBE_LUT_MAX_SIZE 128

namespace cubelut
{

inline const char *SkipSpaces( const char *p )
{
	while ( *p == ' ' || *p == '\t' )
		++p;
	return p;
}

inline bool KeywordIs( const char *line, const char *keyword )
{
	const size_t len = strlen(keyword);
	return strncmp(line, keyword, len) == 0 &&
		(line[len] == ' ' || line[len] == '\t' || line[len] == '\0');
}

// Parses up to count floats from p, returns how many were read
inline int ParseFloats( const char *p, float *out, int count )
{
	int n = 0;
	while ( n < count )
	{
		char *end;
		const double value = strtod(p, &end);
		if ( end == p )
			break;
		out[n++] = (float)value;
		p = end;
	}
	return n;
}

} // namespace cubelut

// Parses the text of a .cube file (null terminated). On success returns
// nullptr, sets size and fills texels with size^3 RGBA16 texels, red changing
// fastest, then green, then blue (the layout of a 3D texture). Values are
// clamped to [0, 1]. On failure returns an error message.
inline const char *R_ParseCubeLUT( const char *text, int *size, std::vector<uint16_t>& texels )
{
	using namespace cubelut;

	int lutSize = 0;
	size_t numEntries = 0;
	size_t expectedEntries = 0;
	std::vector<char> line;

	*size = 0;
	texels.clear();

	const char *p = text;
	while ( *p )
	{
		// Copy one line
		const char *lineEnd = p;
		while ( *lineEnd && *lineEnd != '\n' && *lineEnd != '\r' )
			++lineEnd;
		line.assign(p, lineEnd);
		line.push_back('\0');
		p = lineEnd;
		while ( *p == '\n' || *p == '\r' )
			++p;

		const char *l = SkipSpaces(line.data());
		if ( *l == '\0' || *l == '#' )
			continue;

		if ( isalpha((unsigned char)*l) )
		{
			float v[3];
			if ( KeywordIs(l, "LUT_3D_SIZE") )
			{
				if ( lutSize )
					return "LUT_3D_SIZE given twice";
				lutSize = atoi(l + strlen("LUT_3D_SIZE"));
				if ( lutSize < CUBE_LUT_MIN_SIZE || lutSize > CUBE_LUT_MAX_SIZE )
					return "LUT_3D_SIZE must be between 2 and 128";
				expectedEntries = (size_t)lutSize * lutSize * lutSize;
				texels.reserve(expectedEntries * 4);
			}
			else if ( KeywordIs(l, "LUT_1D_SIZE") )
			{
				return "1D LUTs are not supported";
			}
			else if ( KeywordIs(l, "DOMAIN_MIN") )
			{
				if ( ParseFloats(l + strlen("DOMAIN_MIN"), v, 3) != 3 )
					return "bad DOMAIN_MIN";
				if ( v[0] != 0.0f || v[1] != 0.0f || v[2] != 0.0f )
					return "only DOMAIN_MIN 0 0 0 is supported";
			}
			else if ( KeywordIs(l, "DOMAIN_MAX") )
			{
				if ( ParseFloats(l + strlen("DOMAIN_MAX"), v, 3) != 3 )
					return "bad DOMAIN_MAX";
				if ( v[0] != 1.0f || v[1] != 1.0f || v[2] != 1.0f )
					return "only DOMAIN_MAX 1 1 1 is supported";
			}
			else if ( KeywordIs(l, "LUT_3D_INPUT_RANGE") )
			{
				if ( ParseFloats(l + strlen("LUT_3D_INPUT_RANGE"), v, 2) != 2 )
					return "bad LUT_3D_INPUT_RANGE";
				if ( v[0] != 0.0f || v[1] != 1.0f )
					return "only LUT_3D_INPUT_RANGE 0 1 is supported";
			}
			// TITLE and other keywords don't affect the table
			continue;
		}

		// Table entry
		if ( !lutSize )
			return "table entries before LUT_3D_SIZE";

		float rgb[3];
		if ( ParseFloats(l, rgb, 3) != 3 )
			return "bad table entry";

		if ( numEntries >= expectedEntries )
			return "too many table entries";

		for ( int i = 0; i < 3; ++i )
		{
			float c = rgb[i];
			if ( !(c > 0.0f) ) // also catches NaN
				c = 0.0f;
			else if ( c > 1.0f )
				c = 1.0f;
			texels.push_back((uint16_t)(c * 65535.0f + 0.5f));
		}
		texels.push_back(65535);
		++numEntries;
	}

	if ( !lutSize )
		return "missing LUT_3D_SIZE";

	if ( numEntries != expectedEntries )
		return "not enough table entries";

	*size = lutSize;
	return nullptr;
}

// Identity LUT of the given size, same layout as R_ParseCubeLUT
inline void R_MakeIdentityCubeLUT( int size, std::vector<uint16_t>& texels )
{
	texels.clear();
	texels.reserve((size_t)size * size * size * 4);
	for ( int b = 0; b < size; ++b )
		for ( int g = 0; g < size; ++g )
			for ( int r = 0; r < size; ++r )
			{
				texels.push_back((uint16_t)((r * 65535 + (size - 1) / 2) / (size - 1)));
				texels.push_back((uint16_t)((g * 65535 + (size - 1) / 2) / (size - 1)));
				texels.push_back((uint16_t)((b * 65535 + (size - 1) / 2) / (size - 1)));
				texels.push_back(65535);
			}
}
