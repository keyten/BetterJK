/*[Vertex]*/
#if defined(USE_LIGHT) && !defined(USE_FAST_LIGHT)
#define PER_PIXEL_LIGHTING
#endif
in vec2 attr_TexCoord0;
#if defined(USE_LIGHTMAP) || defined(USE_TCGEN)
in vec2 attr_TexCoord1;
in vec2 attr_TexCoord2;
in vec2 attr_TexCoord3;
in vec2 attr_TexCoord4;
#endif
in vec4 attr_Color;

in vec3 attr_Position;
in vec3 attr_Normal;
#if defined(PER_PIXEL_LIGHTING)
in vec4 attr_Tangent;
#endif

#if defined(USE_VERTEX_ANIMATION)
in vec3 attr_Position2;
in vec3 attr_Normal2;
in vec4 attr_Tangent2;
#elif defined(USE_SKELETAL_ANIMATION)
in uvec4 attr_BoneIndexes;
in vec4 attr_BoneWeights;
#endif

#if defined(USE_LIGHT) && !defined(USE_LIGHT_VECTOR)
in vec3 attr_LightDirection;
#endif

#if defined(USE_SILHOUETTE_POM)
in vec3 attr_Position2;	// silhouette POM shell data, see pom_silhouette.glsl
#endif

layout(std140) uniform Camera
{
	mat4 u_viewProjectionMatrix;
	vec4 u_ViewInfo;
	vec3 u_ViewOrigin;
	vec3 u_ViewForward;
	vec3 u_ViewLeft;
	vec3 u_ViewUp;
	// Forward+ cluster grid of this view (tr_forwardplus.cpp, CameraBlock)
	ivec4 u_FPlusGrid;    // grid texel base, light texel base, tiles x, tiles y
	vec4 u_FPlusParams;   // tile size, depth slices, slice scale, slice bias
	vec4 u_FPlusParams2;  // viewport x, viewport y, enabled, near slice distance
	vec4 u_FPlusDebug;    // r_forwardPlusDebug, selected light, max lights per cluster, r_ltcDebug
};

layout(std140) uniform Entity
{
	mat4 u_ModelMatrix;
	vec4 u_LocalLightOrigin;
	vec3 u_AmbientLight;
	float u_entityTime;
	vec3 u_DirectedLight;
	float u_FXVolumetricBase;
	vec3 u_ModelLightDir;
	float u_VertexLerp;
	vec4 u_GridAmbient[3];
	vec4 u_GridDirected[3];
	vec4 u_GridDirection[3];
	vec4 u_GridParams;
	vec4 u_GridMinimum;
	vec4 u_GridScale;
};

#if defined(USE_SKELETAL_ANIMATION)
layout(std140) uniform Bones
{
	mat3x4 u_BoneMatrices[MAX_G2_BONES];
};
#endif

#if defined(USE_DELUXEMAP)
uniform vec4   u_EnableTextures; // x = normal, y = deluxe, z = specular, w = cube
#endif

#if defined(USE_TCGEN) || defined(USE_LIGHTMAP)
uniform int u_TCGen0;
uniform vec3 u_TCGen0Vector0;
uniform vec3 u_TCGen0Vector1;
uniform int u_TCGen1;
#endif

#if defined(USE_TCMOD)
uniform vec4 u_DiffuseTexMatrix;
uniform vec4 u_DiffuseTexOffTurb;
#endif

uniform vec4 u_BaseColor;
uniform vec4 u_VertColor;
uniform vec4 u_Disintegration;
uniform int u_ColorGen;

#if defined(PER_PIXEL_LIGHTING) && defined(USE_NORMALMAP) && defined(USE_PARALLAXMAP)
uniform sampler2D u_NormalMap;
#endif

out vec4 var_TexCoords;
out vec4 var_Color;

#if defined(PER_PIXEL_LIGHTING)
out vec4 var_Normal;
out vec4 var_Tangent;
out vec4 var_ViewDir;
out vec4 var_LightDir;
#else
out vec3 var_Position;
out vec3 var_Normal;
#endif

#if defined(USE_SILHOUETTE_POM)
out vec2 var_PomShell;
flat out float var_PomHeader;
#endif

vec4 CalcColor(vec3 position)
{
	vec4 color = vec4(1.0);
	if (u_ColorGen == CGEN_DISINTEGRATION_1)
	{
		vec3 delta = u_Disintegration.xyz - position;
		float sqrDistance = dot(delta, delta);
		if (sqrDistance < u_Disintegration.w)
		{
			color = vec4(0.0);
		}
		else if (sqrDistance < u_Disintegration.w + 60.0)
		{
			color = vec4(0.0, 0.0, 0.0, 1.0);
		}
		else if (sqrDistance < u_Disintegration.w + 150.0)
		{
			color = vec4(0.435295, 0.435295, 0.435295, 1.0);
		}
		else if (sqrDistance < u_Disintegration.w + 180.0)
		{
			color = vec4(0.6862745, 0.6862745, 0.6862745, 1.0);
		}
		return color;
	}
	else if (u_ColorGen == CGEN_DISINTEGRATION_2)
	{
		vec3 delta = u_Disintegration.xyz - position;
		float sqrDistance = dot(delta, delta);
		if (sqrDistance < u_Disintegration.w)
		{
			return vec4(0.0);
		}
		return color;
	}
	return color;
}

#if defined(USE_TCGEN) || defined(USE_LIGHTMAP)
vec2 GenTexCoords(int TCGen, vec3 position, vec3 normal, vec3 TCGenVector0, vec3 TCGenVector1)
{
	vec2 tex = attr_TexCoord0;

	switch (TCGen)
	{
		case TCGEN_LIGHTMAP:
			tex = attr_TexCoord1;
		break;

		case TCGEN_LIGHTMAP1:
			tex = attr_TexCoord2;
		break;

		case TCGEN_LIGHTMAP2:
			tex = attr_TexCoord3;
		break;

		case TCGEN_LIGHTMAP3:
			tex = attr_TexCoord4;
		break;

		case TCGEN_ENVIRONMENT_MAPPED:
		{
			vec3 localOrigin = (inverse(u_ModelMatrix) * vec4(u_ViewOrigin, 1.0)).xyz;
			vec3 viewer = normalize(localOrigin - position);
			vec2 ref = reflect(viewer, normal).yz;
			tex.s = ref.x * -0.5 + 0.5;
			tex.t = ref.y *  0.5 + 0.5;
		}
		break;

		case TCGEN_ENVIRONMENT_MAPPED_SP:
		{
			vec3 localOrigin = (inverse(u_ModelMatrix) * vec4(u_ViewOrigin, 1.0)).xyz;
			vec3 viewer = normalize(localOrigin - position);
			vec2 ref = reflect(viewer, normal).xy;
			tex.s = ref.x * -0.5;
			tex.t = ref.y * -0.5;
		}
		break;

		case TCGEN_ENVIRONMENT_MAPPED_SP_FP:
		{
			vec2 ref = reflect(u_ModelLightDir.xyz, normal).xy;
			tex.s = ref.x * -0.5 + 0.5 * u_ModelLightDir.x;
			tex.t = ref.y * -0.5 + 0.5 * u_ModelLightDir.y;
		}
		break;

		case TCGEN_VECTOR:
		{
			tex = vec2(dot(position, TCGenVector0), dot(position, TCGenVector1));
		}
		break;
	}

	return tex;
}
#endif

#if defined(USE_TCMOD)
vec2 ModTexCoords(vec2 st, vec3 position, vec4 texMatrix, vec4 offTurb)
{
	float amplitude = offTurb.z;
	float phase = offTurb.w * 2.0 * M_PI;
	vec2 st2;
	st2.x = st.x * texMatrix.x + (st.y * texMatrix.z + offTurb.x);
	st2.y = st.x * texMatrix.y + (st.y * texMatrix.w + offTurb.y);

	vec2 offsetPos = vec2(position.x + position.z, position.y);

	vec2 texOffset = sin(offsetPos * (2.0 * M_PI / 1024.0) + vec2(phase));

	return st2 + texOffset * amplitude;
}
#endif

#if defined(USE_SKELETAL_ANIMATION)
mat4x3 GetBoneMatrix(uint index)
{
	mat3x4 bone = u_BoneMatrices[index];
	return mat4x3(
		bone[0].x, bone[1].x, bone[2].x,
		bone[0].y, bone[1].y, bone[2].y,
		bone[0].z, bone[1].z, bone[2].z,
		bone[0].w, bone[1].w, bone[2].w);
}
#endif

void main()
{
#if defined(USE_VERTEX_ANIMATION)
	vec3 position  = mix(attr_Position,    attr_Position2,    u_VertexLerp);
	vec3 normal    = mix(attr_Normal,      attr_Normal2,      u_VertexLerp);
	#if defined(PER_PIXEL_LIGHTING)
	vec3 tangent   = mix(attr_Tangent.xyz, attr_Tangent2.xyz, u_VertexLerp);
	#endif
#elif defined(USE_SKELETAL_ANIMATION)
	mat4x3 influence =
		GetBoneMatrix(attr_BoneIndexes[0]) * attr_BoneWeights[0] +
        GetBoneMatrix(attr_BoneIndexes[1]) * attr_BoneWeights[1] +
        GetBoneMatrix(attr_BoneIndexes[2]) * attr_BoneWeights[2] +
        GetBoneMatrix(attr_BoneIndexes[3]) * attr_BoneWeights[3];

    vec3 position = influence * vec4(attr_Position, 1.0);
    vec3 normal = normalize(influence * vec4(attr_Normal - vec3(0.5), 0.0));
	#if defined(PER_PIXEL_LIGHTING)
		vec3 tangent = normalize(influence * vec4(attr_Tangent.xyz - vec3(0.5), 0.0));
	#endif
#else
	vec3 position  = attr_Position;
	vec3 normal    = attr_Normal;
  #if defined(PER_PIXEL_LIGHTING)
	vec3 tangent   = attr_Tangent.xyz;
  #endif
#endif

#if !defined(USE_SKELETAL_ANIMATION)
	normal  = normal  * 2.0 - vec3(1.0);
  #if defined(PER_PIXEL_LIGHTING)
	tangent = tangent * 2.0 - vec3(1.0);
  #endif
#endif

	vec4 wsPosition = u_ModelMatrix * vec4(position, 1.0);

#if defined(USE_TCGEN)
	vec2 texCoords = GenTexCoords(u_TCGen0, position.xyz, normal, u_TCGen0Vector0, u_TCGen0Vector1);
#else
	vec2 texCoords = attr_TexCoord0.st;
#endif

#if defined(USE_TCMOD)
	var_TexCoords.xy = ModTexCoords(texCoords, position, u_DiffuseTexMatrix, u_DiffuseTexOffTurb);
#else
	var_TexCoords.xy = texCoords;
#endif

	vec4 disintegration = CalcColor(position);

	gl_Position = u_viewProjectionMatrix * wsPosition;

	position  = wsPosition.xyz;
	normal    = normalize(mat3(u_ModelMatrix) * normal);
  #if defined(PER_PIXEL_LIGHTING)
	tangent   = normalize(mat3(u_ModelMatrix) * tangent);
  #endif

#if defined(USE_LIGHT_VECTOR)
	vec3 L = u_LocalLightOrigin.xyz;
#elif defined(PER_PIXEL_LIGHTING)
	vec3 L = attr_LightDirection * 2.0 - vec3(1.0);
	L = (u_ModelMatrix * vec4(L, 0.0)).xyz;
#endif

#if defined(USE_LIGHTMAP)
	var_TexCoords.zw = GenTexCoords(u_TCGen1, vec3(0.0), vec3(0.0), vec3(0.0), vec3(0.0));
#endif

	if ( u_FXVolumetricBase > 0.0 )
	{
		vec3 viewForward = u_ViewForward.xyz;

		float d = clamp(dot(normalize(viewForward), normal), 0.0, 1.0);
		d = d * d;
		d = d * d;

		var_Color = vec4(u_FXVolumetricBase * (1.0 - d));
	}
	else
	{
		var_Color = u_VertColor * attr_Color + u_BaseColor;

		#if defined(USE_LIGHT_VECTOR) && defined(USE_FAST_LIGHT)
			float sqrLightDist = dot(L, L);
			float NL = clamp(dot(normal, L) / sqrt(sqrLightDist), 0.0, 1.0);
			var_Color.rgb *= u_DirectedLight * NL + u_AmbientLight;
		#endif
	}
	var_Color *= disintegration;

#if defined(PER_PIXEL_LIGHTING)
  var_LightDir = vec4(L, 0.0);
  #if defined(USE_DELUXEMAP)
	var_LightDir -= u_EnableTextures.y * var_LightDir;
  #endif
#endif

#if defined(PER_PIXEL_LIGHTING)
	vec3 viewDir = u_ViewOrigin.xyz - position;
	var_Tangent = vec4(tangent,   (attr_Tangent.w * 2.0 - 1.0));

	#if defined(USE_NORMALMAP) && defined(USE_PARALLAXMAP)
	  vec3 bitangent = cross(normal, tangent) * var_Tangent.w;
	  mat3 TBN = mat3(tangent, bitangent, normal);
	  vec3 tangentViewDir = viewDir * TBN;

	  // normal map aspect correction for parallax mapping
	  vec2 normalSize = vec2(textureSize(u_NormalMap, 0));
	  float normalMapAspect = normalSize.y / normalSize.x;

	  tangentViewDir *= vec3(
	  	max(1.0, normalMapAspect),
	  	max(1.0, 1.0 / normalMapAspect),
	  	1.0
	  );
	#else
	  vec3 tangentViewDir = vec3(0.0);
	#endif

	// store tangent view direction in other outs to save space
	var_LightDir.w = tangentViewDir.x;
	var_Normal  = vec4(normal,    tangentViewDir.y);
	var_ViewDir = vec4(viewDir,   tangentViewDir.z);
#else
	var_Normal = normal;
	var_Position = position;
#endif

#if defined(USE_SILHOUETTE_POM)
	var_PomShell = attr_Position2.xy;
	var_PomHeader = attr_Position2.z;
#endif
}

/*[Fragment]*/
#if defined(USE_LIGHT) && !defined(USE_FAST_LIGHT)
#define PER_PIXEL_LIGHTING
#endif

layout(std140) uniform Scene
{
	vec4 u_PrimaryLightOrigin;
	vec3 u_PrimaryLightAmbient;
	int  u_globalFogIndex;
	vec3 u_PrimaryLightColor;
	float u_PrimaryLightRadius;
	float u_frameTime;
	float u_deltaTime;
	// screen-space AO (tr_ao.cpp, RB_AOSceneParams)
	// x = application: 0 legacy, 1 indirect-only, 2 split (legacy left of w)
	// y = fraction of baked (lightmap/vertex) light treated as indirect
	// z = multi-bounce approximation, w = split position in window pixels
	vec4 u_AOParams;
	vec4 u_AOParams2; // x = r_debugAO
#if defined(USE_SSGI)
	// screen-space GI source (tr_ssgi.cpp, RB_SSGISceneParams): x = source bits
	// (1 dynamic light, 2 emissive, 4 legacy glow), y = 1 linear scene / 0 legacy
	// display encoded, z = emissive scale, w = legacy glow scale
	vec4 u_SSGIParams;
#endif
};

layout(std140) uniform Camera
{
	mat4 u_viewProjectionMatrix;
	vec4 u_ViewInfo;
	vec3 u_ViewOrigin;
	vec3 u_ViewForward;
	vec3 u_ViewLeft;
	vec3 u_ViewUp;
	// Forward+ cluster grid of this view (tr_forwardplus.cpp, CameraBlock)
	ivec4 u_FPlusGrid;    // grid texel base, light texel base, tiles x, tiles y
	vec4 u_FPlusParams;   // tile size, depth slices, slice scale, slice bias
	vec4 u_FPlusParams2;  // viewport x, viewport y, enabled, near slice distance
	vec4 u_FPlusDebug;    // r_forwardPlusDebug, selected light, max lights per cluster, r_ltcDebug
};

layout(std140) uniform Entity
{
	mat4 u_ModelMatrix;
	vec4 u_LocalLightOrigin;
	vec3 u_AmbientLight;
	float u_entityTime;
	vec3 u_DirectedLight;
	float u_FXVolumetricBase;
	vec3 u_ModelLightDir;
	float u_VertexLerp;
	vec4 u_GridAmbient[3];
	vec4 u_GridDirected[3];
	vec4 u_GridDirection[3];
	vec4 u_GridParams;
	vec4 u_GridMinimum;
	vec4 u_GridScale;
};

struct Light
{
	vec4 origin;
	vec3 color;
	float radius;
};

layout(std140) uniform Lights
{
	uniform mat4 u_ShadowMvp;
	uniform mat4 u_ShadowMvp2;
	uniform mat4 u_ShadowMvp3;
	vec4 u_ShadowSplits;
	vec4 u_ShadowBlend;
	vec4 u_ShadowTexelSize;
	vec4 u_ShadowDepthSpan;
	vec4 u_ShadowBias;
	vec4 u_ShadowPcss;
	vec4 u_ShadowDebug;
	int u_NumLights;
	Light u_Lights[32];
};

uniform int u_LightMask;
// Forward+ (tr_forwardplus.cpp): light data, cluster offset / count, light indexes
uniform samplerBuffer  u_FPlusLights;
uniform usamplerBuffer u_FPlusGridMap;
uniform usamplerBuffer u_FPlusIndexMap;
#if defined(USE_LTC) && defined(PER_PIXEL_LIGHTING)
// LTC area lights (tr_arealights.cpp, tr_ltc_data.h)
uniform sampler2D u_LtcMatrixMap;    // inverse LTC matrix (m00, m02, m20, m22)
uniform sampler2D u_LtcAmplitudeMap; // norm, fresnel, 0, horizon clipped sphere form factor
#endif
uniform sampler2D u_DiffuseMap;

#if defined(USE_ENTITY_GRID) && defined(PER_PIXEL_LIGHTING)
#if defined(USE_ENTITY_GPU_GRID)
uniform sampler3D u_EntityGridAmbient;
uniform sampler3D u_EntityGridDirected;
uniform sampler3D u_EntityGridDirection;
uniform vec3 u_LightGridOrigin;
uniform vec3 u_LightGridCellInverseSize;
#endif

struct EntityGridSample
{
	vec3 ambient;
	vec3 directed;
	vec3 direction;
	float validity;
	vec3 cell;
};

