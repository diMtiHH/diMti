#version 460 core
#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform float uTime;
uniform vec3 uColor;
uniform vec2 uTouch;
uniform float uPressure;
uniform float uHold;
uniform float uEnergy;
uniform float uProgress;
uniform float uActivity;
uniform float uQuality;
uniform float uMotion;
uniform float uPixelRatio;
out vec4 fragColor;
mat2 rot(float a) { float c=cos(a),s=sin(a);return mat2(c,-s,s,c); }
// Height and analytic gradient of four moving lobes. No ray marching,
// finite-difference normal passes or per-frame offscreen texture allocation.
vec3 lobe(vec2 p, vec2 center, vec2 radius, float weight) {
  vec2 d=p-center, inv=1./(radius*radius);
  float value=weight*exp(-dot(d*d,inv));
  return vec3(value,-2.*d*inv*value);
}
vec3 reflectedSpace(vec3 r) {
  vec3 sky=mix(vec3(.018,.026,.045),uColor*.23,smoothstep(-.6,.8,r.y));
  // Broad studio-like space reflections with curved, physically evaluated
  // surface normals; no linear-gradient ellipse masquerading as metal.
  float strip=exp(-pow((r.y-.42+r.x*.31)*6.,2.))*smoothstep(-.9,.3,r.z);
  float softbox=pow(max(0.,dot(r,normalize(vec3(-.65,.75,.5)))),28.);
  float rim=pow(max(0.,dot(r,normalize(vec3(.8,-.2,.35)))),12.);
  sky+=vec3(.95,.98,1.)*(strip*.75+softbox*2.1);
  sky+=uColor*rim*.75;
  sky+=vec3(.2,.24,.30)*exp(-pow((r.y+.5-r.x*.17)*13.,2.));
  return sky;
}
void main() {
  float t=uTime*.24;
  float split=smoothstep(.2,.65,uProgress)*(1.-smoothstep(.72,1.,uProgress));
  vec2 uv=(FlutterFragCoord().xy/uSize-.5)*mix(vec2(2.30,2.30),vec2(2.85,3.0),split);
  uv=rot(.16*sin(t*.57))*uv;
  uv.y*=1.+uHold*.14;
  vec3 density=lobe(uv,vec2(0.),vec2(.69-split*.12,.79-split*.14),1.);
  density+=lobe(uv,vec2(.51+split*.45,.25+.09*sin(t)),vec2(.42,.47),.85);
  density+=lobe(uv,vec2(-.46-split*.30,-.37+.06*cos(t*.7)),vec2(.48,.36),.85);
  density+=lobe(uv,vec2(-.22+.06*sin(t*.8),.55+split*.4),vec2(.36,.40),.75);
  float edge=.49, aa=max(length(density.yz)*2.3/(min(uSize.x,uSize.y)*max(1.,uPixelRatio)),.001);
  float alpha=smoothstep(edge-aa,edge+aa,density.x);
  float height=sqrt(max(.0001,log(max(density.x/edge,1.0001))*.24));
  vec2 slope=.12*density.yz/(max(density.x,.01)*max(height,.012));
  vec2 touch=uv-uTouch*.85;
  float dent=exp(-dot(touch,touch)*8.)*uPressure*.12*uMotion;
  slope+=touch*dent*16.;
  vec3 n=normalize(vec3(-slope,1.)),rd=normalize(vec3(uv*.035,-1.));
  vec3 r=reflect(rd,n);
  float nv=max(0.,dot(n,-rd));
  vec3 f0=vec3(.91,.92,.94),f=f0+(vec3(1.)-f0)*pow(1.-nv,5.);
  vec3 color=reflectedSpace(r)*f;
  float nl=max(0.,dot(n,normalize(vec3(-.4,.7,1.))));
  color+=uColor*.035*nl;
  color*=.70+.30*smoothstep(-.95,.55,uv.y);
  color+=uColor*pow(1.-nv,3.)*.20*(1.+uEnergy*.25);
  color+=uColor*dent*.25;
  color=vec3(1.)-exp(-color*1.14);
  fragColor=vec4(color*alpha,alpha);
}
