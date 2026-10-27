#pragma once
#include <net.h>
#include <c_api.h>
#include <memory>
#include <cstring>
#include <stdexcept>
#include <cmath>

// FP32 processing independent of the model's FP16 storage. Preserve the CPU
// histogram, temporal history, quantization and pixel-centred guide sampling.
inline const char* meteor_post_shader=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Raw {float raw[];};
layout(binding=1) buffer History {float history[];};
layout(binding=2) buffer Histogram {uint hist[];};
layout(binding=3) buffer State {float state[];};
layout(binding=4) buffer Normalized {float normalized[];};
layout(binding=5) readonly buffer Guide {uint guide[];};
layout(binding=6) buffer Aligned {float aligned[];};
layout(binding=7) buffer Result {uint result[];};
layout(push_constant) uniform parameter {
    int n;int w;int h;int gw;int gh;int mode;int first;int alignment;int cleanup;
    float depth_alpha;float range_alpha;
} p;
shared float minimum[256];shared float maximum[256];shared uint bins[512];
float gate(float lo,float hi,float x) {float t=clamp((x-lo)/(hi-lo),0.,1.);return t*t*(3.-2.*t);}
float at(int kind,int x,int y) {int i=clamp(y,0,p.h-1)*p.w+clamp(x,0,p.w-1);return kind==0 ? normalized[i] : aligned[i];}
float depth(int kind,float x,float y) {
    x=clamp(x,0.,float(p.w-1));y=clamp(y,0.,float(p.h-1));
    int ix=int(x),iy=int(y);float fx=x-float(ix),fy=y-float(iy);
    float a=at(kind,ix,iy),b=at(kind,ix+1,iy),d=at(kind,ix,iy+1),e=at(kind,ix+1,iy+1);
    return (a+(b-a)*fx)*(1.-fy)+(d+(e-d)*fx)*fy;
}
float byte_at(int i) {return float((guide[i/4]>>uint((i%4)*8))&255u)/255.;}
vec3 colour_at(int x,int y) {int i=(clamp(y,0,p.gh-1)*p.gw+clamp(x,0,p.gw-1))*3;return vec3(byte_at(i),byte_at(i+1),byte_at(i+2));}
vec3 colour(float x,float y) {
    precise float sx=(x+.5)*float(p.gw)/float(p.w)-.5;
    precise float sy=(y+.5)*float(p.gh)/float(p.h)-.5;
    x=clamp(sx,0.,float(p.gw-1));y=clamp(sy,0.,float(p.gh-1));
    int ix=int(x),iy=int(y);float fx=x-float(ix),fy=y-float(iy);
    vec3 a=colour_at(ix,iy),b=colour_at(ix+1,iy),d=colour_at(ix,iy+1),e=colour_at(ix+1,iy+1);
    return (a+(b-a)*fx)*(1.-fy)+(d+(e-d)*fx)*fy;
}
void main() {
    int i=int(gl_GlobalInvocationID.x),t=int(gl_LocalInvocationID.x);
    if (p.mode==0) {
        float lo=uintBitsToFloat(0x7f800000u),hi=-uintBitsToFloat(0x7f800000u);
        if(t==0)hist[512]=0u;memoryBarrierBuffer();barrier();
        for(int j=t;j<p.n;j+=256) {float v=raw[j];if((floatBitsToUint(v)&0x7f800000u)==0x7f800000u){atomicOr(hist[512],1u);continue;}lo=min(lo,v);hi=max(hi,v);}
        minimum[t]=lo;maximum[t]=hi;hist[t]=0u;hist[t+256]=0u;barrier();
        for(int s=128;s>0;s/=2) {if(t<s){minimum[t]=min(minimum[t],minimum[t+s]);maximum[t]=max(maximum[t],maximum[t+s]);}barrier();}
        if(t==0){state[0]=minimum[0];state[1]=maximum[0];}return;
    }
    if (p.mode==1) {
        bins[t]=0u;bins[t+256]=0u;barrier();
        if(state[1]>state[0]) {
            float scale=512./(state[1]-state[0]);
            for(int j=i;j<p.n;j+=int(gl_NumWorkGroups.x)*256) if((floatBitsToUint(raw[j])&0x7f800000u)!=0x7f800000u)atomicAdd(bins[clamp(int((raw[j]-state[0])*scale),0,511)],1u);
        }
        barrier();if(bins[t]>0u)atomicAdd(hist[t],bins[t]);if(bins[t+256]>0u)atomicAdd(hist[t+256],bins[t+256]);return;
    }
    if (p.mode==2) {
        if(i!=0)return;float lo=state[0],hi=state[1],rl=lo,rh=lo+1.;
        if(hi>lo) {
            uint lt=uint(float(p.n)*.02),ht=uint(float(p.n)*(1.-.02)),acc=0u;int lb=511,hb=511;
            for(int b=0;b<512;b++){acc+=hist[b];if(acc>=lt){lb=b;break;}}
            acc=0u;for(int b=0;b<512;b++){acc+=hist[b];if(acc>=ht){hb=b;break;}}
            float bw=(hi-lo)/512.;rl=lo+float(lb)*bw;rh=lo+float(hb+1)*bw;if(rh<=rl)rh=rl+.001;
        }
        if(p.first!=0){state[2]=rl;state[3]=rh;}else{state[2]+=p.range_alpha*(rl-state[2]);state[3]+=p.range_alpha*(rh-state[3]);}return;
    }
    if (p.mode==3) {
        if(i>=p.n)return;float scale=1./max(state[3]-state[2],.000001);
        precise float value=(floatBitsToUint(raw[i])&0x7f800000u)==0x7f800000u ? 0. : clamp((raw[i]-state[2])*scale,0.,1.);
        if(p.first==0)value=history[i]+p.depth_alpha*(value-history[i]);
        history[i]=value;normalized[i]=float(uint(clamp(value,0.,1.)*255.))/255.;return;
    }
    if (p.mode==4) {
        if(i>=p.n)return;float x=float(i%p.w),y=float(i/p.w),base=depth(0,x,y);
        float gx=depth(0,x+1.,y)-depth(0,x-1.,y),gy=depth(0,x,y+1.)-depth(0,x,y-1.),mag=length(vec2(gx,gy));
        if(mag<.015){aligned[i]=base;return;}float nx=gx/mag,ny=gy/mag,ds=0.,dw=0.;
        for(int j=-4;j<=4;j++){
            float s=float(j)*.5,qx=x+nx*s,qy=y+ny*s;
            float score=abs(depth(0,qx+nx*.5,qy+ny*.5)-depth(0,qx-nx*.5,qy-ny*.5));
            float v=score*score*score*score;ds+=s*v;dw+=v;
        }
        float position=ds/max(dw,1e-12),cs=0.,cw=0.,peak=0.;
        for(int j=-4;j<=4;j++){
            float s=float(j)*.5,qx=x+nx*s,qy=y+ny*s;
            vec3 cx=colour(qx+.5,qy)-colour(qx-.5,qy),cy=colour(qx,qy+.5)-colour(qx,qy-.5);
            precise float energy=0.;precise float along=0.;
            for(int c=0;c<3;c++){energy+=cx[c]*cx[c]+cy[c]*cy[c];float projection=cx[c]*nx+cy[c]*ny;along+=projection*projection;}
            float orientation=gate(.65,.9,along/max(energy,1e-8)),contrast=sqrt(along),delta=(s-position)/2.;
            float v=along*along*orientation*exp(-delta*delta*2.);cs+=s*v;cw+=v;peak=max(peak,contrast*orientation);
        }
        float value=base;
        if(cw>=1e-10){float confidence=gate(.015,.06,mag)*gate(.06,.2,peak);float shift=clamp(position-cs/cw,-2.,2.)*confidence*.75;value=depth(0,x+nx*shift,y+ny*shift);}
        aligned[i]=floor(value*255.+.5)/255.;return;
    }
    if (p.mode==5) {
        if(i>=p.n)return;float x=float(i%p.w),y=float(i/p.w),centre=depth(1,x,y);
        float tl=depth(1,x-1.,y-1.),tc=depth(1,x,y-1.),tr=depth(1,x+1.,y-1.);
        float ml=depth(1,x-1.,y),mr=depth(1,x+1.,y),bl=depth(1,x-1.,y+1.),bc=depth(1,x,y+1.),br=depth(1,x+1.,y+1.);
        float gx=(tr+2.*mr+br-tl-2.*ml-bl)*.25,gy=(bl+2.*bc+br-tl-2.*tc-tr)*.25,mag=length(vec2(gx,gy)),value=centre;
        if(mag>=.015){
            float nx=gx/mag,ny=gy/mag,lo=min(min(min(tl,tc),min(tr,ml)),min(min(mr,bl),min(bc,br))),hi=max(max(max(tl,tc),max(tr,ml)),max(max(mr,bl),max(bc,br)));
            float guard=gate(.4,.85,abs(depth(1,x+nx*2.,y+ny*2.)-depth(1,x-nx*2.,y-ny*2.))/max(hi-lo,1e-5));
            float sum=centre*6.;for(int j=-2;j<=2;j++)if(j!=0)sum+=depth(1,x-ny*float(j),y+nx*float(j))*(abs(j)==1 ? 4. : 1.);
            float limit=min(.08,mag*.4);value=clamp(centre+gate(.015,.06,mag)*guard*.85*clamp(sum/16.-centre,-limit,limit),lo,hi);
        }
        normalized[i]=floor(clamp(value,0.,1.)*255.+.5)/255.;return;
    }
    if(p.mode==6){
        if(i>=(p.n+3)/4)return;uint word=0u;
        for(int j=0;j<4;j++){int k=i*4+j;if(k<p.n){float v=(p.alignment!=0 && p.cleanup==0) ? aligned[k] : normalized[k];word|=uint(floor(clamp(v,0.,1.)*255.+.5))<<uint(j*8);}}
        result[i]=word;
    }
}
)glsl";