#if defined(USE_ENTITY_GPU_GRID)
EntityGridSample SampleEntityGrid(vec3 position)
{
	EntityGridSample result;
	result.ambient = vec3(0.0);
	result.directed = vec3(0.0);
	result.direction = vec3(0.0);
	result.validity = 0.0;
	result.cell = (position - u_LightGridOrigin) * u_LightGridCellInverseSize;
	ivec3 bounds = textureSize(u_EntityGridAmbient, 0);
	ivec3 base = clamp(ivec3(floor(result.cell)), ivec3(0), bounds - ivec3(1));
	vec3 fraction = fract(result.cell);
	float weightSum = 0.0;
	for (int corner = 0; corner < 8; corner++)
	{
		ivec3 offset = ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
		// Match the CPU's linear BSP-array bounds check, including its edge
		// behavior when a corner crosses an X or Y row boundary.
		int linear = base.x + bounds.x * (base.y + bounds.y * base.z) +
			offset.x + bounds.x * (offset.y + bounds.y * offset.z);
		if (linear >= bounds.x * bounds.y * bounds.z)
			continue;
		ivec3 address = ivec3(linear % bounds.x,
			(linear / bounds.x) % bounds.y, linear / (bounds.x * bounds.y));
		vec3 weightAxis = vec3(offset.x != 0 ? fraction.x : 1.0 - fraction.x,
			offset.y != 0 ? fraction.y : 1.0 - fraction.y,
			offset.z != 0 ? fraction.z : 1.0 - fraction.z);
		float weight = weightAxis.x * weightAxis.y * weightAxis.z;
		vec4 encodedDirection = texelFetch(u_EntityGridDirection, address, 0);
		if (encodedDirection.a < 0.5)
			continue;
		result.ambient += weight * texelFetch(u_EntityGridAmbient, address, 0).rgb;
		result.directed += weight * texelFetch(u_EntityGridDirected, address, 0).rgb;
		result.direction += weight * (encodedDirection.rgb * 2.0 - 1.0);
		weightSum += weight;
	}
	if (weightSum > 0.0)
	{
		if (weightSum < 0.99)
		{
			result.ambient /= weightSum;
			result.directed /= weightSum;
		}
		result.validity = weightSum;
		float directionLength = length(result.direction);
		if (directionLength > 1e-5)
			result.direction /= directionLength;
	}
	if (u_GridScale.z < 0.5)
	{
		result.ambient *= ENTITY_GRID_LDR_RANGE;
		result.directed *= ENTITY_GRID_LDR_RANGE;
	}
	result.ambient *= u_GridScale.x;
	result.directed *= u_GridScale.y;
	return result;
}
#endif

EntityGridSample SampleEntityMultiPoint(float worldZ)
{
	EntityGridSample result;
	float height = clamp((worldZ - u_GridParams.x) * u_GridParams.y, 0.0, 1.0);
	float t = height < 0.5 ? clamp((height - 0.12) / 0.38, 0.0, 1.0) :
		1.0 + clamp((height - 0.5) / 0.38, 0.0, 1.0);
	int lo = t < 1.0 ? 0 : 1;
	int hi = lo + 1;
	float blend = fract(min(t, 1.99999));
	result.ambient = mix(u_GridAmbient[lo].rgb, u_GridAmbient[hi].rgb, blend);
	result.directed = mix(u_GridDirected[lo].rgb, u_GridDirected[hi].rgb, blend);
	vec3 direction = mix(u_GridDirection[lo].rgb, u_GridDirection[hi].rgb, blend);
	float directionLength = length(direction);
	result.direction = directionLength > 1e-5 ? direction / directionLength : vec3(0.0);
	result.validity = 1.0;
	result.cell = vec3(0.0);
	return result;
}

vec3 EntityGridSRGBDecode(vec3 color)
{
	color = max(color, vec3(0.0));
	vec3 lo = color * (1.0 / 12.92);
	vec3 hi = pow((color + vec3(0.055)) * (1.0 / 1.055), vec3(2.4));
	return mix(lo, hi, greaterThan(color, vec3(0.04045)));
}

vec3 EntityGridAmbientCompatibility(vec3 ambient)
{
	ambient = min(ambient + u_GridMinimum.rgb, vec3(u_GridMinimum.w));
	if (u_GridParams.w > 0.5)
		ambient = EntityGridSRGBDecode(ambient);
	return ambient;
}

vec3 EntityGridDirectedCompatibility(vec3 directed)
{
	if (u_GridParams.w > 0.5)
		directed = EntityGridSRGBDecode(directed);
	return directed;
}
#endif

#if defined(USE_LIGHTMAP)
uniform sampler2D u_LightMap;
#endif

uniform sampler2D u_EmissiveMap;

#if defined(PER_PIXEL_LIGHTING)
#if defined(USE_NORMALMAP)
uniform sampler2D u_NormalMap;
#endif

#if defined(USE_DELUXEMAP)
uniform sampler2D u_DeluxeMap;
#endif

#if defined(USE_SPECULARMAP)
uniform sampler2D u_SpecularMap;
#endif

#if defined(USE_SHADOWMAP)
#if defined(USE_SHADOWS2)
uniform sampler2DArray u_ShadowMap;
#else
uniform sampler2DArrayShadow u_ShadowMap;
#endif
#endif

#if defined(USE_SSAO)
uniform sampler2D u_SSAOMap;
#endif

#if defined(USE_DSHADOWS)
uniform sampler2DArrayShadow u_ShadowMap2;
#endif

#if defined(USE_CUBEMAP)
uniform samplerCube u_CubeMap;
uniform sampler2D u_EnvBrdfMap;
#elif defined(USE_SSR)
uniform sampler2D u_EnvBrdfMap;
#endif
#if defined(USE_DIFFUSE_IBL) && defined(USE_LIGHT_VECTOR)
uniform samplerCube u_DiffuseIrradianceMap;
uniform sampler2D u_ProbeAverageMap;
// x = blend, y = debug mode, z = zero-based probe index, w = valid probe
uniform vec4 u_DiffuseIBLParams;
#endif
#endif

// x = glow out, y = deluxe, z = screen shadow, w = cube
uniform vec4 u_EnableTextures;
// rgb = linear scale; |w| = 0 disabled, 1 explicit, 2 auto source; sign = legacy/linear scene
uniform vec4 u_EmissiveParams;

uniform vec4 u_NormalScale;
uniform vec4 u_SpecularScale;
// r_autoPBRDebug (tr_autopbr.cpp): rgb = material class / source color, a = 1 when on
uniform vec4 u_MaterialDebug;

#if defined(USE_WETNESS) && defined(PER_PIXEL_LIGHTING)
// rain wetness, tr_weather.cpp RB_WeatherWetnessBind
uniform sampler2D u_WeatherDepthMap; // static top-down rain occlusion depth (D16)
uniform mat4 u_WeatherMvp;
uniform vec4 u_WetnessParams;  // strength (< 0: excluded draw), roughness scale, darkening, normal flattening
uniform vec4 u_WetnessParams2; // depth bias, normal offset (world), debug view, split x
uniform vec4 u_WetnessParams3; // facing floor, physical porosity (0/1), material class, unused
uniform vec4 u_PuddleParams;   // coverage (0: off, < 0: excluded draw), roughness, slope min, slope max
uniform vec4 u_PuddleParams2;  // 1 / pattern scale (world)
uniform vec4 u_PuddleHeight;   // relief depth low, 1 / (high - low) (0: no usable height), softness, fill bias
#endif
// Runtime A/B for the standard PBR diffuse model: 0 = Lambert, 1 = Burley/Disney
uniform int u_DiffuseBRDF;
uniform float u_ParallaxBias;
#if defined(USE_PARALLAXMAP)
// tr_pom.cpp R_PomSetUniforms, docs/rend2-pom.md
uniform vec4 u_PomShadow;		// self shadow strength (0 = off), steps, start bias (depth), softness
uniform vec4 u_PomTraversal;	// adaptive steps (0 = legacy 16 + 8), min steps, max steps, binary steps
uniform vec4 u_PomLod;			// fade start, 1 / fade width (0 = no fade), self shadowed local lights (>= 256 all)
uniform vec4 u_PomDebug;		// frozen sun direction (0 = live), r_pomDebug view
#endif

#if defined(PER_PIXEL_LIGHTING) && defined(USE_CUBEMAP)
uniform vec4 u_CubeMapInfo;
#endif

#if defined(USE_ALPHA_TEST)
uniform int u_AlphaTestType;
#endif

in vec4 var_TexCoords;
in vec4 var_Color;

#if defined(PER_PIXEL_LIGHTING)
in vec4 var_Normal;
in vec4 var_Tangent;
in vec4 var_ViewDir;
in vec4 var_LightDir;
#else
in vec3 var_Position;
in vec3 var_Normal;
#endif

#if defined(USE_SILHOUETTE_POM)
in vec2 var_PomShell;
flat in float var_PomHeader;
// texture gradients of the material maps: the foot point derivatives of the
// shell fragment (the hit coordinate jumps at the displaced silhouette)
vec2 g_pomGradX;
vec2 g_pomGradY;
#endif

out vec4 out_Color;
out vec4 out_Glow;

vec3 EmissiveLinearToLegacyScene(in vec3 color)
{
	vec3 lo = 12.92 * color;
	vec3 hi = 1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055;
	return mix(lo, hi, greaterThanEqual(color, vec3(0.0031308)));
}

vec3 EmissiveLegacySceneToLinear(in vec3 color)
{
	color = max(color, vec3(0.0));
	vec3 lo = color * (1.0 / 12.92);
	vec3 hi = pow((color + vec3(0.055)) * (1.0 / 1.055), vec3(2.4));
	return mix(lo, hi, greaterThan(color, vec3(0.04045)));
}

#if defined(USE_SSR) || defined(USE_SSGI)
// Screen-space attachments of renderFbo (tr_screenspace.cpp): reflections
// (tr_ssr.cpp, ssr_*.glsl) and diffuse GI (tr_ssgi.cpp, ssgi_*.glsl). Only
// written by opaque stages, the others have them masked.
out vec4 out_SSRNormal;   // rg = octahedral world normal, b = roughness, a = SSR receiver
#if defined(USE_SSR)
out vec4 out_SSRSpecular; // rgb = sqrt(specular IBL weight)
out vec4 out_SSRCubemap;  // rgb = cubemap reflection added to out_Color, a = view depth
#endif
#if defined(USE_SSGI)
out vec4 out_SSGIAlbedo;   // rgb = sRGB encoded diffuse albedo, a = GI receiver
out vec4 out_SSGIRadiance; // rgb = linear GI source radiance, a = view depth

// diffuse lobe of the dynamic lights of this fragment (scene space), the
// view independent part of their outgoing radiance: bounced by the SSGI
vec3 g_ssgiDynamicDiffuse = vec3(0.0);
#endif

vec2 SSREncodeNormal(in vec3 n)
{
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	vec2 e = n.xy;
	if (n.z < 0.0)
		e = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
	return e * 0.5 + 0.5;
}

void SSRWriteNone(in vec3 worldPosition)
{
	float viewDepth = dot(worldPosition - u_ViewOrigin, normalize(u_ViewForward));
	out_SSRNormal = vec4(0.5, 0.5, 1.0, 0.0);
#if defined(USE_SSR)
	out_SSRSpecular = vec4(0.0);
	out_SSRCubemap = vec4(0.0, 0.0, 0.0, viewDepth);
#endif
#if defined(USE_SSGI)
	out_SSGIAlbedo = vec4(0.0);
	out_SSGIRadiance = vec4(0.0, 0.0, 0.0, viewDepth);
#endif
}
#endif

#if defined(USE_SSGI)
// GI receiver: normal and diffuse albedo (after the metalness split: metals
// have no diffuse lobe), stored sRGB encoded for 8 bit precision
void SSGIWriteReceiver(in vec3 N, in float roughness, in vec3 albedo)
{
  #if !(defined(USE_SSR) && defined(PER_PIXEL_LIGHTING) && defined(USE_SPECULARMAP))
	out_SSRNormal = vec4(SSREncodeNormal(N), roughness, 0.0);
  #endif
	albedo = clamp(albedo, 0.0, 1.0);
	if (u_SSGIParams.y > 0.5)
		albedo = EmissiveLinearToLegacyScene(albedo);
	out_SSGIAlbedo = vec4(albedo, 1.0);
}

// GI source radiance, linear HDR. litColor = the stage color before its own
// emission, in scene space.
void SSGIWriteRadiance(in vec3 litColor, in vec3 emissiveLinear, in vec3 stageColor)
{
	int bits = int(u_SSGIParams.x);
	bool linearScene = u_SSGIParams.y > 0.5;
	vec3 radiance = vec3(0.0);
	if ((bits & 1) != 0)
	{
		// the linear share of the dynamic diffuse light in the stored color
		vec3 d = g_ssgiDynamicDiffuse;
		radiance += linearScene ? d : max(
			EmissiveLegacySceneToLinear(litColor) - EmissiveLegacySceneToLinear(litColor - d), vec3(0.0));
	}
	if ((bits & 2) != 0)
		radiance += emissiveLinear * u_SSGIParams.z;
	if ((bits & 4) != 0 && (u_EnableTextures.x > 0.5 || abs(u_EmissiveParams.w) == 2.0))
	{
		// legacy glow / auto emissive: the whole stage color, no physical intensity
		radiance += (linearScene ? max(stageColor, vec3(0.0)) : EmissiveLegacySceneToLinear(stageColor)) *
			u_SSGIParams.w;
	}
	out_SSGIRadiance.rgb = radiance;
}
#endif

#if defined(USE_SHADOWMAP) && defined(PER_PIXEL_LIGHTING)
// Legacy depth is GL_DEPTH_COMPONENT16; modern raw depth is 24-bit.
#define DEPTH_MAX_ERROR 0.0000152587890625

#if defined(USE_SHADOWS2)

struct SunCascadeResult
{
	float visibility;
	float rawDepth;
	float fixedPcf;
	float blockerDepth;
	float penumbraWorld;
	float biasWorld;
	float cascade;
};

float ShadowCascadeValue(in vec4 v, in int cascade)
{
	return cascade == 0 ? v.x : (cascade == 1 ? v.y : v.z);
}

vec3 ShadowProject(in mat4 m, in vec3 p)
{
	vec4 q = m * vec4(p, 1.0);
	return q.xyz / q.w * 0.5 + 0.5;
}

// dz / d(shadow uv), solved from screen-space derivatives. Calls are made
// before cascade-dependent branches so derivatives remain well-defined.
vec2 ShadowReceiverGradient(in vec3 shadowPos)
{
	vec2 uvDx = dFdx(shadowPos.xy);
	vec2 uvDy = dFdy(shadowPos.xy);
	float zDx = dFdx(shadowPos.z);
	float zDy = dFdy(shadowPos.z);
	float det = uvDx.x * uvDy.y - uvDx.y * uvDy.x;
	if (abs(det) < 1e-10)
		return vec2(0.0);
	return vec2(zDx * uvDy.y - zDy * uvDx.y,
		uvDx.x * zDy - zDx * uvDy.x) / det;
}

float ShadowRawDepth(in int cascade, in vec2 uv)
{
	ivec2 size = textureSize(u_ShadowMap, 0).xy;
	ivec2 p = clamp(ivec2(uv * vec2(size)), ivec2(0), size - ivec2(1));
	return texelFetch(u_ShadowMap, ivec3(p, cascade), 0).r;
}

float ShadowReceiverDepth(in float centerDepth, in vec2 gradient,
	in vec2 uvOffset, in float depthSpan)
{
	float correction = dot(gradient, uvOffset) * u_ShadowBias.z;
	float correctionClamp = u_ShadowBias.w / max(depthSpan, 1e-5);
	correction = clamp(correction, -correctionClamp, correctionClamp);
	return centerDepth + correction - u_ShadowBias.x / max(depthSpan, 1e-5);
}

float ShadowStableAngle(in vec3 worldPosition)
{
	vec3 cell = floor(worldPosition * 0.25);
	float h = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	return h * 6.28318530718;
}

vec2 ShadowVogel(in int sampleIndex, in int sampleCount, in float angleOffset)
{
	float i = float(sampleIndex) + 0.5;
	float r = sqrt(i / float(sampleCount));
	float a = i * 2.39996322973 + angleOffset;
	return vec2(cos(a), sin(a)) * r;
}

void ShadowSampleCounts(out int blockerSamples, out int filterSamples)
{
	int quality = int(u_ShadowPcss.w + 0.5);
	if (quality <= 0)
	{
		blockerSamples = 8;
		filterSamples = 8;
	}
	else if (quality == 1)
	{
		blockerSamples = 12;
		filterSamples = 16;
	}
	else
	{
		blockerSamples = 24;
		filterSamples = 32;
	}
}

float ShadowManualPcf(in int cascade, in vec3 shadowPos,
	in vec2 receiverGradient, in float depthSpan, in float radiusUv,
	in int sampleCount, in float angle)
{
	float visibility = 0.0;
	for (int i = 0; i < 32; ++i)
	{
		if (i >= sampleCount)
			break;
		vec2 offset = i == 0 ? vec2(0.0) :
			ShadowVogel(i - 1, sampleCount - 1, angle) * radiusUv;
		float receiver = ShadowReceiverDepth(shadowPos.z, receiverGradient, offset, depthSpan);
		visibility += receiver <= ShadowRawDepth(cascade, shadowPos.xy + offset) ? 1.0 : 0.0;
	}
	return visibility / float(sampleCount);
}

