/*[Vertex]*/
void main()
{
	vec2 position = vec2(2.0 * float(gl_VertexID & 2) - 1.0, 4.0 * float(gl_VertexID & 1) - 1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

/*[Fragment]*/
// SSR scene color pyramid (tr_ssr.cpp): the next mip of the opaque HDR scene, sampled by rough
// reflections. Four bilinear taps on the texel corners around the 2x2 source block, a 4x4 box: the
// overlapping footprints keep the cone blur of rough surfaces from showing blocks. u_SSRSceneMap has
// BASE_LEVEL = MAX_LEVEL = the source level. u_SSRTexelSize.xy = 1 / source size, zw = 1 / destination
// size.

out vec4 out_Color;

void main()
{
	vec2 uv = gl_FragCoord.xy * u_SSRTexelSize.zw;
	vec2 offset = u_SSRTexelSize.xy;

	vec4 color  = textureLod(u_SSRSceneMap, uv + vec2(-offset.x, -offset.y), 0.0);
	color      += textureLod(u_SSRSceneMap, uv + vec2( offset.x, -offset.y), 0.0);
	color      += textureLod(u_SSRSceneMap, uv + vec2(-offset.x,  offset.y), 0.0);
	color      += textureLod(u_SSRSceneMap, uv + vec2( offset.x,  offset.y), 0.0);
	out_Color = color * 0.25;
}
