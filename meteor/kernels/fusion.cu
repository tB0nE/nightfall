// Same arithmetic as depth_fusion::reference. Compile with tools/build_kernels.py.
extern "C" __global__ void fusion_blur(const float* src,int w,int h,float sigma,int axis,float* out){
 int i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=w*h)return;int x=i%w,y=i/w,r=(int)ceilf(3.f*sigma);float sum=0,norm=0;
 for(int k=-r;k<=r;k++){float t=k/sigma,v=expf(-.5f*t*t);int xx=axis==0?min(max(x+k,0),w-1):x;int yy=axis==1?min(max(y+k,0),h-1):y;sum+=src[yy*w+xx]*v;norm+=v;}out[i]=sum/norm;
}
extern "C" __global__ void fusion_product(const float* a,const float* b,int n,float* out){int i=blockIdx.x*blockDim.x+threadIdx.x;if(i<n)out[i]=a[i]*b[i];}
extern "C" __global__ void fusion_correct(const float* delta,const float* coarse,const float* weighted,const float* coverage,int n,float* out){int i=blockIdx.x*blockDim.x+threadIdx.x;if(i<n)out[i]=delta[i]-(coverage[i]>.01f?weighted[i]/coverage[i]:coarse[i]);}
extern "C" __global__ void fusion_protect(const float* delta,const float* weight,int w,int h,float* out){int i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=w*h)return;int x=i%w,y=i/w;float gx=(delta[y*w+min(x+1,w-1)]-delta[y*w+max(x-1,0)])*.5f,gy=(delta[min(y+1,h-1)*w+x]-delta[max(y-1,0)*w+x])*.5f,d=delta[i]/.10f;out[i]=weight[i]*expf(-.5f*d*d-.5f*(gx*gx+gy*gy)/(.025f*.025f));}
extern "C" __global__ void fusion_finish(const float* base,const float* delta,const float* weight,const float* d2,const float* d8,const float* d24,const float* w2,const float* w8,const float* w24,int n,int multi,float* out){
 int i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=n)return;
 float v=base[i]+(multi?((delta[i]-d2[i])*weight[i]+(d2[i]-d8[i])*w2[i]+(d8[i]-d24[i])*w8[i]+d24[i]*w24[i]):delta[i]*weight[i]);out[i]=fminf(fmaxf(v,0.f),1.f);
}

