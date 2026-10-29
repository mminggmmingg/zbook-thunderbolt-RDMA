/*
 * send_rnr — RC SEND 를 수신 버퍼가 모자란 상태로 보내 RNR 처리를 시험한다(llama.cpp RPC RDMA 전송과 같은 QP 설정).
 * 송신 측은 크기 S 의 SEND 를 W 개까지 겹쳐 보내고, 수신 측은 R 개만 미리 게시한 뒤 완료마다 D µs 쉬고 다시 게시한다.
 * → 송신이 수신보다 앞서 RNR NAK 가 나도록 만든다. rnr_retry=7(무한)이므로 모든 SEND 가 성공해야 정상.
 * 각 SEND 앞 8 B 에 순번을 넣어 수신 측이 순서·길이·내용(끝 8 B)을 확인한다.
 *   수신(B): send_rnr <dev> server [port] [N] [S] [R] [D]
 *   송신(A): send_rnr <dev> client <서버IP> [port] [N] [S] [W]
 * 기본: N=2000, S=262144, R=24, D=200, W=24. QP: timeout 14, retry 7, rnr_retry 7, min_rnr_timer 1. GID index 1.
 * 종료 코드: 0 = 전부 성공, 1 = 내용 불일치, 2 = WC 오류/설정 실패.
 */
#include <infiniband/verbs.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAXSLOT 24
struct qpinfo { uint32_t qpn, psn; uint8_t gid[16]; };

static void die(const char *m) { perror(m); exit(2); }
static void send_all(int fd, const void *b, size_t n) {
	const char *p = b; while (n) { ssize_t k = send(fd, p, n, 0); if (k <= 0) die("send"); p += k; n -= k; }
}
static void recv_all(int fd, void *b, size_t n) {
	char *p = b; while (n) { ssize_t k = recv(fd, p, n, 0); if (k <= 0) die("recv"); p += k; n -= k; }
}
static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

static struct ibv_context *ctx; static struct ibv_pd *pd; static struct ibv_cq *cq;
static struct ibv_mr *mr; static uint8_t *buf; static struct ibv_qp *qp;

static void to_rts(const struct qpinfo *peer, uint32_t mypsn) {
	struct ibv_port_attr pa; ibv_query_port(ctx, 1, &pa);
	struct ibv_qp_attr a = { .qp_state = IBV_QPS_INIT, .pkey_index = 0, .port_num = 1,
		.qp_access_flags = IBV_ACCESS_LOCAL_WRITE };
	if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS)) die("INIT");
	memset(&a, 0, sizeof(a));
	a.qp_state = IBV_QPS_RTR; a.path_mtu = pa.active_mtu; a.dest_qp_num = peer->qpn; a.rq_psn = peer->psn;
	a.max_dest_rd_atomic = 1; a.min_rnr_timer = 1;
	a.ah_attr.is_global = 1; a.ah_attr.port_num = 1; a.ah_attr.grh.sgid_index = 1; a.ah_attr.grh.hop_limit = 64;
	memcpy(a.ah_attr.grh.dgid.raw, peer->gid, 16);
	if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
			  IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER)) die("RTR");
	memset(&a, 0, sizeof(a));
	a.qp_state = IBV_QPS_RTS; a.timeout = 14; a.retry_cnt = 7; a.rnr_retry = 7; a.sq_psn = mypsn; a.max_rd_atomic = 1;
	if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN |
			  IBV_QP_MAX_QP_RD_ATOMIC)) die("RTS");
}

