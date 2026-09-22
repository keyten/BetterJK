/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// Froxel fog composite (tr_volumetric.cpp): the fog of everything drawn before it (the layers up to
// SS_FOG, the sky included) from the depth buffer, in the HDR scene before tone mapping.
//
// Blend ONE, SRC_ALPHA:  color = color * T + S,  glow = glow * T + bloom
//
// The glow buffer is the source of bloom: the fog attenuates it like the scene (as the legacy fog
// pass). r_volumetricFogBloom adds the bright part of the in-scattering (soft knee), so light beams
// bloom and the dim haze does not.

uniform sampler2D u_ScreenDepthMap;

out vec4 out_Color;
out vec4 out_Glow;

void main()
{
	vec2 tc = gl_FragCoord.xy / r_FBufScale;
	float depth = texture(u_ScreenDepthMap, tc).r;

	vec3 worldPos = FroxelSceneWorldPosition(tc, depth);
	vec4 fog = FroxelFog(worldPos);

	vec3 bloom = vec3(0.0);
	float bloomScale = u_FroxelDebugParams.y;
	if (bloomScale > 0.0)
	{
		float luma = dot(fog.rgb, vec3(0.2126, 0.7152, 0.0722));
		float knee = clamp(luma - 0.5, 0.0, 1.0);
		bloom = fog.rgb * knee * knee * bloomScale;
	}

	out_Color = vec4(fog.rgb, fog.a);
	out_Glow = vec4(bloom, fog.a);
}
