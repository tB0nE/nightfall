// Linux-only diagnostic packet sink. No files in the delivery path, loopback only.
#pragma once
#include "monado_nvenc_bridge.h"
#include <stdbool.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <time.h>
#include <unistd.h>

struct meteor_owned_packet { uint8_t *bytes; uint32_t length; };
static int meteor_direct_socket = -1;
static uint64_t meteor_direct_epoch, meteor_direct_sequence;

static void meteor_direct_close(void)
{
    if (meteor_direct_socket >= 0) close(meteor_direct_socket);
    meteor_direct_socket = -1;
}

static int meteor_encoded_copy(void *context, const uint8_t *data, uint32_t length)
{
    struct meteor_owned_packet *packet = context;
    if (!length || length > 8 * 1024 * 1024 || packet->bytes) return 0;
    packet->bytes = malloc(length);
    if (!packet->bytes) return 0;
    memcpy(packet->bytes, data, length); packet->length = length;
    return 1;
}

static uint64_t meteor_direct_now_ms(void)
{
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

static uint64_t meteor_direct_now_us(void)
{
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000 + (uint64_t)now.tv_nsec / 1000;
}

static bool meteor_direct_wait(short events, uint64_t deadline)
{
    for (;;) {
        uint64_t now = meteor_direct_now_ms();
        if (now >= deadline) return false;
        struct pollfd fd = {.fd = meteor_direct_socket, .events = events};
        int result = poll(&fd, 1, (int)(deadline - now));
        if (result < 0 && errno == EINTR) continue;
        return result > 0 && (fd.revents & events) != 0;
    }
}

static bool meteor_direct_io(void *bytes, size_t length, bool writing, uint64_t deadline)
{
    uint8_t *cursor = bytes;
    while (length) {
        if (!meteor_direct_wait(writing ? POLLOUT : POLLIN, deadline)) return false;
        ssize_t done = writing ? send(meteor_direct_socket, cursor, length, MSG_NOSIGNAL) : recv(meteor_direct_socket, cursor, length, 0);
        if (done < 0 && (errno == EAGAIN || errno == EINTR || errno == EWOULDBLOCK)) continue;
        if (done <= 0) return false;
        cursor += done; length -= (size_t)done;
    }
    return true;
}

static void meteor_direct_u64(uint8_t *out, uint64_t value, unsigned length)
{
    for (unsigned i = 0; i < length; ++i) out[i] = (uint8_t)(value >> (i * 8));
}

static void meteor_direct_header(uint8_t header[152], const struct meteor_stereo_encode_v1 *input, uint32_t length, bool idr)
{
    memset(header, 0, 152); memcpy(header, "NFXR", 4);
    meteor_direct_u64(header + 4, 1, 2); meteor_direct_u64(header + 6, 152, 2);
    meteor_direct_u64(header + 8, meteor_direct_epoch, 8);
    meteor_direct_u64(header + 16, meteor_direct_sequence, 8);
    header[48] = 1;
    if (!input) { header[50] = 1; return; }
    meteor_direct_u64(header + 24, input->frame_id, 8);
    meteor_direct_u64(header + 32, input->display_ns, 8);
    meteor_direct_u64(header + 40, length, 4);
    uint32_t eye_size=input->eye_size ? input->eye_size : 256;
    meteor_direct_u64(header + 44, eye_size*2, 2); meteor_direct_u64(header + 46, eye_size, 2);
    header[49] = idr ? 1 : 0;
    if (getenv("METEOR_XR_TRACKED_SCENE")) header[49] |= 2; // Render poses/FOV in adopted Quest LOCAL.
    _Static_assert(sizeof(float) == 4, "Wire requires float32");
    for (unsigned i = 0; i < 22; ++i) {
        uint32_t bits; memcpy(&bits, &input->views[i], 4);
        meteor_direct_u64(header + 64 + i * 4, bits, 4);
    }
}

static bool meteor_direct_connect(const char *port_text, uint64_t deadline)
{
    char *end; long port = strtol(port_text, &end, 10);
    if (!*port_text || *end || port < 1 || port > 65535) return false;
    if (getrandom(&meteor_direct_epoch, sizeof(meteor_direct_epoch), 0) != (ssize_t)sizeof(meteor_direct_epoch)) return false;
    if (!meteor_direct_epoch) meteor_direct_epoch = 1;
    meteor_direct_sequence = 0;
    meteor_direct_socket = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (meteor_direct_socket < 0) return false;
    int enabled = 1;
    if (setsockopt(meteor_direct_socket, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled)) != 0) return false;
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)}};
    if (connect(meteor_direct_socket, (struct sockaddr *)&address, sizeof(address)) != 0) {
        if (errno != EINPROGRESS || !meteor_direct_wait(POLLOUT, deadline)) return false;
        int error; socklen_t size = sizeof(error);
        if (getsockopt(meteor_direct_socket, SOL_SOCKET, SO_ERROR, &error, &size) != 0 || error) return false;
    }
    return true;
}

static bool meteor_direct_send(const struct meteor_stereo_encode_v1 *input, const struct meteor_owned_packet *packet, const char *port)
{
    uint64_t deadline = meteor_direct_now_ms() + 2000;
    if (meteor_direct_socket < 0 && !meteor_direct_connect(port, deadline)) { meteor_direct_close(); return false; }
    if (!packet->bytes || !packet->length || packet->length > 8 * 1024 * 1024 || meteor_direct_sequence >= 2048) {
        meteor_direct_close(); return false;
    }
    bool idr = false;
    for (uint32_t i = 0; i + 3 < packet->length; ++i)
        if (packet->bytes[i] == 0 && packet->bytes[i+1] == 0 && packet->bytes[i+2] == 1 && (packet->bytes[i+3] & 31) == 5) idr = true;
    uint8_t header[152], ack[20], expected[20];
    meteor_direct_header(header, input, packet->length, idr);
    memcpy(expected, "NFXA", 4); meteor_direct_u64(expected + 4, meteor_direct_sequence, 8); meteor_direct_u64(expected + 12, input->frame_id, 8);
    uint64_t send_start = meteor_direct_now_us();
    if (!meteor_direct_io(header, sizeof(header), true, deadline) ||
        !meteor_direct_io(packet->bytes, packet->length, true, deadline)) {
        meteor_direct_close(); return false;
    }
    uint64_t sent = meteor_direct_now_us();
    if (!meteor_direct_io(ack, sizeof(ack), false, deadline) || memcmp(ack, expected, sizeof(ack))) {
        meteor_direct_close(); return false;
    }
    fprintf(stderr,"METEOR_DIRECT_TIMING frame=%llu send_us=%llu ack_us=%llu\n",
        (unsigned long long)input->frame_id, (unsigned long long)(sent-send_start),
        (unsigned long long)(meteor_direct_now_us()-sent));
    ++meteor_direct_sequence;
    return true;
}

static bool meteor_direct_finish(void)
{
    if (meteor_direct_socket < 0) return true;
    uint8_t header[152], ack[12], expected[12];
    meteor_direct_header(header, NULL, 0, false);
    memcpy(expected, "NFXE", 4); meteor_direct_u64(expected + 4, meteor_direct_sequence, 8);
    uint64_t deadline = meteor_direct_now_ms() + 2000;
    bool ok = meteor_direct_io(header, sizeof(header), true, deadline) &&
        meteor_direct_io(ack, sizeof(ack), false, deadline) && !memcmp(ack, expected, sizeof(ack));
    meteor_direct_close();
    return ok;
}
