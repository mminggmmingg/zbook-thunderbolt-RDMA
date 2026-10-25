"""odl_ar2.py (tbv 판) — 참고 스택의 OdlAllReduce2 인터페이스를 그대로 두고 전송만 libtbvcoll 로 바꾼다.

vsh-odl-ar2-allreduce.patch 의 훅(DS4_ODL_AR2=1)이 `from odl_ar2 import OdlAllReduce2` 로 불러
eligible() / all_reduce_out() 만 쓰므로, 이 파일이 원본 odl_ar2.py 자리를 덮으면 vLLM 은 고치지 않는다.
cap 을 넘는 크기·그래프 캡처 중 호출은 eligible()=False → RCCL(tbv IB 경로)로 넘어간다.

환경변수 (step3b 와 같은 이름)
  TBV_DEVS  레일 장치들            (기본 usb4_rdma0,usb4_rdma5)
  TBV_PEER  rank0 의 TB IP         (기본 10.99.0.1, rank1 만 접속에 씀)
  TBV_PORT  랑데부 포트            (기본 18996)
  TBV_CAP   한 번에 보낼 최대 바이트 (기본 4 MiB = 디코드 512 토큰)
  나머지 TBV_ASYNC / TBV_NSLOT / TBV_CPU / TBV_UNCACHED 는 libtbvcoll 이 직접 읽는다.
"""
import ctypes
import os

import torch

_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "libtbvcoll.so")
_DTYPE = {torch.float32: 0, torch.float16: 1, torch.bfloat16: 2}   # libtbvcoll 순서(odl 과 다름)


class OdlAllReduce2:
    def __init__(self, rank: int, **_ignored):
        lib = ctypes.CDLL(_LIB)
        lib.tbv_ar_init.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p,
                                    ctypes.c_int, ctypes.c_size_t]
        lib.tbv_ar_init.restype = ctypes.c_int
        lib.tbv_ar_allreduce.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                         ctypes.c_int, ctypes.c_void_p]
        lib.tbv_ar_allreduce.restype = ctypes.c_int
        lib.tbv_ar_cap.restype = ctypes.c_int
        lib.tbv_ar_err.restype = ctypes.c_int
        devs = os.environ.get("TBV_DEVS", "usb4_rdma0,usb4_rdma5")
        peer = os.environ.get("TBV_PEER", "10.99.0.1") if rank == 1 else ""
        port = int(os.environ.get("TBV_PORT", "18996"))
        cap = int(os.environ.get("TBV_CAP", str(4 << 20)))
        rc = lib.tbv_ar_init(rank, devs.encode(), peer.encode(), port, cap)
        if rc != 0:
            raise RuntimeError(f"tbv_ar_init 실패 rc={rc}")
        self._lib = lib
        self._fn = lib.tbv_ar_allreduce
        self.max_bytes = lib.tbv_ar_cap()

    def eligible(self, t: torch.Tensor) -> bool:
        return (
            t.is_cuda
            and t.is_contiguous()
            and t.dtype in _DTYPE
            and 0 < t.numel() * t.element_size() <= self.max_bytes
            and not torch.cuda.is_current_stream_capturing()
        )

    def all_reduce_out(self, inp: torch.Tensor, out: torch.Tensor) -> torch.Tensor:
        """out = inp + peer(inp). 스트림 비동기."""
        if self._lib.tbv_ar_err():
            raise RuntimeError("tbvcoll: 이전 라운드 오류가 남아 있음")
        rc = self._fn(ctypes.c_void_p(inp.data_ptr()), ctypes.c_void_p(out.data_ptr()),
                      inp.numel() * inp.element_size(), _DTYPE[inp.dtype],
                      ctypes.c_void_p(torch.cuda.current_stream().cuda_stream))
        if rc != 0:   # -2(cap 초과)는 eligible 에서 걸러지므로 여기 오면 실제 오류
            raise RuntimeError(f"tbv_ar_allreduce 실패 rc={rc}")
        return out
