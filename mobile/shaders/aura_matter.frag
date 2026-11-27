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
float hash31(vec3 p) { p=fract(p*.1031);p+=dot(p,p.yzx+33.33);return fract((p.x+p.y)*p.z); }

void main() {
  vec2 uv=(FlutterFragCoord().xy/uSize-.5)*2.3;
  float t=uTime*.35;
  float sequence=sin(clamp(uProgress,0.,1.)*3.14159265);
  float squeeze=1.+uHold*.12+sequence*.18;
  vec3 sum=vec3(0.); float coverage=0.;
  float broad=0.;
  vec2 touch=uTouch*1.05;
  float local=exp(-dot(uv-touch,uv-touch)*3.5)*uPressure;
  uv-=uTouch*local*.16*uMotion;
  uv*=squeeze;
  float layers=9.+floor(uQuality*7.);
  for(int i=0;i<17;i++) {
    if(float(i)>=layers) break;
    float z=-1.06+2.12*float(i)/(layers-1.);
    vec3 p=vec3(uv,z);
    p.xz=rot(t*.19)*p.xz;
    p.xy=rot(-.28+.16*sin(t*.23))*p.xy;
    float a=atan(p.y,p.x), latitude=atan(p.z,length(p.xy));
    float radius=length(p);
    float shape=.83+.115*sin(a*3.+latitude*4.+t*.7)
      +.055*cos(a*5.-latitude*3.-t*.43)+.045*sin(latitude*7.+t*.31);
    shape+=local*.04;
    float shell=exp(-abs(radius-shape)*45.);
    float fine=.5+.5*cos(latitude*171.+a*13.+sin(a*8.+t)*1.7+t*.7);
    float braided=.5+.5*cos(a*97.-latitude*21.+sin(latitude*9.+t*.5)*2.);
    float fibers=pow(fine,19.)*.76+pow(braided,27.)*.24;
    float striation=pow(.5+.5*cos(latitude*53.+a*19.-t*.44),8.);
    float front=.36+.64*(z+1.06)/2.12;
    float density=shell*(fibers*.53+striation*.09);
    float sparks=step(.997,hash31(floor(p*95.)))*shell*.24;
    vec3 tint=mix(uColor,vec3(.92,.97,1.),front*.65);
    sum+=tint*(density+sparks)*front*(1.+uEnergy*.25+sequence*.45);
    broad+=shell*.012;
    coverage+=density*.35;
  }
  float halo=exp(-abs(length(uv)-.81)*13.)*.015;
  sum+=uColor*(broad*.11+halo)*(1.+local*.6);
  sum=vec3(1.)-exp(-sum*1.9);
  float alpha=clamp(max(max(sum.r,sum.g),sum.b)*1.4+coverage*.13,0.,1.);
  float edge=1.-smoothstep(1.34,1.48,length(uv));
  fragColor=vec4(sum*edge,alpha*edge);
}
