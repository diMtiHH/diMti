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
out vec4 fragColor;
mat2 rot(float a) { float c=cos(a),s=sin(a);return mat2(c,-s,s,c); }
float smoothUnion(float a,float b,float k) { float h=clamp(.5+.5*(b-a)/k,0.,1.);return mix(b,a,h)-k*h*(1.-h); }
float ellipsoid(vec3 p,vec3 r) { float a=length(p/r),b=length(p/(r*r));return a*(a-1.)/max(b,.001); }
float field(vec3 p) {
  float t=uTime*.24;
  p.xz=rot(t*.31)*p.xz;
  p.xy=rot(.16*sin(t*.57))*p.xy;
  float sequence=sin(clamp(uProgress,0.,1.)*3.14159265);
  float split=smoothstep(.2,.65,uProgress)*(1.-smoothstep(.72,1.,uProgress));
  p.y*=1.+uHold*.14;
  p+=sin(p.yzx*4.1+vec3(t,t*.73,-t*.57))*.045;
  float dent=exp(-dot(p.xy-uTouch*.85,p.xy-uTouch*.85)*8.)*uPressure*.16*uMotion;
  p.z+=dent;
  float d=ellipsoid(p,vec3(.69-split*.18,.79-split*.20,.65));
  vec3 a=vec3(.51+split*.45,.25+.11*sin(t),.12);
  vec3 b=vec3(-.46-split*.30,-.37,.14*cos(t*.7));
  vec3 c=vec3(-.22,.55+split*.4,-.18);
  float k=mix(.32,.08,split);
  d=smoothUnion(d,ellipsoid(p-a,vec3(.42,.47,.44)),k);
  d=smoothUnion(d,ellipsoid(p-b,vec3(.48,.36,.43)),k);
  d=smoothUnion(d,ellipsoid(p-c,vec3(.36,.40,.32)),k);
  return d;
}
vec3 normal(vec3 p) {
  vec2 e=vec2(.006,0.);
  return normalize(vec3(field(p+e.xyy)-field(p-e.xyy),
    field(p+e.yxy)-field(p-e.yxy),field(p+e.yyx)-field(p-e.yyx)));
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
  float split=smoothstep(.2,.65,uProgress)*(1.-smoothstep(.72,1.,uProgress));
  float viewWidth=2.20-.40*abs(sin(uTime*.24*.31));
  vec2 uv=(FlutterFragCoord().xy/uSize-.5)*mix(vec2(viewWidth,2.15),vec2(2.65,2.85),split);
  if(length(uv)>1.49) { fragColor=vec4(0.);return; }
  vec3 ro=vec3(uv,3.2),rd=normalize(vec3(uv*.035,-1.));
  float travel=1.75,dist=1.;vec3 p=ro;
  float budget=25.+floor(uQuality*19.);
  for(int i=0;i<45;i++) {
    if(float(i)>=budget) break;
    p=ro+rd*travel;dist=field(p);
    if(dist<.003||travel>4.7) break;
    travel+=dist*.83;
  }
  if(dist>.008||travel>4.7) { fragColor=vec4(0.);return; }
  vec3 n=normal(p),v=-rd,r=reflect(rd,n);
  float nv=max(0.,dot(n,v));
  vec3 f0=vec3(.91,.92,.94),f=f0+(vec3(1.)-f0)*pow(1.-nv,5.);
  vec3 color=reflectedSpace(r)*f;
  float nl=max(0.,dot(n,normalize(vec3(-.4,.7,1.))));
  color+=uColor*.035*nl;
  float micro=sin(p.x*87.+sin(p.y*53.)*.4)*sin(p.z*61.-p.y*33.);
  color*=.985+.015*micro;
  color*=.70+.30*smoothstep(-.95,.55,p.y);
  color+=uColor*pow(1.-nv,3.)*.20*(1.+uEnergy*.25);
  color+=uColor*uPressure*.035*exp(-dot(p.xy-uTouch,p.xy-uTouch)*4.);
  color=vec3(1.)-exp(-color*1.14);
  // Successful ray hits are opaque. Mapping the convergence residual to
  // opacity creates false contour bands across an otherwise smooth metal.
  float alpha=1.-smoothstep(.006,.010,max(0.,dist));
  fragColor=vec4(color*alpha,alpha);
}
