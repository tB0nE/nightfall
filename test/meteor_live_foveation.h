#pragma once
#include <cstdio>
#include <string>
inline void meteor_poll_foveation(const char *root,bool &enabled) {
    static thread_local std::string previous_root;
    static thread_local unsigned long long sequence=0;
    if(!root) return;
    if(previous_root!=root) {previous_root=root; sequence=0;}
    const std::string prefix=std::string(root)+"/foveation-";
    FILE *file=fopen((prefix+"request").c_str(),"r"); if(!file) return;
    char line[128]{}; bool read=fgets(line,sizeof(line),file)!=nullptr;
    bool eof=fgetc(file)==EOF; fclose(file);
    unsigned long long next=0; unsigned value=0; char extra=0;
    if(!read || !eof || sscanf(line,"%llu %u %c",&next,&value,&extra)!=2 || !next || next<=sequence || value>1) return;
    sequence=next; enabled=value!=0;
    file=fopen((prefix+"ack.tmp").c_str(),"w");
    if(file) {bool ok=fprintf(file,"%llu %u %u 0\n",next,value,value)>0; if(fclose(file)!=0) ok=false;
        if(ok) rename((prefix+"ack.tmp").c_str(),(prefix+"ack").c_str());}
    fprintf(stderr,"METEOR_FOVEATION_UPDATE sequence=%llu enabled=%u\n",next,value);
}