inline const char* meteor_nv12_shader=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Source {uint source[];};
layout(binding=1) buffer Output {uint output_rgb[];};
layout(push_constant) uniform parameter {int sw;int sh;int w;int h;int matrix;int full;} p;
float read_byte(int i){return float((source[i/4]>>uint((i%4)*8))&255u);}
float bilinear(int offset,int stride,int w,int h,float u,float v) {
    float x=u*float(w)-.5,y=v*float(h)-.5,bx=floor(x),by=floor(y),tx=x-bx,ty=y-by;
    int x0=clamp(int(bx),0,w-1)*stride,x1=clamp(int(bx)+1,0,w-1)*stride;
    int y0=clamp(int(by),0,h-1)*p.sw+offset,y1=clamp(int(by)+1,0,h-1)*p.sw+offset;
    precise float a=read_byte(y0+x0)+(read_byte(y0+x1)-read_byte(y0+x0))*tx;
    precise float b=read_byte(y1+x0)+(read_byte(y1+x1)-read_byte(y1+x0))*tx;
    return a+(b-a)*ty;
}
void main(){
    int i=int(gl_GlobalInvocationID.x);if(i>=p.w*p.h)return;int x=i%p.w,y=i/p.w;
    float kr=.2126,kb=.0722;if(p.matrix==5||p.matrix==6){kr=.299;kb=.114;}if(p.matrix==9||p.matrix==10){kr=.2627;kb=.0593;}
    float kg=1.-kr-kb,rv=2.*(1.-kr),bu=2.*(1.-kb),gu=bu*kb/kg,gv=rv*kr/kg;
    float yo=p.full!=0?0.:16.,ys=p.full!=0?1.:255./219.,cs=p.full!=0?1.:255./224.;
    precise vec3 sum=vec3(0.);
    for(int yy=0;yy<4;yy++)for(int xx=0;xx<4;xx++){
        float u=clamp((float(x)+.5)/float(p.w)+((float(xx)+.5)/4.-.5)/float(p.w),0.,1.);
        float v=clamp((float(y)+.5)/float(p.h)+((float(yy)+.5)/4.-.5)/float(p.h),0.,1.);
        float l=(bilinear(0,1,p.sw,p.sh,u,v)-yo)*ys;
        float cu=(bilinear(p.sw*p.sh,2,p.sw/2,p.sh/2,u,v)-128.)*cs;
        float cv=(bilinear(p.sw*p.sh+1,2,p.sw/2,p.sh/2,u,v)-128.)*cs;
        sum+=clamp(vec3(l+rv*cv,l-gu*cu-gv*cv,l+bu*cu),0.,255.);
    }
    uvec3 rgb=uvec3(roundEven(sum/16.));output_rgb[i]=rgb.r|(rgb.g<<8)|(rgb.b<<16);
}
)glsl";

