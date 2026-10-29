# gpu_metrics v3.0(APU) 를 50 ms 마다 읽어 평균 클럭·전력·온도와 스로틀 카운터 증가량을 낸다(읽기만). argv[1] = 초
import struct, sys, time
P = '/sys/class/drm/card1/device/gpu_metrics'
def rd():
    b = open(P, 'rb').read()
    u16 = lambda o: struct.unpack_from('<H', b, o)[0]
    u32 = lambda o: struct.unpack_from('<I', b, o)[0]
    return dict(t_gfx=u16(4)/100, t_soc=u16(6)/100, gfx_act=u16(42), dram_rd=u16(94), dram_wr=u16(96),
                sock_w=u32(112)/1000, gfx_w=u32(124)/1000, stapm=u16(170), stapm_cur=u16(172),
                gfxclk=u16(174), socclk=u16(176), fclk=u16(182), uclk=u16(186), gfx_max=u16(224),
                thr=[u32(228+4*i) for i in range(7)])
end = time.time() + float(sys.argv[1]); s = []
first = rd()
while time.time() < end:
    s.append(rd()); time.sleep(0.05)
busy = [x for x in s if x['gfx_act'] > 50] or s
avg = lambda k, xs: sum(x[k] for x in xs) / len(xs)
print(f"  samples {len(s)} (busy {len(busy)}): gfxclk {avg('gfxclk',busy):.0f} socclk {avg('socclk',busy):.0f} fclk {avg('fclk',busy):.0f} uclk {avg('uclk',busy):.0f} MHz, gfx_max {avg('gfx_max',busy):.0f}")
print(f"  power socket {avg('sock_w',busy):.1f} W gfx {avg('gfx_w',busy):.1f} W, stapm limit {avg('stapm',busy):.0f}/{avg('stapm_cur',busy):.0f}, temp gfx {avg('t_gfx',busy):.1f} soc {avg('t_soc',busy):.1f} C")
print(f"  dram rd/wr (raw) {avg('dram_rd',busy):.0f}/{avg('dram_wr',busy):.0f}, gfx activity {avg('gfx_act',busy):.0f}")
names = ['prochot', 'spl', 'fppt', 'sppt', 'thm_core', 'thm_gfx', 'thm_soc']
print('  throttle residency delta:', {n: s[-1]['thr'][i] - first['thr'][i] for i, n in enumerate(names)})
