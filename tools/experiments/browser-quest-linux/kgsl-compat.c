/* Experimental guest-only Mesa ABI adapter. No device policy changes.
 * Use only via LD_PRELOAD in a bounded offscreen test, never globally.
 * New allocations remain owned by the same process and KGSL file descriptor.
 */
#include <stdint.h>
#include <stdarg.h>
#include <asm-generic/ioctl.h>
extern long syscall(long, ...);
extern int *__errno_location(void);
#define ERRNO (*__errno_location())
#define SYS_IOCTL 29 /* Linux AArch64 */
struct old_alloc { uint32_t id, flags; uint64_t size, mmapsize, gpuaddr, pad[2]; };
struct old_free { uint32_t id, pad; };
struct new_alloc { uint64_t size, flags, va_len, mmapsize; uint32_t id, metadata_len; uint64_t metadata; };
struct new_info { uint64_t gpuaddr, flags, size, va_len, va_addr; uint32_t id; };
struct new_free { uint64_t flags, priv; uint32_t id, type, len; };
_Static_assert(sizeof(struct old_alloc) == 48, "old alloc ABI");
_Static_assert(sizeof(struct new_alloc) == 48, "new alloc ABI");
_Static_assert(sizeof(struct new_info) == 48, "new info ABI");
_Static_assert(sizeof(struct new_free) == 32, "new free ABI");
static int raw(int fd, unsigned long req, void *arg) { return (int)syscall(SYS_IOCTL, fd, req, arg); }
int ioctl(int fd, unsigned long req, ...) {
    va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
    int result = raw(fd, req, arg);
    if (result >= 0 || (ERRNO != 13 && ERRNO != 25)) return result;
    int original_error = ERRNO;
    if (req == _IOWR(0x09, 0x34, struct old_alloc) && arg) {
        struct old_alloc *old = arg;
        /* Legacy kernel handler implicitly forces 32-bit GPU addresses. The
         * new API does not. Preserve that contract; copying only old->flags
         * can put command buffers above the legacy addressable range.
         */
        struct new_alloc alloc = {.size = old->size, .flags = (uint64_t)old->flags | (1ULL << 32)};
        if (raw(fd, _IOWR(0x09, 0x45, struct new_alloc), &alloc) < 0) return -1;
        struct new_info info = {.id = alloc.id};
        if (raw(fd, _IOWR(0x09, 0x47, struct new_info), &info) < 0) {
            int error = ERRNO;
            struct new_free release = {.id = alloc.id};
            raw(fd, _IOW(0x09, 0x46, struct new_free), &release);
            ERRNO = error; return -1;
        }
        old->id = alloc.id; old->flags = (uint32_t)info.flags;
        old->size = info.size; old->mmapsize = alloc.mmapsize; old->gpuaddr = info.gpuaddr;
        return 0;
    }
    if (req == _IOWR(0x09, 0x35, struct old_free) && arg) {
        struct new_free release = {.id = ((struct old_free *)arg)->id};
        return raw(fd, _IOW(0x09, 0x46, struct new_free), &release);
    }
    ERRNO = original_error;
    return result;
}
