#pragma once
// DEV per-client compositor events. Not global compositor/device readiness.
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t meteor_event_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t meteor_event_sequence, meteor_next_session;

static uint64_t meteor_session_event(uint64_t session, const char *event)
{
    const char *generation = getenv("METEOR_XR_RUNTIME_GENERATION");
    if (!generation) return 0; // Legacy probes remain opt-in.
    if (strlen(generation) != 32 || strspn(generation, "0123456789abcdef") != 32) abort();
    pthread_mutex_lock(&meteor_event_mutex);
    if (!session) session = ++meteor_next_session;
    fprintf(stderr, "METEOR_XR_EVENT {\"generation\":\"%s\",\"sequence\":%" PRIu64
            ",\"session\":%" PRIu64 ",\"event\":\"%s\"}\n",
            generation, ++meteor_event_sequence, session, event);
    fflush(stderr);
    pthread_mutex_unlock(&meteor_event_mutex);
    return session;
}