// Resident VDA preparation: same pixel-centred clamp-to-edge sampling as the
// CPU reference, with normalization before interpolation (not after it).
__device__ float fusion_depth_at(const float* src,int w,int h,int x,int y,const float* range){
 float v=src[min(max(y,0),h-1)*w+min(max(x,0),w-1)];return fminf(fmaxf((v-range[0])/fmaxf(range[1]-range[0],1e-6f),0.f),1.f);
}
extern "C" __global__ void fusion_resample(const float* src,int sw,int sh,const float* range,int w,int h,float* dst){
 int i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=w*h)return;
 float x=fminf(fmaxf((i%w+.5f)*sw/w-.5f,0.f),sw-1.f),y=fminf(fmaxf((i/w+.5f)*sh/h-.5f,0.f),sh-1.f);
 int ix=(int)x,iy=(int)y;float tx=x-ix,ty=y-iy;
 float a=fusion_depth_at(src,sw,sh,ix,iy,range)*(1.f-tx)+fusion_depth_at(src,sw,sh,ix+1,iy,range)*tx;
 float b=fusion_depth_at(src,sw,sh,ix,iy+1,range)*(1.f-tx)+fusion_depth_at(src,sw,sh,ix+1,iy+1,range)*tx;
 dst[i]=a*(1.f-ty)+b*ty;
}
extern "C" __global__ void fusion_crop_planar(const float* src,int sw,int sh,float* dst,int ox,int oy,int cw,int ch){
 int n=cw*ch,i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=n*3)return;
 int c=i/n,p=i%n;dst[i]=src[c*sw*sh+(oy+p/cw)*sw+ox+p%cw];
}
// Deterministic one-block robust trimmed fit. Each thread owns disjoint ring
// samples; only sums/maxima/counts are reduced. Quantile is selected by 32
// bisection steps instead of sorting/readback of the full overlap array.
extern "C" __global__ void fusion_fit(const float* base,const float* detail,int w,int h,float* fit){
 __shared__ double sums[5][256];__shared__ double maxima[256];__shared__ double scale,offset,threshold,lower,upper;
 __shared__ int valid;
 int t=threadIdx.x,cw=w/2,ch=h/2,cols=(cw+1)/2,rows=(ch+1)/2,total=cols*rows;
 if(t==0){scale=1.;offset=0.;threshold=1e30;valid=1;}__syncthreads();
 for(int iteration=0;iteration<5;iteration++){
  double n=0,sx=0,sy=0,xx=0,xy=0;
  for(int j=t;j<total;j+=256){int x=(j%cols)*2,y=(j/cols)*2;float d=min(min(x,y),min(cw-1-x,ch-1-y)),f=w*.05f;
   if(d<f*.25f||d>f*1.25f)continue;
   double a=detail[y*cw+x],b=base[(h/4+y)*w+w/4+x];
   if(fabs(a*scale+offset-b)<=threshold){n++;sx+=a;sy+=b;xx+=a*a;xy+=a*b;}
  }
  sums[0][t]=n;sums[1][t]=sx;sums[2][t]=sy;sums[3][t]=xx;sums[4][t]=xy;__syncthreads();
  for(int stride=128;stride;stride/=2){if(t<stride)for(int c=0;c<5;c++)sums[c][t]+=sums[c][t+stride];__syncthreads();}
  if(t==0){n=sums[0][0];if(n<8.)valid=0;double denom=sums[3][0]-sums[1][0]*sums[1][0]/fmax(n,1.);scale=denom>1e-10?(sums[4][0]-sums[1][0]*sums[2][0]/n)/denom:1.;offset=(sums[2][0]-scale*sums[1][0])/fmax(n,1.);}
  __syncthreads();if(!valid)break;
  double maxerr=0;int count=0;
  for(int j=t;j<total;j+=256){int x=(j%cols)*2,y=(j/cols)*2;float d=min(min(x,y),min(cw-1-x,ch-1-y)),f=w*.05f;if(d<f*.25f||d>f*1.25f)continue;count++;maxerr=fmax(maxerr,fabs(detail[y*cw+x]*scale+offset-base[(h/4+y)*w+w/4+x]));}
  maxima[t]=maxerr;sums[0][t]=count;__syncthreads();
  for(int stride=128;stride;stride/=2){if(t<stride){maxima[t]=fmax(maxima[t],maxima[t+stride]);sums[0][t]+=sums[0][t+stride];}__syncthreads();}
  double target=floor(sums[0][0]*.85)+1.;
  if(t==0){lower=0.;upper=maxima[0];}__syncthreads();
  for(int step=0;step<32;step++){
   double limit=(lower+upper)*.5;int accepted=0;
   for(int j=t;j<total;j+=256){int x=(j%cols)*2,y=(j/cols)*2;float d=min(min(x,y),min(cw-1-x,ch-1-y)),f=w*.05f;if(d<f*.25f||d>f*1.25f)continue;
    if(fabs(detail[y*cw+x]*scale+offset-base[(h/4+y)*w+w/4+x])<=limit)accepted++;}
   sums[0][t]=accepted;__syncthreads();for(int stride=128;stride;stride/=2){if(t<stride)sums[0][t]+=sums[0][t+stride];__syncthreads();}
   if(t==0){if(sums[0][0]>=target)upper=limit;else lower=limit;}__syncthreads();
  }
  if(t==0)threshold=upper;__syncthreads();
 }
 if(t==0){fit[0]=(float)scale;fit[1]=(float)offset;fit[2]=(valid&&isfinite(scale)&&isfinite(offset)&&scale>0.)?1.f:0.f;}
}
extern "C" __global__ void fusion_prepare_delta(const float* base,const float* centre,const float* fit,int w,int h,float* delta,float* mask){
 int i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=w*h)return;int x=i%w-w/4,y=i/w-h/4,cw=w/2,ch=h/2;
 if(x<0||y<0||x>=cw||y>=ch||fit[2]!=1.f){delta[i]=0;mask[i]=0;return;}
 float d=min(min(x,y),min(cw-1-x,ch-1-y)),t=fminf(fmaxf(d/(w*.05f),0.f),1.f);
 mask[i]=t*t*(3.f-2.f*t);delta[i]=centre[y*cw+x]*fit[0]+fit[1]-base[i];
}
extern "C" __global__ void fusion_quantize(const float* src,int n,unsigned char* dst){int i=blockIdx.x*blockDim.x+threadIdx.x;if(i<n)dst[i]=(unsigned char)roundf(fminf(fmaxf(src[i],0.f),1.f)*255.f);}

