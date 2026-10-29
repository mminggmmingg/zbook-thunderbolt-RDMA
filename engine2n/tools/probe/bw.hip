// GPU memory bandwidth: read-only reduction and copy over a 4 GiB buffer (hipMalloc, like model weights), 20 reps each.
#include <hip/hip_runtime.h>
#include <cstdio>
#include <vector>
#include <algorithm>
#define CK(x) do { hipError_t e = (x); if (e != hipSuccess) { printf("%s -> %s\n", #x, hipGetErrorString(e)); return 1; } } while (0)
__global__ void rd(const float4 * __restrict__ a, size_t n, float * out) {
    float4 s = {0, 0, 0, 0};
    for (size_t i = blockIdx.x * (size_t) blockDim.x + threadIdx.x; i < n; i += (size_t) gridDim.x * blockDim.x) {
        float4 v = a[i]; s.x += v.x; s.y += v.y; s.z += v.z; s.w += v.w;
    }
    if (s.x + s.y + s.z + s.w == 12345.f) out[0] = s.x;  // keep the loads
}
__global__ void cp(const float4 * __restrict__ a, float4 * __restrict__ b, size_t n) {
    for (size_t i = blockIdx.x * (size_t) blockDim.x + threadIdx.x; i < n; i += (size_t) gridDim.x * blockDim.x) b[i] = a[i];
}
int main() {
    const size_t bytes = 4ull << 30, n = bytes / 16;
    float4 *a, *b; float * o;
    CK(hipMalloc(&a, bytes)); CK(hipMalloc(&b, bytes)); CK(hipMalloc(&o, 4));
    CK(hipMemset(a, 1, bytes)); CK(hipMemset(b, 0, bytes));
    hipEvent_t e0, e1; CK(hipEventCreate(&e0)); CK(hipEventCreate(&e1));
    for (int k = 0; k < 2; k++) {
        std::vector<float> gb;
        for (int r = 0; r < 20; r++) {
            CK(hipEventRecord(e0));
            if (k == 0) rd<<<4096, 256>>>(a, n, o); else cp<<<4096, 256>>>(a, b, n);
            CK(hipEventRecord(e1)); CK(hipEventSynchronize(e1));
            float ms; CK(hipEventElapsedTime(&ms, e0, e1));
            gb.push_back((k == 0 ? bytes : 2 * bytes) / (ms * 1e6));
        }
        std::sort(gb.begin(), gb.end());
        printf("%s: median %.1f GB/s, min %.1f, max %.1f\n", k == 0 ? "read " : "copy ", gb[10], gb[0], gb[19]);
    }
    return 0;
}
