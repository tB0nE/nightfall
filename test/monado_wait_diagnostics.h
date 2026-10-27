#pragma once
#include <unistd.h>
#include <sys/syscall.h>
static void meteor_swapchain_wait_diagnostic(const void *sc,uint32_t index,int uses,int64_t elapsed_ns,int result) {
    if(!getenv("METEOR_XR_WAIT_DIAGNOSTICS")) return;
    fprintf(stderr,"METEOR_SWAPCHAIN_WAIT pid=%ld tid=%ld swapchain=%p image=%u uses=%d elapsed_ns=%lld result=%d\n",
        (long)getpid(),(long)syscall(SYS_gettid),sc,index,uses,(long long)elapsed_ns,result);
}
