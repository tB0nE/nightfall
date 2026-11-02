/* Tiny allocation-only ABI probe: no GPU commands, shaders, DRM or root.
 * Structure layouts correspond to Qualcomm's public msm_kgsl UAPI:
 * https://github.com/lfdevs/mesa-for-android-container/blob/adreno-main/src/freedreno/vulkan/msm_kgsl.h
 * Each successful allocation is freed; closing the fd also releases ownership.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct alloc_old { uint32_t id, flags; uint64_t size, mmapsize, gpuaddr, reserved[2]; };
struct free_old { uint32_t id, reserved; };
struct alloc_new { uint64_t size, flags, va_len, mmapsize; uint32_t id, metadata_len; uint64_t metadata; };
struct info_new { uint64_t gpuaddr, flags, size, va_len, va_addr; uint32_t id; };
struct free_new { uint64_t flags, priv; uint32_t id, type, len; };
_Static_assert(sizeof(struct alloc_old) == 48, "old allocation ABI");
_Static_assert(sizeof(struct alloc_new) == 48, "new allocation ABI");
_Static_assert(sizeof(struct free_old) == 8, "old free ABI");
_Static_assert(sizeof(struct free_new) == 32, "new free ABI");

int main(void) {
    alarm(3); /* Device-side cap independent of the host/USB session. */
    char context[256] = "unknown", domain[80] = "unknown";
    FILE *label = fopen("/proc/self/attr/current", "r");
    if (label) { if (fgets(context, sizeof(context), label)) {
        char *type = strchr(context, ':');
        if (type) type = strchr(type + 1, ':');
        if (type) { char *end = strchr(++type, ':'); if (end) *end = 0;
            snprintf(domain, sizeof(domain), "%.79s", type); }
    } fclose(label); }
    printf("{\"uid\":%u,\"euid\":%u,\"selinux_domain\":\"%s\",\"bytes_per_allocation\":4096,\"tests\":[", getuid(), geteuid(), domain);
    const uint32_t modes[] = {0, 3U << 26, (3U << 26) | (1U << 31)};
    int first = 1;
    for (unsigned api = 0; api < 2; api++) for (unsigned mode = 0; mode < 3; mode++) {
        int fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
        int open_error = fd < 0 ? errno : 0, result = -1, alloc_error = 0, free_error = 0, info_error = 0;
        int has_gpuaddr = 0;
        if (fd >= 0) {
            if (api == 0) {
                struct alloc_old request = {.size = 4096, .flags = modes[mode]};
                result = ioctl(fd, _IOWR(0x09, 0x34, struct alloc_old), &request);
                alloc_error = result < 0 ? errno : 0;
                if (result == 0) {
                    struct free_old release = {.id = request.id};
                    if (ioctl(fd, _IOWR(0x09, 0x35, struct free_old), &release) < 0) free_error = errno;
                }
            } else {
                struct alloc_new request = {.size = 4096, .flags = modes[mode]};
                result = ioctl(fd, _IOWR(0x09, 0x45, struct alloc_new), &request);
                alloc_error = result < 0 ? errno : 0;
                if (result == 0) {
                    struct info_new info = {.id = request.id};
                    if (ioctl(fd, _IOWR(0x09, 0x47, struct info_new), &info) < 0) info_error = errno;
                    else has_gpuaddr = info.gpuaddr != 0;
                    struct free_new release = {.id = request.id};
                    if (ioctl(fd, _IOW(0x09, 0x46, struct free_new), &release) < 0) free_error = errno;
                }
            }
            close(fd);
        }
        printf("%s{\"api\":\"%s\",\"flags\":%u,\"open_errno\":%d,\"allocated\":%s,\"allocation_errno\":%d,\"free_errno\":%d,\"info_errno\":%d,\"gpu_address_available\":%s}",
               first ? "" : ",", api ? "GPUOBJ_ALLOC" : "GPUMEM_ALLOC_ID", modes[mode], open_error,
               result == 0 ? "true" : "false", alloc_error, free_error, info_error, has_gpuaddr ? "true" : "false");
        first = 0;
    }
    puts("]}");
    return 0;
}
