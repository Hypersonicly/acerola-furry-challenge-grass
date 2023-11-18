Shader "Custom/Water" {
	SubShader {
		Tags {
			"LightMode" = "ForwardBase"
		}

		Pass {
            Cull Off

			CGPROGRAM

			#pragma vertex vert
			#pragma fragment frag

			#include "UnityPBSLighting.cginc"
            #include "AutoLight.cginc"

			struct VertexData {
				float4 vertex : POSITION;
				float3 normal : NORMAL;
                float2 uv : TEXCOORD0;
			};

			struct v2f {
				float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
				float3 normal : TEXCOORD1;
				float3 worldPos : TEXCOORD2;
			};

            int _ShellIndex; // This is the current shell layer being operated on, it ranges from 0 -> _ShellCount 
			int _ShellCount; // This is the total number of shells, useful for normalizing the shell index
			float _ShellLength; // This is the amount of distance that the shells cover, if this is 1 then the shells will span across 1 world space unit
			float _Density;  // This is the density of the strands, used for initializing the noise
			float _NoiseMin, _NoiseMax; // This is the range of possible hair lengths, which the hash then interpolates between 
			float _Thickness; // This is the thickness of the hair strand
			float _Attenuation; // This is the exponent on the shell height for lighting calculations to fake ambient occlusion (the lack of ambient light)
			float _OcclusionBias; // This is an additive constant on the ambient occlusion in order to make the lighting less harsh and maybe kind of fake in-scattering
			float _ShellDistanceAttenuation; // This is the exponent on determining how far to push the shell outwards, which biases shells downwards or upwards towards the minimum/maximum distance covered
			float _Curvature; // This is the exponent on the physics displacement attenuation, a higher value controls how stiff the hair is
			float _DisplacementStrength; // The strength of the displacement (very complicated)
			float3 _ShellColor; // The color of the shells (very complicated)
			float3 _ShellDirection; // The direction the shells are going to point towards, this is updated by the CPU each frame based on user input/movement

			//int hash
			float hash(uint n) {
				// integer hash copied from Hugo Elias
				n = (n << 13U) ^ n;
				n = n * (n * n * 15731U + 0x789221U) + 0x1376312589U;
				return float(n & uint(0x7fffffffU)) / float(0x7fffffff);
			}
			//random 1d from 2d
			float rand1d(float2 value, float2 dotDir = float2(12.9898, 78.233)){
    			float2 smallValue = sin(value);
    			float random = dot(smallValue, dotDir);
    			random = frac(sin(random) * 143758.5453);
    			return random;
			}
			//random 2d
			float2 rand2d(float2 value){
    			return float2(
        			rand1d(value, float2(12.989, 78.233)),
        			rand1d(value, float2(39.346, 11.135))
    			);
			}

			float2 modulo(float2 divident, float2 divisor){
    			float2 positiveDivident = divident % divisor + divisor;
    			return positiveDivident % divisor;
			}

			float voronoiNoise(float2 value, float2 period){
    			float2 baseCell = floor(value);

    			float minDistToCell = 10;
    			[unroll]
    			for(int x=-1; x<=1; x++){
        			[unroll]
        			for(int y=-1; y<=1; y++){
            			float2 cell = baseCell + float2(x, y);
						float2 tiledCell = modulo(cell, period);
            			float2 cellPosition = cell + rand2d(tiledCell);
            			float2 toCell = cellPosition - value;
            			float distToCell = length(toCell);
            			if(distToCell < minDistToCell){
                			minDistToCell = distToCell;
            			}
        			}
    			}
    			return minDistToCell;
			}

			v2f vert(VertexData v) {
				v2f i;

				//normalize shell height 
				float shellHeight = (float)_ShellIndex / (float)_ShellCount;
				//adjust shell height based on voronoi noise
				shellHeight = pow(shellHeight, _ShellDistanceAttenuation) * lerp(0.25, 1, voronoiNoise((frac(v.uv*2) * 2 - 1), float2(2, 2)));
				// extrude shells along normals according height
				v.vertex.xyz += v.normal.xyz * _ShellLength * shellHeight;
				//convert normals to world space
                i.normal = normalize(UnityObjectToWorldNormal(v.normal));
				//calculate stiffness
				float k = pow(shellHeight, _Curvature);
				//displace shells according to strength and stiffness
				v.vertex.xyz += _ShellDirection * k * _DisplacementStrength;

                i.worldPos = mul(unity_ObjectToWorld, v.vertex);
                i.pos = UnityObjectToClipPos(v.vertex);

                i.uv = v.uv;

				return i;
			}

			float4 frag(v2f i) : SV_TARGET {
				//scale uv to create more strands
				float2 newUV = i.uv * _Density;
				//convert to local space uv
				float2 localUV = frac(newUV) * 2 - 1;

				float localDistanceFromCenter = length(localUV);
				// This casts the above uvs to uint so it can be more easily passed into the hashing function without doing a ton of annoying casts because
				// type casting can be really annoying and really ruin your day and you will generally not notice for potentially hours sometimes
                uint2 tid = newUV;
				uint seed = tid.x + 100 * tid.y + 100 * 10;

                float shellIndex = _ShellIndex;
                float shellCount = _ShellCount;
				//generate random number from hashing function and lerp it
                float rand = lerp(_NoiseMin, _NoiseMax, hash(seed));
				//normalized shell height
                float h = shellIndex / shellCount;

				//calculate distance for pixels to be outside of thickness
				int outsideThickness = (localDistanceFromCenter) > (_Thickness * (rand - h));
				
				//culls pixels outside of thickness
				if (outsideThickness && _ShellIndex > 0) discard;
				// This is the lighting output since at this point we have determined we are not discarding the pixel, so we have to color it
				// This lighting model is a modification of the Valve's half lambert as described in the video. It is not physically based, but it looks cool I think.
				// What's going on here is we take the dot product between the normal and the direction of the main Unity light source (the sun) which returns a value
				// between -1 to 1, which is then clamped to 0 to 1 by the DotClamped function provided by Unity, we then convert the 0 to 1 to 0.5 to 1 with the following
				// multiplication and addition.
				float ndotl = DotClamped(i.normal, _WorldSpaceLightPos0) * 0.5f + 0.5f;
				// Valve's half lambert squares the ndotl output, which is going to bring values down, once again you can see how this looks on desmos by graphing x^2
				ndotl = ndotl * ndotl;
				// In order to fake ambient occlusion, we take the normalized shell height and take it to an attenuation exponent, which will do the same exact thing
				// I have explained that exponents will do to numbers between 0 and 1. A higher attenuation value means the occlusion of ambient light will become much stronger,
				// as the number is brought down closer to 0, and if we multiply a color with 0 then it'll be black aka in shadow.
				float ambientOcclusion = pow(h, _Attenuation);
				// This is a additive bias on the ambient occlusion, if you don't want the gradient to go towards black then you can add a bit to this in order to prevent
				// such a harsh gradient transition
				ambientOcclusion += _OcclusionBias;
				// Since the bias can push the ambient occlusion term above 1, we want to clamp it to 0 to 1 in order to prevent breaking the laws of physics by producing
				// more light than was received since if you multiply a color with a number greater than 1, it'll become brighter, and that just physically does not make
				// sense in this context
				ambientOcclusion = saturate(ambientOcclusion);
				// We put it all together down here by multiplying the color with Valve's half lambert and our fake ambient occlusion. You can remove some of these terms
				// to see how it changes the lighting and shadowing.
                return float4(_ShellColor * ndotl * ambientOcclusion, 1.0);
			}

			ENDCG
		}
	}
}