/*[Vertex]*/
// Depth (and velocity) of silhouette POM shells and of their base surfaces in
// the crossfade band: depth prepass, sun shadow cascades. tr_pom_silhouette.cpp,
// the ray / height field functions are in pom_silhouette.glsl.
in vec3 attr_Position;
in vec3 attr_Normal;
in vec4 attr_Tangent;
in vec2 attr_TexCoord0;
in vec3 attr_Position2;	// shell: s0, D, group header * 2 + wall (see pom_silhouette.glsl)

layout(std140) uniform Camera
{
	mat4 u_viewProjectionMatrix;
	vec4 u_ViewInfo;
	vec3 u_ViewOrigin;
	vec3 u_ViewForward;
	vec3 u_ViewLeft;
	vec3 u_ViewUp;
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
};

out vec3 var_Position;
out vec2 var_TexCoords;
out vec3 var_Normal;
out vec4 var_Tangent;
out vec2 var_PomShell;
flat out float var_PomHeader;

void main()
{
	vec4 wsPosition = u_ModelMatrix * vec4(attr_Position, 1.0);
	gl_Position = u_viewProjectionMatrix * wsPosition;

	vec3 normal = attr_Normal * 2.0 - vec3(1.0);
	vec3 tangent = attr_Tangent.xyz * 2.0 - vec3(1.0);

	var_Position = wsPosition.xyz;
	var_TexCoords = attr_TexCoord0;
	var_Normal = normalize(mat3(u_ModelMatrix) * normal);
	var_Tangent = vec4(normalize(mat3(u_ModelMatrix) * tangent), attr_Tangent.w * 2.0 - 1.0);
	var_PomShell = attr_Position2.xy;
	var_PomHeader = attr_Position2.z;
}

/*[Fragment]*/
uniform sampler2D u_NormalMap;
uniform vec4 u_NormalScale;

layout(std140) uniform Camera
{
	mat4 u_viewProjectionMatrix;
	vec4 u_ViewInfo;
	vec3 u_ViewOrigin;
	vec3 u_ViewForward;
	vec3 u_ViewLeft;
	vec3 u_ViewUp;
};

#if defined(USE_VELOCITY)
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
};

layout(std140) uniform PreviousEntity
{
	mat4 u_PreviousModelMatrix;
	vec4 u_PreviousLocalLightOrigin;
	vec3 u_PreviousAmbientLight;
	float u_PreviousEntityTime;
	vec3 u_PreviousDirectedLight;
	float u_PreviousFXVolumetricBase;
	vec3 u_PreviousModelLightDir;
	float u_PreviousVertexLerp;
};

layout(std140) uniform TemporalInfo
{
	mat4 u_previousViewProjectionMatrix;
	vec2 u_currentJitter;
	vec2 u_previousJitter;
	float u_previousFrameTime;
};

out vec4 out_Color;
#endif

in vec3 var_Position;
in vec2 var_TexCoords;
in vec3 var_Normal;
in vec4 var_Tangent;
in vec2 var_PomShell;
flat in float var_PomHeader;

void main()
{
	vec3 position = var_Position;
	bool shell = PomIsShellDraw();
	bool ortho = u_PomParams2.z > 0.0;
	float viewDistance = distance(position, u_ViewOrigin);

	// derivatives before any discard
	vec2 uvDx = dFdx(var_TexCoords);
	vec2 uvDy = dFdy(var_TexCoords);

	bool keep = PomFadeKeep(position, u_ViewOrigin, gl_FragCoord.xy, shell);
	if (!keep)
		discard;

	float depth = gl_FragCoord.z;
	if (shell)
	{
		vec3 N = normalize(var_Normal);
		vec3 T = normalize(var_Tangent.xyz - N * dot(N, var_Tangent.xyz));
		vec3 B = cross(N, T) * var_Tangent.w;
		vec3 rayDir = ortho ? normalize(u_ViewForward) : normalize(position - u_ViewOrigin);
		float parallaxDepth = u_NormalScale.a;
		vec2 aspect = PomAspect(vec2(textureSize(u_NormalMap, 0)));
		float pixelFootprint = ortho ? u_PomParams2.z :
			viewDistance * 2.0 * length(u_ViewUp) / (u_ViewInfo.y * r_FBufScale.y);
		bool wall = PomIsWall(var_PomHeader);
		vec2 gradX, gradY;
		PomGradients(wall, uvDx, uvDy, pixelFootprint, var_PomShell.y, parallaxDepth, aspect, gradX, gradY);

		PomHit hit = PomSilhouetteTrace(u_NormalMap, aspect, parallaxDepth,
			position, rayDir, var_TexCoords, var_PomShell.x, var_PomShell.y,
			PomHeaderTexel(var_PomHeader), T, B, N, gradX, gradY);
		if (!hit.hit)
			discard;

		position = hit.position;
		// sun cascades: the caster moves away from the light, the receivers
		// already offset their lookups (r_shadowDepthBias / r_shadowNormalBias)
		if (ortho)
			position += rayDir * u_PomFade.w;
		depth = PomShellDepth(u_viewProjectionMatrix, position, rayDir, viewDistance + hit.t);
	}
	gl_FragDepth = depth;

#if defined(USE_VELOCITY)
	// motion of the virtual surface point: reprojected with the previous
	// camera and entity transform, as velocity.glsl does for its vertices
	vec4 clipPosition = u_viewProjectionMatrix * vec4(position, 1.0);
	vec4 modelPosition = inverse(u_ModelMatrix) * vec4(position, 1.0);
	vec4 prevClipPosition = u_previousViewProjectionMatrix * (u_PreviousModelMatrix * modelPosition);

	vec2 currentPos = (clipPosition.xy / clipPosition.w) * 0.5 + 0.5;
	vec2 prevPos = (prevClipPosition.xy / prevClipPosition.w) * 0.5 + 0.5;
	vec2 motionVector = currentPos - prevPos;

	motionVector -= u_currentJitter / r_FBufScale.xy;
	motionVector -= u_previousJitter / r_FBufScale.xy;

	out_Color = vec4(motionVector, 0.0, 1.0);
#endif
}
