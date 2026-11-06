#pragma once
// Small native threading seam for the shared bounded encoded-packet queue.
#ifdef _WIN32
typedef SRWLOCK meteor_delivery_mutex;
typedef CONDITION_VARIABLE meteor_delivery_condition;
typedef HANDLE meteor_delivery_thread;
#define METEOR_DELIVERY_MUTEX_INIT SRWLOCK_INIT
#define METEOR_DELIVERY_CONDITION_INIT CONDITION_VARIABLE_INIT
static void meteor_delivery_lock(meteor_delivery_mutex *m) { AcquireSRWLockExclusive(m); }
static void meteor_delivery_unlock(meteor_delivery_mutex *m) { ReleaseSRWLockExclusive(m); }
static void meteor_delivery_signal(meteor_delivery_condition *c) { WakeConditionVariable(c); }
static void meteor_delivery_broadcast(meteor_delivery_condition *c) { WakeAllConditionVariable(c); }
static void meteor_delivery_wait(meteor_delivery_condition *c,meteor_delivery_mutex *m) {
    SleepConditionVariableSRW(c,m,INFINITE,0);
}
static int meteor_delivery_wait_until(meteor_delivery_condition *c,meteor_delivery_mutex *m,uint64_t deadline) {
    uint64_t now=meteor_direct_now_ms();
    if(now>=deadline) return 1;
    return SleepConditionVariableSRW(c,m,(DWORD)(deadline-now),0) ? 0 : 1;
}
struct meteor_delivery_start {void *(*run)(void *);void *argument;};
static DWORD WINAPI meteor_delivery_entry(void *argument) {
    struct meteor_delivery_start start=*(struct meteor_delivery_start *)argument;
    free(argument); start.run(start.argument); return 0;
}
static int meteor_delivery_create(meteor_delivery_thread *thread,void *(*run)(void *),void *argument) {
    struct meteor_delivery_start *start=malloc(sizeof(*start));
    if(!start) return 1;
    start->run=run;start->argument=argument;
    *thread=CreateThread(NULL,0,meteor_delivery_entry,start,0,NULL);
    if(!*thread) {free(start);return 1;}
    return 0;
}
static void meteor_delivery_join(meteor_delivery_thread thread) {
    WaitForSingleObject(thread,INFINITE);CloseHandle(thread);
}
#else
#include <pthread.h>
typedef pthread_mutex_t meteor_delivery_mutex;
typedef pthread_cond_t meteor_delivery_condition;
typedef pthread_t meteor_delivery_thread;
#define METEOR_DELIVERY_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#define METEOR_DELIVERY_CONDITION_INIT PTHREAD_COND_INITIALIZER
static void meteor_delivery_lock(meteor_delivery_mutex *m) {pthread_mutex_lock(m);}
static void meteor_delivery_unlock(meteor_delivery_mutex *m) {pthread_mutex_unlock(m);}
static void meteor_delivery_signal(meteor_delivery_condition *c) {pthread_cond_signal(c);}
static void meteor_delivery_broadcast(meteor_delivery_condition *c) {pthread_cond_broadcast(c);}
static void meteor_delivery_wait(meteor_delivery_condition *c,meteor_delivery_mutex *m) {pthread_cond_wait(c,m);}
static int meteor_delivery_wait_until(meteor_delivery_condition *c,meteor_delivery_mutex *m,uint64_t deadline) {
    uint64_t now=meteor_direct_now_ms();
    if(now>=deadline) return 1;
    struct timespec absolute;clock_gettime(CLOCK_REALTIME,&absolute);
    uint64_t ns=absolute.tv_nsec+(deadline-now)*1000000;
    absolute.tv_sec+=(time_t)(ns/1000000000);absolute.tv_nsec=(long)(ns%1000000000);
    return pthread_cond_timedwait(c,m,&absolute);
}
static int meteor_delivery_create(meteor_delivery_thread *thread,void *(*run)(void *),void *argument) {
    return pthread_create(thread,NULL,run,argument);
}
static void meteor_delivery_join(meteor_delivery_thread thread) {pthread_join(thread,NULL);}
#endif