SunCascadeResult EvaluateSunCascade(in mat4 shadowMvp, in int cascade,
	in vec3 worldPosition, in vec3 geometricNormal, in float normalLight,
	in vec2 receiverGradient)
{
	SunCascadeResult result;
	float worldTexel = ShadowCascadeValue(u_ShadowTexelSize, cascade);
	float depthSpan = ShadowCascadeValue(u_ShadowDepthSpan, cascade);
	float normalOffset = worldTexel * u_ShadowBias.y * (1.0 - normalLight);
	vec3 shadowPos = ShadowProject(shadowMvp, worldPosition + geometricNormal * normalOffset);

	result.visibility = 1.0;
	result.rawDepth = 1.0;
	result.fixedPcf = 1.0;
	result.blockerDepth = 1.0;
	result.penumbraWorld = 0.0;
	result.biasWorld = u_ShadowBias.x + normalOffset;
	result.cascade = float(cascade);

	if (any(lessThan(shadowPos, vec3(0.0))) || any(greaterThan(shadowPos, vec3(1.0))))
		return result;

	int debugMode = int(u_ShadowDebug.x + 0.5);
	if (debugMode == 1 || debugMode == 7 || debugMode == 9)
		return result;
	if (debugMode == 2)
	{
		result.rawDepth = ShadowRawDepth(cascade, shadowPos.xy);
		return result;
	}

	float angle = ShadowStableAngle(worldPosition);
	int blockerSamples, filterSamples;
	ShadowSampleCounts(blockerSamples, filterSamples);
	float uvPerWorld = u_ShadowTexelSize.w / max(worldTexel, 1e-5);
	float fixedRadiusUv = 1.5 * u_ShadowTexelSize.w;
	bool pcssEnabled = u_ShadowPcss.z >= 0.5 && u_ShadowPcss.x > 0.0 && u_ShadowPcss.y > 0.0;

	if (debugMode == 3 || !pcssEnabled)
		result.fixedPcf = ShadowManualPcf(cascade, shadowPos, receiverGradient,
			depthSpan, fixedRadiusUv, filterSamples, angle);
	if (debugMode == 3)
	{
		result.visibility = result.fixedPcf;
		return result;
	}

	if (!pcssEnabled)
	{
		result.visibility = result.fixedPcf;
		return result;
	}

	// A directional light has no finite light-plane distance. Search in the
	// largest permitted receiver-space penumbra instead, which keeps the
	// meaning identical in every cascade.
	float searchWorld = max(2.0 * worldTexel, u_ShadowPcss.y);
	float searchRadiusUv = searchWorld * uvPerWorld;
	float blockerSum = 0.0;
	float blockerCount = 0.0;
	for (int i = 0; i < 24; ++i)
	{
		if (i >= blockerSamples)
			break;
		vec2 offset = i == 0 ? vec2(0.0) :
			ShadowVogel(i - 1, blockerSamples - 1, angle) * searchRadiusUv;
		float receiver = ShadowReceiverDepth(shadowPos.z, receiverGradient, offset, depthSpan);
		float sampleDepth = ShadowRawDepth(cascade, shadowPos.xy + offset);
		if (sampleDepth < receiver)
		{
			blockerSum += sampleDepth;
			blockerCount += 1.0;
		}
	}

	if (blockerCount < 0.5)
		return result;

	result.blockerDepth = blockerSum / blockerCount;
	float separationWorld = max((shadowPos.z - result.blockerDepth) * depthSpan, 0.0);
	result.penumbraWorld = min(separationWorld * u_ShadowPcss.x, u_ShadowPcss.y);
	if (debugMode == 4 || debugMode == 5)
		return result;
	float filterRadiusUv = max(0.5 * u_ShadowTexelSize.w,
		result.penumbraWorld * uvPerWorld);
	result.visibility = ShadowManualPcf(cascade, shadowPos, receiverGradient,
		depthSpan, filterRadiusUv, filterSamples, angle);
	return result;
}

SunCascadeResult MixSunCascadeResults(in SunCascadeResult a,
	in SunCascadeResult b, in float t)
{
	SunCascadeResult r;
	r.visibility = mix(a.visibility, b.visibility, t);
	r.rawDepth = mix(a.rawDepth, b.rawDepth, t);
	r.fixedPcf = mix(a.fixedPcf, b.fixedPcf, t);
	r.blockerDepth = mix(a.blockerDepth, b.blockerDepth, t);
	r.penumbraWorld = mix(a.penumbraWorld, b.penumbraWorld, t);
	r.biasWorld = mix(a.biasWorld, b.biasWorld, t);
	r.cascade = mix(a.cascade, b.cascade, t);
	return r;
}

SunCascadeResult sunShadowModern(in vec3 worldPosition,
	in vec3 geometricNormal, in float normalLight)
{
	vec3 base0 = ShadowProject(u_ShadowMvp, worldPosition);
	vec3 base1 = ShadowProject(u_ShadowMvp2, worldPosition);
	vec3 base2 = ShadowProject(u_ShadowMvp3, worldPosition);
	vec2 gradient0 = ShadowReceiverGradient(base0);
	vec2 gradient1 = ShadowReceiverGradient(base1);
	vec2 gradient2 = ShadowReceiverGradient(base2);

	float viewDepth = dot(worldPosition - u_ViewOrigin, normalize(u_ViewForward));
	float split0 = u_ShadowSplits.x;
	float split1 = u_ShadowSplits.y;
	float half0 = u_ShadowBlend.x;
	float half1 = u_ShadowBlend.y;
	SunCascadeResult result;

	if (half0 > 0.0 && viewDepth >= split0 - half0 && viewDepth <= split0 + half0)
	{
		SunCascadeResult a = EvaluateSunCascade(u_ShadowMvp, 0, worldPosition,
			geometricNormal, normalLight, gradient0);
		SunCascadeResult b = EvaluateSunCascade(u_ShadowMvp2, 1, worldPosition,
			geometricNormal, normalLight, gradient1);
		float t = smoothstep(split0 - half0, split0 + half0, viewDepth);
		result = MixSunCascadeResults(a, b, t);
	}
	else if (viewDepth < split0)
	{
		result = EvaluateSunCascade(u_ShadowMvp, 0, worldPosition,
			geometricNormal, normalLight, gradient0);
	}
	else if (half1 > 0.0 && viewDepth >= split1 - half1 && viewDepth <= split1 + half1)
	{
		SunCascadeResult a = EvaluateSunCascade(u_ShadowMvp2, 1, worldPosition,
			geometricNormal, normalLight, gradient1);
		SunCascadeResult b = EvaluateSunCascade(u_ShadowMvp3, 2, worldPosition,
			geometricNormal, normalLight, gradient2);
		float t = smoothstep(split1 - half1, split1 + half1, viewDepth);
		result = MixSunCascadeResults(a, b, t);
	}
	else if (viewDepth < split1)
	{
		result = EvaluateSunCascade(u_ShadowMvp2, 1, worldPosition,
			geometricNormal, normalLight, gradient1);
	}
	else
	{
		result = EvaluateSunCascade(u_ShadowMvp3, 2, worldPosition,
			geometricNormal, normalLight, gradient2);
	}

	float farFade = smoothstep(u_ShadowSplits.w, u_ShadowSplits.z, viewDepth);
	result.visibility = mix(result.visibility, 1.0, farFade);
	return result;
}

#else

// Input: It uses texture coords as the random number seed.
// Output: Random number: [0,1), that is between 0.0 and 0.999999... inclusive.
// Author: Michael Pohoreski
// Copyright: Copyleft 2012 :-)
// Source: http://stackoverflow.com/questions/5149544/can-i-generate-a-random-number-inside-a-pixel-shader

float random( const vec2 p )
{
  // We need irrationals for pseudo randomness.
  // Most (all?) known transcendental numbers will (generally) work.
  const vec2 r = vec2(
    23.1406926327792690,  // e^pi (Gelfond's constant)
     2.6651441426902251); // 2^sqrt(2) (Gelfond-Schneider constant)
  //return fract( cos( mod( 123456789., 1e-7 + 256. * dot(p,r) ) ) );
  return mod( 123456789., 1e-7 + 256. * dot(p,r) );
}

const vec2 poissonDisk[16] = vec2[16](
	vec2( -0.94201624, -0.39906216 ),
	vec2( 0.94558609, -0.76890725 ),
	vec2( -0.094184101, -0.92938870 ),
	vec2( 0.34495938, 0.29387760 ),
	vec2( -0.91588581, 0.45771432 ),
	vec2( -0.81544232, -0.87912464 ),
	vec2( -0.38277543, 0.27676845 ),
	vec2( 0.97484398, 0.75648379 ),
	vec2( 0.44323325, -0.97511554 ),
	vec2( 0.53742981, -0.47373420 ),
	vec2( -0.26496911, -0.41893023 ),
	vec2( 0.79197514, 0.19090188 ),
	vec2( -0.24188840, 0.99706507 ),
	vec2( -0.81409955, 0.91437590 ),
	vec2( 0.19984126, 0.78641367 ),
	vec2( 0.14383161, -0.14100790 )
);

float PCF(const sampler2DArrayShadow shadowmap, const float layer, const vec2 st, const float dist, float PCFScale)
{
	float mult;
	float scale = PCFScale / r_shadowMapSize;

#if defined(USE_SHADOW_FILTER)
	float r = random(gl_FragCoord.xy / r_FBufScale);
	float sinr = sin(r);
	float cosr = cos(r);
	mat2 rmat = mat2(cosr, sinr, -sinr, cosr) * scale;

	mult =  texture(shadowmap, vec4(st + rmat * vec2(-0.7055767, 0.196515), layer, dist));
	mult += texture(shadowmap, vec4(st + rmat * vec2(0.3524343, -0.7791386), layer, dist));
	mult += texture(shadowmap, vec4(st + rmat * vec2(0.2391056, 0.9189604), layer, dist));
  #if defined(USE_SHADOW_FILTER2)
	mult += texture(shadowmap, vec4(st + rmat * vec2(-0.07580382, -0.09224417), layer, dist));
	mult += texture(shadowmap, vec4(st + rmat * vec2(0.5784913, -0.002528916), layer, dist));
	mult += texture(shadowmap, vec4(st + rmat * vec2(0.192888, 0.4064181), layer, dist));
	mult += texture(shadowmap, vec4(st + rmat * vec2(-0.6335801, -0.5247476), layer, dist));
	mult += texture(shadowmap, vec4(st + rmat * vec2(-0.5579782, 0.7491854), layer, dist));
	mult += texture(shadowmap, vec4(st + rmat * vec2(0.7320465, 0.6317794), layer, dist));

	mult *= 0.11111;
  #else
    mult *= 0.33333;
  #endif
#else
	float r = random(gl_FragCoord.xy / r_FBufScale);
	float sinr = sin(r);
	float cosr = cos(r);
	mat2 rmat = mat2(cosr, sinr, -sinr, cosr) * scale;

	mult =  texture(shadowmap, vec4(st, layer, dist));
	for (int i = 0; i < 16; i++)
	{
		vec2 delta = rmat * poissonDisk[i];
		mult += texture(shadowmap, vec4(st + delta, layer, dist));
	}
	mult *= 1.0 / 17.0;
#endif

	return mult;
}

float sunShadow(in vec3 viewOrigin, in vec3 viewDir, in vec3 biasOffset, in sampler2DArrayShadow shadowMapCascades)
{
	vec4 biasPos = vec4(viewOrigin - viewDir + biasOffset, 1.0);
	float cameraDistance = length(viewDir);

	const float PCFScale = 1.5;
	const float edgeBias = 0.5 - ( 4.0 * PCFScale / r_shadowMapSize );
	float edgefactor = 0.0;
	const float fadeTo = 1.0;
	float result = 1.0;

	vec4 shadowpos = u_ShadowMvp * biasPos;
	shadowpos.xyz = shadowpos.xyz / shadowpos.w * 0.5 + 0.5;
	if (all(lessThanEqual(abs(shadowpos.xyz - vec3(0.5)), vec3(edgeBias))))
	{
		vec3 dCoords = smoothstep(0.3, 0.45, abs(shadowpos.xyz - vec3(0.5)));
		edgefactor = 2.0 * PCFScale * clamp(dCoords.x + dCoords.y + dCoords.z, 0.0, 1.0);
		result = PCF(shadowMapCascades,
					 0.0,
					 shadowpos.xy,
					 shadowpos.z,
					 PCFScale + edgefactor);
	}
	else
	{
		shadowpos = u_ShadowMvp2 * (biasPos + vec4(biasOffset, 0.0));
		shadowpos.xyz = shadowpos.xyz / shadowpos.w * 0.5 + 0.5;
		if (all(lessThanEqual(abs(shadowpos.xyz - vec3(0.5)), vec3(edgeBias))))
		{
			vec3 dCoords = smoothstep(0.3, 0.45, abs(shadowpos.xyz - vec3(0.5)));
			edgefactor = 0.5 * PCFScale * clamp(dCoords.x + dCoords.y + dCoords.z, 0.0, 1.0);
			result = PCF(shadowMapCascades,
						 1.0,
						 shadowpos.xy,
						 shadowpos.z,
						 PCFScale + edgefactor);
		}
		else
		{
			shadowpos = u_ShadowMvp3 * (biasPos + vec4(biasOffset, 0.0));
			shadowpos.xyz = shadowpos.xyz / shadowpos.w * 0.5 + 0.5;
			if (all(lessThanEqual(abs(shadowpos.xyz - vec3(0.5)), vec3(1.0))))
			{
				result = PCF(shadowMapCascades,
							 2.0,
							 shadowpos.xy,
							 shadowpos.z,
							 PCFScale);
				float fade = clamp(cameraDistance / r_shadowCascadeZFar * 10.0 - 9.0, 0.0, 1.0);
				result = mix(result, fadeTo, fade);
			}
		}
	}

	return result;
}
#endif
#endif

#if defined(USE_PARALLAXMAP)
#define POM_VIEW_MAX_LINEAR_STEPS 64
#define POM_VIEW_MAX_BINARY_STEPS 16
#define POM_SHADOW_MAX_STEPS 32

// State of the POM view ray hit of this fragment, shared by the self shadow
// rays of every light (GetPomSelfShadow). Filled by GetParallaxOffset or, for
// silhouette POM shells, by PomSilhouetteFragment. Height convention: the red
// channel of the normalHeightMap is the flipped height (tr_image.cpp), i.e. the
// depth s in [0, 1] below the top of the relief, 0 = top.
struct PomSurface
{
	bool  valid;
	vec2  uv;			// hit texture coordinate
	float depth;		// hit depth s
	vec3  T, B, N;		// world frame the relief is extruded along (N = up)
	vec2  scale;		// texture units per unit of s per unit of tangent slope: aspect * parallaxDepth
	vec2  gradX, gradY;	// texture gradients for every height sample
	float fade;			// distance fade, 1 = full POM
	float viewSamples;
	float shadowSamples;
};
PomSurface g_pom;
float g_pomLightWeight = 0.0;	// self shadow weight of the dynamic light being evaluated
float g_pomLocalShadow = 1.0;	// r_pomDebug 5: darkest local light self shadow

// The one reading of the material height field, shared by POM and the height
// aware puddles: the normalHeightMap alpha is flipped on load (R_FindImageFile)
// and swizzled into red (RawImage_SwizzleRA), so this is the depth below the
// top of the relief, 0 = highest point, 1 = deepest (pom_silhouette.glsl
// PomSampleDepth is the same).
float SampleMaterialDepth(in sampler2D normalMap, in vec2 uv, in vec2 gradX, in vec2 gradY)
{
	return textureGrad(normalMap, uv, gradX, gradY).r;
}

// r_pomFadeStart / r_pomFadeEnd: 1 near, 0 beyond the end (normal mapping)
float PomDistanceFade(in float viewDistance)
{
	if (u_PomLod.y <= 0.0)
		return 1.0;
	return 1.0 - clamp((viewDistance - u_PomLod.x) * u_PomLod.y, 0.0, 1.0);
}

// ordinary POM: tangent frame of the vertex shader tangentViewDir, which
// includes the normal map aspect correction
void PomInitSurface(in vec2 texCoords, in vec2 dx, in vec2 dy, in float fade)
{
	g_pom.valid = false;
	g_pom.uv = texCoords;
	g_pom.depth = 0.0;
	g_pom.N = normalize(var_Normal.xyz);
	g_pom.T = normalize(var_Tangent.xyz);
	g_pom.B = cross(g_pom.N, g_pom.T) * var_Tangent.w;
	vec2 normalSize = vec2(textureSize(u_NormalMap, 0));
	float normalMapAspect = normalSize.y / normalSize.x;
	vec2 aspect = vec2(max(1.0, normalMapAspect), max(1.0, 1.0 / normalMapAspect));
	g_pom.scale = aspect * (u_NormalScale.a * fade);
	g_pom.gradX = dx;
	g_pom.gradY = dy;
	g_pom.fade = fade;
	g_pom.viewSamples = 0.0;
	g_pom.shadowSamples = 0.0;
}

// linearSearchSteps / binarySearchSteps: 16 / 8 is the legacy traversal
float RayIntersectDisplaceMap(in vec2 inDp, in vec2 ds, in sampler2D normalMap, in float parallaxBias,
	in int linearSearchSteps, in int binarySearchSteps, in vec2 dx, in vec2 dy)
{
	vec2 dp = fract(inDp - parallaxBias * ds);

	// current size of search window
	float size = 1.0 / float(linearSearchSteps);

	// current depth position
	float depth = 0.0;

	// best match found (starts with last position 1.0)
	float bestDepth = 1.0;

	// try sampling at least one border pixel
	vec2 tMin = (vec2(0.0) - dp) / ds;
	vec2 tMax = (vec2(1.0) - dp) / ds;
	vec2 t = max(tMin, tMax);
	float tExit  = min(t.x, t.y);
	float stepFraction = fract(tExit / size) * size;
	depth -= size-stepFraction;

	// search front to back for first point inside object
	for(int i = 0; i < POM_VIEW_MAX_LINEAR_STEPS; ++i)
	{
		if (i >= linearSearchSteps)
			break;
		depth += size;

		// height is flipped before uploaded to the gpu
		float t = SampleMaterialDepth(normalMap, dp + ds * depth, dx, dy);
		g_pom.viewSamples += 1.0;

		if(depth >= t)
		{
			bestDepth = depth;	// store best depth
			break;
		}
	}

	depth = bestDepth;

	// recurse around first point (depth) for closest match
	for(int i = 0; i < POM_VIEW_MAX_BINARY_STEPS; ++i)
	{
		if (i >= binarySearchSteps)
			break;
		size *= 0.5;

		// height is flipped before uploaded to the gpu
		float t = SampleMaterialDepth(normalMap, dp + ds * depth, dx, dy);

		if(depth >= t)
		{
			bestDepth = depth;
			depth -= 2.0 * size;
		}

		depth += size;
	}
	g_pom.viewSamples += float(binarySearchSteps) + 2.0;

	float beforeDepth = SampleMaterialDepth(normalMap, dp + ds * (depth-size), dx, dy) - depth + size;
	float afterDepth  = SampleMaterialDepth(normalMap, dp + ds * depth, dx, dy) - depth;
	float deltaDepth = beforeDepth - afterDepth;
	float weight = mix(0.0, beforeDepth / deltaDepth , deltaDepth > 0);
	bestDepth += weight*size;

	// the virtual hit, for the self shadow rays
	g_pom.uv = dp + ds * bestDepth;
	g_pom.depth = bestDepth;

	return bestDepth - parallaxBias;
}

