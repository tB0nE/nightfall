/* Host-only ABI adapter tests: never opens a GPU or submits commands. */
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#define syscall mock_syscall
#include "kgsl-compat.c"
#undef syscall
static int calls, fail_info, freed, passthrough;
long mock_syscall(long number, ...) {
    (void)number;
    va_list ap; va_start(ap,number);
    int fd=va_arg(ap,int); unsigned long req=va_arg(ap,unsigned long); void *arg=va_arg(ap,void *);
    va_end(ap); assert(fd==7); calls++;
    if(req==_IOWR(9,0x34,struct old_alloc) || req==_IOWR(9,0x35,struct old_free)) { errno=EACCES; return -1; }
    if(req==_IOWR(9,0x45,struct new_alloc)) {
        struct new_alloc *a=arg;
        assert(a->flags==((1ULL<<32)|8)); assert(a->size==4096);
        a->id=42; a->mmapsize=8192; return 0;
    }
    if(req==_IOWR(9,0x47,struct new_info)) {
        if(fail_info) {errno=EIO; return -1;}
        struct new_info *i=arg; assert(i->id==42);
        i->gpuaddr=0x100000; i->flags=(1ULL<<32)|8; i->size=4096; return 0;
    }
    if(req==_IOW(9,0x46,struct new_free)) {
        assert(((struct new_free*)arg)->id==42); freed++; return 0;
    }
    passthrough++; errno=EINVAL; return -1;
}
int main(void) {
    struct old_alloc a={.size=4096,.flags=8};
    assert(ioctl(7,_IOWR(9,0x34,struct old_alloc),&a)==0);
    assert(a.id==42 && a.size==4096 && a.mmapsize==8192 && a.gpuaddr==0x100000 && a.flags==8);
    struct old_free f={.id=42};
    assert(ioctl(7,_IOWR(9,0x35,struct old_free),&f)==0 && freed==1);
    fail_info=1; a=(struct old_alloc){.size=4096,.flags=8};
    assert(ioctl(7,_IOWR(9,0x34,struct old_alloc),&a)==-1 && errno==EIO && freed==2);
    assert(ioctl(7,0x123UL,&a)==-1 && errno==EINVAL && passthrough==1);
    assert(calls==10);
    return 0;
}
