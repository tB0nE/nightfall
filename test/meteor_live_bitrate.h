#pragma once
#include <cstdio>
#include <cstdint>
#include <string>
// Latest-only host-local command; caller owns the NVENC thread and session dir.
struct MeteorLiveBitrate {
    uint64_t sequence=0;
    template<class Apply> void poll(const char *root,uint32_t fallback,uint32_t &current,Apply apply) {
        if(!root) return;
        const std::string prefix=std::string(root)+"/bitrate-";
        FILE *request=fopen((prefix+"request").c_str(),"r"); if(!request) return;
        char line[128]{};
        bool read=fgets(line,sizeof(line),request)!=nullptr;
        bool eof=fgetc(request)==EOF; fclose(request);
        unsigned long long next=0; unsigned mbps=0; char extra=0;
        if(!read || !eof || sscanf(line,"%llu %u %c",&next,&mbps,&extra)!=2 || !next || next<=sequence ||
           (mbps && (mbps<8 || mbps>160))) return;
        sequence=next;
        uint32_t target=mbps ? mbps*1000000u : fallback;
        int result=target==current ? 0 : apply(target);
        if(result==0) current=target;
        FILE *ack=fopen((prefix+"ack.tmp").c_str(),"w");
        if(ack) {
            bool ok=fprintf(ack,"%llu %u %u %u\n",next,mbps,current,unsigned(result))>0;
            if(fclose(ack)!=0) ok=false;
            if(ok) rename((prefix+"ack.tmp").c_str(),(prefix+"ack").c_str());
        }
        fprintf(stderr,"METEOR_BITRATE_UPDATE sequence=%llu requested_mbps=%u applied_bps=%u status=%d\n",next,mbps,current,result);
    }
};
