/*
 Copyright (c) 2012 The VCT Project

  This file is part of VoxelConeTracing and is an implementation of
  "Interactive Indirect Illumination Using Voxel Cone Tracing" by Crassin et al

  VoxelConeTracing is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  VoxelConeTracing is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with VoxelConeTracing.  If not, see <http://www.gnu.org/licenses/>.
*/

/*!
* \author Dominik Lazarek (dominik.lazarek@gmail.com)
* \author Andreas Weinmann (andy.weinmann@gmail.com)
*/

#version 420

in VertexData {
  vec3 viewDirVS;
  float pixelSizeVS;
  vec2 uv;
} In;

out vec4 outColor;

uniform sampler2D gBuffer_color;
uniform sampler2D gBuffer_pos;
uniform sampler2D gBuffer_normal;
uniform sampler2D shadowMap;


uniform vec3 lightPos;
uniform vec3 lightDir;
uniform mat4 lightCamProjMat;
uniform mat4 lightCamviewMat;

const uint NODE_MASK_VALUE = 0x3FFFFFFF;
const uint NODE_MASK_TAG = (0x00000001 << 31);
const uint NODE_MASK_TAG_STATIC = (0x00000003 << 30);
const uint NODE_NOT_FOUND = 0xFFFFFFFF;

const uvec3 childOffsets[8] = {
  uvec3(0, 0, 0),
  uvec3(1, 0, 0),
  uvec3(0, 1, 0),
  uvec3(1, 1, 0),
  uvec3(0, 0, 1),
  uvec3(1, 0, 1),
  uvec3(0, 1, 1), 
  uvec3(1, 1, 1)};


 const uint pow2[] = {1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024};

 uniform uint voxelGridResolution;
uniform mat4 viewI;
uniform mat4 voxelGridTransformI;
uniform uint numLevels;

layout(r32ui) uniform readonly uimageBuffer nodePool_next;
layout(r32ui) uniform readonly uimageBuffer nodePool_color;
layout(r32ui) uniform readonly uimageBuffer nodePool_radiance;

vec4 convRGBA8ToVec4(uint val) {
    return vec4( float((val & 0x000000FF)), 
                 float((val & 0x0000FF00) >> 8U), 
                 float((val & 0x00FF0000) >> 16U), 
                 float((val & 0xFF000000) >> 24U));
}

uint convVec4ToRGBA8(vec4 val) {
    return (uint(val.w) & 0x000000FF)   << 24U
            |(uint(val.z) & 0x000000FF) << 16U
            |(uint(val.y) & 0x000000FF) << 8U 
            |(uint(val.x) & 0x000000FF);
}

uint vec3ToUintXYZ10(uvec3 val) {
    return (uint(val.z) & 0x000003FF)   << 20U
            |(uint(val.y) & 0x000003FF) << 10U 
            |(uint(val.x) & 0x000003FF);
}

uvec3 uintXYZ10ToVec3(uint val) {
    return uvec3(uint((val & 0x000003FF)),
                 uint((val & 0x000FFC00) >> 10U), 
                 uint((val & 0x3FF00000) >> 20U));
}

vec4 phong(in vec2 uv, in vec3 normal, in vec3 lVec, in vec3 vVec)
{
    vec4 vSpecular = vec4(0);
    vec4 vDiffuse = vec4(0);
    int shininess = 0;

    vec4 texColor = texture(gBuffer_color, uv);
    vec4 vAmbient = 0.2 * vec4(1,1,1,1) * texColor;
    vVec = normalize(vVec);
    normal = normalize(normal);
    float intensity = 1;
    vec3 lVecNorm = normalize(lVec);
    float lambert = max(dot(normal,lVecNorm), 0.0);
    if(lambert > 0){
       vec4 lightcolor = vec4(1,1,1,1);
       vDiffuse = lightcolor * lambert * texColor * intensity ;
       vec3 R = normalize(reflect(-lVecNorm, normal));
       if(shininess>0){
            float specular = pow(clamp(dot(R, vVec), 0.0, 1.0), shininess);
            vSpecular = lightcolor * specular * intensity;
            }
    }
    return (vAmbient + vDiffuse + vSpecular);
}


/*
 * This function implements the "slab test" algorithm for intersecting a ray
 * with a box
 (http://www.siggraph.org/education/materials/HyperGraph/raytrace/rtinter3.htm)
 */
bool intersectRayWithAABB (in vec3 ro, in vec3 rd,         // Ray-origin and -direction
                           in vec3 boxMin, in vec3 boxMax,
                           out float tEnter, out float tLeave)
{
    vec3 tempMin = (boxMin - ro) / rd; 
    vec3 tempMax = (boxMax - ro) / rd;
    
    vec3 v3Max = max (tempMax, tempMin);
    vec3 v3Min = min (tempMax, tempMin);
    
    tLeave = min (v3Max.x, min (v3Max.y, v3Max.z));
    tEnter = max (max (v3Min.x, 0.0), max (v3Min.y, v3Min.z));    
    
    return tLeave >= tEnter;
}

