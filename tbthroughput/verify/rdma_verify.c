/*
 * rdma_verify — RC RDMA WRITE / READ 데이터 무결성 시험 (호스트 메모리 MR, 여러 QP 가 한 MR 공유).
 * 매 회차: 클라이언트가 QP 마다 임의 길이(1 B ~ 4 MiB)·임의(비정렬) 오프셋 구간을 정하고 TCP 로 알린다.
 *  WRITE: 클라이언트가 PRNG 패턴을 써서 WRITE_WITH_IMM → 서버가 구간을 바이트 단위로 대조하고, 구간 앞뒤 64 B 보호 바이트가
 *         그대로인지 본다(엉뚱한 오프셋 기록 검출).
 *  READ : 서버가 구간에 패턴을 채우면 클라이언트가 RDMA READ 로 읽어 와 대조한다.
 *   서버(A):      rdma_verify <dev> server [port] [회차] [QP수]
 *   클라이언트(B): rdma_verify <dev> client <서버IP> [port] [회차] [QP수]
 * GID index 1(RoCE v2, thunderbolt0 IPv4). 종료 코드 = 불일치가 하나라도 있으면 1.
 */
#include <infiniband/verbs.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define BUF_SZ (7u << 20)   /* 호스트 memlock 8 MiB 안 */
#define GUARD 64
#define MAXQ 8
#define MAX_LEN (4u << 20)

struct qpinfo { uint32_t qpn, psn; uint8_t gid[16]; };
struct hello { uint32_t nqp; uint64_t addr; uint32_t rkey; struct qpinfo q[MAXQ]; };
struct desc { uint32_t op, it, q, pad; uint64_t roff, loff, len, seed; };
struct result { uint32_t bad, guard_bad; uint64_t first_bad; };

static void die(const char *m) { perror(m); exit(2); }
static void send_all(int fd, const void *b, size_t n) {
	const char *p = b; while (n) { ssize_t k = send(fd, p, n, 0); if (k <= 0) die("send"); p += k; n -= k; }
}
static void recv_all(int fd, void *b, size_t n) {
	char *p = b; while (n) { ssize_t k = recv(fd, p, n, 0); if (k <= 0) die("recv"); p += k; n -= k; }
}
static uint64_t rng(uint64_t *s) { *s ^= *s >> 12; *s ^= *s << 25; *s ^= *s >> 27; return *s * 0x2545F4914F6CDD1DULL; }
static void fill(uint8_t *d, size_t n, uint64_t seed) {
	uint64_t s = seed | 1; size_t i = 0;
	while (i < n) { uint64_t v = rng(&s); for (int k = 0; k < 8 && i < n; k++, i++) d[i] = (uint8_t)(v >> (8 * k)); }
}
static uint64_t check(const uint8_t *d, size_t n, uint64_t seed, uint32_t *bad) {
	uint64_t s = seed | 1, first = UINT64_MAX; size_t i = 0;
	while (i < n) { uint64_t v = rng(&s); for (int k = 0; k < 8 && i < n; k++, i++)
		if (d[i] != (uint8_t)(v >> (8 * k))) { if (first == UINT64_MAX) first = i; (*bad)++; } }
	return first;
}

static struct ibv_context *ctx; static struct ibv_pd *pd; static struct ibv_cq *cq;
static struct ibv_mr *mr; static uint8_t *buf; static struct ibv_qp *qp[MAXQ];