// Self shadowing of direct light by the relief (r_pomSelfShadow): marches
// from the view ray hit towards the light, L = world direction towards the
// light (normalized). Soft visibility from the deepest occluder penetration
// along the ray, nearer occluders count more. 1 = lit. Only for direct light:
// the callers multiply the sun shadow and the dynamic light attenuation,
// never ambient, lightmap ambient, IBL, SSR, SSGI or emissive.
// Compiled only with r_pomSelfShadow set at renderer start
// (USE_POM_SELFSHADOW): the rays are inlined at every call site.
float GetPomSelfShadow(in vec3 L)
{
#if !defined(USE_POM_SELFSHADOW)
	return 1.0;
#else
	float strength = clamp(u_PomShadow.x, 0.0, 1.0) * g_pom.fade;
	if (!g_pom.valid || strength <= 0.0)
		return 1.0;

	vec3 Lt = vec3(dot(L, g_pom.T), dot(L, g_pom.B), dot(L, g_pom.N));
	// towards the base plane every ray ends in the relief: fade to full
	// shadow below 3 degrees instead of marching nearly horizontal rays
	const float minElevation = 0.05;
	float horizon = clamp(Lt.z / minElevation, 0.0, 1.0);
	float visibility = 0.0;
	float s0 = g_pom.depth - u_PomShadow.z;
	if (horizon > 0.0)
	{
		visibility = 1.0;
		if (s0 > 0.0)
		{
			// texture offset per unit of s climbed towards the light
			vec2 duv = Lt.xy / max(Lt.z, minElevation) * g_pom.scale;
			int steps = int(u_PomShadow.y);
			float invSteps = 1.0 / float(steps);
			float occlusion = 0.0;
			for (int i = 0; i < POM_SHADOW_MAX_STEPS; i++)
			{
				if (i >= steps || occlusion >= 1.0)
					break;
				float f = (float(i) + 0.5) * invSteps;
				float s = s0 * (1.0 - f);
				// height is flipped before uploaded to the gpu
				float h = SampleMaterialDepth(u_NormalMap, g_pom.uv + duv * (g_pom.depth - s), g_pom.gradX, g_pom.gradY);
				g_pom.shadowSamples += 1.0;
				occlusion = max(occlusion, (s - h) * u_PomShadow.w * (1.0 - f));
			}
			visibility = 1.0 - clamp(occlusion, 0.0, 1.0);
		}
		visibility *= horizon;
	}
	return mix(1.0, visibility, strength);
#endif
}

// r_pomDebugFreezeLight keeps the sun direction of the moment it was set
vec3 PomSunDirection(in vec3 primaryLightDir)
{
	return dot(u_PomDebug.xyz, u_PomDebug.xyz) > 0.0 ? normalize(u_PomDebug.xyz) : primaryLightDir;
}

vec3 PomDebugHeat(in float x)
{
	x = clamp(x, 0.0, 1.0);
	return clamp(vec3(1.5 - abs(4.0 * x - 3.0), 1.5 - abs(4.0 * x - 2.0), 1.5 - abs(4.0 * x - 1.0)), 0.0, 1.0);
}
#endif

vec2 GetParallaxOffset(in vec2 texCoords, in vec3 tangentDir)
{
#if defined(USE_PARALLAXMAP)
	vec2 dx = dFdx(texCoords);
	vec2 dy = dFdy(texCoords);
	float fade = PomDistanceFade(length(var_ViewDir.xyz));
	PomInitSurface(texCoords, dx, dy, fade);
	if (fade <= 0.0)
		return vec2(0.0);

	vec3 offsetDir = normalize(tangentDir);

	// r_pomAdaptiveSteps: more linear steps towards grazing angles, fewer
	// with the distance fade; off = the legacy 16 + 8 traversal
	int linearSteps = 16;
	int binarySteps = 8;
	if (u_PomTraversal.x > 0.0)
	{
		float grazing = 1.0 - abs(offsetDir.z);
		float steps = mix(u_PomTraversal.y, u_PomTraversal.z, grazing);
		steps = mix(min(4.0, steps), steps, fade);
		linearSteps = int(steps + 0.5);
		binarySteps = int(u_PomTraversal.w);
	}

	offsetDir.xy *= -u_NormalScale.a / offsetDir.z;
	offsetDir.xy *= fade;

	vec2 offset = offsetDir.xy * RayIntersectDisplaceMap(texCoords, offsetDir.xy, u_NormalMap, u_ParallaxBias,
		linearSteps, binarySteps, dx, dy);
	g_pom.valid = true;
	return offset;
#else
	return vec2(0.0);
#endif
}

float D_Charlie(in float a, in float NH)
{
	// Estevez and Kulla 2017, "Production Friendly Microfacet Sheen BRDF"
	float invAlpha = 1.0 / a;
	float cos2h = NH * NH;
	float sin2h = max(1.0 - cos2h, 0.0078125); // 2^(-14/2), so sin2h^2 > 0 in fp16
	return (2.0 + invAlpha) * pow(sin2h, invAlpha * 0.5) / (2.0 * M_PI);
}

float V_Neubelt(in float NV, in float NL)
{
	// Neubelt and Pettineo 2013, "Crafting a Next-gen Material Pipeline for The Order: 1886"
	return 1.0 / (4.0 * (NL + NV - NL * NV));
}

float D_Ashikhmin(float roughness, float nh){
                float a2 = roughness * roughness;
                float cos2h = nh * nh ;
                float sin2h = max(1.0 - cos2h, 0.0078125); // 2^(-14/2), so sin2h^2 > 0 in fp16
	            float sin4h = sin2h * sin2h;
                float cot2 = -cos2h / (a2 * sin2h);
	            return 1.0 / (M_PI * (4.0 * a2 + 1.0) * sin4h) * (4.0 * exp(cot2) + sin4h);

            }

vec3 Specular_CharlieSheen(float Roughness, float NoH, float NoV, float NoL, vec3 SpecularColor, float cloth)
{
	float D = cloth > 0.f ? D_Ashikhmin(Roughness, NoH) : D_Charlie(Roughness, NoH);

	return (D * V_Neubelt(NoV, NoL)) * SpecularColor; //No fresnel in the documentation.
}

vec3 Fresnel_Schlick(const vec3 f0, float f90, float VoH)
{
	// Schlick 1994, "An Inexpensive BRDF Model for Physically-Based Rendering"
	return f0 + (f90 - f0) * pow(1.0 - VoH, 5.f);
}

vec3 Diff_Burley(float roughness, float NoV, float NoL, float LoH)
{
	// Burley 2012, "Physically-Based Shading at Disney"
	float f90 = 0.5 + 2.0 * roughness * LoH * LoH;
	vec3 lightScatter = Fresnel_Schlick(vec3(1.0), f90, NoL);
	vec3 viewScatter = Fresnel_Schlick(vec3(1.0), f90, NoV);
	return lightScatter * viewScatter * (1.0 / M_PI);
}

vec3 F_Schlick(in vec3 SpecularColor, in float VH)
{
	float Fc = pow(1 - VH, 5);
	return clamp(50.0 * SpecularColor.g, 0.0, 1.0) * Fc + (1 - Fc) * SpecularColor; //hacky way to decide if reflectivity is too low (< 2%)
}

float D_GGX( in float NH, in float a )
{
	/*float alphaSq = roughness*roughness;
	float f = (NH * alphaSq - NH) * NH + 1.0;
	return alphaSq / (f * f);*/

	float a2 = a * a;
	float d = (NH * a2 - NH) * NH + 1;
	return a2 / (M_PI * d * d);
}

// Appoximation of joint Smith term for GGX
// [Heitz 2014, "Understanding the Masking-Shadowing Function in Microfacet-Based BRDFs"]
float V_SmithJointApprox(in float a, in float NV, in float NL)
{
	float Vis_SmithV = NL * (NV * (1 - a) + a);
	float Vis_SmithL = NV * (NL * (1 - a) + a);
	return 0.5 * (1.0 / (Vis_SmithV + Vis_SmithL));
}

float CalcVisibility(in float NL, in float NE, in float roughness)
{
	float alphaSq = roughness * roughness;

	float lambdaE = NL * sqrt((-NE * alphaSq + NE) * NE + alphaSq);
	float lambdaL = NE * sqrt((-NL * alphaSq + NL) * NL + alphaSq);

	return 0.5 / (lambdaE + lambdaL);
}

// http://www.frostbite.com/2014/11/moving-frostbite-to-pbr/
vec3 CalcSpecular(
	in vec3 specular,
	in float NH,
	in float NL,
	in float NE,
	in float LH,
	in float VH,
	in float roughness
)
{
	//Using #if to define our BRDF's is a good idea.
#if !defined(USE_CLOTH_BRDF) //should define this as the base BRDF
	vec3  F = F_Schlick(specular, VH);
	float D = D_GGX(NH, roughness);
	float V = V_SmithJointApprox(roughness, NE, NL);
#else //and define this as the cloth BRDF
	//this cloth model essentially uses the metallic input to help transition from isotropic to anisotropic reflections.
	//as cloth is a microfibre structure, cloth like velevet and silk tends to have anisotropy.
	vec3 F = specular; //this shading model omits fresnel
	float D = D_Charlie(roughness, NH);
	float V = V_Neubelt(NE, NL);
#endif

	return D * F * V;
}

//Energy conserving wrap term.
float WrapLambert(in float NL, in float w)
{
	return clamp((NL + w) / pow(1.0 + w, 2.0), 0.0, 1.0);
}

vec3 Diffuse_Lambert(in vec3 DiffuseColor)
{
	return DiffuseColor * (1.0 / M_PI);
}

vec3 CalcDiffuse(
	in vec3 diffuse,
	in float NE,
	in float NL,
	in float LH,
	in float roughness
)
{
	//Using #if to define our diffuse's is a good idea.
#if !defined(USE_CLOTH_BRDF) //should define this as the base BRDF
	if (u_DiffuseBRDF == 1)
	{
		return diffuse * Diff_Burley(roughness, clamp(NE, 0.0, 1.0), NL, LH);
	}
	return Diffuse_Lambert(diffuse);
#else //and define this as the cloth diffuse
	//this cloth model has a wrapped diffuse, we can be energy conservant here.
	vec3 d = Diffuse_Lambert(diffuse);
	d *= WrapLambert(NL, 0.5);
	// Cheap subsurface scatter
	// ideally we should actually have a new colour for subsurface, but for cloth most times it makes sense to just use the diffuse.
	d *= clamp(diffuse + NL, 0.0, 1.0);
	return d;
#endif
}

float CalcLightAttenuation(float normDist)
{
	// zero light at 1.0, approximating q3 style
	float attenuation = 0.5 * normDist - 0.5;
	return clamp(attenuation, 0.0, 1.0);
}

#if defined(USE_DSHADOWS)
#define DEPTH_MAX_ERROR 0.0000152587890625

vec2 poissonDiscPolar[9] = vec2[9]
(
vec2(-0.7055767, 0.196515),    vec2(0.3524343, -0.7791386),
vec2(0.2391056, 0.9189604),    vec2(-0.07580382, -0.09224417),
vec2(0.5784913, -0.002528916), vec2(0.192888, 0.4064181),
vec2(-0.6335801, -0.5247476),  vec2(-0.5579782, 0.7491854),
vec2(0.7320465, 0.6317794)
);

// based on https://www.gamedev.net/forums/topic/687535-implementing-a-cube-map-lookup-function/5337472/
vec3 sampleCube(in vec3 v)
{
	vec3 vAbs = abs(v);
	float ma = 0.0;
	vec2 uv = vec2(0.0);
	float faceIndex = 0.0;
	if(vAbs.z >= vAbs.x && vAbs.z >= vAbs.y)
	{
		faceIndex = v.z < 0.0 ? 5.0 : 4.0;
		ma = 0.5 / vAbs.z;
		uv = vec2(v.z < 0.0 ? -v.x : v.x, -v.y);
	}
	else if(vAbs.y >= vAbs.x)
	{
		faceIndex = v.y < 0.0 ? 3.0 : 2.0;
		ma = 0.5 / vAbs.y;
		uv = vec2(v.x, v.y < 0.0 ? -v.z : v.z);
	}
	else
	{
		faceIndex = v.x < 0.0 ? 1.0 : 0.0;
		ma = 0.5 / vAbs.x;
		uv = vec2(v.x < 0.0 ? v.z : -v.z, -v.y);
	}
	return vec3(uv * ma + 0.5, faceIndex);
}

float pcfShadow(in sampler2DArrayShadow depthMap, in vec3 L, in float distance, in int lightId)
{
	const int samples = 9;
	const float diskRadius = M_PI / 512.0;

	vec2 polarL = vec2(atan(L.z, L.x), acos(L.y));
	float shadow = 0.0;

	for (int i = 0; i < samples; ++i)
	{
		vec2 samplePolar = poissonDiscPolar[i] * diskRadius + polarL;
		vec3 sampleVec = vec3(0.0);
		sampleVec.x = cos(samplePolar.x) * sin(samplePolar.y);
		sampleVec.z = sin(samplePolar.x) * sin(samplePolar.y);
		sampleVec.y = cos(samplePolar.y);

		vec3 lookup = sampleCube(sampleVec) + vec3(0.0, 0.0, lightId * 6.0);

		shadow += texture(depthMap, vec4(lookup, distance));
	}
	shadow /= float(samples);
	return shadow;
}

float getLightDepth(in vec3 Vec, in float f)
{
	vec3 AbsVec = abs(Vec);
	float Z = max(AbsVec.x, max(AbsVec.y, AbsVec.z));

	const float n = 1.0;

	float NormZComp = (f + n) / (f - n) - 2 * f*n / (Z* (f - n));

	return ((NormZComp + 1.0) * 0.5);
}
#endif

/*
Dynamic lights. EvaluateDynamicLight / EvaluateDynamicLightSimple are the one
place where the radiance of a single dynamic light is computed. The legacy loop
(u_LightMask bits over the Lights block) and the Forward+ loop (cluster light
list, tr_forwardplus.cpp) only differ in which lights they iterate.
*/

// Forward+: the cluster of this fragment and its light list
#define FPLUS_HARD_CAP 256		// guards the loop against corrupted counts
#define FPLUS_LIGHT_TEXELS 5

// area light types / flags, tr_local.h DLIGHT_* / AREALIGHT_*
#define FPLUS_TYPE_RECT 1.0
#define FPLUS_TYPE_LINE 2.0
#define AREALIGHT_TWO_SIDED     1
#define AREALIGHT_SPECULAR_ONLY 2
#define AREALIGHT_DYNAMIC       4
#define AREALIGHT_SELECTED      8

struct FPlusLight
{
	vec3  origin;		// area lights: centre
	float radius;		// area lights: influence range
	vec3  color;		// area lights: radiance
	float type;			// 0 = point, FPLUS_TYPE_*
	int   shadowSlot;	// < 0 = unshadowed
	int   flags;		// area lights: AREALIGHT_*
	float halfWidth;	// area lights: along right (line: half length)
	float halfHeight;	// area lights: along up (line: tube radius)
};

bool FPlusEnabled()
{
	return u_FPlusParams2.z > 0.0;
}

// must match R_ForwardPlusSlice (tr_forwardplus.cpp)
int FPlusSlice(in vec3 position)
{
	int numSlices = int(u_FPlusParams.y);
	if (numSlices <= 1)
		return 0;
	float depth = dot(position - u_ViewOrigin, normalize(u_ViewForward));
	if (depth <= u_FPlusParams2.w)
		return 0;
	return clamp(1 + int(floor(log(depth) * u_FPlusParams.z + u_FPlusParams.w)), 1, numSlices - 1);
}

ivec2 FPlusTile()
{
	ivec2 tile = ivec2((gl_FragCoord.xy - u_FPlusParams2.xy) / u_FPlusParams.x);
	return clamp(tile, ivec2(0), u_FPlusGrid.zw - ivec2(1));
}

int FPlusCluster(in vec3 position)
{
	ivec2 tile = FPlusTile();
	return (FPlusSlice(position) * u_FPlusGrid.w + tile.y) * u_FPlusGrid.z + tile.x;
}

// x = first entry in the index list, y = light count
ivec2 FPlusClusterLights(in vec3 position)
{
	uvec4 cell = texelFetch(u_FPlusGridMap, u_FPlusGrid.x + FPlusCluster(position));
	return ivec2(int(cell.x), min(int(cell.y), FPLUS_HARD_CAP));
}

int FPlusLightIndex(in int entry)
{
	return int(texelFetch(u_FPlusIndexMap, entry).x);
}

FPlusLight FPlusFetchLight(in int lightIndex)
{
	int base = u_FPlusGrid.y + lightIndex * FPLUS_LIGHT_TEXELS;
	vec4 t0 = texelFetch(u_FPlusLights, base);
	vec4 t1 = texelFetch(u_FPlusLights, base + 1);
	vec4 t2 = texelFetch(u_FPlusLights, base + 2);
	FPlusLight light;
	light.origin = t0.xyz;
	light.radius = t0.w;
	light.color = t1.rgb;
	light.type = t1.w;
	light.shadowSlot = int(t2.x);
	light.flags = int(t2.y);
	light.halfWidth = t2.z;
	light.halfHeight = t2.w;
	return light;
}

// r_forwardPlusDebug 6 / 7 / 9 only show some lights
// debug views are compiled only with r_forwardPlusDebug set at shader load
// (USE_FPLUS_DEBUG): in every lightall permutation they cost compile time
bool FPlusDebugSkipLight(in FPlusLight light, in int lightIndex)
{
#if !defined(USE_FPLUS_DEBUG)
	return false;
#else
	int mode = int(u_FPlusDebug.x);
	if (mode == 6)
		return light.shadowSlot < 0;
	if (mode == 7)
		return light.shadowSlot >= 0;
	if (mode == 9)
		return lightIndex != int(u_FPlusDebug.y);
	return false;
#endif
}

#if defined(PER_PIXEL_LIGHTING)
struct DLightSurface
{
	vec3  position;
	vec3  N;
	vec3  E;
	float NE;
	vec3  diffuse;
	vec3  specular;
	float roughness;
	vec3  vertexNormal;
};

// receiver side visibility of one light, 1 = not occluded: POM self
// shadowing (tr_pom.cpp) for the lights the budget picked, legacy and
// Forward+ alike; it scales the attenuation before the SSGI source is taken
float DynamicLightReceiverVisibility(in DLightSurface s, in vec3 L)
{
#if defined(USE_PARALLAXMAP)
	if (g_pomLightWeight > 0.0)
	{
		float visibility = mix(1.0, GetPomSelfShadow(L), g_pomLightWeight);
		g_pomLocalShadow = min(g_pomLocalShadow, visibility);
		return visibility;
	}
#endif
	return 1.0;
}

#if defined(USE_PARALLAXMAP)
// estimated contribution of a light at the receiver, for the self shadow budget
float PomLightImportance(in vec3 toLight, in vec3 lightColor, in float lightRadius)
{
	float attenuation = CalcLightAttenuation(lightRadius * lightRadius / max(dot(toLight, toLight), 1e-6));
	return dot(lightColor, vec3(0.2126, 0.7152, 0.0722)) * attenuation;
}