inline const char* meteor_resize_shader=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Source {uint source[];};
layout(binding=1) buffer Normalized {float normalized[];};
layout(binding=2) buffer Thumbnail {float thumbnail[];};
layout(push_constant) uniform parameter {int sw;int sh;int w;int h;int cstep;int mode;int planar;float rx;float ry;} p;
vec4 weights(float t) {
    float a=-.75;
    precise float w0=((a*(t+1.)-5.*a)*(t+1.)+8.*a)*(t+1.)-4.*a;
    precise float w1=((a+2.)*t-(a+3.))*t*t+1.;
    precise float w2=((a+2.)*(1.-t)-(a+3.))*(1.-t)*(1.-t)+1.;
    return vec4(w0,w1,w2,1.-w0-w1-w2);
}
float value(int x,int y,int c){
    int i=clamp(y,0,p.sh-1)*p.sw+clamp(x,0,p.sw-1);
    if(p.planar!=0)return uintBitsToFloat(source[c*p.sw*p.sh+i]);
    i=i*3+c;return float((source[i/4]>>uint((i%4)*8))&255u)/255.;
}
void main(){
    int i=int(gl_GlobalInvocationID.x);
    if(p.mode==1){
        if(i>=432)return;int c=i/144,x=i%16,y=(i%144)/16;
        int x0=x*p.w/16,x1=(x+1)*p.w/16,y0=y*p.h/9,y1=(y+1)*p.h/9;
        precise float sum=0.;for(int yy=y0;yy<y1;yy++)for(int xx=x0;xx<x1;xx++)sum+=normalized[c*p.cstep+yy*p.w+xx];
        thumbnail[i]=sum/float((x1-x0)*(y1-y0));return;
    }
    if(i>=p.w*p.h)return;
    precise float sx=(float(i%p.w)+.5)*p.rx-.5;
    precise float sy=(float(i/p.w)+.5)*p.ry-.5;
    int bx=int(floor(sx)),by=int(floor(sy));vec4 wx=weights(sx-floor(sx)),wy=weights(sy-floor(sy));
    const vec3 mean=vec3(.485,.456,.406),stddev=vec3(.229,.224,.225);
    for(int c=0;c<3;c++){
        precise float sum=0.;for(int j=0;j<4;j++){precise float across=0.;for(int k=0;k<4;k++)across+=wx[k]*value(bx-1+k,by-1+j,c);sum+=wy[j]*across;}
        normalized[c*p.cstep+i]=(sum-mean[c])/stddev[c];
    }
}
)glsl";

