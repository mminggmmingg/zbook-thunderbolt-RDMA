// hipStreamWaitValue32 on pinned host memory: does the GPU hold back later work until the host writes
// the flag, and how long from the host write until a following kernel has finished?
#include <hip/hip_runtime.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>
#define CK(x) do { hipError_t e = (x); if (e != hipSuccess) { printf("%s -> %s\n", #x, hipGetErrorString(e)); return 1; } } while (0)
__global__ void bump(int * p) { p[0] += 1; }
static double us(std::chrono::steady_clock::time_point a, std::chrono::steady_clock::time_point b) {
    return std::chrono::duration<double, std::micro>(b - a).count();
}
int main() {
    int can = -1;
    CK(hipDeviceGetAttribute(&can, hipDeviceAttributeCanUseStreamWaitValue, 0));
    printf("CanUseStreamWaitValue=%d\n", can);
    for (unsigned flags : {(unsigned) hipHostMallocDefault, (unsigned) hipHostMallocCoherent}) {
        volatile uint32_t * flag = nullptr;
        CK(hipHostMalloc((void **) &flag, 4096, flags));
        *flag = 0;
        int * d = nullptr; CK(hipMalloc(&d, 4)); CK(hipMemset(d, 0, 4));
        hipStream_t st; CK(hipStreamCreateWithFlags(&st, hipStreamNonBlocking));
        double tot = 0, mx = 0; int held = 0; const int N = 200;
        for (int i = 1; i <= N; i++) {
            CK(hipStreamWaitValue32(st, (void *) flag, (uint32_t) i, hipStreamWaitValueGte, 0xFFFFFFFF));
            bump<<<1, 1, 0, st>>>(d);
            std::this_thread::sleep_for(std::chrono::microseconds(200));
            if (hipStreamQuery(st) == hipErrorNotReady) held++;        // still waiting on the flag
            auto t0 = std::chrono::steady_clock::now();
            std::atomic_thread_fence(std::memory_order_seq_cst);
            *flag = (uint32_t) i;
            std::atomic_thread_fence(std::memory_order_seq_cst);
            CK(hipStreamSynchronize(st));
            double u = us(t0, std::chrono::steady_clock::now());
            tot += u; if (u > mx) mx = u;
        }
        int h = 0; CK(hipMemcpy(&h, d, 4, hipMemcpyDeviceToHost));
        printf("flags=%u: kernel held until write %d/%d, write->done avg %.1f us max %.1f us, counter %d\n",
               flags, held, N, tot / N, mx, h);
        CK(hipStreamDestroy(st)); CK(hipFree(d)); CK(hipHostFree((void *) flag));
    }
    return 0;
}