static void wait_wc(int n, enum ibv_wc_opcode want, const char *what) {
	struct ibv_wc wc[16];
	while (n > 0) {
		int k = ibv_poll_cq(cq, 16, wc);
		if (k < 0) die("poll_cq");
		for (int i = 0; i < k; i++) {
			if (wc[i].status != IBV_WC_SUCCESS) {
				fprintf(stderr, "%s: wc status %s opcode %d\n", what, ibv_wc_status_str(wc[i].status), wc[i].opcode);
				exit(2);
			}
			if (wc[i].opcode != want) { fprintf(stderr, "%s: 예상 밖 opcode %d\n", what, wc[i].opcode); exit(2); }
		}
		n -= k;
	}
}
static void post_recv(struct ibv_qp *q) {
	struct ibv_recv_wr wr = { .wr_id = 1, .num_sge = 0 }, *bad;
	if (ibv_post_recv(q, &wr, &bad)) die("post_recv");
}
static void to_rts(struct ibv_qp *q, const struct qpinfo *peer, uint32_t mypsn) {
	struct ibv_port_attr pa; ibv_query_port(ctx, 1, &pa);
	struct ibv_qp_attr a = { .qp_state = IBV_QPS_INIT, .pkey_index = 0, .port_num = 1,
		.qp_access_flags = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ };
	if (ibv_modify_qp(q, &a, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS)) die("INIT");
	memset(&a, 0, sizeof(a));
	a.qp_state = IBV_QPS_RTR; a.path_mtu = pa.active_mtu; a.dest_qp_num = peer->qpn; a.rq_psn = peer->psn;
	a.max_dest_rd_atomic = 4; a.min_rnr_timer = 12;
	a.ah_attr.is_global = 1; a.ah_attr.port_num = 1; a.ah_attr.grh.sgid_index = 1; a.ah_attr.grh.hop_limit = 64;
	memcpy(a.ah_attr.grh.dgid.raw, peer->gid, 16);
	if (ibv_modify_qp(q, &a, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
			  IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER)) die("RTR");
	memset(&a, 0, sizeof(a));
	a.qp_state = IBV_QPS_RTS; a.timeout = 20; a.retry_cnt = 7; a.rnr_retry = 7; a.sq_psn = mypsn; a.max_rd_atomic = 4;
	if (ibv_modify_qp(q, &a, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN |
			  IBV_QP_MAX_QP_RD_ATOMIC)) die("RTS");
}

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: see header\n"); return 2; }
	const char *dev = argv[1]; int server = !strcmp(argv[2], "server");
	int ai = server ? 3 : 4;
	const char *peer_ip = server ? NULL : argv[3];
	int port = argc > ai ? atoi(argv[ai]) : 18799;
	int iters = argc > ai + 1 ? atoi(argv[ai + 1]) : 100;
	int nqp = argc > ai + 2 ? atoi(argv[ai + 2]) : 1;
	if (nqp < 1 || nqp > MAXQ) { fprintf(stderr, "QP 수 1..%d\n", MAXQ); return 2; }

	int n; struct ibv_device **l = ibv_get_device_list(&n);
	for (int i = 0; i < n; i++) if (!strcmp(ibv_get_device_name(l[i]), dev)) ctx = ibv_open_device(l[i]);
	if (!ctx) { fprintf(stderr, "장치 %s 없음\n", dev); return 2; }
	pd = ibv_alloc_pd(ctx); cq = ibv_create_cq(ctx, 4 * MAXQ + 16, NULL, NULL, 0);
	if (posix_memalign((void **)&buf, 4096, BUF_SZ)) die("memalign");
	memset(buf, 0, BUF_SZ);
	mr = ibv_reg_mr(pd, buf, BUF_SZ, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ);
	if (!pd || !cq || !mr) die("pd/cq/mr");
	union ibv_gid gid; if (ibv_query_gid(ctx, 1, 1, &gid)) die("query_gid");

	struct hello me = { .nqp = nqp, .addr = (uintptr_t)buf, .rkey = mr->rkey }, peer;
	for (int i = 0; i < nqp; i++) {
		struct ibv_qp_init_attr ia = { .send_cq = cq, .recv_cq = cq, .qp_type = IBV_QPT_RC,
			.cap = { .max_send_wr = 16, .max_recv_wr = 16, .max_send_sge = 1, .max_recv_sge = 1 } };
		qp[i] = ibv_create_qp(pd, &ia); if (!qp[i]) die("create_qp");
		me.q[i].qpn = qp[i]->qp_num; me.q[i].psn = (uint32_t)(lrand48() & 0xffffff); memcpy(me.q[i].gid, gid.raw, 16);
	}

	int fd;
	if (server) {
		int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
		setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = INADDR_ANY };
		if (bind(ls, (void *)&sa, sizeof(sa)) || listen(ls, 1)) die("bind/listen");
		fd = accept(ls, NULL, NULL); if (fd < 0) die("accept");
	} else {
		fd = socket(AF_INET, SOCK_STREAM, 0);
		struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(port) };
		inet_pton(AF_INET, peer_ip, &sa.sin_addr);
		int ok = -1; for (int t = 0; t < 50 && ok; t++) { ok = connect(fd, (void *)&sa, sizeof(sa)); if (ok) usleep(100000); }
		if (ok) die("connect");
	}
	send_all(fd, &me, sizeof(me)); recv_all(fd, &peer, sizeof(peer));
	if (peer.nqp != (uint32_t)nqp) { fprintf(stderr, "QP 수 불일치\n"); return 2; }
	for (int i = 0; i < nqp; i++) to_rts(qp[i], &peer.q[i], me.q[i].psn);

	uint64_t seed0 = 0x5EED1234ULL ^ (uint64_t)time(NULL);
	if (!server) send_all(fd, &seed0, 8); else recv_all(fd, &seed0, 8);
	uint64_t rs = seed0 | 1, slice = BUF_SZ / nqp;
	uint32_t tot_bad = 0, tot_guard = 0; uint64_t bytes[2] = {0, 0};

	for (int op = 0; op < 2; op++) {            /* 0 = WRITE, 1 = READ */
		for (int it = 0; it < iters; it++) {
			struct desc d[MAXQ];
			if (!server) {
				for (int q = 0; q < nqp; q++) {
					uint64_t cls = rng(&rs) % 3, lim = cls == 0 ? 4096 : cls == 1 ? 65536 : MAX_LEN;
					uint64_t room = slice - 2 * GUARD - 8; if (lim > room) lim = room;
					uint64_t len = 1 + rng(&rs) % lim;
					d[q] = (struct desc){ .op = op, .it = it, .q = q, .len = len, .seed = rng(&rs),
						.roff = q * slice + GUARD + rng(&rs) % (room - len + 1),
						.loff = q * slice + GUARD + rng(&rs) % (room - len + 1) };
				}
				send_all(fd, d, sizeof(d[0]) * nqp);
			} else {
				recv_all(fd, d, sizeof(d[0]) * nqp);
				for (int q = 0; q < nqp; q++) {
					uint8_t *r = buf + d[q].roff;
					if (op == 0) { memset(r - GUARD, 0xEE, d[q].len + 2 * GUARD); post_recv(qp[q]); }
					else fill(r, d[q].len, d[q].seed);
				}
				char rdy = 'R'; send_all(fd, &rdy, 1);
			}
			if (!server) {
				char rdy; recv_all(fd, &rdy, 1);
				for (int q = 0; q < nqp; q++) {
					uint8_t *loc = buf + d[q].loff;
					if (op == 0) fill(loc, d[q].len, d[q].seed); else memset(loc, 0, d[q].len);
					struct ibv_sge sg = { .addr = (uintptr_t)loc, .length = (uint32_t)d[q].len, .lkey = mr->lkey };
					struct ibv_send_wr wr = { .wr_id = q, .sg_list = &sg, .num_sge = 1, .send_flags = IBV_SEND_SIGNALED,
						.opcode = op == 0 ? IBV_WR_RDMA_WRITE_WITH_IMM : IBV_WR_RDMA_READ }, *bad;
					wr.imm_data = htonl(it * MAXQ + q);
					wr.wr.rdma.remote_addr = peer.addr + d[q].roff; wr.wr.rdma.rkey = peer.rkey;
					if (ibv_post_send(qp[q], &wr, &bad)) die("post_send");
				}
				wait_wc(nqp, op == 0 ? IBV_WC_RDMA_WRITE : IBV_WC_RDMA_READ, op == 0 ? "write" : "read");
				struct result res = {0};
				if (op == 1) {
					for (int q = 0; q < nqp; q++) {
						uint32_t b = 0; uint64_t f = check(buf + d[q].loff, d[q].len, d[q].seed, &b);
						if (b && !res.bad)
							res.first_bad = f;
						res.bad += b;
						bytes[1] += d[q].len;
					}
				} else {
					recv_all(fd, &res, sizeof(res));
					for (int q = 0; q < nqp; q++) bytes[0] += d[q].len;
				}
				if (op == 1) send_all(fd, &res, sizeof(res));
				if (res.bad || res.guard_bad)
					fprintf(stderr, "[%s it=%d] 불일치 %u B, 보호바이트 %u B, 첫 위치 %llu\n", op ? "READ" : "WRITE",
						it, res.bad, res.guard_bad, (unsigned long long)res.first_bad);
				tot_bad += res.bad; tot_guard += res.guard_bad;
			} else {
				struct result res = {0};
				if (op == 0) {
					wait_wc(nqp, IBV_WC_RECV_RDMA_WITH_IMM, "recv");
					for (int q = 0; q < nqp; q++) {
						uint8_t *r = buf + d[q].roff; uint32_t b = 0;
						uint64_t f = check(r, d[q].len, d[q].seed, &b);
						if (b && !res.bad)
							res.first_bad = f;
						res.bad += b;
						for (int g = 0; g < GUARD; g++) {
							res.guard_bad += (r[-1 - g] != 0xEE);
							res.guard_bad += (r[d[q].len + g] != 0xEE);
						}
					}
					send_all(fd, &res, sizeof(res));
				} else {
					recv_all(fd, &res, sizeof(res));
				}
				tot_bad += res.bad; tot_guard += res.guard_bad;
			}
		}
	}
	printf("%s %s QP=%d 회차=%d: WRITE %.1f MiB, READ %.1f MiB, 불일치 %u B, 보호바이트 %u B → %s\n",
	       server ? "server" : "client", dev, nqp, iters, bytes[0] / 1048576.0, bytes[1] / 1048576.0,
	       tot_bad, tot_guard, (tot_bad || tot_guard) ? "FAIL" : "PASS");
	return (tot_bad || tot_guard) ? 1 : 0;
}