// r_pomSelfShadowLights 1 / 2: only the N strongest lights at this pixel get a
// self shadow ray. Returns the importance of the (N+1)-th strongest light; the
// weight of a light fades in between 1x and 1.5x of it, so the choice changes
// without pops. 0 = every light, < 0 = none.
float PomLocalLightCut(in vec3 position, in bool fplus, in ivec2 list)
{
#if !defined(USE_POM_SELFSHADOW)
	return -1.0;
#else
	int maxLights = int(u_PomLod.z);
	if (clamp(u_PomShadow.x, 0.0, 1.0) * g_pom.fade <= 0.0 || !g_pom.valid || maxLights <= 0)
		return -1.0;
	if (maxLights >= list.y)
		return 0.0;
	maxLights = min(maxLights, 4);

	float top[5] = float[5](0.0, 0.0, 0.0, 0.0, 0.0);
	for (int k = 0; k < list.y; k++)
	{
		vec3 lightOrigin, lightColor;
		float lightRadius;
		if (fplus)
		{
			FPlusLight light = FPlusFetchLight(FPlusLightIndex(list.x + k));
			if (light.type != 0.0)
				continue;
			lightOrigin = light.origin;
			lightColor = light.color;
			lightRadius = light.radius;
		}
		else
		{
			if ( ( u_LightMask & ( 1 << k ) ) == 0 )
				continue;
			lightOrigin = u_Lights[k].origin.xyz;
			lightColor = u_Lights[k].color;
			lightRadius = u_Lights[k].radius;
		}
		float importance = PomLightImportance(lightOrigin - position, lightColor, lightRadius);
		// insert into the descending list of the maxLights + 1 strongest
		for (int j = 0; j < 5; j++)
		{
			if (j > maxLights)
				break;
			if (importance > top[j])
			{
				float moved = top[j];
				top[j] = importance;
				importance = moved;
			}
		}
	}
	return max(top[maxLights], 1e-8);
#endif
}

float PomLocalLightWeight(in float cut, in vec3 toLight, in vec3 lightColor, in float lightRadius)
{
	if (cut < 0.0)
		return 0.0;
	if (cut == 0.0)
		return 1.0;
	return smoothstep(cut, cut * 1.5, PomLightImportance(toLight, lightColor, lightRadius));
}
#endif

// shadowLayer: cube index in u_ShadowMap2 (6 layers each), < 0 = unshadowed
vec3 EvaluateDynamicLight(
	in DLightSurface s,
	in vec3 lightOrigin,
	in vec3 lightColor,
	in float lightRadius,
	in int shadowLayer)
{
	vec3  L  = lightOrigin - s.position;
	float sqrLightDist = dot(L, L);

	float attenuation = CalcLightAttenuation(lightRadius * lightRadius / sqrLightDist);

	#if defined(USE_DSHADOWS)
		vec3 sampleVector = L;
		L /= sqrt(sqrLightDist);
		if (shadowLayer >= 0)
		{
			sampleVector += L * tan(acos(dot(s.vertexNormal, -L)));
			float distance = getLightDepth(sampleVector, lightRadius);
			attenuation *= pcfShadow(u_ShadowMap2, L, distance, shadowLayer);
		}
	#else
		L /= sqrt(sqrLightDist);
	#endif
	attenuation *= DynamicLightReceiverVisibility(s, L);

	float NL = clamp(dot(s.N, L), 0.0, 1.0);
	#if defined(USE_SPECULARMAP)
	vec3  H  = normalize(L + s.E);
	float LH = clamp(dot(L, H), 0.0, 1.0);
	#elif !defined(USE_CLOTH_BRDF)
	float LH = 0.0;
	if (u_DiffuseBRDF == 1)
	{
		vec3 H = normalize(L + s.E);
		LH = clamp(dot(L, H), 0.0, 1.0);
	}
	#endif
	#if !defined(USE_CLOTH_BRDF)
	vec3 reflectance = M_PI * CalcDiffuse(s.diffuse, s.NE, NL, LH, s.roughness);
	#else
	vec3 reflectance = s.diffuse;
	#endif
	#if defined(USE_SSGI)
	// the diffuse lobe only (view independent), after shadows and receiver
	// visibility: the source of the screen-space GI
	g_ssgiDynamicDiffuse += lightColor * reflectance * attenuation * NL;
	#endif
	#if defined(USE_SPECULARMAP)
	float NH = clamp(dot(s.N, H), 0.0, 1.0);
	float VH = clamp(dot(s.E, H), 0.0, 1.0);
	reflectance += CalcSpecular(s.specular, NH, NL, s.NE, LH, VH, s.roughness);
	#endif
	return lightColor * reflectance * attenuation * NL;
}

#if defined(USE_LTC)
/*
LTC area lights (tr_arealights.cpp), Forward+ only. Rectangles, and lines
(sabers) as a thin rectangle turned towards the receiver. The polygon integral
[Heitz et al. 2016] with the horizon clipped sphere approximation [Hill and
Heitz 2016]; tables from tools/ltcfit (tr_ltc_data.h):
  specular = FF(M^-1 * quad) * (F0 * norm + (1 - F0) * fresnel)
  diffuse  = FF(quad) * albedo           (exact Lambert form factor)
FF = form factor (cosine weighted solid angle / pi). The light color is the
emitted radiance. Attenuation is the geometry itself; the smooth window at the
influence range only hides the Forward+ cull radius.
*/
#define LTC_LUT_SIZE  64.0
#define LTC_LUT_SCALE ((LTC_LUT_SIZE - 1.0) / LTC_LUT_SIZE)
#define LTC_LUT_BIAS  (0.5 / LTC_LUT_SIZE)

#if defined(USE_LTC_DEBUG)
vec3 g_ltcSpecular = vec3(0.0);
vec3 g_ltcDiffuse = vec3(0.0);
vec3 g_ltcMode = vec3(0.0);		// source mode tint, weighted by contribution
float g_ltcBest = 0.0;
int g_ltcBestLight = -1;		// strongest area light here (r_ltcDebug 8)
#endif

// integral of the cosine lobe over one edge; the rational fit of
// theta / sin(theta) includes the 1 / (2 pi) of the form factor
vec3 LtcIntegrateEdgeVec(in vec3 v1, in vec3 v2)
{
	float x = dot(v1, v2);
	float y = abs(x);
	float a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
	float b = 3.4175940 + (4.1616724 + y) * y;
	float v = a / b;
	float thetaSinTheta = (x > 0.0) ? v : 0.5 * inversesqrt(max(1.0 - x * x, 1e-7)) - v;
	return cross(v1, v2) * thetaSinTheta;
}

// form factor of the quad q0..q3 (receiver at the origin, tangent frame,
// winding: cross(q1 - q0, q3 - q0) points away from the emitting side)
// transformed by Minv, clipped by the horizon
float LtcQuadFormFactor(in mat3 Minv, in vec3 q0, in vec3 q1, in vec3 q2, in vec3 q3, in bool twoSided)
{
	vec3 L0 = normalize(Minv * q0);
	vec3 L1 = normalize(Minv * q1);
	vec3 L2 = normalize(Minv * q2);
	vec3 L3 = normalize(Minv * q3);
	vec3 F = LtcIntegrateEdgeVec(L0, L1) + LtcIntegrateEdgeVec(L1, L2) +
		LtcIntegrateEdgeVec(L2, L3) + LtcIntegrateEdgeVec(L3, L0);
	float len = length(F);
	if (len <= 1e-7)
		return 0.0;
	float z = F.z / len;
	if (dot(q0, cross(q1 - q0, q3 - q0)) < 0.0)
	{
		// the back of the emitter
		if (!twoSided)
			return 0.0;
		z = -z;
	}
	vec2 uv = vec2(z * 0.5 + 0.5, len) * LTC_LUT_SCALE + LTC_LUT_BIAS;
	return len * texture(u_LtcAmplitudeMap, uv).w;
}

vec3 EvaluateAreaLight(in DLightSurface s, in FPlusLight light, in int lightIndex)
{
	int base = u_FPlusGrid.y + lightIndex * FPLUS_LIGHT_TEXELS;
	vec3 right = texelFetch(u_FPlusLights, base + 3).xyz;
	vec3 up = texelFetch(u_FPlusLights, base + 4).xyz;
	bool twoSided = (light.flags & AREALIGHT_TWO_SIDED) != 0;
	vec3 toReceiver = s.position - light.origin;

	if (light.type == FPLUS_TYPE_LINE)
	{
		// the blade seen from the receiver: a ribbon one tube diameter wide,
		// facing it (same projected area as the tube)
		vec3 n = toReceiver - right * dot(toReceiver, right);
		float l = length(n);
		if (l < 1e-3)
			return vec3(0.0);
		up = cross(n / l, right);
		twoSided = true;
	}
	else if (!twoSided && dot(toReceiver, cross(right, up)) <= 0.0)
		return vec3(0.0);

	// influence window from the closest point of the emitter
	vec3 closest = light.origin +
		right * clamp(dot(toReceiver, right), -light.halfWidth, light.halfWidth) +
		up * clamp(dot(toReceiver, up), -light.halfHeight, light.halfHeight);
	float d = length(s.position - closest) / max(light.radius, 1.0);
	float d2 = d * d;
	float window = clamp(1.0 - d2 * d2, 0.0, 1.0);
	window *= window;
	if (window <= 0.0)
		return vec3(0.0);

	// POM self shadow: towards the centre (one ray, not one per corner)
	window *= DynamicLightReceiverVisibility(s, normalize(light.origin - s.position));

	// receiver tangent frame, T1 in the plane of N and E
	vec3 N = s.N;
	float NE = dot(N, s.E);
	vec3 T1 = s.E - N * NE;
	if (dot(T1, T1) < 1e-8)
		T1 = abs(N.z) < 0.999 ? cross(N, vec3(0.0, 0.0, 1.0)) : vec3(1.0, 0.0, 0.0);
	T1 = normalize(T1);
	vec3 T2 = cross(N, T1);
	mat3 toTangent = transpose(mat3(T1, T2, N));

	vec3 R = right * light.halfWidth;
	vec3 U = up * light.halfHeight;
	vec3 c = light.origin - s.position;
	vec3 q0 = toTangent * (c - R - U);
	vec3 q1 = toTangent * (c - R + U);
	vec3 q2 = toTangent * (c + R + U);
	vec3 q3 = toTangent * (c + R - U);

	vec3 radiance = light.color * window;
	vec3 diffuseOut = vec3(0.0);
	vec3 specularOut = vec3(0.0);
	float formFactor = 0.0;

	// static stock lamps: the lightmap already has their diffuse light
	#if defined(USE_CLOTH_BRDF)
	formFactor = LtcQuadFormFactor(mat3(1.0), q0, q1, q2, q3, twoSided);
	#endif
	if ((light.flags & AREALIGHT_SPECULAR_ONLY) == 0)
	{
		#if !defined(USE_CLOTH_BRDF)
		formFactor = LtcQuadFormFactor(mat3(1.0), q0, q1, q2, q3, twoSided);
		#endif
		diffuseOut = radiance * s.diffuse * formFactor;
		#if defined(USE_SSGI)
		// view independent diffuse only: the screen-space GI source
		g_ssgiDynamicDiffuse += diffuseOut;
		#endif
	}

	#if defined(USE_SPECULARMAP)
	#if !defined(USE_CLOTH_BRDF)
	vec2 uv = vec2(sqrt(clamp(s.roughness, 0.0, 1.0)), sqrt(1.0 - clamp(NE, 0.0, 1.0)));
	uv = uv * LTC_LUT_SCALE + LTC_LUT_BIAS;
	vec4 t1 = texture(u_LtcMatrixMap, uv);
	vec4 t2 = texture(u_LtcAmplitudeMap, uv);
	mat3 Minv = mat3(vec3(t1.x, 0.0, t1.y), vec3(0.0, 1.0, 0.0), vec3(t1.z, 0.0, t1.w));
	float specFF = LtcQuadFormFactor(Minv, q0, q1, q2, q3, twoSided);
	// Schlick split as F_Schlick, including its no-specular cut
	vec3 F = s.specular * t2.x + (1.0 - s.specular) * t2.y * clamp(50.0 * s.specular.g, 0.0, 1.0);
	specularOut = radiance * specFF * F;
	#else
	// cloth (Charlie) lobe: wide, a representative point is enough
	vec3 L = normalize(closest - s.position);
	vec3 H = normalize(L + s.E);
	float NL = clamp(dot(N, L), 0.0, 1.0);
	specularOut = radiance * M_PI * formFactor * CalcSpecular(s.specular,
		clamp(dot(N, H), 0.0, 1.0), NL, NE, clamp(dot(L, H), 0.0, 1.0),
		clamp(dot(s.E, H), 0.0, 1.0), s.roughness);
	#endif
	#endif

	#if defined(USE_LTC_DEBUG)
	g_ltcSpecular += specularOut;
	g_ltcDiffuse += diffuseOut;
	vec3 tint = light.type == FPLUS_TYPE_LINE ? vec3(0.1, 1.0, 0.2) :
		(light.flags & AREALIGHT_DYNAMIC) != 0 ? vec3(1.0, 0.5, 0.05) :
		(light.flags & AREALIGHT_SPECULAR_ONLY) != 0 ? vec3(0.1, 0.35, 1.0) : vec3(0.1, 0.9, 1.0);
	float strength = dot(specularOut + diffuseOut, vec3(0.2126, 0.7152, 0.0722));
	g_ltcMode += tint * strength;
	if (strength > g_ltcBest)
	{
		g_ltcBest = strength;
		g_ltcBestLight = lightIndex;
	}
	#endif
	return diffuseOut + specularOut;
}
#endif

vec3 CalcDynamicLightContribution(
	in float roughness,
	in vec3 N,
	in vec3 E,
	in vec3 viewOrigin,
	in vec3 viewDir,
	in float NE,
	in vec3 diffuse,
	in vec3 specular,
	in vec3 vertexNormal)
{
	vec3 outColor = vec3(0.0);

	DLightSurface s;
	s.position = viewOrigin - viewDir;
	s.N = N;
	s.E = E;
	s.NE = NE;
	s.diffuse = diffuse;
	s.specular = specular;
	s.roughness = roughness;
	s.vertexNormal = vertexNormal;

	if (u_LightMask == 0)
		return outColor;

	// one loop and one EvaluateDynamicLight call site for both paths: every
	// lightall permutation inlines it, a second copy doubled the compile time
	bool fplus = FPlusEnabled();
	ivec2 list = fplus ? FPlusClusterLights(s.position) : ivec2(0, min(u_NumLights, MAX_DLIGHTS));
#if defined(USE_PARALLAXMAP)
	float pomCut = PomLocalLightCut(s.position, fplus, list);
#endif
	for (int k = 0; k < list.y; k++)
	{
		vec3 lightOrigin, lightColor;
		float lightRadius;
		int shadowLayer;
		if (fplus)
		{
			int lightIndex = FPlusLightIndex(list.x + k);
			FPlusLight light = FPlusFetchLight(lightIndex);
			if (FPlusDebugSkipLight(light, lightIndex))
				continue;
			if (light.type != 0.0)
			{
				// area light (r_ltcAreaLights): only in the USE_LTC programs
#if defined(USE_LTC)
#if defined(USE_PARALLAXMAP)
				g_pomLightWeight = PomLocalLightWeight(pomCut, light.origin - s.position, light.color, light.radius);
#endif
				outColor += EvaluateAreaLight(s, light, lightIndex);
#endif
				continue;
			}
			lightOrigin = light.origin;
			lightColor = light.color;
			lightRadius = light.radius;
			shadowLayer = light.shadowSlot;
		}
		else
		{
			if ( ( u_LightMask & ( 1 << k ) ) == 0 )
				continue;
			lightOrigin = u_Lights[k].origin.xyz;
			lightColor = u_Lights[k].color;
			lightRadius = u_Lights[k].radius;
			shadowLayer = k;
		}
#if defined(USE_PARALLAXMAP)
		g_pomLightWeight = PomLocalLightWeight(pomCut, lightOrigin - s.position, lightColor, lightRadius);
#endif
		outColor += EvaluateDynamicLight(s, lightOrigin, lightColor, lightRadius, shadowLayer);
	}
	return outColor;
}
#else
vec3 EvaluateDynamicLightSimple(
	in vec3 position,
	in vec3 N,
	in vec3 lightOrigin,
	in vec3 lightColor,
	in float lightRadius)
{
	vec3 L = lightOrigin - position;
	float sqrLightDist = dot(L, L);
	float attenuation = CalcLightAttenuation(lightRadius * lightRadius / sqrLightDist);
	L /= sqrt(sqrLightDist);
	float NL = clamp(dot(N, L), 0.0, 1.0);
	return lightColor * attenuation * NL;
}

vec3 CalcDynamicLightContribution(
	in vec3 position,
	in vec3 N )
{
	vec3 outLight = vec3(0.0);
	if (u_LightMask == 0)
		return outLight;

	bool fplus = FPlusEnabled();
	ivec2 list = fplus ? FPlusClusterLights(position) : ivec2(0, min(u_NumLights, MAX_DLIGHTS));
	for (int k = 0; k < list.y; k++)
	{
		vec3 lightOrigin, lightColor;
		float lightRadius;
		if (fplus)
		{
			int lightIndex = FPlusLightIndex(list.x + k);
			FPlusLight light = FPlusFetchLight(lightIndex);
			if (light.type != 0.0 || FPlusDebugSkipLight(light, lightIndex))
				continue;
			lightOrigin = light.origin;
			lightColor = light.color;
			lightRadius = light.radius;
		}
		else
		{
			if ( ( u_LightMask & ( 1 << k ) ) == 0 )
				continue;
			lightOrigin = u_Lights[k].origin.xyz;
			lightColor = u_Lights[k].color;
			lightRadius = u_Lights[k].radius;
		}
		outLight += EvaluateDynamicLightSimple(position, N, lightOrigin, lightColor, lightRadius);
	}
	return outLight;
}
#endif

// r_forwardPlusDebug views that replace the lit color (1-5, 8); 6, 7 and 9
// show the filtered dynamic light alone. False = not a debug view here.
vec3 FPlusHashColor(in int n)
{
	return fract(sin(vec3(float(n)) * vec3(12.9898, 78.233, 37.719)) * 43758.5453) * 0.8 + 0.2;
}