int traverseOctree(in vec3 posTex, in float d, in float pixelSizeTS, out vec3 nodePosTex, out vec3 nodePosMaxTex) {
  nodePosTex = vec3(0.0);
  nodePosMaxTex = vec3(1.0);

  float sideLength = 1.0;
  int nodeAddress = 0;
  
  for (uint iLevel = 0; iLevel < numLevels; ++iLevel) {
    float voxelSize = sideLength;
    float projVoxelSize = voxelSize / d;

    if (projVoxelSize / 2 < pixelSizeTS) {
      break;
    }
    
    uint nodeNext = imageLoad(nodePool_next, nodeAddress).x;

    uint childStartAddress = nodeNext & NODE_MASK_VALUE;
      if (childStartAddress == 0U) {
        break;
      }
      
      uvec3 offVec = uvec3(2.0 * posTex);
      uint off = offVec.x + 2U * offVec.y + 4U * offVec.z;

      // Restart while-loop with the child node (aka recursion)
      sideLength = sideLength / 2.0;
      nodeAddress = int(childStartAddress + off);
      nodePosTex += vec3(childOffsets[off]) * vec3(sideLength);
      nodePosMaxTex = nodePosTex + vec3(sideLength);
      posTex = 2.0 * posTex - vec3(offVec);
    } // level-for

  return nodeAddress;
}

vec4 coneTrace(in vec3 posTex, in vec3 dirTex, in float coneAngleRad) {
  vec4 color = vec4(0);
  vec3 rayDirTex = dirTex;
  vec3 rayOriginTex = posTex;

  // PixelSize in texture space is the pixel-viewpsace size divided by the scale
  // of the voxelGrid
  float pixelSizeTS = In.pixelSizeVS / length(voxelGridTransformI[0]);
  pixelSizeTS *= 10;
  
  float tEnter = 0.0;
  float tLeave = 0.0;

  if (!intersectRayWithAABB(rayOriginTex, rayDirTex, vec3(0.0), vec3(1.0), tEnter, tLeave)) {
    return color;
  }
  
  tEnter = max(tEnter, 0.0);
    
  vec3 nodePosMin = vec3(0.0);
  vec3 nodePosMax = vec3(1.0);
    
  float end = tLeave;
  for (float f = tEnter + 0.00001; f < end; f += tLeave + 0.00001) {
    vec3 posTex = (rayOriginTex + rayDirTex * f);
   
    int address = traverseOctree(posTex, f, pixelSizeTS, nodePosMin, nodePosMax);
    
    uint nodeColorU = imageLoad(nodePool_color, address).x;
    uint nodeRadianceU = imageLoad(nodePool_radiance, address).x;
    memoryBarrier();

    vec4 newCol = vec4(convRGBA8ToVec4(nodeColorU)) / 255.0;
    vec4 radiance = vec4(convRGBA8ToVec4(nodeRadianceU)) / 255.0;

    newCol *= radiance;
    
    if (!intersectRayWithAABB(posTex, rayDirTex, nodePosMin, nodePosMax, tEnter, tLeave)) {
      return color; // prevent infinite loop
    }

    float colorCorrection = tLeave / (1.0 / float(voxelGridResolution));
    newCol.a = 1.0 - pow((1.0 - newCol.a), colorCorrection); 
    
    newCol.xyz *= newCol.a;
    color = (1.0 - color.a) * newCol + color;
    
    if (color.a > 0.99) {
      return color;
    }
  }

  return color;
}

vec4 gatherIndirectIllum(in vec3 surfacePosWS, in vec3 surfaceNormalWS) {
  vec4 color = vec4(0);
  int weights = 0;
  vec3 posTex = (voxelGridTransformI * vec4(surfacePosWS, 1.0)).xyz * 0.5 + 0.5;

  
  vec3 dir = vec3(0,1,0);
  float nd = max(dot(surfaceNormalWS, dir), 0);
  if (nd > 0.0001) {
    color += nd * coneTrace(posTex, dir, 0.0);
    ++weights;
  }
  
  dir = vec3(1,0,0);
  nd = max(dot(surfaceNormalWS, dir), 0);
  if (nd > 0.0001) {
    color += nd * coneTrace(posTex, dir, 0.0);
    ++weights;
  }
  dir = vec3(0,0,1);
  nd = max(dot(surfaceNormalWS, dir), 0);
  if (nd > 0.0001) {
    color += nd * coneTrace(posTex, dir, 0.0);
    ++weights;
  }
  dir = vec3(0, -1, 0);
  nd = max(dot(surfaceNormalWS, dir), 0);
  if (nd > 0.0001) {
    color += nd * coneTrace(posTex, dir, 0.0);
    ++weights;
  }
  dir = vec3(-1, 0, 0);
  nd = max(dot(surfaceNormalWS, dir), 0);
  if (nd > 0.0001) {
    color += nd * coneTrace(posTex, dir, 0.0);
    ++weights;
  }
  dir = vec3(0,0,-1);
  nd = max(dot(surfaceNormalWS, dir), 0);
  if (nd > 0.0001) {
    color += nd * coneTrace(posTex, dir, 0.0);
    ++weights;
  }

  return color / float(weights);
}


//vec3 dirLightDirectionWS = normalize(vec3(-1.0, 1.0, 1.0));
vec3 dirLightColor = vec3(1.0, 1.0, 1.0);

void main(void)
{
  vec4 posWS = vec4(vec3(texture(gBuffer_pos, In.uv)),1);
  vec3 normalWS = normalize(texture(gBuffer_normal, In.uv).xyz);
  //vec3 diffColor = texture(gBuffer_color, In.uv).xyz;


  
 float visibility = 1.0;
 vec4 posLVS = lightCamviewMat * posWS;
 vec4 posLProj = lightCamProjMat * posLVS;
 posLProj.xyz /= posLProj.w;
 posLProj.xyz = posLProj.xyz * 0.5 + 0.5;

 float e = 0.0008;
 if (abs(texture(shadowMap, posLProj.xy).x) + e < abs(posLProj.z)){
   visibility = 0.1;
 }
 

 outColor = visibility * phong(In.uv, normalWS, normalize(lightDir), normalize(vec3(posWS)));
 outColor += gatherIndirectIllum(posWS, normalWS);

}