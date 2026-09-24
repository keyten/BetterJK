/*[Vertex]*/

layout(std140) uniform Scene
{
	vec4 u_PrimaryLightOrigin;
	vec3 u_PrimaryLightAmbient;
	int  u_globalFogIndex;
	vec3 u_PrimaryLightColor;
	float u_PrimaryLightRadius;
	float u_frameTime;
	float u_deltaTime;
};

uniform vec2 u_MapZExtents;
uniform vec3 u_EnvForce;
uniform vec4 u_RandomOffset;

in vec3 attr_Position;
in vec3 attr_Color;

out vec3 var_Position;
out vec3 var_Velocity;

const float CHUNK_EXTENDS = 2000.0;
const float HALF_CHUNK_EXTENDS = CHUNK_EXTENDS * 0.5;

vec3 NewParticleZPosition( in vec3 in_position )
{
	vec3 position = in_position;
	position.xy += u_RandomOffset.xy;
	position.z += u_MapZExtents.y - u_MapZExtents.x;

	return position;
}

void main()
{
	var_Velocity = attr_Color;
	var_Velocity = mix(var_Velocity, u_EnvForce, u_deltaTime * 0.002);
	var_Position = attr_Position;
	var_Position += var_Velocity * u_deltaTime;

	if (var_Position.z < u_MapZExtents.x)
	{
		var_Position = NewParticleZPosition(var_Position);
		var_Velocity.xy = u_EnvForce.xy;
	}

	// Keep each physical VBO slot within its own chunk. The CPU can then
	// frustum-cull that slot without changing its particle identity or update.
	var_Position.xy = mod(var_Position.xy + vec2(HALF_CHUNK_EXTENDS),
		vec2(CHUNK_EXTENDS)) - vec2(HALF_CHUNK_EXTENDS);
}
