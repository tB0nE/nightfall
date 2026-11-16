#!/usr/bin/env python3
"""Compile and exercise the actual receiver function from the vcpkg patch.

Alternating two receive threads deterministically exposes process-global fairness
state, without a headset, a stream, or timing-dependent race detection.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'addons/nightfall-stream/vcpkg-overlay/moonlight-common-c/0004-multipath-second-path.patch'


class ReceiverTest(unittest.TestCase):
    def test_audio_video_keep_independent_receive_order(self):
        lines = PATCH.read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line.startswith('+int recvUdpSocketMultipath('))
        end = next(i for i in range(start, len(lines)) if lines[i] == '+}')
        function = '\n'.join(line[1:] for line in lines[start:end + 1])
        preamble = r'''
#include <stdbool.h>
#include <pthread.h>
#include <stdio.h>
#include <poll.h>
#include <sys/socket.h>
#include <string.h>
typedef int SOCKET;
#define INVALID_SOCKET -1
#define UDP_RECV_POLL_TIMEOUT_MS 100
// Both paths have data. recvfrom identifies which was read, with no OS/network
// scheduling involved. The production receiver body below is unmodified.
static int pollSockets(struct pollfd *p, int n, int timeout) {
    (void)timeout;
    for(int i=0;i<n;i++) p[i].revents=POLLIN;
    return n;
}
static ssize_t fake_recvfrom(int fd, void *buffer, size_t n, int flags, struct sockaddr *a, socklen_t *l) {
    (void)n;(void)flags;(void)a;(void)l;
    *(char*)buffer=(char)fd; return 1;
}
#define recvfrom fake_recvfrom
static int recvUdpSocket(SOCKET s, char *buffer, int size, bool select) {
    (void)size;(void)select; *buffer=(char)s; return 1;
}
'''
        harness = r'''
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition=PTHREAD_COND_INITIALIZER;
static int turn=0;
static char results[2][2];
static void *receive(void *arg) {
    int id=*(int*)arg;
    for(int i=0;i<2;i++) {
        pthread_mutex_lock(&mutex);
        while(turn != i*2+id) pthread_cond_wait(&condition,&mutex);
        recvUdpSocketMultipath(1,2,&results[id][i],1,false);
        turn++;
        pthread_cond_broadcast(&condition);
        pthread_mutex_unlock(&mutex);
    }
    return NULL;
}
int main(void) {
    pthread_t threads[2];int ids[2]={0,1};
    for(int i=0;i<2;i++) pthread_create(&threads[i],NULL,receive,&ids[i]);
    for(int i=0;i<2;i++) pthread_join(threads[i],NULL);
    for(int i=0;i<2;i++) {
        if(results[i][0]!=2 || results[i][1]!=1) {
            fprintf(stderr,"receiver %d shares fairness state: %d,%d\n",i,results[i][0],results[i][1]);
            return 1;
        }
    }
    char buffer=0;
    if(recvUdpSocketMultipath(7,INVALID_SOCKET,&buffer,1,false)!=1 || buffer!=7) return 2;
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='nf-multipath-receiver-') as temporary:
            source = Path(temporary) / 'receiver.c'
            executable = Path(temporary) / 'receiver'
            source.write_text(preamble + function + harness)
            subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-pthread', str(source), '-o', str(executable)], check=True, timeout=30)
            subprocess.run([str(executable)], check=True, timeout=5)


if __name__ == '__main__':
    unittest.main()
