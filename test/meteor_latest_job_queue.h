#pragma once
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

// Owns at most one active and one pending job. Replacement is legal only for
// unencoded raw jobs, never compressed interframes. Callbacks run without lock.
struct meteor_job_queue {
    pthread_mutex_t mutex;
    pthread_cond_t wake;
    pthread_t worker;
    bool started, stopping, failed;
    void *pending;
    bool (*process)(void *);
    void (*dispose)(void *);
    uint64_t accepted, completed, replaced;
};
static void *meteor_jobs_worker(void *context) {
    struct meteor_job_queue *q=context;
    for (;;) {
        pthread_mutex_lock(&q->mutex);
        while (!q->pending && !q->stopping && !q->failed) pthread_cond_wait(&q->wake,&q->mutex);
        if (q->failed || (!q->pending && q->stopping)) { pthread_mutex_unlock(&q->mutex); break; }
        void *job=q->pending; q->pending=NULL;
        pthread_mutex_unlock(&q->mutex);
        bool ok=q->process(job);
        q->dispose(job);
        pthread_mutex_lock(&q->mutex);
        if (ok) ++q->completed;
        else q->failed=true;
        pthread_mutex_unlock(&q->mutex);
        if (!ok) break;
    }
    return NULL;
}
// Ownership transfers only on success; replaced pending jobs are disposed here.
static bool meteor_jobs_submit(struct meteor_job_queue *q,void *job) {
    if (!job) return false;
    pthread_mutex_lock(&q->mutex);
    if (q->stopping || q->failed) { pthread_mutex_unlock(&q->mutex); return false; }
    if (!q->started) {
        q->accepted=q->completed=q->replaced=0;
        if (pthread_create(&q->worker,NULL,meteor_jobs_worker,q)) { pthread_mutex_unlock(&q->mutex); return false; }
        q->started=true;
    }
    void *old=q->pending;
    q->pending=job; ++q->accepted;
    if (old) ++q->replaced;
    pthread_cond_signal(&q->wake); pthread_mutex_unlock(&q->mutex);
    if (old) q->dispose(old);
    return true;
}
static bool meteor_jobs_finish(struct meteor_job_queue *q) {
    pthread_mutex_lock(&q->mutex);
    q->stopping=true; bool started=q->started;
    pthread_cond_signal(&q->wake); pthread_mutex_unlock(&q->mutex);
    if (started) pthread_join(q->worker,NULL);
    pthread_mutex_lock(&q->mutex);
    bool ok=!q->failed; void *pending=q->pending; q->pending=NULL;
    q->started=q->stopping=q->failed=false;
    pthread_mutex_unlock(&q->mutex);
    if (pending) q->dispose(pending);
    return ok;
}