static void post_recv_slot(int slot, uint32_t S) {
	struct ibv_sge sg = { .addr = (uintptr_t)(buf + (size_t)slot * S), .length = S, .lkey = mr->lkey };
	struct ibv_recv_wr wr = { .wr_id = (uint64_t)slot, .sg_list = &sg, .num_sge = 1 }, *bad;
	if (ibv_post_recv(qp, &wr, &bad)) die("post_recv");
}

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: see header\n"); return 2; }
	const char *dev = argv[1]; int server = !strcmp(argv[2], "server");
	int ai = server ? 3 : 4;
	const char *peer_ip = server ? NULL : argv[3];
	int port = argc > ai ? atoi(argv[ai]) : 18899;
	long N = argc > ai + 1 ? atol(argv[ai + 1]) : 2000;
	uint32_t S = argc > ai + 2 ? (uint32_t)atol(argv[ai + 2]) : 262144;
	int slots = argc > ai + 3 ? atoi(argv[ai + 3]) : 24;         /* 수신: R, 송신: W */
	int delay_us = server && argc > ai + 4 ? atoi(argv[ai + 4]) : 200;
	if (slots < 1 || slots > MAXSLOT || S < 16) { fprintf(stderr, "slots 1..%d, S >= 16\n", MAXSLOT); return 2; }

	int n; struct ibv_device **l = ibv_get_device_list(&n);
	for (int i = 0; i < n; i++) if (!strcmp(ibv_get_device_name(l[i]), dev)) ctx = ibv_open_device(l[i]);
	if (!ctx) { fprintf(stderr, "장치 %s 없음\n", dev); return 2; }
	size_t bsz = (size_t)slots * S;
	pd = ibv_alloc_pd(ctx); cq = ibv_create_cq(ctx, 2 * MAXSLOT + 16, NULL, NULL, 0);
	if (posix_memalign((void **)&buf, 4096, bsz)) die("memalign");
	memset(buf, 0, bsz);
	mr = ibv_reg_mr(pd, buf, bsz, IBV_ACCESS_LOCAL_WRITE);
	if (!pd || !cq || !mr) die("pd/cq/mr");
	union ibv_gid gid; if (ibv_query_gid(ctx, 1, 1, &gid)) die("query_gid");
	struct ibv_qp_init_attr ia = { .send_cq = cq, .recv_cq = cq, .qp_type = IBV_QPT_RC,
		.cap = { .max_send_wr = MAXSLOT, .max_recv_wr = MAXSLOT, .max_send_sge = 1, .max_recv_sge = 1 } };
	qp = ibv_create_qp(pd, &ia); if (!qp) die("create_qp");
	struct qpinfo me = { .qpn = qp->qp_num, .psn = (uint32_t)(lrand48() & 0xffffff) }, peer;
	memcpy(me.gid, gid.raw, 16);

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
	to_rts(&peer, me.psn);
	if (server) for (int s = 0; s < slots; s++) post_recv_slot(s, S);
	char go = 'G';
	if (server) send_all(fd, &go, 1); else recv_all(fd, &go, 1);  /* 수신 게시 후 시작 */

	struct ibv_wc wc[16];
	long done = 0, posted = 0, bad = 0; double t0 = now_s();
	while (done < N) {
		if (!server) {
			while (posted < N && posted - done < slots) {
				int s = (int)(posted % slots); uint8_t *p = buf + (size_t)s * S;
				uint64_t tag = (uint64_t)posted, tail = ~tag;
				memcpy(p, &tag, 8); memcpy(p + S - 8, &tail, 8);
				struct ibv_sge sg = { .addr = (uintptr_t)p, .length = S, .lkey = mr->lkey };
				struct ibv_send_wr wr = { .wr_id = (uint64_t)posted, .sg_list = &sg, .num_sge = 1,
					.opcode = IBV_WR_SEND, .send_flags = IBV_SEND_SIGNALED }, *bw;
				if (ibv_post_send(qp, &wr, &bw)) die("post_send");
				posted++;
			}
		}
		int k = ibv_poll_cq(cq, 16, wc);
		if (k < 0) die("poll_cq");
		for (int i = 0; i < k; i++) {
			if (wc[i].status != IBV_WC_SUCCESS) {
				fprintf(stderr, "%s: #%ld wc status %s (%d) opcode %d, %.3f s 경과\n", server ? "recv" : "send",
					done, ibv_wc_status_str(wc[i].status), wc[i].status, wc[i].opcode, now_s() - t0);
				return 2;
			}
			if (server) {
				int s = (int)wc[i].wr_id; uint8_t *p = buf + (size_t)s * S; uint64_t tag, tail;
				memcpy(&tag, p, 8); memcpy(&tail, p + S - 8, 8);
				if (wc[i].byte_len != S || tag != (uint64_t)done || tail != ~tag) {
					if (bad < 5) fprintf(stderr, "recv #%ld: len %u tag %llu tail ok %d\n", done, wc[i].byte_len,
							     (unsigned long long)tag, tail == ~tag);
					bad++;
				}
				if (delay_us) usleep(delay_us);
				if (done + slots < N) post_recv_slot(s, S);
			}
			done++;
		}
	}
	double dt = now_s() - t0;
	printf("%s %s N=%ld S=%u %s=%d%s: %.3f s, %.1f MB/s, 불일치 %ld → %s\n", server ? "recv" : "send", dev, N, S,
	       server ? "R" : "W", slots, server ? "" : "", dt, N * (double)S / dt / 1e6, bad, bad ? "FAIL" : "PASS");
	if (server) printf("  (수신 지연 %d µs/완료)\n", delay_us);
	return bad ? 1 : 0;
}
