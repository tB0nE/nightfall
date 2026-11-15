/* SPDX-License-Identifier: MIT
 * Explicit Meteor socket activation; no dependency on systemd. Returns a
 * duplicated, close-on-exec listener owned by the runtime, or -1 on error.
 */
#pragma once
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int
meteor_xr_listen_fd(const char *value)
{
    if (!value || !*value) { errno = EINVAL; return -1; }
    for (const char *p = value; *p; ++p) {
        if (*p < '0' || *p > '9') { errno = EINVAL; return -1; }
    }
    char *end = NULL;
    errno = 0;
    long parsed = strtol(value, &end, 10);
    if (errno || *end || parsed < 3 || parsed > INT_MAX) { errno = EINVAL; return -1; }
    int fd = (int)parsed, accepting = 0, type = 0;
    socklen_t size = sizeof(accepting);
    if (getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &size) || !accepting) {
        errno = EINVAL; return -1;
    }
    size = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_STREAM) {
        errno = EINVAL; return -1;
    }
    struct sockaddr_un address;
    size = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &size) || address.sun_family != AF_UNIX) {
        errno = EINVAL; return -1;
    }
    int copy = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    if (copy < 0) { return -1; }
    close(fd);
    return copy;
}