bool FPlusDebugColor(in vec3 position, in vec3 litColor, in vec3 dynamicLight, out vec3 color)
{
	color = litColor;
#if !defined(USE_FPLUS_DEBUG)
	return false;
#else
	int mode = int(u_FPlusDebug.x);
	if (!FPlusEnabled() || mode <= 0)
		return false;

	if (mode == 6 || mode == 7 || mode == 9)
	{
		color = dynamicLight;
		return true;
	}

	ivec2 list = FPlusClusterLights(position);
	float maxLights = max(u_FPlusDebug.z, 1.0);
	if (mode == 1)
	{
		vec2 p = mod(gl_FragCoord.xy - u_FPlusParams2.xy, u_FPlusParams.x);
		bool edge = p.x < 1.0 || p.y < 1.0;
		color = edge ? vec3(1.0, 0.85, 0.1) : litColor;
	}
	else if (mode == 2)
		color = FPlusHashColor(FPlusSlice(position) + 7) * (0.35 + 0.65 * clamp(dot(litColor, vec3(0.333)), 0.0, 1.0));
	else if (mode == 3)
		color = FPlusHashColor(FPlusCluster(position));
	else if (mode == 4)
	{
		// black = none, blue -> green -> red = up to the per cluster limit
		float t = float(list.y) / maxLights;
		color = list.y == 0 ? vec3(0.02) :
			(t < 0.5 ? mix(vec3(0.0, 0.1, 1.0), vec3(0.0, 1.0, 0.1), t * 2.0) :
				mix(vec3(0.0, 1.0, 0.1), vec3(1.0, 0.05, 0.0), t * 2.0 - 1.0));
	}
	else if (mode == 5)
		color = float(list.y) >= maxLights ? vec3(1.0, 0.0, 0.0) : litColor * 0.25;
	else if (mode == 8)
	{
		// lights whose sphere contains the point, tinted by index, brighter at the centre
		vec3 sum = vec3(0.0);
		for (int k = 0; k < list.y; k++)
		{
			int lightIndex = FPlusLightIndex(list.x + k);
			FPlusLight light = FPlusFetchLight(lightIndex);
			float d = length(light.origin - position) / max(light.radius, 1.0);
			if (d < 1.0)
				sum += FPlusHashColor(lightIndex) * (0.25 + 0.75 * (1.0 - d)) * 0.5;
		}
		color = litColor * 0.15 + sum;
	}
	return true;
#endif
}

#if defined(USE_LTC_DEBUG) && defined(PER_PIXEL_LIGHTING)
// r_ltcDebug (tr_arealights.cpp): 1 specular, 2 diffuse, 3 source mode,
// 4 area lights per cluster, 5 influence bounds, 8 strongest light id.
// 6 / 7 (outlines / normals) are polygons drawn on the lit image.
bool LtcDebugColor(in vec3 position, in vec3 litColor, out vec3 color)
{
	color = litColor;
	int mode = int(u_FPlusDebug.w);
	if (!FPlusEnabled() || mode <= 0 || mode == 6 || mode == 7 || mode > 8)
		return false;

	if (mode == 1)
		color = g_ltcSpecular;
	else if (mode == 2)
		color = g_ltcDiffuse;
	else if (mode == 3)
		color = g_ltcMode + litColor * 0.05;
	else if (mode == 4 || mode == 5)
	{
		ivec2 list = FPlusClusterLights(position);
		int count = 0;
		vec3 sum = vec3(0.0);
		for (int k = 0; k < list.y; k++)
		{
			int lightIndex = FPlusLightIndex(list.x + k);
			FPlusLight light = FPlusFetchLight(lightIndex);
			if (light.type == 0.0)
				continue;
			count++;
			float d = length(light.origin - position) / max(light.radius, 1.0);
			if (d < 1.0)
			{
				vec3 c = (light.flags & AREALIGHT_SELECTED) != 0 ? vec3(1.0) : FPlusHashColor(lightIndex);
				sum += c * (0.25 + 0.75 * (1.0 - d)) * 0.5;
			}
		}
		if (mode == 4)
			color = count == 0 ? litColor * 0.15 :
				mix(vec3(0.0, 0.2, 1.0), vec3(1.0, 0.1, 0.0), clamp(float(count - 1) / 7.0, 0.0, 1.0));
		else
			color = litColor * 0.15 + sum;
	}
	else if (mode == 8)
		color = g_ltcBestLight < 0 ? litColor * 0.1 : FPlusHashColor(g_ltcBestLight);
	return true;
}
#endif

float luma(vec3 color)
{
	const vec3 weight = vec3(0.2126, 0.7152, 0.0722);
	return dot(color, weight);
}

vec3 CalcIBLContribution(
	in float roughness,
	in vec3 N,
	in vec3 E,
	in vec3 viewOrigin,
	in vec3 viewDir,
	in float NE,
	in vec3 specular,
	in vec3 lighting
)
{
#if defined(PER_PIXEL_LIGHTING) && defined(USE_CUBEMAP) && defined(USE_SPECULARMAP)
	// parallax corrected cubemap (cheaper trick)
	// from http://seblagarde.wordpress.com/2012/09/29/image-based-lighting-approaches-and-parallax-corrected-cubemap/
	vec3 parallax = u_CubeMapInfo.xyz + u_CubeMapInfo.w * viewDir;

	vec3 R = reflect(-E, N) - parallax;
	vec4 cubeLightColor = textureLod(u_CubeMap, R, roughness * ROUGHNESS_MIPS) * u_EnableTextures.w;

	// Scale reflection based on current light luminance / max luminance of the cubemap 
	cubeLightColor.rgb *= clamp(luma(lighting) / cubeLightColor.a, 0.0, 1.0);

	// Base BRDF
	#if !defined(USE_CLOTH_BRDF)
		vec2 EnvBRDF = texture(u_EnvBrdfMap, vec2(roughness, NE)).rg;
		return cubeLightColor.rgb * (specular.rgb * EnvBRDF.x + EnvBRDF.y);
	// Cloth BRDF
	#else
		float EnvBRDF = texture(u_EnvBrdfMap, vec2(roughness, NE)).b;
		return cubeLightColor.rgb * EnvBRDF;
	#endif
#else
	return vec3(0.0);
#endif
}

#if defined(USE_SSR)
// The factor CalcIBLContribution applies to the cubemap radiance: SSR
// replaces cubemap radiance with screen-space radiance under the same BRDF.
vec3 SSRSpecularWeight(in float roughness, in float NE, in vec3 specular)
{
#if defined(PER_PIXEL_LIGHTING) && defined(USE_SPECULARMAP)
	#if !defined(USE_CLOTH_BRDF)
		vec2 EnvBRDF = texture(u_EnvBrdfMap, vec2(roughness, NE)).rg;
		return specular.rgb * EnvBRDF.x + EnvBRDF.y;
	#else
		return vec3(texture(u_EnvBrdfMap, vec2(roughness, NE)).b);
	#endif
#else
	return vec3(0.0);
#endif
}
#endif

#if defined(USE_WETNESS) && defined(PER_PIXEL_LIGHTING)
// 0..1 rain exposure of a world position: the particle test of weather.glsl
// (culled when depth > stored depth) against the same map, with a small depth
// bias and a bilinear blend of 4 binary tests for a soft, stable 1 texel edge.
float ComputeRainExposure(in vec3 worldPosition, in vec3 geometricNormal)
{
	// half a texel along the normal: walls test the column in front of them
	// instead of their own top
	vec4 p = u_WeatherMvp * vec4(worldPosition + geometricNormal * u_WetnessParams2.y, 1.0);
	vec3 uvz = p.xyz / p.w * 0.5 + 0.5;
	if (any(lessThan(uvz.xy, vec2(0.0))) || any(greaterThan(uvz.xy, vec2(1.0))))
		return 0.0;

	// slope scaled: steep faces vary more in depth across one texel
	float bias = u_WetnessParams2.x * (1.0 + 2.0 * (1.0 - abs(geometricNormal.z)));
	float z = uvz.z - bias;

	ivec2 size = textureSize(u_WeatherDepthMap, 0);
	vec2 texel = uvz.xy * vec2(size) - 0.5;
	ivec2 base = ivec2(floor(texel));
	vec2 f = texel - vec2(base);
	ivec2 maxTexel = size - 1;
	float e00 = step(z, texelFetch(u_WeatherDepthMap, clamp(base,               ivec2(0), maxTexel), 0).r);
	float e10 = step(z, texelFetch(u_WeatherDepthMap, clamp(base + ivec2(1, 0), ivec2(0), maxTexel), 0).r);
	float e01 = step(z, texelFetch(u_WeatherDepthMap, clamp(base + ivec2(0, 1), ivec2(0), maxTexel), 0).r);
	float e11 = step(z, texelFetch(u_WeatherDepthMap, clamp(base + ivec2(1, 1), ivec2(0), maxTexel), 0).r);
	return mix(mix(e00, e10, f.x), mix(e01, e11, f.x), f.y);
}

