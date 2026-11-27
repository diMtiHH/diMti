#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uEnvironment;
uniform vec2 uTouch;
uniform float uPressure;
uniform float uEnergy;
uniform float uProgress;
uniform float uActivity;
uniform float uQuality;
out vec4 fragColor;

float hash21(vec2 p) {
  vec3 q = fract(vec3(p.xyx) * vec3(.1031, .1030, .0973));
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p); f = f*f*(3.-2.*f);
  return mix(mix(hash21(i), hash21(i+vec2(1,0)), f.x),
    mix(hash21(i+vec2(0,1)), hash21(i+1.), f.x), f.y);
}
mat2 rotate(float a) { float c=cos(a), s=sin(a); return mat2(c,-s,s,c); }

vec3 stars(vec2 p, float scale, float time, float brightness) {
  vec2 q = p*scale + vec2(time*.08,time*.025);
  vec2 cell=floor(q), f=fract(q);
  float seed=hash21(cell), present=step(.68,seed);
  vec2 at=vec2(.17+.66*hash21(cell+17.),.17+.66*hash21(cell+53.));
  vec2 d=f-at; float r=length(d);
  float radius=mix(.010,.032,hash21(cell+111.));
  float core=1.-smoothstep(radius*.25,radius,r);
  float glow=exp(-r*r/(radius*radius*9.))*.15;
  float ray=(exp(-abs(d.x)*210.)*exp(-abs(d.y)*19.)+
    exp(-abs(d.y)*210.)*exp(-abs(d.x)*19.))*.12*step(.94,seed);
  float pulse=.82+.18*sin(time*.45+seed*40.);
  return mix(vec3(.55,.66,.84),vec3(.96,.98,1.),seed)*
    (core+glow+ray)*present*pulse*brightness;
}

void main() {
  vec2 uv=FlutterFragCoord().xy/uSize;
  float aspect=uSize.x/uSize.y;
  vec2 p=(uv-.5)*vec2(aspect,1.);
  float t=uTime, activation=sin(clamp(uProgress,0.,1.)*3.14159265);
  vec2 touch=uTouch*vec2(aspect,.7)*.36;
  vec2 delta=p-touch;
  p+=delta*exp(-dot(delta,delta)*19.)*uPressure*.035;
  p*=1.+activation*.18;
  vec3 color=vec3(.006,.012,.025);
  vec3 accent=vec3(.73,.82,.97);
  if(uEnvironment>2.5) {
    accent=vec3(.93,.71,.52);
    vec2 lens=p-vec2(.12,.03), q=rotate(.3+sin(t*.055)*.12)*lens;
    float l=dot(q*vec2(.82,1.16),q)+.026;
    p+=q*(.014+activation*.014)/l;
    p+=vec2(-q.y,q.x)*(.012+.008*sin(t*.09))/l;
    for(int i=0;i<7;i++) {
      float fi=float(i), radius=.19+fi*.061;
      vec2 arc=rotate(.30+fi*.035+sin(t*.035)*.08)*lens;
      float ellipse=length(arc*vec2(1.,.55+fi*.019));
      float line=exp(-abs(ellipse-radius)*550.);
      float halo=exp(-abs(ellipse-radius)*85.)*.07;
      float window=pow(.5+.5*cos(atan(arc.y,arc.x)-.6-fi*.13),4.);
      color+=(line*.046+halo)*accent*window*(.8+activation*.7);
    }
    color+=accent*.018*exp(-dot(lens,lens)*3.);
  } else if(uEnvironment>1.5) {
    accent=vec3(.44,.86,.77);
    // Depth layers of oblique, folded curtains. Fine vertical striation is
    // carried through the same nonlinear field, not stacked sine-wave lines.
    vec2 base=rotate(-.47)*p;
    for(int i=0;i<8;i++) {
      if(float(i)>4.+uQuality*3.) break;
      float z=float(i)/7.;
      vec2 q=base*(1.+z*.9)+vec2(z*.16,-z*.23);
      q.x+=.18*sin(q.y*3.7+t*.075+z*2.1)+.08*sin(q.y*9.2-t*.041+z);
      q.y+=.10*sin(q.x*6.1+t*.044+z*3.);
      q+=vec2(noise(q*3.+t*.025),noise(q*4.-t*.018))*.13;
      float folded=q.x+.19*sin(q.y*4.2+t*.065+z*2.);
      float band=exp(-abs(folded-(z-.5)*.34)*mix(18.,31.,z));
      float crest=exp(-abs(folded-(z-.5)*.34)*150.);
      float filaments=.55+.45*pow(.5+.5*sin(q.y*190.+noise(q*16.)*17.),2.);
      float veil=.45+.55*noise(vec2(q.y*4.-t*.04,z*7.));
      vec3 spectral=mix(vec3(.055,.19,.48),vec3(.18,.75,.50),
        .5+.5*sin(q.y*2.2+z*2.4));
      spectral=mix(spectral,vec3(.43,.85,.79),crest*.65);
      color+=spectral*(band*.078+crest*.050)*filaments*veil*(1.-z*.45)*(1.+activation*.7);
    }
    color+=vec3(.01,.025,.04)*noise(p*4.+t*.01);
  } else if(uEnvironment>.5) {
    accent=vec3(.59,.67,.98);
    // The galactic centre is deliberately displaced from the living object.
    vec2 q=rotate(-.48)*(p-vec2(.19,-.28)); q.y*=2.25;
    float r=length(q)+.004, a=atan(q.y,q.x);
    float arm=pow(.5+.5*cos(a*3.-log(r+0.02)*4.4-t*(.016+activation*.06)),9.);
    float dust=noise(q*34.+vec2(t*.013,0.));
    float disc=exp(-r*3.4)*(1.-exp(-r*15.));
    float lanes=pow(.5+.5*cos(a*3.-log(r+.018)*4.4-.4),5.);
    color+=mix(vec3(.12,.13,.28),accent,arm)*disc*(.035+arm*.10)*(.35+dust*.65);
    color*=1.-lanes*disc*.22;
    color+=vec3(.78,.83,.96)*exp(-r*36.)*.12;
    color+=stars(q,95.,t*.2,.45)*disc*arm;
  } else {
    color+=vec3(.012,.019,.035)*noise(p*3.+vec2(t*.003,0.));
    color+=vec3(.009,.014,.024)*exp(-length(p-vec2(.12,-.22))*2.);
  }
  color+=stars(p,29.,t, .39);
  color+=stars(p+vec2(19.,7.),51.,t*.65,.28);
  if(uQuality>.4) color+=stars(p+vec2(5.,29.),83.,t*.35,.15);
  float wave=exp(-abs(length(p-touch)-(.18+(1.-uPressure)*.25))*35.)*uPressure;
  color+=accent*wave*.016;
  color+=accent*exp(-dot(p,p)*13.)*(uEnergy*.012+activation*.023+uActivity*.004);
  // A single continuous exposure across the display; no opaque bottom panel.
  color*=.92+.08*pow(max(0.,1.-length(p)*.6),2.);
  color=vec3(1.)-exp(-color*1.32);
  fragColor=vec4(color,1.);
}