// Parallel fit: preserve the five trimmed least-squares iterations, but
// distribute sample moments and exact error-quantile selection over the GPU.
// First 12 bytes remain the public scale/offset/valid ABI used by preparation.
struct FusionFitState {
 float scale_out,offset_out,valid_out;int count;
 double scale,offset,threshold;
 unsigned long long prefix;unsigned int rank;int shift;
};
extern "C" __global__ void fusion_fit_samples(const float* base,const float* detail,int w,int h,double2* samples,FusionFitState* state){
 int j=blockIdx.x*blockDim.x+threadIdx.x,cw=w/2,ch=h/2,cols=(cw+1)/2,rows=(ch+1)/2;
 if(j==0){state->scale=1.;state->offset=0.;state->threshold=1e300;state->valid_out=1.f;state->count=cols*rows;}
 if(j>=cols*rows)return;
 int x=(j%cols)*2,y=(j/cols)*2;float d=min(min(x,y),min(cw-1-x,ch-1-y)),f=w*.05f;
 samples[j]=(d>=f*.25f&&d<=f*1.25f)?make_double2(detail[y*cw+x],base[(h/4+y)*w+w/4+x]):make_double2(-1.,0.);
}
extern "C" __global__ void fusion_fit_moments(const double2* samples,const FusionFitState* state,int n,double* partial){
 __shared__ double sums[5][256];int t=threadIdx.x,j=blockIdx.x*blockDim.x+t;
 double a=-1.,b=0.;if(j<n){double2 p=samples[j];a=p.x;b=p.y;}
 bool keep=a>=0.&&fabs(a*state->scale+state->offset-b)<=state->threshold;
 sums[0][t]=keep?1.:0.;sums[1][t]=keep?a:0.;sums[2][t]=keep?b:0.;sums[3][t]=keep?a*a:0.;sums[4][t]=keep?a*b:0.;__syncthreads();
 for(int s=128;s;s/=2){if(t<s)for(int k=0;k<5;k++)sums[k][t]+=sums[k][t+s];__syncthreads();}
 if(t<5)partial[blockIdx.x*5+t]=sums[t][0];
}
extern "C" __global__ void fusion_fit_solve(const double* partial,int blocks,FusionFitState* state){
 double a[5]={0.,0.,0.,0.,0.};for(int b=0;b<blocks;b++)for(int k=0;k<5;k++)a[k]+=partial[b*5+k];
 double n=a[0],denom=a[3]-a[1]*a[1]/fmax(n,1.);
 double scale=denom>1e-10?(a[4]-a[1]*a[2]/n)/denom:1.;double offset=(a[2]-scale*a[1])/fmax(n,1.);
 state->scale=scale;state->offset=offset;state->scale_out=(float)scale;state->offset_out=(float)offset;
 state->valid_out=(n>=8.&&isfinite(scale)&&isfinite(offset)&&scale>0.)?1.f:0.f;
}
extern "C" __global__ void fusion_fit_errors(const double2* samples,const FusionFitState* state,int n,unsigned long long* errors,double* partial){
 __shared__ int counts[256];int t=threadIdx.x,j=blockIdx.x*blockDim.x+t;int valid=0;
 if(j<n){double2 p=samples[j];valid=p.x>=0.;errors[j]=valid?(unsigned long long)__double_as_longlong(fabs(p.x*state->scale+state->offset-p.y)):~0ULL;}
 counts[t]=valid;__syncthreads();for(int s=128;s;s/=2){if(t<s)counts[t]+=counts[t+s];__syncthreads();}
 if(t==0)partial[blockIdx.x*5]=(double)counts[0];
}
extern "C" __global__ void fusion_fit_radix_init(const double* partial,int blocks,FusionFitState* state){
 int count=0;for(int b=0;b<blocks;b++)count+=(int)partial[b*5];state->prefix=0;state->rank=(unsigned int)(count*.85);state->shift=56;
}
extern "C" __global__ void fusion_fit_radix_hist(const unsigned long long* errors,const FusionFitState* state,int n,unsigned int* partial){
 __shared__ unsigned int hist[256];int t=threadIdx.x,j=blockIdx.x*blockDim.x+t;hist[t]=0;__syncthreads();
 if(j<n){unsigned long long key=errors[j];int shift=state->shift;unsigned long long mask=shift==56?0ULL:(~0ULL<<(shift+8));
  if(key!=~0ULL&&(key&mask)==state->prefix)atomicAdd(&hist[(key>>shift)&255],1u);}
 __syncthreads();partial[blockIdx.x*256+t]=hist[t];
}
extern "C" __global__ void fusion_fit_radix_select(const unsigned int* partial,int blocks,FusionFitState* state){
 __shared__ unsigned int hist[256];int t=threadIdx.x;unsigned int count=0;for(int b=0;b<blocks;b++)count+=partial[b*256+t];hist[t]=count;__syncthreads();
 if(t==0){unsigned int rank=state->rank,bin=0;for(;bin<255;bin++){if(rank<hist[bin])break;rank-=hist[bin];}
  state->rank=rank;state->prefix|=(unsigned long long)bin<<state->shift;
  if(state->shift==0)state->threshold=__longlong_as_double((long long)state->prefix);state->shift-=8;}
}
// Coefficients are computed once per instance on the CPU, not once per pixel.
extern "C" __global__ void fusion_blur_cached(const float* src,int w,int h,const float* weights,int radius,float norm,int axis,float* out){
 int i=blockIdx.x*blockDim.x+threadIdx.x;if(i>=w*h)return;int x=i%w,y=i/w;float sum=0;
 for(int k=-radius;k<=radius;k++){int xx=axis==0?min(max(x+k,0),w-1):x;int yy=axis==1?min(max(y+k,0),h-1):y;sum+=src[yy*w+xx]*weights[k+radius];}out[i]=sum/norm;
}
extern "C" __global__ void fusion_quantize_checked(const float* src,const float* fit,int n,unsigned char* dst){
 int i=blockIdx.x*blockDim.x+threadIdx.x;if(i==0)dst[n]=fit[2]==1.f?1:0;
 if(i<n)dst[i]=(unsigned char)roundf(fminf(fmaxf(src[i],0.f),1.f)*255.f);
}
extern "C" __global__ void fusion_copy_checked(const unsigned char* src,const float* fit,int n,unsigned char* dst){int i=blockIdx.x*blockDim.x+threadIdx.x;if(i==0)dst[n]=fit[2]==1.f?1:0;if(i<n)dst[i]=src[i];}
