// Bounded-2 alignment and Bounded-4 contour cleanup. Rebuild PTX with
// tools/build_kernels.py. Pixel-centred clamp-to-edge bilinear sampling.
__device__ float gate(float a, float b, float v) {
    float t = fminf(fmaxf((v-a)/(b-a),0.f),1.f);
    return t*t*(3.f-2.f*t);
}
template<class T> __device__ float bilinear(const T* p,int w,int h,float x,float y,float scale) {
    x=fminf(fmaxf(x,0.f),(float)(w-1)); y=fminf(fmaxf(y,0.f),(float)(h-1));
    int ix=(int)x, iy=(int)y, jx=min(ix+1,w-1), jy=min(iy+1,h-1);
    float fx=x-ix,fy=y-iy;
    float a=p[iy*w+ix]*scale,b=p[iy*w+jx]*scale,c=p[jy*w+ix]*scale,d=p[jy*w+jx]*scale;
    return (a+(b-a)*fx)*(1.f-fy)+(c+(d-c)*fx)*fy;
}
__device__ float dep(const unsigned char* d,int w,int h,float x,float y) {
    return bilinear(d,w,h,x,y,1.f/255.f);
}
__device__ float col(const float* p,int gw,int gh,int w,int h,float x,float y) {
    return bilinear(p,gw,gh,(x+.5f)*gw/w-.5f,(y+.5f)*gh/h-.5f,1.f);
}
extern "C" __global__ void depth_align(const unsigned char* depth,const float* rgb,
    int w,int h,int gw,int gh,unsigned char* out) {
    int idx=blockIdx.x*blockDim.x+threadIdx.x;
    if(idx>=w*h)return;
    float x=idx%w,y=idx/w,base=dep(depth,w,h,x,y);
    float gx=dep(depth,w,h,x+1,y)-dep(depth,w,h,x-1,y);
    float gy=dep(depth,w,h,x,y+1)-dep(depth,w,h,x,y-1);
    float mag=sqrtf(gx*gx+gy*gy);
    if(mag<.015f){out[idx]=depth[idx];return;}
    float nx=gx/mag,ny=gy/mag,ds=0,dw=0;
    for(int i=-4;i<=4;i++) {
        float s=i*.5f,qx=x+nx*s,qy=y+ny*s;
        float score=fabsf(dep(depth,w,h,qx+nx*.5f,qy+ny*.5f)-dep(depth,w,h,qx-nx*.5f,qy-ny*.5f));
        float v=score*score*score*score; ds+=s*v;dw+=v;
    }
    float position=ds/fmaxf(dw,1e-12f),cs=0,cw=0,peak=0;
    for(int i=-4;i<=4;i++) {
        float s=i*.5f,qx=x+nx*s,qy=y+ny*s,energy=0,along=0;
        for(int c=0;c<3;c++) {
            const float* p=rgb+c*gw*gh;
            float cx=col(p,gw,gh,w,h,qx+.5f,qy)-col(p,gw,gh,w,h,qx-.5f,qy);
            float cy=col(p,gw,gh,w,h,qx,qy+.5f)-col(p,gw,gh,w,h,qx,qy-.5f);
            float v=cx*nx+cy*ny;
            energy+=cx*cx+cy*cy;along+=v*v;
        }
        float orientation=gate(.65f,.9f,along/fmaxf(energy,1e-8f));
        float contrast=sqrtf(along),delta=(s-position)/2.f;
        float v=along*along*orientation*expf(-delta*delta*2.f);
        cs+=s*v;cw+=v;peak=fmaxf(peak,contrast*orientation);
    }
    if(cw<1e-10f){out[idx]=depth[idx];return;}
    float confidence=gate(.015f,.06f,mag)*gate(.06f,.2f,peak);
    float shift=fminf(fmaxf(position-cs/cw,-2.f),2.f)*confidence*.75f;
    out[idx]=(unsigned char)roundf(dep(depth,w,h,x+nx*shift,y+ny*shift)*255.f);
}
extern "C" __global__ void depth_contour(const unsigned char* depth,int w,int h,unsigned char* out) {
    int idx=blockIdx.x*blockDim.x+threadIdx.x;
    if(idx>=w*h)return;
    float x=idx%w,y=idx/w,centre=dep(depth,w,h,x,y);
    float tl=dep(depth,w,h,x-1,y-1),tc=dep(depth,w,h,x,y-1),tr=dep(depth,w,h,x+1,y-1);
    float ml=dep(depth,w,h,x-1,y),mr=dep(depth,w,h,x+1,y);
    float bl=dep(depth,w,h,x-1,y+1),bc=dep(depth,w,h,x,y+1),br=dep(depth,w,h,x+1,y+1);
    float gx=(tr+2*mr+br-tl-2*ml-bl)*.25f,gy=(bl+2*bc+br-tl-2*tc-tr)*.25f;
    float mag=sqrtf(gx*gx+gy*gy);
    if(mag<.015f){out[idx]=depth[idx];return;}
    float nx=gx/mag,ny=gy/mag;
    float lo=fminf(fminf(fminf(tl,tr),fminf(bl,br)),fminf(fminf(tc,bc),fminf(ml,mr)));
    float hi=fmaxf(fmaxf(fmaxf(tl,tr),fmaxf(bl,br)),fmaxf(fmaxf(tc,bc),fmaxf(ml,mr)));
    float guard=gate(.4f,.85f,fabsf(dep(depth,w,h,x+nx*2,y+ny*2)-dep(depth,w,h,x-nx*2,y-ny*2))/fmaxf(hi-lo,1e-5f));
    float sum=centre*6;
    for(int i=-2;i<=2;i++)if(i)sum+=dep(depth,w,h,x-ny*i,y+nx*i)*(abs(i)==1?4.f:1.f);
    float limit=fminf(.08f,mag*.4f),delta=fminf(fmaxf(sum/16.f-centre,-limit),limit);
    float value=fminf(fmaxf(centre+gate(.015f,.06f,mag)*guard*.85f*delta,lo),hi);
    out[idx]=(unsigned char)roundf(fminf(fmaxf(value,0.f),1.f)*255.f);
}
