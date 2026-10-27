// Owned-packet and native sender tests; no GPU, runtime or network listener.
#include "monado_direct_transport.h"
#include <assert.h>
#include <stdio.h>
#include <sys/wait.h>

static void child_exact(int fd, void *data, size_t size)
{
    size_t offset = 0;
    while (offset < size) {
        ssize_t done = read(fd, (uint8_t *)data + offset, size - offset);
        assert(done > 0); offset += (size_t)done;
    }
}

static void test_delivery(bool bad_ack)
{
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    meteor_direct_socket = pair[0]; meteor_direct_epoch = 11; meteor_direct_sequence = 0;
    assert(fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0);
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        close(pair[0]);
        uint8_t header[152], payload[5], ack[20] = {0};
        child_exact(pair[1], header, sizeof(header)); child_exact(pair[1], payload, sizeof(payload));
        assert(!memcmp(header, "NFXR", 4) && header[6] == 152 && header[24] == 9 && header[49] == 1);
        assert(header[40] == 5 && header[44] == 0 && header[45] == 2);
        assert(payload[3] == 0x65);
        memcpy(ack, bad_ack ? "BAD!" : "NFXA", 4); meteor_direct_u64(ack + 12, 9, 8);
        assert(write(pair[1], ack, sizeof(ack)) == sizeof(ack));
        if (!bad_ack) {
            child_exact(pair[1], header, sizeof(header)); assert(header[50] == 1 && header[16] == 1);
            uint8_t end[12] = {0}; memcpy(end, "NFXE", 4); meteor_direct_u64(end + 4, 1, 8);
            assert(write(pair[1], end, sizeof(end)) == sizeof(end));
        }
        close(pair[1]); _exit(0);
    }
    close(pair[1]);
    struct meteor_stereo_encode_v1 input = {.size = sizeof(input), .frame_id = 9, .display_ns = 123};
    uint8_t bytes[] = {0, 0, 1, 0x65, 7};
    struct meteor_owned_packet packet = {.bytes = bytes, .length = sizeof(bytes)};
    bool result = meteor_direct_send(&input, &packet, "invalid-unused-port");
    if (result != !bad_ack) fprintf(stderr, "delivery bad_ack=%d result=%d errno=%d\n", bad_ack, result, errno);
    assert(result == !bad_ack);
    if (result) assert(meteor_direct_finish());
    assert(meteor_direct_socket == -1);
    int status; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

int main(void)
{
    uint8_t bytes[] = {1,2,3}; struct meteor_owned_packet copy = {0};
    assert(!meteor_encoded_copy(&copy, bytes, 0));
    assert(!meteor_encoded_copy(&copy, bytes, 8 * 1024 * 1024 + 1));
    assert(meteor_encoded_copy(&copy, bytes, sizeof(bytes)));
    bytes[0] = 9; assert(copy.bytes[0] == 1 && copy.length == 3);
    assert(!meteor_encoded_copy(&copy, bytes, sizeof(bytes))); free(copy.bytes);
    test_delivery(false); test_delivery(true);
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    meteor_direct_socket = pair[0]; close(pair[1]);
    struct meteor_stereo_encode_v1 input = {.frame_id = 1};
    struct meteor_owned_packet packet = {.bytes = bytes, .length = sizeof(bytes)};
    assert(!meteor_direct_send(&input, &packet, "unused")); assert(meteor_direct_socket == -1);
    assert(!meteor_direct_send(&input, &packet, "70000")); assert(meteor_direct_socket == -1);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    meteor_direct_socket = pair[0];
    assert(!meteor_direct_wait(POLLIN, meteor_direct_now_ms() + 20));
    close(pair[1]); meteor_direct_close();
    assert(meteor_direct_finish());
    return 0;
}
