// CPU 활동 패턴 흉내: N 개 스레드가 (spin) 쉬지 않고 돌거나, (sleep) us 마이크로초씩 자고 깨기를 반복하거나,
// (copy) 10 KiB 를 복사하고 us 마이크로초 쉬기(us=0 이면 64 MiB 를 쉬지 않고 복사)를 반복한다.
//   wakeloop spin|sleep|copy <threads> <us> <seconds>
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <time.h>
#include <unistd.h>
static int mode_sleep, mode_copy, us; static volatile int stop;
static void * run(void * a) {
    (void) a;
    prctl(PR_SET_TIMERSLACK, 1000UL, 0, 0, 0);
    struct timespec ts = {0, us * 1000L};
    unsigned long n = 0;
    const size_t sz = mode_copy && us == 0 ? (64u << 20) : 10240;
    char * src = mode_copy ? malloc(sz) : NULL, * dst = mode_copy ? malloc(sz) : NULL;
    if (mode_copy) { memset(src, 1, sz); memset(dst, 0, sz); }
    while (!stop) {
        if (mode_copy) { memcpy(dst, src, sz); __asm__ volatile("" ::: "memory"); if (us) nanosleep(&ts, NULL); }
        else if (mode_sleep) nanosleep(&ts, NULL);
        else __builtin_ia32_pause();
        n++;
    }
    return (void *) n;
}
int main(int argc, char ** argv) {
    if (argc < 5) { fprintf(stderr, "usage: wakeloop spin|sleep threads us seconds\n"); return 2; }
    mode_sleep = !strcmp(argv[1], "sleep"); mode_copy = !strcmp(argv[1], "copy"); int nt = atoi(argv[2]); us = atoi(argv[3]); int sec = atoi(argv[4]);
    pthread_t th[64];
    for (int i = 0; i < nt; i++) pthread_create(&th[i], NULL, run, NULL);
    sleep(sec); stop = 1;
    unsigned long tot = 0;
    for (int i = 0; i < nt; i++) { void * r; pthread_join(th[i], &r); tot += (unsigned long) r; }
    printf("%s x%d: %.0f loops/s per thread\n", argv[1], nt, (double) tot / nt / sec);
    return 0;
}