inline const char* meteor_blur_shader=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Source {float source[];};
layout(binding=1) buffer Destination {float destination[];};
layout(push_constant) uniform parameter {int w;int h;int horizontal;int radius;float sigma;} p;
void main(){int i=int(gl_GlobalInvocationID.x);if(i>=p.w*p.h)return;int x=i%p.w,y=i/p.w;
    precise float sum=0.;precise float weight=0.;
    for(int t=-p.radius;t<=p.radius;t++){int xx=p.horizontal!=0?clamp(x+t,0,p.w-1):x,yy=p.horizontal!=0?y:clamp(y+t,0,p.h-1);float v=exp(-.5*float(t*t)/(p.sigma*p.sigma));sum+=v*source[yy*p.w+xx];weight+=v;}
    destination[i]=sum/weight;
}
)glsl";

inline std::unique_ptr<ncnn::Pipeline> meteor_pipeline(const ncnn::VulkanDevice* dev,const ncnn::Option& opt,const char* source,int local=256) {
    std::vector<uint32_t> code;
    if(ncnn::compile_spirv_module(source,opt,code))throw std::runtime_error("Cannot compile Vulkan processing shader");
    auto pipeline=std::make_unique<ncnn::Pipeline>(dev);pipeline->set_local_size_xyz(local,1,1);
    std::vector<ncnn::vk_specialization_type> specs(3);specs[0].i=local;specs[1].i=specs[2].i=1;
    if(pipeline->create(code.data(),code.size()*4,specs))throw std::runtime_error("Cannot create Vulkan processing shader");
    return pipeline;
}

