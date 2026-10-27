#define _POSIX_C_SOURCE 200809L
#include "meteor_latest_job_queue.h"
#include <assert.h>
#include <stdlib.h>
static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake=PTHREAD_COND_INITIALIZER;
static bool entered, release_first, fail;
static unsigned disposed[5], processed[5];
static bool process(void *job) {
    unsigned id=*(unsigned *)job;
    pthread_mutex_lock(&gate);
    ++processed[id];
    if (id==1) { entered=true; pthread_cond_signal(&wake); while(!release_first) pthread_cond_wait(&wake,&gate); }
    bool ok=!fail;
    pthread_mutex_unlock(&gate); return ok;
}
static void dispose(void *job) {
    pthread_mutex_lock(&gate); ++disposed[*(unsigned *)job]; pthread_mutex_unlock(&gate); free(job);
}
static void *make(unsigned id) { unsigned *p=malloc(sizeof(*p)); assert(p); *p=id; return p; }
int main(void) {
    struct meteor_job_queue q={.mutex=PTHREAD_MUTEX_INITIALIZER,.wake=PTHREAD_COND_INITIALIZER,.process=process,.dispose=dispose};
    assert(meteor_jobs_submit(&q,make(1)));
    pthread_mutex_lock(&gate); while(!entered) pthread_cond_wait(&wake,&gate); pthread_mutex_unlock(&gate);
    assert(meteor_jobs_submit(&q,make(2)));
    assert(meteor_jobs_submit(&q,make(3)));
    assert(disposed[2]==1 && !processed[2]);
    pthread_mutex_lock(&gate); release_first=true; pthread_cond_signal(&wake); pthread_mutex_unlock(&gate);
    assert(meteor_jobs_finish(&q));
    assert(q.accepted==3 && q.completed==2 && q.replaced==1);
    assert(processed[1]==1 && processed[3]==1 && disposed[1]==1 && disposed[3]==1);
    fail=true;
    assert(meteor_jobs_submit(&q,make(4))); assert(!meteor_jobs_finish(&q));
    assert(disposed[4]==1 && !q.started && !q.pending);
    assert(meteor_jobs_finish(&q));
    // A failed active job must also release the pending job during shutdown.
    entered=false; release_first=false;
    assert(meteor_jobs_submit(&q,make(1)));
    pthread_mutex_lock(&gate); while(!entered) pthread_cond_wait(&wake,&gate); pthread_mutex_unlock(&gate);
    assert(meteor_jobs_submit(&q,make(2)));
    pthread_mutex_lock(&gate); release_first=true; pthread_cond_signal(&wake); pthread_mutex_unlock(&gate);
    assert(!meteor_jobs_finish(&q));
    assert(q.accepted==2 && !q.completed && disposed[1]==2 && disposed[2]==2 && !q.pending);
}