// Procedural puddles: world anchored low frequency value noise, one domain
// warp and two octaves (3 noise evaluations, 12 hashes), 0..1.
float PuddleHash(vec2 p)
{
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float PuddleValueNoise(vec2 p)
{
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = PuddleHash(i);
	float b = PuddleHash(i + vec2(1.0, 0.0));
	float c = PuddleHash(i + vec2(0.0, 1.0));
	float d = PuddleHash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float PuddleField(vec2 p)
{
	float w = PuddleValueNoise(p * 0.5 + 17.3);
	vec2 q = p + (w - 0.5) * 0.8;
	return 0.65 * PuddleValueNoise(q) + 0.35 * PuddleValueNoise(q * 2.3 + 5.1);
}

#if defined(USE_PARALLAXMAP)
// Height aware puddles (r_puddleHeight): the macro basin (0 where the macro
// puddle fringe starts, 1 in its core) sets a static water level inside the
// relief of the material, depth = PuddleRelief (1 = deepest). The
// deepest cracks fill first, then the low areas, the core covers the peaks.
// x = shallow film (bumps still show), y = submerged, z = normal flattening.
vec3 PuddleMicro(in float basin, in float depth)
{
	float soft = u_PuddleHeight.z;
	float fill = basin * (1.0 + 2.0 * soft + u_PuddleHeight.w) - soft;
	float level = 1.0 - fill;
	float edge = smoothstep(level - soft, level, depth);
	float core = smoothstep(level, level + soft, depth);
	return vec3(edge, core, max(smoothstep(level, level + 2.0 * soft, depth), 0.5 * edge));
}

// SampleMaterialDepth rescaled to the relief this height map really uses
// (2nd..98th percentile, image_t heightRange): 0 = its peaks, 1 = its deepest
float PuddleRelief(in float materialDepth)
{
	return clamp((materialDepth - u_PuddleHeight.x) * u_PuddleHeight.y, 0.0, 1.0);
}
#endif
#endif

#if defined(PER_PIXEL_LIGHTING) && defined(USE_SSAO)
// Jimenez et al. 2016, "Practical Real-Time Strategies for Accurate Indirect
// Occlusion": multi-bounce fit, bright albedo loses less light in creases
vec3 AOMultiBounce(float visibility, vec3 albedo)
{
	vec3 a =  2.0404 * albedo - 0.3324;
	vec3 b = -4.7951 * albedo + 0.6417;
	vec3 c =  2.7552 * albedo + 0.6903;
	return max(vec3(visibility), ((visibility * a + b) * visibility + c) * visibility);
}

// Lagarde & de Rousiers 2014, "Moving Frostbite to PBR": specular occlusion
// from ambient occlusion
float SpecularOcclusion(float NE, float visibility, float roughness)
{
	return clamp(pow(NE + visibility, exp2(-16.0 * roughness - 1.0)) - 1.0 + visibility, 0.0, 1.0);
}
#endif

vec3 CalcNormal( in vec3 vertexNormal, in vec4 vertexTangent, in vec2 texCoords )
{
#if defined(USE_NORMALMAP)
	vec3 biTangent = vertexTangent.w * cross(vertexNormal, vertexTangent.xyz);
#if defined(USE_SILHOUETTE_POM)
	vec3 N = textureGrad(u_NormalMap, texCoords, g_pomGradX, g_pomGradY).agb - vec3(0.5);
#else
	vec3 N = texture(u_NormalMap, texCoords).agb - vec3(0.5);
#endif
	N.xy *= u_NormalScale.xy;
	N.z = sqrt(clamp((0.25 - N.x * N.x) - N.y * N.y, 0.0, 1.0));
	N = N.x * vertexTangent.xyz + N.y * biTangent + N.z * vertexNormal;
	return normalize(N);
#else
	return normalize(vertexNormal);
#endif
}

#if defined(USE_SILHOUETTE_POM)
// Silhouette POM (pom_silhouette.glsl): crossfade, ordinary POM for base
// surfaces inside the crossfade band, ray / height field intersection for
// shells. Returns the texture and lightmap coordinates and the view vector
// (camera - surface point) of the virtual surface, writes gl_FragDepth.
void PomSilhouetteFragment(inout vec2 texCoords, inout vec2 lmCoords, out vec3 viewDir,
	out PomHit hit, out bool shell)
{
	vec3 position = u_ViewOrigin - var_ViewDir.xyz;
	float viewDistance = length(var_ViewDir.xyz);
	vec2 uvDx = dFdx(texCoords);
	vec2 uvDy = dFdy(texCoords);
	shell = PomIsShellDraw();
	viewDir = var_ViewDir.xyz;
	hit.hit = false;
	hit.entryInside = false;
	hit.uv = texCoords;
	hit.lmUV = lmCoords;
	hit.position = position;
	hit.depth = 0.0;
	hit.t = 0.0;
	hit.samples = 0.0;

	bool keep = PomFadeKeep(position, u_ViewOrigin, gl_FragCoord.xy, shell);
	if (!shell)
	{
		vec3 tangentViewDir = vec3(var_LightDir.w, var_Normal.w, var_ViewDir.w);
		texCoords += GetParallaxOffset(texCoords, tangentViewDir);
		g_pomGradX = dFdx(texCoords);
		g_pomGradY = dFdy(texCoords);
		if (!keep)
			discard;
		gl_FragDepth = gl_FragCoord.z;
		return;
	}
	if (!keep)
		discard;

	vec3 N = normalize(var_Normal.xyz);
	vec3 T = normalize(var_Tangent.xyz - N * dot(N, var_Tangent.xyz));
	vec3 B = cross(N, T) * var_Tangent.w;
	vec3 rayDir = -var_ViewDir.xyz / viewDistance;
	float parallaxDepth = u_NormalScale.a;
	vec2 aspect = PomAspect(vec2(textureSize(u_NormalMap, 0)));
	float pixelFootprint = viewDistance * 2.0 * length(u_ViewUp) / (u_ViewInfo.y * r_FBufScale.y);
	PomGradients(PomIsWall(var_PomHeader), uvDx, uvDy, pixelFootprint, var_PomShell.y,
		parallaxDepth, aspect, g_pomGradX, g_pomGradY);

	hit = PomSilhouetteTrace(u_NormalMap, aspect, parallaxDepth, position, rayDir, texCoords,
		var_PomShell.x, var_PomShell.y, PomHeaderTexel(var_PomHeader), T, B, N, g_pomGradX, g_pomGradY);

	// the shell hit feeds the same self shadow rays as ordinary POM
	g_pom.valid = hit.hit;
	g_pom.uv = hit.uv;
	g_pom.depth = hit.depth;
	g_pom.T = T;
	g_pom.B = B;
	g_pom.N = N;
	g_pom.scale = aspect * parallaxDepth;
	g_pom.gradX = g_pomGradX;
	g_pom.gradY = g_pomGradY;
	g_pom.fade = 1.0;
	g_pom.viewSamples = hit.samples;
	g_pom.shadowSamples = 0.0;
	if (!hit.hit)
	{
		// r_pomSilhouetteDebug 6 keeps the pixels the ray missed
		if (int(u_PomParams2.w) != 6)
			discard;
		gl_FragDepth = gl_FragCoord.z;
		return;
	}

	texCoords = hit.uv;
  #if defined(USE_LIGHTMAP)
	lmCoords = hit.lmUV;
  #endif
	viewDir = u_ViewOrigin - hit.position;
	gl_FragDepth = PomShellDepth(u_viewProjectionMatrix, hit.position, rayDir, viewDistance + hit.t);
}
#endif

void main()
{
	vec3 viewDir, lightColor, ambientColor;
	vec3 L, N, E;

	vec2 texCoords = var_TexCoords.xy;
	vec2 lmCoords = var_TexCoords.zw;
#if defined(USE_SILHOUETTE_POM)
	vec3 pomViewDir;
	PomHit pomHit;
	bool pomShell;
	PomSilhouetteFragment(texCoords, lmCoords, pomViewDir, pomHit, pomShell);
#endif
#if defined(USE_SSR) || defined(USE_SSGI)
  #if defined(USE_SILHOUETTE_POM)
	SSRWriteNone(u_ViewOrigin - pomViewDir);
  #elif defined(PER_PIXEL_LIGHTING)
	SSRWriteNone(u_ViewOrigin - var_ViewDir.xyz);
  #else
	SSRWriteNone(var_Position);
  #endif
#endif
#if defined(PER_PIXEL_LIGHTING) && !defined(USE_SILHOUETTE_POM)
	// Unpack tangent view direction
	vec3 tangentViewDir = vec3(var_LightDir.w, var_Normal.w, var_ViewDir.w);
	vec2 tex_offset = GetParallaxOffset(texCoords, tangentViewDir);
	texCoords += tex_offset;
#endif

#if defined(USE_SILHOUETTE_POM)
	vec4 diffuse = textureGrad(u_DiffuseMap, texCoords, g_pomGradX, g_pomGradY);
#else
	vec4 diffuse = texture(u_DiffuseMap, texCoords);
#endif
	diffuse.a *= var_Color.a;
#if defined(USE_ALPHA_TEST)
	if (u_AlphaTestType == ALPHA_TEST_GT0)
	{
		if (diffuse.a == 0.0)
			discard;
	}
	else if (u_AlphaTestType == ALPHA_TEST_LT128)
	{
		if (diffuse.a >= 0.5)
			discard;
	}
	else if (u_AlphaTestType == ALPHA_TEST_GE128)
	{
		if (diffuse.a < 0.5)
			discard;
	}
	else if (u_AlphaTestType == ALPHA_TEST_GE192)
	{
		if (diffuse.a < 0.75)
			discard;
	}
	else if (u_AlphaTestType == ALPHA_TEST_E255)
	{
		if (diffuse.a < 1.00)
			discard;
	}
#endif

#if defined(PER_PIXEL_LIGHTING)
  #if defined(USE_SILHOUETTE_POM)
	viewDir = pomViewDir;
  #else
	viewDir = var_ViewDir.xyz;
  #endif
	E = normalize(viewDir);
	L = var_LightDir.xyz;
  #if defined(USE_DELUXEMAP)
	L += (texture(u_DeluxeMap, lmCoords).xyz - vec3(0.5)) * u_EnableTextures.y;
  #endif
#endif

#if defined(USE_LIGHTMAP)
	vec4 lightmapColor = texture(u_LightMap, lmCoords);
#endif

#if defined(PER_PIXEL_LIGHTING)
	float attenuation;

  #if defined(USE_LIGHTMAP)
	lightColor	= lightmapColor.rgb * var_Color.rgb;
	ambientColor = vec3 (0.0);
	attenuation = 1.0;
  #elif defined(USE_LIGHT_VECTOR)
	lightColor	= u_DirectedLight * var_Color.rgb;
	ambientColor = u_AmbientLight * var_Color.rgb;
	attenuation = 1.0;
  #elif defined(USE_LIGHT_VERTEX)
	lightColor	= var_Color.rgb;
	ambientColor = vec3 (0.0);
	attenuation = 1.0;
  #endif

  #if defined(USE_ENTITY_GRID)
	#if defined(USE_ENTITY_GPU_GRID)
	EntityGridSample gridGpu;
	#endif
	EntityGridSample gridMulti;
	#if defined(USE_ENTITY_GPU_GRID)
	if (u_GridParams.z > 1.5 || u_GridScale.w > 0.5)
		gridGpu = SampleEntityGrid(u_ViewOrigin - viewDir);
	#endif
	if ((u_GridParams.z > 0.5 && u_GridParams.z < 1.5) || u_GridScale.w > 0.5)
		gridMulti = SampleEntityMultiPoint((u_ViewOrigin - viewDir).z);
	if (u_GridParams.z > 0.5)
	{
		#if defined(USE_ENTITY_GPU_GRID)
		EntityGridSample selected = u_GridParams.z > 1.5 ? gridGpu : gridMulti;
		#else
		EntityGridSample selected = gridMulti;
		#endif
		L = selected.direction;
		lightColor = EntityGridDirectedCompatibility(selected.directed) * var_Color.rgb;
		ambientColor = EntityGridAmbientCompatibility(selected.ambient) * var_Color.rgb;
	}
  #endif
	float sqrLightDist = max(dot(L, L), 1e-12);

  #if defined(USE_SILHOUETTE_POM)
	// the base surface normal: shell walls face other directions
	vec3 vertexNormal = var_Normal.xyz * u_NormalScale.z;
  #else
	vec3 vertexNormal = mix(var_Normal.xyz, -var_Normal.xyz, float(gl_FrontFacing)) * u_NormalScale.z;
  #endif
	N = CalcNormal(vertexNormal, var_Tangent, texCoords);
	L /= sqrt(sqrLightDist);

  #if defined(USE_WETNESS)
	// Rain wetness: changes only the material inputs (normal here, albedo and
	// roughness below), before any lighting, so direct light, dynamic lights,
	// cubemap IBL, SSR and SSGI all see the same wet material.
	float rainExposure = 0.0;
	float wetness = 0.0;
	float puddleSlope = 0.0;
	float puddleField = 0.0;
	float puddle = 0.0;
	float puddleEdge = 0.0;
	float puddleMacro = 0.0;
	float puddleMacroEdge = 0.0;
	float puddleDepth = -1.0;	// material depth of the height aware path, < 0: none
	if (u_WetnessParams.x > 0.0 || u_WetnessParams2.z > 0.0)
	{
		vec3 wetGeoNormal = normalize(vertexNormal);
		if (u_WetnessParams.x > 0.0 || u_WetnessParams2.z == 1.0)
			rainExposure = ComputeRainExposure(u_ViewOrigin - viewDir, wetGeoNormal);
		// walls get about half the rain, faces pointing down none
		// (entities: most of the side, u_WetnessParams3.x)
		float facing = mix(u_WetnessParams3.x, 1.0, clamp(wetGeoNormal.z, 0.0, 1.0)) * step(-0.2, wetGeoNormal.z);
		wetness = rainExposure * max(u_WetnessParams.x, 0.0) * facing;
		if (u_WetnessParams2.z == 4.0 && gl_FragCoord.x < u_WetnessParams2.w)
			wetness = 0.0;	// dry / wet split
		N = normalize(mix(N, wetGeoNormal, wetness * u_WetnessParams.w));

		// Puddles: rain exposure x flat geometric normal x world noise x
		// world-only eligibility. The normal map is not used for the slope.
		puddleSlope = smoothstep(u_PuddleParams.z, u_PuddleParams.w, wetGeoNormal.z);
		float exposureP = smoothstep(0.5, 1.0, rainExposure);
		bool puddleDebug = u_WetnessParams2.z >= 5.0 && u_WetnessParams2.z <= 15.0;
		if (u_PuddleParams.x > 0.0 && ((wetness > 0.0 && puddleSlope * exposureP > 0.0) || puddleDebug))
		{
			puddleField = PuddleField((u_ViewOrigin - viewDir).xy * u_PuddleParams2.x);
			float t = 1.0 - u_PuddleParams.x;
			float gate = puddleSlope * exposureP * step(0.0, u_WetnessParams.x);
			puddleMacro = smoothstep(t, t + 0.06, puddleField) * gate;
			puddleMacroEdge = smoothstep(t - 0.10, t, puddleField) * gate;
			puddle = puddleMacro;
			puddleEdge = puddleMacroEdge;
			// smooth water surface: underlying detail fades in the core
			float flatten = max(puddle, puddleEdge * 0.5);
    #if defined(USE_PARALLAXMAP)
			// the real height field of the shaded (POM displaced) point decides
			// where inside the macro puddle the water stands
			if (u_PuddleHeight.y > 0.0)
			{
				puddleDepth = PuddleRelief(SampleMaterialDepth(u_NormalMap, texCoords, g_pom.gradX, g_pom.gradY));
				float basin = clamp((puddleField - (t - 0.10)) / 0.16, 0.0, 1.0);
				vec3 micro = PuddleMicro(basin, puddleDepth) * gate;
				puddleEdge = micro.x;
				puddle = micro.y;
				flatten = micro.z;
			}
    #endif
			if (u_WetnessParams2.z == 4.0 && gl_FragCoord.x < u_WetnessParams2.w)
				puddle = puddleEdge = flatten = 0.0;
			N = normalize(mix(N, wetGeoNormal, flatten));
		}
	}
  #endif

	// screen-space AO (r) and sun contact shadow (g) of this view
	float AO = 1.0;
	float contactShadow = 1.0;
	#if defined (USE_SSAO)
	vec2 windowTex = gl_FragCoord.xy / r_FBufScale;
	vec2 screenAO = texture(u_SSAOMap, windowTex).rg;
	AO = screenAO.r;
	contactShadow = screenAO.g;
	#endif
	float cascadeShadow = 1.0;
	#if defined(USE_SHADOWMAP) && defined(USE_SHADOWS2)
	SunCascadeResult sunInfo;
	#endif
	#if defined(USE_PARALLAXMAP)
	float pomSunShadow = 1.0;
	#endif

  #if defined(USE_SHADOWMAP)
	vec3 primaryLightDir = normalize(u_PrimaryLightOrigin.xyz);
	float NPL = clamp(dot(N, primaryLightDir), 0.0, 1.0);
	#if defined(USE_SHADOWS2)
	vec3 geometricNormal = normalize(vertexNormal);
	float geometricNPL = clamp(dot(geometricNormal, primaryLightDir), 0.0, 1.0);
	sunInfo = sunShadowModern(u_ViewOrigin - viewDir, geometricNormal, geometricNPL);
	cascadeShadow = sunInfo.visibility;
	#else
	vec3 normalBias = vertexNormal * (1.0 - NPL);
	cascadeShadow = sunShadow(u_ViewOrigin, viewDir, normalBias, u_ShadowMap);
	#endif
	// contact shadows only refine the near field of the cascaded shadow map
	float shadowValue = cascadeShadow * contactShadow * NPL;
	#if defined(USE_PARALLAXMAP)
	// POM self shadow: part of the sun visibility, so it applies wherever the
	// sun shadow does (r_sunlightMode 1 lightmap modulation, 2 direct sun)
	pomSunShadow = GetPomSelfShadow(PomSunDirection(primaryLightDir));
	shadowValue *= pomSunShadow;
	#endif

    #if defined(SHADOWMAP_MODULATE)
	vec3 ambientScale = mix(vec3(1.0), u_PrimaryLightAmbient, u_EnableTextures.z);
	lightColor = mix(ambientScale * lightColor, lightColor, shadowValue);
    #endif
  #endif

  #if defined(USE_LIGHTMAP) || defined(USE_LIGHT_VERTEX)
	ambientColor = lightColor;
	float surfNL = clamp(dot(vertexNormal, L), 0.0, 1.0);

	// Scale the incoming light to compensate for the baked-in light angle
	// attenuation.
	lightColor /= max(surfNL, 0.25);

	// Recover any unused light as ambient, in case attenuation is over 4x or
	// light is below the surface
	ambientColor = max(ambientColor - lightColor * surfNL, 0.0);
  #endif

	// Lambert and Burley diffuse both contain 1 / PI. Compensate it here to
	// preserve Rend2's legacy lightmap, vertex-light and light-grid intensity.
	// Dynamic lights apply the same compensation to their diffuse term locally.
	lightColor *= M_PI;

	// Dont scale ambient as we dont compute lambertian diffuse for it
	// We dont compute it because cloth diffuse is dependent on NL
	// So we just skip this. Reconsider this again when more BRDFS are added

	vec4 specular = vec4(1.0);
	float roughness = 0.99;
  #if defined(USE_SPECULARMAP)
  #if !defined(USE_SPECGLOSS)
    #if defined(USE_SILHOUETTE_POM)
	vec4 ORMS = textureGrad(u_SpecularMap, texCoords, g_pomGradX, g_pomGradY);
    #else
	vec4 ORMS = texture(u_SpecularMap, texCoords);
    #endif
	ORMS.xyzw *= u_SpecularScale.zwxy;

	specular.rgb = mix(vec3(0.08) * ORMS.w, diffuse.rgb, ORMS.z);
	diffuse.rgb *= vec3(1.0 - ORMS.z);

	roughness = mix(0.01, 1.0, ORMS.y);
	AO = min(ORMS.x, AO);
  #else
    #if defined(USE_SILHOUETTE_POM)
	specular = textureGrad(u_SpecularMap, texCoords, g_pomGradX, g_pomGradY);
    #else
	specular = texture(u_SpecularMap, texCoords);
    #endif
	specular.rgb *= u_SpecularScale.xyz;
	roughness = mix(1.0, 0.01, specular.a * (1.0 - u_SpecularScale.w));
  #endif
  #endif

  #if defined(USE_WETNESS)
	if (wetness > 0.0)
	{
		// a water film darkens porous (rough, dielectric) albedo and smooths
		// the surface; F0 is kept: dielectrics stay dielectric, metals metal.
		// diffuse is already (1 - metal) scaled on the ORMS path.
		// generic class: physical porosity from the material; other classes
		// (cloth, armor, ...) use their darkening as is
		float porosity = roughness;
    #if defined(USE_SPECULARMAP) && !defined(USE_SPECGLOSS)
		porosity *= 1.0 - ORMS.z;
    #endif
		porosity = mix(1.0, porosity, u_WetnessParams3.y);
		diffuse.rgb *= 1.0 - wetness * u_WetnessParams.z * porosity;
		roughness = mix(roughness, max(roughness * u_WetnessParams.y, 0.08), wetness);
	}
	if (puddleEdge > 0.0)
	{
		// standing water: fringe intermediate, core near mirror; F0 kept
		// (no metal, no tint), the dielectric Fresnel / IBL / SSR reflect it
		float metal = 0.0;
    #if defined(USE_SPECULARMAP) && !defined(USE_SPECGLOSS)
		metal = ORMS.z;
    #endif
		float fringeRough = min(roughness, mix(roughness, u_PuddleParams.y, 0.5));
		roughness = mix(roughness, fringeRough, puddleEdge);
		roughness = mix(roughness, u_PuddleParams.y, puddle);
		diffuse.rgb *= 1.0 - 0.25 * puddle * (1.0 - metal);
	}
  #endif

	vec3 specularAO = specular.rgb * AO;
#if defined(USE_SSAO)
	vec3 ambientVisibility = vec3(AO);
	bool indirectOnlyAO = u_AOParams.x == 1.0 ||
		(u_AOParams.x == 2.0 && gl_FragCoord.x >= u_AOParams.w);
	if (indirectOnlyAO)
	{
		// AO is the loss of indirect light: it attenuates ambient light, the
		// share of baked lighting that is indirect, and (as specular
		// occlusion) the environment reflections, never real-time direct
		// light (sun, dynamic lights, light grid directed light)
		if (u_AOParams.z > 0.0)
			ambientVisibility = AOMultiBounce(AO, diffuse.rgb);
		ambientColor *= ambientVisibility;
    #if defined(USE_LIGHTMAP) || defined(USE_LIGHT_VERTEX)
		lightColor *= mix(vec3(1.0), ambientVisibility, u_AOParams.y);
    #endif
		specularAO = specular.rgb * SpecularOcclusion(abs(dot(N, E)) + 1e-5, AO, roughness);
	}
	else
#endif
	ambientColor *= AO;

	// The cubemap provides only an angular distribution. Keep the light-grid
	// ambient as the energy source; never add the captured world's full light.
	vec3 diffuseAmbientColor = ambientColor;
#if defined(USE_DIFFUSE_IBL) && defined(USE_LIGHT_VECTOR)
	vec3 probeIrradiance = vec3(0.0);
	vec3 directionalFactor = vec3(1.0);
	if (u_DiffuseIBLParams.w > 0.5)
	{
		probeIrradiance = max(texture(u_DiffuseIrradianceMap, N).rgb, vec3(0.0));
		vec3 averageIrradiance = max(texelFetch(u_ProbeAverageMap,
			ivec2(int(u_DiffuseIBLParams.z), 0), 0).rgb, vec3(0.0));
		float averageLuma = dot(averageIrradiance, vec3(0.2126, 0.7152, 0.0722));
		if (averageLuma > 1e-4)
		{
			// The sphere average of cosine-convolved radiance equals the
			// sphere average of radiance, so both textures have matching units.
			vec3 safeAverage = max(averageIrradiance, vec3(averageLuma * 0.05));
			directionalFactor = clamp(probeIrradiance / safeAverage,
				vec3(0.25), vec3(4.0));
		}
		diffuseAmbientColor *= mix(vec3(1.0), directionalFactor,
			clamp(u_DiffuseIBLParams.x, 0.0, 1.0));
	}
#endif

	vec3  H  = normalize(L + E);
	float NE = abs(dot(N, E)) + 1e-5;
	float NL = clamp(dot(N, L), 0.0, 1.0);
	float LH = clamp(dot(L, H), 0.0, 1.0);

	vec3  Fd = CalcDiffuse(diffuse.rgb, NE, NL, LH, roughness);
	vec3  Fs = vec3(0.0);

  #if defined(USE_SPECULARMAP)
  #if defined(USE_LIGHT_VECTOR)
	float NH = clamp(dot(N, H), 0.0, 1.0);
	float VH = clamp(dot(E, H), 0.0, 1.0);
	Fs = CalcSpecular(specular.rgb, NH, NL, NE, LH, VH, roughness);
  #endif

  #if ((defined(USE_LIGHTMAP) && defined(USE_DELUXEMAP)) || defined(USE_LIGHT_VERTEX)) && defined(r_deluxeSpecular)
	float NH = clamp(dot(N, H), 0.0, 1.0);
	float VH = clamp(dot(E, H), 0.0, 1.0);
	Fs = CalcSpecular(specular.rgb, NH, NL, NE, LH, VH, roughness) * r_deluxeSpecular;
  #endif
  #endif

	vec3 reflectance = Fd + Fs;

	out_Color.rgb  = lightColor * reflectance * (attenuation * NL);
	out_Color.rgb += diffuseAmbientColor * diffuse.rgb;

	// kept separately: r_forwardPlusDebug, later SSGI style consumers
	vec3 dynamicLight = CalcDynamicLightContribution(roughness, N, E, u_ViewOrigin, viewDir, NE, diffuse.rgb, specular.rgb, vertexNormal);
	out_Color.rgb += dynamicLight;
#if defined(USE_SSR)
	vec3 cubemapReflection = CalcIBLContribution(roughness, N, E, u_ViewOrigin, viewDir, NE, specularAO, lightColor + ambientColor);
	out_Color.rgb += cubemapReflection;
  #if defined(USE_SPECULARMAP)
	out_SSRNormal = vec4(SSREncodeNormal(N), roughness, 1.0);
	out_SSRSpecular = vec4(sqrt(clamp(SSRSpecularWeight(roughness, NE, specularAO), 0.0, 1.0)), 0.0);
	out_SSRCubemap.rgb = cubemapReflection;
  #endif
#else
	out_Color.rgb += CalcIBLContribution(roughness, N, E, u_ViewOrigin, viewDir, NE, specularAO, lightColor + ambientColor);
#endif
#if defined(USE_SSGI)
	SSGIWriteReceiver(N, roughness, diffuse.rgb);
#endif

  #if defined(USE_PRIMARY_LIGHT)
	vec3  L2   = normalize(u_PrimaryLightOrigin.xyz);
	vec3  H2   = normalize(L2 + E);
	float NL2  = clamp(dot(N,  L2), 0.0, 1.0);
	float L2H2 = clamp(dot(L2, H2), 0.0, 1.0);
	float NH2  = clamp(dot(N,  H2), 0.0, 1.0);
	float VH2  = clamp(dot(E, H), 0.0, 1.0);
	reflectance  = CalcDiffuse(diffuse.rgb, NE, NL2, L2H2, roughness);
	reflectance += CalcSpecular(specular.rgb, NH2, NL2, NE, L2H2, VH2, roughness);

	lightColor = u_PrimaryLightColor;
    #if defined(USE_SHADOWMAP)
	lightColor *= shadowValue;
    #endif

	out_Color.rgb += lightColor * reflectance * NL2;
  #endif

  #if defined(USE_SHADOWMAP) && defined(USE_SHADOWS2)
	// r_shadowDebug 1-9. These values are deliberately written unlit; the
	// post-process path bypasses tone mapping while a shadow debug view is on.
	if (u_ShadowDebug.x >= 1.0)
	{
		vec3 debugColor;
		if (u_ShadowDebug.x == 1.0)
		{
			vec3 c0 = vec3(1.0, 0.18, 0.12);
			vec3 c1 = vec3(0.15, 1.0, 0.2);
			vec3 c2 = vec3(0.15, 0.35, 1.0);
			debugColor = sunInfo.cascade < 1.0 ?
				mix(c0, c1, sunInfo.cascade) : mix(c1, c2, sunInfo.cascade - 1.0);
		}
		else if (u_ShadowDebug.x == 2.0)
			debugColor = vec3(sunInfo.rawDepth);
		else if (u_ShadowDebug.x == 3.0)
			debugColor = vec3(sunInfo.fixedPcf);
		else if (u_ShadowDebug.x == 4.0)
			debugColor = vec3(sunInfo.blockerDepth);
		else if (u_ShadowDebug.x == 5.0)
			debugColor = vec3(sunInfo.penumbraWorld / max(u_ShadowPcss.y, 1e-5));
		else if (u_ShadowDebug.x == 6.0)
			debugColor = vec3(sunInfo.visibility);
		else if (u_ShadowDebug.x == 7.0)
			debugColor = vec3(contactShadow);
		else if (u_ShadowDebug.x == 8.0)
			debugColor = vec3(sunInfo.visibility * contactShadow);
		else
			debugColor = vec3(sunInfo.biasWorld / max(u_ShadowBias.w, 1e-5));

		out_Color = vec4(debugColor, diffuse.a);
		out_Glow = vec4(0.0, 0.0, 0.0, diffuse.a);
		return;
	}
  #endif

#if defined(USE_DIFFUSE_IBL) && defined(USE_LIGHT_VECTOR)
	if (u_DiffuseIBLParams.y >= 1.0 && u_DiffuseIBLParams.y <= 5.0)
	{
		vec3 debugColor;
		if (u_DiffuseIBLParams.y == 1.0)
			debugColor = probeIrradiance;
		else if (u_DiffuseIBLParams.y == 2.0)
			debugColor = directionalFactor * 0.5; // neutral response = middle gray
		else if (u_DiffuseIBLParams.y == 3.0)
			debugColor = ambientColor * diffuse.rgb;
		else if (u_DiffuseIBLParams.y == 4.0)
			debugColor = diffuseAmbientColor * diffuse.rgb;
		else if (u_DiffuseIBLParams.w > 0.5)
		{
			float id = u_DiffuseIBLParams.z + 1.0;
			debugColor = fract(sin(id * vec3(12.9898, 78.233, 39.3467)) * 43758.5453);
		}
		else
			debugColor = vec3(1.0, 0.0, 1.0); // legacy fallback: no probe
		out_Color = vec4(debugColor, diffuse.a);
		out_Glow = vec4(0.0, 0.0, 0.0, diffuse.a);
    #if defined(USE_SSR) && defined(USE_SPECULARMAP)
		out_SSRSpecular = vec4(0.0);
		out_SSRCubemap.rgb = vec3(0.0);
    #endif
		return;
	}
#endif

#if defined(USE_LTC_DEBUG) && defined(PER_PIXEL_LIGHTING)
	// r_ltcDebug 1-5, 8, written unlit (tone mapping is bypassed)
	vec3 ltcDebugColor;
	if (LtcDebugColor(u_ViewOrigin - viewDir, out_Color.rgb, ltcDebugColor))
	{
		out_Color = vec4(ltcDebugColor, diffuse.a);
		out_Glow = vec4(0.0, 0.0, 0.0, diffuse.a);
    #if defined(USE_SSR) && defined(USE_SPECULARMAP)
		out_SSRSpecular = vec4(0.0);
		out_SSRCubemap.rgb = vec3(0.0);
    #endif
		return;
	}
#endif

	// r_forwardPlusDebug 1-9, written unlit (tone mapping is bypassed)
	vec3 fplusDebugColor;
	if (FPlusDebugColor(u_ViewOrigin - viewDir, out_Color.rgb, dynamicLight, fplusDebugColor))
	{
		out_Color = vec4(fplusDebugColor, diffuse.a);
		out_Glow = vec4(0.0, 0.0, 0.0, diffuse.a);
    #if defined(USE_SSR) && defined(USE_SPECULARMAP)
		out_SSRSpecular = vec4(0.0);
		out_SSRCubemap.rgb = vec3(0.0);
    #endif
		return;
	}

  #if defined(USE_ENTITY_GPU_GRID)
	if (u_GridScale.w > 0.5)
	{
		vec3 legacy = u_AmbientLight + u_DirectedLight * max(dot(N, normalize(var_LightDir.xyz)), 0.0);
		vec3 multi = EntityGridAmbientCompatibility(gridMulti.ambient) +
			EntityGridDirectedCompatibility(gridMulti.directed) * max(dot(N, gridMulti.direction), 0.0);
		vec3 gpu = EntityGridAmbientCompatibility(gridGpu.ambient) +
			EntityGridDirectedCompatibility(gridGpu.directed) * max(dot(N, gridGpu.direction), 0.0);
		vec3 debugColor = vec3(0.0);
		if (u_GridScale.w == 1.0) debugColor = gridGpu.ambient;
		else if (u_GridScale.w == 2.0) debugColor = gridGpu.directed;
		else if (u_GridScale.w == 3.0) debugColor = gridGpu.direction * 0.5 + 0.5;
		else if (u_GridScale.w == 4.0) debugColor = vec3(gridGpu.validity);
		else if (u_GridScale.w == 5.0) debugColor = fract(gridGpu.cell * 0.125);
		else if (u_GridScale.w == 6.0) debugColor = legacy;
		else if (u_GridScale.w == 7.0) debugColor = multi;
		else if (u_GridScale.w == 8.0) debugColor = gpu;
		else if (u_GridScale.w == 9.0) debugColor = min(abs(gpu - legacy) * 4.0, vec3(1.0));
		out_Color = vec4(debugColor, diffuse.a);
		out_Glow = vec4(0.0, 0.0, 0.0, diffuse.a);
    #if defined(USE_SSR) && defined(USE_SPECULARMAP)
		out_SSRSpecular = vec4(0.0);
		out_SSRCubemap.rgb = vec3(0.0);
    #endif
		return;
	}
  #endif

  #if defined(USE_WETNESS)
	// r_weatherWetnessDebug 1-16 (not 4), written unlit (tone mapping is bypassed)
	if (u_WetnessParams2.z >= 1.0 && u_WetnessParams2.z <= 16.0 && u_WetnessParams2.z != 4.0)
	{
		float shade = 0.35 + 0.65 * NE;
		vec3 debugColor;
		// 11-15: material depth of the shaded point (raw, and rescaled to the
		// relief), < 0 without usable height (no normalHeightMap, flat height
		// or r_puddleHeight 0): magenta in 11, 12, 14
		float debugRawDepth = -1.0;
		float debugDepth = -1.0;
    #if defined(USE_PARALLAXMAP)
		if (u_PuddleHeight.y > 0.0)
		{
			debugRawDepth = SampleMaterialDepth(u_NormalMap, texCoords, g_pom.gradX, g_pom.gradY);
			debugDepth = PuddleRelief(debugRawDepth);
		}
    #endif
		if (u_WetnessParams2.z >= 11.0 && u_WetnessParams2.z <= 15.0 && u_WetnessParams2.z != 13.0 && u_WetnessParams2.z != 15.0 && debugDepth < 0.0)
			debugColor = vec3(1.0, 0.0, 1.0) * shade;
		else if (u_WetnessParams2.z == 11.0)	// raw sampled height, white = 1 (top of the 0..1 range)
			debugColor = vec3(1.0 - debugRawDepth);
		else if (u_WetnessParams2.z == 12.0)	// interpreted relief: deepest dark blue, peaks orange
			debugColor = mix(vec3(0.02, 0.05, 0.4), vec3(1.0, 0.55, 0.1), 1.0 - debugDepth);
		else if (u_WetnessParams2.z == 13.0)	// macro puddle mask only
			debugColor = mix(mix(vec3(0.25), vec3(0.2, 0.9, 0.9), puddleMacroEdge),
				vec3(0.05, 0.2, 1.0), puddleMacro) * shade;
		else if (u_WetnessParams2.z == 14.0)	// micro mask at a half filled basin, ungated
		{
    #if defined(USE_PARALLAXMAP)
			vec3 micro = PuddleMicro(0.5, debugDepth);
			debugColor = mix(mix(vec3(0.15 + 0.5 * (1.0 - debugDepth)), vec3(0.2, 0.9, 0.9), micro.x),
				vec3(0.05, 0.2, 1.0), micro.y);
    #else
			debugColor = vec3(1.0, 0.0, 1.0);
    #endif
		}
		else if (u_WetnessParams2.z == 15.0)	// combined puddle over the relief
			debugColor = mix(mix(vec3(0.15 + 0.5 * (1.0 - max(puddleDepth, 0.0))), vec3(0.2, 0.9, 0.9), puddleEdge),
				vec3(0.05, 0.2, 1.0), puddle);
		else if (u_WetnessParams2.z == 1.0)
			debugColor = vec3(rainExposure) * shade;
		else if (u_WetnessParams2.z == 2.0)
			debugColor = u_WetnessParams.x < 0.0 ? vec3(1.0, 0.0, 1.0) * shade :
				mix(vec3(0.25), vec3(0.1, 0.35, 1.0), wetness) * shade;
		else if (u_WetnessParams2.z == 3.0 || u_WetnessParams2.z == 9.0)
			debugColor = vec3(roughness);
		else if (u_WetnessParams2.z == 5.0)
			debugColor = mix(vec3(0.6, 0.1, 0.1), vec3(0.1, 0.8, 0.1), puddleSlope) * shade;
		else if (u_WetnessParams2.z == 6.0)
			debugColor = u_PuddleParams.x > 0.0 ? mix(vec3(puddleField),
				vec3(0.1, 0.35, 1.0), 0.5 * step(1.0 - u_PuddleParams.x, puddleField)) : vec3(0.25) * shade;
		else if (u_WetnessParams2.z == 7.0)
			debugColor = vec3(smoothstep(0.5, 1.0, rainExposure) * puddleSlope) * shade;
		else if (u_WetnessParams2.z == 8.0)
			debugColor = mix(mix(vec3(0.25), vec3(0.2, 0.9, 0.9), puddleEdge),
				vec3(0.05, 0.2, 1.0), puddle) * shade;
		else if (u_WetnessParams2.z == 16.0)	// wet response class, r_autoPBRDebug 1 colors
		{
			int cls = int(u_WetnessParams3.z + 0.5);
			vec3 classColors[7] = vec3[7](vec3(0.55), vec3(1.0, 0.85, 0.1), vec3(1.0, 0.5, 0.4),
				vec3(0.2, 0.4, 1.0), vec3(0.55, 0.28, 0.08), vec3(0.15, 0.9, 0.3), vec3(0.8, 0.15, 0.9));
			debugColor = (u_WetnessParams.x < 0.0 ? vec3(1.0, 0.0, 1.0) : classColors[clamp(cls, 0, 6)]) * shade;
		}
		else // 10: eligibility
			debugColor = (u_PuddleParams.x < 0.0 ? vec3(1.0, 0.0, 1.0) :
				u_PuddleParams.x > 0.0 ? vec3(0.1, 0.8, 0.1) : vec3(0.25)) * shade;
		out_Color = vec4(debugColor, diffuse.a);
		out_Glow = vec4(0.0, 0.0, 0.0, diffuse.a);
    #if defined(USE_SSR) && defined(USE_SPECULARMAP)
		out_SSRSpecular = vec4(0.0);
		out_SSRCubemap.rgb = vec3(0.0);
    #endif
		return;
	}
  #endif

	// r_autoPBRDebug 1-2, flat color with a little view facing shading so the
	// shape stays readable; written unlit (tone mapping is bypassed)
	if (u_MaterialDebug.a > 0.0)
	{
		out_Color = vec4(u_MaterialDebug.rgb * (0.35 + 0.65 * NE), diffuse.a);
		out_Glow = vec4(0.0, 0.0, 0.0, diffuse.a);
    #if defined(USE_SSR) && defined(USE_SPECULARMAP)
		out_SSRSpecular = vec4(0.0);
		out_SSRCubemap.rgb = vec3(0.0);
    #endif
		return;
	}

  #if defined(USE_PARALLAXMAP) && defined(USE_POM_DEBUG)
	// r_pomDebug 1-8 (compiled with r_pomDebug set at renderer start), written unlit (tone mapping is bypassed)
	int pomView = int(u_PomDebug.w);
	if (pomView >= 1)
	{
		float shade = 0.35 + 0.65 * NE;
		vec3 debugColor;
		if (pomView == 1)	// raw height at the undisplaced coordinate
			debugColor = vec3(1.0 - textureGrad(u_NormalMap, var_TexCoords.xy, g_pom.gradX, g_pom.gradY).r);
		else if (pomView == 2)	// displaced texture coordinate
			debugColor = vec3(fract(texCoords), 0.0);
		else if (pomView == 3)	// view ray hit depth, white = top
			debugColor = g_pom.valid ? vec3(1.0 - g_pom.depth) : vec3(0.3, 0.0, 0.3);
		else if (pomView == 4)	// sun self shadow (1 without a sun shadow map)
			debugColor = vec3(pomSunShadow) * shade;
		else if (pomView == 5)	// darkest self shadow of the dynamic lights
			debugColor = vec3(g_pomLocalShadow) * shade;
		else if (pomView == 6)	// view ray height samples
			debugColor = g_pom.valid ? PomDebugHeat(g_pom.viewSamples / 74.0) : vec3(0.3) * shade;
		else if (pomView == 7)	// self shadow height samples, all lights
			debugColor = PomDebugHeat(g_pom.shadowSamples / (3.0 * max(u_PomShadow.y, 1.0)));
		else	// distance fade
			debugColor = PomDebugHeat(g_pom.fade) * shade;
		out_Color = vec4(debugColor, 1.0);
		out_Glow = vec4(0.0, 0.0, 0.0, 1.0);
    #if defined(USE_SSR) && defined(USE_SPECULARMAP)
		out_SSRSpecular = vec4(0.0);
		out_SSRCubemap.rgb = vec3(0.0);
    #endif
		return;
	}
  #endif

  #if defined(USE_SILHOUETTE_POM)
	// r_pomSilhouetteDebug 4-8, 10, 11 (1-3 are overlays, 9 is the crossfade
	// split), written unlit (tone mapping is bypassed)
	int pomDebug = int(u_PomParams2.w);
	if (pomDebug >= 4 && pomDebug != 9)
	{
		float shade = 0.35 + 0.65 * NE;
		bool pomWall = pomShell && PomIsWall(var_PomHeader);
		vec3 debugColor;
		if (pomDebug == 4)	// top cap green, walls orange, base surfaces in the crossfade band blue
			debugColor = (pomShell ? (pomWall ? vec3(1.0, 0.55, 0.1) : vec3(0.2, 0.9, 0.3)) : vec3(0.3, 0.4, 1.0)) * shade;
		else if (pomDebug == 5)	// pixels drawn through a boundary wall
			debugColor = pomWall ? vec3(1.0, 0.15, 0.1) : vec3(0.3) * shade;
		else if (pomDebug == 6)	// shell pixels the ray missed (discarded otherwise)
			debugColor = (pomShell && !pomHit.hit) ? vec3(1.0, 0.0, 1.0) : vec3(0.3) * shade;
		else if (pomDebug == 7)	// virtual hit distance, 32 unit bands
			debugColor = PomHeatColor(fract(length(viewDir) / 32.0)) * shade;
		else if (pomDebug == 8)	// height samples of the ray
			debugColor = pomShell ? PomHeatColor(pomHit.samples / (u_PomParams.y + u_PomParams.z + 1.0)) : vec3(0.3) * shade;
		else if (pomDebug == 10)	// linear view depth, 2048 units
			debugColor = vec3(clamp(dot(-viewDir, normalize(u_ViewForward)) / 2048.0, 0.0, 1.0));
		else	// material normal
			debugColor = N * 0.5 + 0.5;
		out_Color = vec4(debugColor, 1.0);
		out_Glow = vec4(0.0, 0.0, 0.0, 1.0);
    #if defined(USE_SSR) && defined(USE_SPECULARMAP)
		out_SSRSpecular = vec4(0.0);
		out_SSRCubemap.rgb = vec3(0.0);
    #endif
		return;
	}
  #endif

  #if defined(USE_SSAO)
	// r_debugAO 7-9, written unlit (tone mapping is bypassed for these)
	if (u_AOParams2.x >= 7.0)
	{
		if (u_AOParams2.x == 7.0)
			out_Color.rgb = vec3(cascadeShadow);
		else if (u_AOParams2.x == 8.0)
			out_Color.rgb = vec3(cascadeShadow * contactShadow);
		else
			out_Color.rgb = indirectOnlyAO ? ambientVisibility : vec3(AO);
		out_Color.a = diffuse.a;
		out_Glow = vec4(0.0, 0.0, 0.0, out_Color.a);
		return;
	}
  #endif
#else
	lightColor = var_Color.rgb;
  #if defined(USE_LIGHTMAP)
	lightColor *= lightmapColor.rgb;
  #endif
  #if defined(USE_SSGI)
	vec3 vertexDynamicLight = CalcDynamicLightContribution(var_Position, var_Normal);
	lightColor += vertexDynamicLight;
	g_ssgiDynamicDiffuse = diffuse.rgb * vertexDynamicLight;
	SSGIWriteReceiver(normalize(var_Normal), 1.0, diffuse.rgb);
  #else
	lightColor += CalcDynamicLightContribution(var_Position, var_Normal);
  #endif

    out_Color.rgb = diffuse.rgb * lightColor;
#endif

	out_Color.a = diffuse.a;
#if defined(USE_SSGI)
	vec3 ssgiLitColor = out_Color.rgb;
	vec3 ssgiEmissive = vec3(0.0);
#endif
	vec3 emissive = vec3(0.0);
	if (abs(u_EmissiveParams.w) == 1.0)
	{
#if defined(USE_SILHOUETTE_POM)
		vec3 emissiveLinear = textureGrad(u_EmissiveMap, texCoords, g_pomGradX, g_pomGradY).rgb * u_EmissiveParams.rgb;
#else
		vec3 emissiveLinear = texture(u_EmissiveMap, texCoords).rgb * u_EmissiveParams.rgb;
#endif
#if defined(USE_SSGI)
		ssgiEmissive = emissiveLinear;
#endif
		if (u_EmissiveParams.w > 0.0)
		{
			emissive = emissiveLinear;
			out_Color.rgb += emissiveLinear;
		}
		else
		{
			emissive = EmissiveLinearToLegacyScene(emissiveLinear);
			out_Color.rgb = EmissiveLinearToLegacyScene(
				EmissiveLegacySceneToLinear(out_Color.rgb) + emissiveLinear);
		}
	}
	else if (abs(u_EmissiveParams.w) == 2.0)
	{
		emissive = out_Color.rgb;
	}
	// Legacy glow still exports the complete stage color. New emissive stages
	// export only their masked emission when the legacy keyword is absent.
	out_Glow = mix(vec4(emissive, out_Color.a), out_Color, u_EnableTextures.x);
#if defined(USE_SSGI)
	SSGIWriteRadiance(ssgiLitColor, ssgiEmissive, out_Color.rgb);
#endif
}
