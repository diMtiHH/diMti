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

// Analytic front/back surfaces replace the depth-sampling loop. Filter fine
// fibers at the destination pixel footprint, not in a stretched small image.
float thread(float phase, float width, float footprint) {
  float aa=max(footprint, .02);
  float distance=abs(fract(phase/3.14159265+.5)-.5)*3.14159265;
  float line=min(2.*width/aa,clamp((width+.5*aa-distance)/aa,0.,1.));
  return mix(line, width*.63662, smoothstep(1.5,3.2,aa));
}
float fibers(vec2 uv, float a, float radius, float side, float t) {
  float r=length(uv)/radius;
  float z=sqrt(max(.001,1.-r*r))*side;
  vec3 p=vec3(uv/radius,z);
  float c=cos(t*.19),s=sin(t*.19);
  p.xz=mat2(c,-s,s,c)*p.xz;
  float longitudinal=atan(p.y,p.x);
  float latitude=atan(p.z,length(p.xy))+.075*sin(longitudinal*3.+t*.7);
  float pixel=2.3/(min(uSize.x,uSize.y)*max(1.,uPixelRatio));
  float latWidth=pixel/(radius*max(.06,abs(z)));
  float angleWidth=pixel/max(length(uv),.03);
  float fine=thread(latitude*85.+longitudinal*6.5+sin(a*8.+t)*.85+t*.35,.12,latWidth*85.+angleWidth*14.);
  float braid=thread(longitudinal*48.-latitude*10.5+sin(latitude*9.+t*.5),.08,angleWidth*48.+latWidth*20.);
  float structure=thread(latitude*26.+a*9.5-t*.22,.16,latWidth*26.+angleWidth*9.5);
  return fine*.58+braid*.18+structure*.13;
}
void main() {
  vec2 uv=(FlutterFragCoord().xy/uSize-.5)*2.3;
  float t=uTime*.35, sequence=sin(clamp(uProgress,0.,1.)*3.14159265);
  float local=exp(-dot(uv-uTouch,uv-uTouch)*3.5)*uPressure;
  uv-=uTouch*local*.16*uMotion;
  uv*=1.+uHold*.12+sequence*.18;
  float a=atan(uv.y,uv.x), r=length(uv);
  float shape=.86+.09*sin(a*3.+t*.7)+.045*cos(a*5.-t*.43)+local*.04;
  float aa=2.8/(min(uSize.x,uSize.y)*max(1.,uPixelRatio));
  float edge=1.-smoothstep(shape-aa,shape+aa,r);
  float front=fibers(uv,a,shape,1.,t);
  float back=fibers(uv,a+.12,shape*.94,-1.,t)*.35;
  float rim=exp(-abs(r-shape)*40.)*.17;
  vec3 tint=mix(uColor,vec3(.92,.97,1.),.42+.16*sin(a+t*.1));
  vec3 light=tint*(front+back+rim)*(1.05+uEnergy*.2+sequence*.35);
  light=vec3(1.)-exp(-light*1.65);
  float alpha=clamp(max(max(light.r,light.g),light.b)*1.35,0.,1.)*edge;
  fragColor=vec4(light*edge,alpha);
}
