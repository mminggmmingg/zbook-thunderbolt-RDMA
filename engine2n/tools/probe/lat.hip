// kernel launch costs: (1) 20000 back-to-back empty launches then one sync -> per-launch GPU/CP time,
// (2) launch + stream sync round trip, 5000 times -> median latency.
#include <hip/hip_runtime.h>
#include <chrono>
#include <cstdio>
#include <vector>
#include <algorithm>
__global__ void k(int * p, int a, int b, int c, int d) { if (p && a == 12345) p[0] = b + c + d; }
int main() {
    hipStream_t s; hipStreamCreateWithFlags(&s, hipStreamNonBlocking);
    for (int i = 0; i < 1000; i++) k<<<1, 64, 0, s>>>(nullptr, i, 1, 2, 3);
    hipStreamSynchronize(s);
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < 20000; i++) k<<<1, 64, 0, s>>>(nullptr, i, 1, 2, 3);
    hipStreamSynchronize(s);
    double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
    std::vector<double> rt;
    for (int i = 0; i < 5000; i++) {
        auto a = std::chrono::steady_clock::now();
        k<<<1, 64, 0, s>>>(nullptr, i, 1, 2, 3); hipStreamSynchronize(s);
        rt.push_back(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - a).count());
    }
    std::sort(rt.begin(), rt.end());
    printf("back-to-back: %.2f us/launch | launch+sync: median %.1f us, p90 %.1f us\n", us / 20000, rt[2500], rt[4500]);
    return 0;
}