struct MeteorProcessing {
    const ncnn::VulkanDevice* device;
    std::shared_ptr<ncnn::VkBlobAllocator> allocator;
    std::unique_ptr<ncnn::VkStagingAllocator> staging;
    ncnn::Option opt;
    int width,height;
    std::unique_ptr<ncnn::Pipeline> post,footprint,resize,blur_pipeline;
    ncnn::VkMat history,histogram,state,normalized,aligned,result;
    ncnn::VkMat prepared,thumb,blur_a,blur_b;
    MeteorProcessing(int gpu,int w,int h):width(w),height(h) {
        if(ncnn_version_number()!=NCNN_VERSION_NUMBER)throw std::runtime_error("Vulkan processing/ncnn runtime version mismatch");
        if(w<1||h<1||w>8192||h>8192||ncnn::create_gpu_instance()!=0||gpu<0||gpu>=ncnn::get_gpu_count())throw std::runtime_error("Invalid Vulkan processing device or dimensions");
        device=ncnn::get_gpu_device(gpu);
        if(device->info.type()==3 || device->info.max_workgroup_invocations()<256)throw std::runtime_error("Hardware Vulkan processing unavailable");
        allocator=std::make_shared<ncnn::VkBlobAllocator>(device);staging=std::make_unique<ncnn::VkStagingAllocator>(device);
        opt.use_vulkan_compute=true;opt.use_fp16_storage=false;opt.use_fp16_packed=false;opt.use_fp16_arithmetic=false;opt.use_packing_layout=false;
        opt.blob_vkallocator=allocator.get();opt.workspace_vkallocator=allocator.get();opt.staging_vkallocator=staging.get();
    }
    ncnn::VkMat upload_bytes(const unsigned char* src,size_t bytes,ncnn::VkCompute& cmd) {
        ncnn::Mat host(int((bytes+3)/4));if(host.empty())throw std::runtime_error("Cannot allocate processing upload");host.fill(0.f);std::memcpy(host.data,src,bytes);
        ncnn::VkMat gpu;cmd.record_clone(host,gpu,opt);if(gpu.empty())throw std::runtime_error("Cannot allocate Vulkan processing upload");return gpu;
    }
    void nv12(const unsigned char* bytes,int sw,int sh,int matrix,bool full,unsigned char* rgb) {
        if(!footprint)footprint=meteor_pipeline(device,opt,meteor_nv12_shader);
        ncnn::VkCompute cmd(device);auto input=upload_bytes(bytes,size_t(sw)*sh*3/2,cmd);
        ncnn::VkMat output(width*height,size_t(4),1,allocator.get());
        if(output.empty())throw std::runtime_error("Cannot allocate RGB conversion output");
        std::vector<ncnn::vk_constant_type> c(6);int v[]={sw,sh,width,height,matrix,int(full)};for(int i=0;i<6;i++)c[i].i=v[i];
        ncnn::Mat dispatch;dispatch.w=width*height;dispatch.h=dispatch.c=1;
        cmd.record_pipeline(footprint.get(),{input,output},{},c,dispatch);
        ncnn::Mat host;cmd.record_clone(output,host,opt);
        if(cmd.submit_and_wait())throw std::runtime_error("Vulkan NV12 conversion failed");
        const auto* values=static_cast<const unsigned*>(host.data);
        for(int i=0;i<width*height;i++){rgb[i*3]=values[i]&255;rgb[i*3+1]=(values[i]>>8)&255;rgb[i*3+2]=(values[i]>>16)&255;}
    }
    ncnn::VkMat prepare(const void* bytes,int sw,int sh,bool planar,float* thumbnail) {
        if(!resize)resize=meteor_pipeline(device,opt,meteor_resize_shader);
        if(prepared.empty()||thumb.empty()){prepared.create(width,height,3,size_t(4),1,allocator.get());thumb.create(432,size_t(4),1,allocator.get());}
        if(prepared.empty()||thumb.empty())throw std::runtime_error("Cannot allocate prepared VDA image");
        ncnn::VkCompute cmd(device);auto input=upload_bytes(static_cast<const unsigned char*>(bytes),size_t(sw)*sh*3*(planar?4:1),cmd);
        std::vector<ncnn::vk_constant_type> c(9);int v[]={sw,sh,width,height,int(prepared.cstep),0,int(planar)};for(int i=0;i<7;i++)c[i].i=v[i];c[7].f=float(sw)/float(width);c[8].f=float(sh)/float(height);
        ncnn::Mat dispatch;dispatch.w=width*height;dispatch.h=dispatch.c=1;
        cmd.record_pipeline(resize.get(),{input,prepared,thumb},{},c,dispatch);
        c[5].i=1;dispatch.w=432;cmd.record_pipeline(resize.get(),{input,prepared,thumb},{},c,dispatch);
        ncnn::Mat host;cmd.record_clone(thumb,host,opt);
        if(cmd.submit_and_wait())throw std::runtime_error("Vulkan VDA preparation failed");
        std::memcpy(thumbnail,host.data,432*4);return prepared;
    }
    ncnn::VkMat soften(const ncnn::VkMat& raw,float sigma) {
        ncnn::VkCompute convert(device);ncnn::VkMat fp32;device->convert_packing(raw,fp32,1,1,convert,opt);
        if(convert.submit_and_wait())throw std::runtime_error("Vulkan depth conversion failed");
        if(sigma<=0)return fp32;
        if(!blur_pipeline)blur_pipeline=meteor_pipeline(device,opt,meteor_blur_shader);
        if(blur_a.empty()||blur_b.empty()){blur_a.create(width*height,size_t(4),1,allocator.get());blur_b.create(width*height,size_t(4),1,allocator.get());}
        if(blur_a.empty()||blur_b.empty())throw std::runtime_error("Cannot allocate depth softening buffers");
        ncnn::VkCompute cmd(device);
        std::vector<ncnn::vk_constant_type> c(5);c[0].i=width;c[1].i=height;c[3].i=std::min(8,int(std::ceil(3*sigma)));c[4].f=sigma;
        ncnn::Mat dispatch;dispatch.w=width*height;dispatch.h=dispatch.c=1;
        c[2].i=1;cmd.record_pipeline(blur_pipeline.get(),{fp32,blur_a},{},c,dispatch);
        c[2].i=0;cmd.record_pipeline(blur_pipeline.get(),{blur_a,blur_b},{},c,dispatch);
        if(cmd.submit_and_wait())throw std::runtime_error("Vulkan depth softening failed");return blur_b;
    }
    void process(const float* raw,const unsigned char* rgb,int gw,int gh,bool first,float da,float ra,bool align,bool cleanup,unsigned char* output) {
        ncnn::VkCompute cmd(device);ncnn::Mat host(width*height);std::memcpy(host.data,raw,size_t(width)*height*4);
        ncnn::VkMat input;cmd.record_clone(host,input,opt);
        process_device(input,rgb,gw,gh,first,da,ra,align,cleanup,output,cmd);
    }
    void process_device(const ncnn::VkMat& input,const unsigned char* rgb,int gw,int gh,bool first,float da,float ra,bool align,bool cleanup,unsigned char* output,ncnn::VkCompute& cmd) {
        if(!post) {
            post=meteor_pipeline(device,opt,meteor_post_shader);
            for(auto* b:{&history,&normalized,&aligned})b->create(width*height,size_t(4),1,allocator.get());
            histogram.create(513,size_t(4),1,allocator.get());state.create(4,size_t(4),1,allocator.get());result.create((width*height+3)/4,size_t(4),1,allocator.get());
            if(history.empty()||histogram.empty()||state.empty()||normalized.empty()||aligned.empty()||result.empty())throw std::runtime_error("Vulkan processing allocation failed");
        }
        unsigned char zero=0;auto guide=upload_bytes(align ? rgb : &zero,align ? size_t(gw)*gh*3 : 1,cmd);
        std::vector<ncnn::VkMat> bindings={input,history,histogram,state,normalized,guide,aligned,result};
        for(int mode=0;mode<=6;mode++) {
            if((mode==4&&!align)||(mode==5&&(!align||!cleanup)))continue;
            std::vector<ncnn::vk_constant_type> c(11);
            int values[]={width*height,width,height,gw,gh,mode,int(first),int(align),int(cleanup)};
            for(int i=0;i<9;i++)c[i].i=values[i];c[9].f=da;c[10].f=ra;
            ncnn::Mat dispatch;dispatch.w=mode==0||mode==2 ? 256 : mode==1 ? 256*64 : mode==6 ? (width*height+3)/4 : width*height;dispatch.h=dispatch.c=1;
            cmd.record_pipeline(post.get(),bindings,{},c,dispatch);
        }
        ncnn::Mat out,validation;cmd.record_clone(result,out,opt);cmd.record_clone(histogram,validation,opt);
        if(cmd.submit_and_wait())throw std::runtime_error("Vulkan postprocessing failed");
        if(static_cast<const unsigned*>(validation.data)[512])throw std::runtime_error("Nonfinite resident depth");
        std::memcpy(output,out.data,size_t(width)*height);
    }
};

// A tensor owns its allocator independently of its model/processor. No raw
// depth is mapped on the host; this object is immutable until destruction.
struct MeteorResidentDepth {
    const ncnn::VulkanDevice* device;
    std::shared_ptr<ncnn::VkBlobAllocator> allocator;
    int width,height;
    ncnn::VkMat data;
    MeteorResidentDepth(MeteorProcessing& p,const ncnn::VkMat& source):device(p.device),allocator(p.allocator),width(p.width),height(p.height) {
        if(source.empty()||size_t(source.w)*source.h*source.d*source.c*source.elempack!=size_t(width)*height)throw std::runtime_error("Invalid resident depth shape");
        auto fp32=p.soften(source,0);
        ncnn::VkCompute cmd(device);cmd.record_clone(fp32,data,p.opt);
        if(cmd.submit_and_wait()||data.empty())throw std::runtime_error("Cannot retain Vulkan depth");
    }
};
