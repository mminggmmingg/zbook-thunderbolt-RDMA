# gpu_metrics v3.0(APU) 시계열(읽기만): 100 ms 마다 한 줄
#   경과초 gfxclk gfx_max gfx활동% 소켓W gfxW 전체코어W 코어최대클럭 표면온도C gfx온도C 코어최고온도C
#   STAPM현재한도 스로틀누적(prochot spl fppt sppt thm_core thm_gfx thm_soc)   (argv[1] = 초)
import struct, sys, time
P = '/sys/class/drm/card1/device/gpu_metrics'
t0 = time.time(); end = t0 + float(sys.argv[1])
while time.time() < end:
    b = open(P, 'rb').read()
    u16 = lambda o: struct.unpack_from('<H', b, o)[0]
    u32 = lambda o: struct.unpack_from('<I', b, o)[0]
    tcore = max(u16(8 + 2*i) for i in range(16)) / 100
    thr = ' '.join(str(u32(228 + 4*i)) for i in range(7))
    print(f"{time.time()-t0:6.1f} {u16(174)} {u16(224)} {u16(42)} {u32(112)/1000:.1f} {u32(124)/1000:.1f} "
          f"{u32(132)/1000:.1f} {u16(222)} {u16(40)/100:.1f} {u16(4)/100:.1f} {tcore:.1f} {u16(172)} {thr}", flush=True)
    time.sleep(0.1)
