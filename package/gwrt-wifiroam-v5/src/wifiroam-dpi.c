// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * wifiroam-dpi - netfilter-queue client that enforces the per-client domain
 * blocklist of wifiroam.
 *
 * This file is a source reconstruction of the shipped aarch64 binary
 * (wifiroam 0.1.0-r47, /usr/sbin/wifiroam-dpi).  The original source was not
 * part of the apk; the behaviour below was recovered from the disassembly and
 * the .rodata strings.  See ../../README.md for the recovery notes.
 *
 * How it works:
 *   - wifiroamd.uc owns the blocklist file /tmp/wifiroam/dpi_blocklist:
 *         <client-mac> <domain>[,<domain>...]
 *     one client per line, '#' comments, leading blanks ignored.
 *   - This daemon copies every packet to userspace (NFQUEUE 0) and looks at
 *     TCP/UDP payloads.  For a client that appears in the blocklist it parses
 *     the TLS ClientHello (and, for QUIC, the crypto handshake) for the SNI
 *     and drops the packet when the SNI matches one of the client's domains.
 *   - QUIC cannot be decoded without the connection keys, so for a listed
 *     client all UDP/443 is dropped and a raw substring scan over the UDP
 *     payload is used as a best-effort match for plain-text SNI carriers.
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <linux/netfilter.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include <libnetfilter_queue/libnetfilter_queue.h>

#define DPI_BLOCKLIST	"/tmp/wifiroam/dpi_blocklist"
#define DPI_PIDFILE	"/tmp/wifiroam-dpi.pid"

#define INIT_ENTRIES	16	/* initial MAC slots for bl_load() */
#define MAX_DOMAINS	16	/* initial domain slots per MAC */
#define FLOW_CACHE_SIZE	4096
#define FLOW_CACHE_TTL	120	/* seconds a cached accept is valid */
#define NEIGH_TTL	10	/* seconds the ip-neigh cache is valid */
#define BL_POLL_TTL	14	/* seconds between blocklist stat() polls */
#define SNI_MAX		2048
#define PKTBUF_SIZE	65536

/* One blocklist line: a client MAC plus the domains blocked for it. */
struct bl_entry {
	char mac[18];
	char **domains;
	int n;
};

/* One ip-neigh entry (64 bytes, as in the original). */
struct neigh_entry {
	char ip[46];
	char mac[18];
};

/* One flow-cache slot; verdict 1 = accept until expiry, 0 = no verdict. */
struct flow_cache {
	uint32_t hash;		/* unused, keeps verdict 8-byte aligned */
	int verdict;
	time_t expiry;
};

static int g_reload;
static int g_stop;
static struct bl_entry *g_bl;
static int g_bl_n;
static struct neigh_entry *g_neigh;
static int g_neigh_n;
static time_t g_neigh_ts;
static time_t g_bl_mtime;
static struct flow_cache g_cache[FLOW_CACHE_SIZE];

/* QUIC variable-length integer; returns bytes consumed or -1. */
static int quic_varint(const unsigned char *p, int len, int off, uint64_t *out)
{
	uint64_t v;
	int n, i;

	if (off >= len)
		return -1;

	n = 1 << (p[off] >> 6);
	if (off + n > len)
		return -1;

	v = p[off] & 0x3f;
	for (i = 1; i < n; i++)
		v = (v << 8) | p[off + i];

	*out = v;
	return n;
}

/* Direction-independent 12-bit flow hash. */
static unsigned int flow_hash(int af, const void *sa, const void *da,
			      unsigned short sport, unsigned short dport,
			      unsigned char proto)
{
	const unsigned char *s = sa, *d = da, *tmp;
	unsigned int a = 0, b = 0, h, tp;
	int n, i;

	if (af == AF_INET) {
		for (i = 0; i < 4; i++)
			a = (a << 8) | s[i];
		for (i = 0; i < 4; i++)
			b = (b << 8) | d[i];
	} else {
		for (i = 0; i < 16; i += 4) {
			a ^= *(const uint32_t *)(s + i);
			b ^= *(const uint32_t *)(d + i);
		}
	}

	if (a <= b) {
		tmp = s;
		s = d;
		d = tmp;
		tp = sport;
		sport = dport;
		dport = tp;
	}

	n = (af == AF_INET) ? 4 : 16;
	h = proto * 0x9e3779b1u;
	for (i = 0; i < n; i++)
		h = h * 31 + d[i];
	for (i = 0; i < n; i++)
		h = h * 31 + s[i];
	h = h * 31 + dport;
	h = h * 31 + sport;

	return h & 0xfff;
}

static void on_signal(int sig)
{
	if (sig == SIGHUP)
		g_reload = 1;
	else
		g_stop = 1;
}

static void bl_free(void)
{
	int i, j;

	if (g_bl) {
		for (i = 0; i < g_bl_n; i++) {
			for (j = 0; j < g_bl[i].n; j++)
				free(g_bl[i].domains[j]);
			free(g_bl[i].domains);
		}
		free(g_bl);
		g_bl = NULL;
	}
	g_bl_n = 0;
}

static int neigh_add(struct neigh_entry **arr, int *cap, int n,
		     const char *ip, const char *mac)
{
	if (n >= *cap) {
		struct neigh_entry *tmp;

		*cap *= 2;
		tmp = realloc(*arr, *cap * sizeof(**arr));
		if (!tmp)
			return n;
		*arr = tmp;
	}
	snprintf((*arr)[n].ip, sizeof((*arr)[n].ip), "%s", ip);
	snprintf((*arr)[n].mac, sizeof((*arr)[n].mac), "%s", mac);
	return n + 1;
}

/* Rebuild the IP -> MAC map from the neighbour table. */
static void neigh_refresh(void)
{
	struct neigh_entry *arr;
	FILE *fp;
	char line[512];
	int n = 0, cap = 64;

	free(g_neigh);
	g_neigh = NULL;
	g_neigh_n = 0;

	arr = calloc(cap, sizeof(*arr));
	if (!arr)
		return;

	fp = popen("ip neigh show 2>/dev/null", "r");
	if (fp) {
		while (fgets(line, sizeof(line), fp)) {
			char ip[46], mac[18], *p, *q;

			p = line;
			while (*p == ' ' || *p == '\t')
				p++;
			if (!*p)
				continue;

			q = strchr(p, ' ');
			if (!q)
				continue;
			*q++ = '\0';
			snprintf(ip, sizeof(ip), "%.45s", p);

			p = strstr(q, "lladdr ");
			if (!p)
				continue;
			if (sscanf(p + 7, "%17s", mac) != 1)
				continue;
			if (!strchr(mac, ':'))
				continue;
			if (!strcmp(mac, "00:00:00:00:00:00"))
				continue;

			n = neigh_add(&arr, &cap, n, ip, mac);
		}
		fclose(fp);
	}

	if (n == 0) {
		fp = fopen("/proc/net/arp", "r");
		if (fp) {
			char header[512];

			if (!fgets(header, sizeof(header), fp)) {
				fclose(fp);
				fp = NULL;
			}
		}
		while (fp && fgets(line, sizeof(line), fp)) {
			char ip[46], dev[16], mac[18];

			if (sscanf(line, "%45s %*s %15s %17s", ip, dev, mac) != 3)
				continue;
			if (!strchr(mac, ':'))
				continue;
			if (!strcmp(mac, "00:00:00:00:00:00"))
				continue;

			n = neigh_add(&arr, &cap, n, ip, mac);
		}
		if (fp)
			fclose(fp);
	}

	g_neigh = arr;
	g_neigh_n = n;
	g_neigh_ts = time(NULL);
}

static const char *neigh_mac(const char *ip)
{
	int i;

	if (!g_neigh || time(NULL) - g_neigh_ts > NEIGH_TTL)
		neigh_refresh();

	for (i = 0; i < g_neigh_n; i++)
		if (!strcmp(g_neigh[i].ip, ip))
			return g_neigh[i].mac;

	return NULL;
}

static struct bl_entry *bl_find_mac(const char *mac)
{
	int i;

	for (i = 0; i < g_bl_n; i++)
		if (!strcasecmp(g_bl[i].mac, mac))
			return &g_bl[i];

	return NULL;
}

/* Suffix match on a domain boundary: "x.example.com" matches "example.com". */
static int sni_blocked(const struct bl_entry *e, const char *host)
{
	size_t hlen = strlen(host);
	int i;

	for (i = 0; i < e->n; i++) {
		const char *d = e->domains[i];
		size_t dlen = strlen(d);

		if (hlen < dlen)
			continue;
		if (strcasecmp(host + hlen - dlen, d))
			continue;
		if (hlen == dlen)
			return 1;
		if (host[hlen - dlen - 1] == '.')
			return 1;
	}

	return 0;
}

/* (Re)load /tmp/wifiroam/dpi_blocklist. */
static void bl_load(void)
{
	struct stat st;
	struct bl_entry *arr;
	FILE *fp;
	char line[1024];
	int n = 0, cap = INIT_ENTRIES;

	if (stat(DPI_BLOCKLIST, &st) != 0) {
		bl_free();
		g_bl_mtime = 0;
		return;
	}

	fp = fopen(DPI_BLOCKLIST, "r");
	if (!fp) {
		bl_free();
		g_bl_mtime = 0;
		return;
	}

	g_bl_mtime = st.st_mtime;

	arr = calloc(cap, sizeof(*arr));
	if (!arr) {
		fclose(fp);
		return;
	}

	while (fgets(line, sizeof(line), fp)) {
		struct bl_entry *e;
		char *p = line, *mac, *save = NULL, *tok;
		size_t len;

		while (*p == ' ' || *p == '\t')
			p++;
		if (*p == '\0' || *p == '\n' || *p == '#')
			continue;

		mac = strsep(&p, " \t");
		if (!mac || !p)
			continue;

		while (*p == ' ' || *p == '\t')
			p++;
		len = strlen(p);
		while (len && (p[len - 1] == '\n' || p[len - 1] == '\r'))
			p[--len] = '\0';

		if (n >= cap) {
			struct bl_entry *tmp;

			cap *= 2;
			tmp = realloc(arr, cap * sizeof(*arr));
			if (!tmp)
				break;
			arr = tmp;
		}

		e = &arr[n];
		snprintf(e->mac, sizeof(e->mac), "%s", mac);
		e->domains = NULL;
		e->n = 0;

		for (tok = strtok_r(p, ",", &save); tok;
		     tok = strtok_r(NULL, ",", &save)) {
			char *dup = strdup(tok);
			char **tmp;

			if (!dup)
				continue;
			tmp = realloc(e->domains, (e->n + 1) * sizeof(char *));
			if (!tmp) {
				free(dup);
				continue;
			}
			e->domains = tmp;
			e->domains[e->n++] = dup;
		}

		if (e->n > 0)
			n++;
	}

	fclose(fp);
	bl_free();
	g_bl = arr;
	g_bl_n = n;
}

/* Extract the SNI from a TLS ClientHello; returns the SNI length. */
static int tls_sni(const unsigned char *p, int len, char *out)
{
	int rlen, c, cslen, C, comp, M, extlen, E, off;

	if (len <= 4)
		return 0;
	if (p[0] != 0x16)
		return 0;
	rlen = (p[3] << 8) | p[4];
	if (!rlen)
		return 0;
	if (len < rlen + 5)
		return 0;
	if (p[5] != 1)
		return 0;
	if (len <= 0x2b)
		return 0;

	c = 44 + p[43];
	if (len <= c + 1)
		return 0;
	cslen = (p[c] << 8) | p[c + 1];
	C = c + 2 + cslen;
	if (len <= C)
		return 0;

	comp = p[C];
	M = C + 1 + comp;
	if (len <= M + 1)
		return 0;
	extlen = (p[M] << 8) | p[M + 1];
	E = M + 2 + extlen;
	if (len < E)
		return 0;

	for (off = M + 2; off + 3 < E; ) {
		int type = (p[off] << 8) | p[off + 1];
		int elen = (p[off + 2] << 8) | p[off + 3];
		int next = off + 4 + elen;

		if (E < next)
			return 0;

		if (type == 0) {
			int sn;

			if (elen <= 4)
				return 0;
			if (((p[off + 4] << 8) | p[off + 5]) >= elen - 1)
				return 0;
			sn = (p[off + 7] << 8) | p[off + 8];
			if (!sn)
				return 0;
			if (E < off + 9 + sn)
				return 0;
			memcpy(out, p + off + 9, sn);
			out[sn] = '\0';
			return sn;
		}

		off = next;
	}

	return 0;
}

static int pkt_pass(struct nfq_q_handle *qh, int id)
{
	nfq_set_verdict(qh, id, NF_ACCEPT, 0, NULL);
	return 0;
}

static int pkt_allow(struct nfq_q_handle *qh, int id, struct flow_cache *e,
		     time_t now)
{
	e->verdict = 1;
	e->expiry = now + FLOW_CACHE_TTL;
	nfq_set_verdict2(qh, id, NF_ACCEPT, 1, 0, NULL);
	return 0;
}

static int pkt_block(struct nfq_q_handle *qh, int id, struct flow_cache *e,
		     time_t now)
{
	e->verdict = 0;
	e->expiry = now + FLOW_CACHE_TTL;
	nfq_set_verdict2(qh, id, NF_DROP, 2, 0, NULL);
	return 0;
}

static int cb(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg,
	      struct nfq_data *nfa, void *data)
{
	struct nfqnl_msg_packet_hdr *ph;
	unsigned char *payload = NULL;
	const unsigned char *src, *dst;
	int id, len, l4, nexthdr, af;
	uint16_t proto;
	time_t now;
	struct flow_cache *e;
	struct bl_entry *bl;
	const char *mac;
	unsigned int hash;
	int rem;

	(void)nfmsg;
	(void)data;

	ph = nfq_get_msg_packet_hdr(nfa);
	if (!ph)
		return 0;

	id = ntohl(ph->packet_id);
	len = nfq_get_payload(nfa, &payload);
	if (len <= 0)
		return pkt_pass(qh, id);

	proto = ntohs(ph->hw_protocol);

	if (proto == 0x86dd) {
		af = AF_INET6;
		if (len <= 0x27)
			return pkt_pass(qh, id);
		nexthdr = payload[6];
		l4 = 40;
		src = payload + 8;
		dst = payload + 24;
	} else {
		int ihl;

		if (len <= 0x13)
			return pkt_pass(qh, id);
		ihl = payload[0] & 0xf;
		if (ihl <= 4)
			return pkt_pass(qh, id);
		nexthdr = payload[9];
		l4 = ihl * 4;
		src = payload + 12;
		dst = payload + 16;
		af = AF_INET;
	}

	if (l4 >= len)
		return pkt_pass(qh, id);

	if (nexthdr == 6) {
		/* TCP: parse ClientHello, match SNI against the blocklist. */
		char ip[46], sni[SNI_MAX];
		const unsigned char *tcp = payload + l4;
		int sport, dport, doff;

		if (l4 + 19 >= len)
			return pkt_pass(qh, id);

		sport = (tcp[0] << 8) | tcp[1];
		dport = (tcp[2] << 8) | tcp[3];
		doff = (tcp[12] >> 4) * 4;
		if (doff <= 19)
			return pkt_pass(qh, id);

		hash = flow_hash(af, src, dst, sport, dport, nexthdr);
		now = time(NULL);
		e = &g_cache[hash];

		if (e->verdict != 0) {
			if (now <= e->expiry) {
				if (e->verdict >= 0) {
					nfq_set_verdict(qh, id, e->verdict, 0, NULL);
					return 0;
				}
			} else {
				e->verdict = 0;
			}
		}

		l4 += doff;
		rem = len - l4;
		if (rem <= 0)
			return pkt_pass(qh, id);

		inet_ntop(af, src, ip, sizeof(ip));
		mac = neigh_mac(ip);
		bl = mac ? bl_find_mac(mac) : NULL;

		if (tls_sni(payload + l4, rem, sni) > 0 && bl &&
		    sni_blocked(bl, sni))
			return pkt_block(qh, id, e, now);

		return pkt_allow(qh, id, e, now);
	}

	if (nexthdr == 17) {
		/* UDP: QUIC handshake sniffing, plus the raw fallback scan. */
		char ip[46], sni[SNI_MAX], qbuf[SNI_MAX];
		const unsigned char *p;
		int sport, dport, udpoff, n = 0;

		if (l4 + 7 >= len)
			return pkt_pass(qh, id);

		sport = (payload[l4] << 8) | payload[l4 + 1];
		dport = (payload[l4 + 2] << 8) | payload[l4 + 3];

		hash = flow_hash(af, src, dst, sport, dport, nexthdr);
		now = time(NULL);
		e = &g_cache[hash];

		if (e->verdict != 0) {
			if (now <= e->expiry) {
				if (e->verdict >= 0) {
					nfq_set_verdict(qh, id, e->verdict, 0, NULL);
					return 0;
				}
			} else {
				e->verdict = 0;
			}
		}

		udpoff = l4 + 8;
		rem = len - udpoff;
		if (rem <= 0)
			return pkt_pass(qh, id);

		inet_ntop(af, src, ip, sizeof(ip));
		mac = neigh_mac(ip);
		bl = mac ? bl_find_mac(mac) : NULL;

		p = payload + udpoff;

		if (rem > 6 && (int8_t)p[0] < 0 && !(p[0] & 0x30)) {
			uint64_t v;
			int off, dcid, scid, end;

			dcid = p[5];
			if (dcid <= 0x14 && rem > 6 + dcid) {
				scid = p[6 + dcid];
				if (scid > 0x14)
					goto quic_done;
				off = 7 + dcid + scid;
				if (rem < off)
					goto quic_done;

				int r;

				r = quic_varint(p, rem, off, &v);
				if (r < 0)
					goto quic_done;
				off += r;
				if (v > (uint64_t)(rem - off))
					goto quic_done;
				off += v;

				r = quic_varint(p, rem, off, &v);
				if (r < 0)
					goto quic_done;
				off += r;
				if (v > (uint64_t)(rem - off))
					goto quic_done;
				end = off + (int)v;

				while (off < end) {
					uint64_t type, cgoff, cglen;
					int r;

					r = quic_varint(p, rem, off, &type);
					if (r < 0)
						break;
					off += r;
					if (type != 6)
						break;

					r = quic_varint(p, rem, off, &cgoff);
					if (r < 0)
						break;
					off += r;
					r = quic_varint(p, rem, off, &cglen);
					if (r < 0)
						break;

					if (end < off + r + (int)cglen)
						break;
					if (cgoff + cglen <= SNI_MAX) {
						memcpy(qbuf + cgoff, p + off + r, cglen);
						if ((int)(cgoff + cglen) > n)
							n = cgoff + cglen;
					}
					off += r + (int)cglen;
				}
			}
		}

quic_done:
		if (n > 4 && tls_sni((unsigned char *)qbuf, n, sni) > 0 && bl &&
		    sni_blocked(bl, sni))
			return pkt_block(qh, id, e, now);

		if (rem > 0 && bl) {
			int j;

			/* No QUIC decryption: block the whole media flow. */
			if (dport == 443)
				return pkt_block(qh, id, e, now);

			/*
			 * Legacy QUIC (draft-29, version 0xff00001d) carries
			 * the SNI in the clear; the LE load below matches the
			 * wire bytes ff 00 00 1d.
			 */
			if (rem > 4 && (int8_t)p[0] < 0 &&
			    *(const uint32_t *)(p + 1) == 0x1d0000ff)
				return pkt_block(qh, id, e, now);

			for (j = 0; j < bl->n; j++) {
				const char *d = bl->domains[j];
				size_t sl = strlen(d);
				int k;

				for (k = 0; k + (int)sl <= rem; k++)
					if (!strncasecmp((const char *)p + k, d, sl))
						return pkt_block(qh, id, e, now);
			}
		}

		return pkt_allow(qh, id, e, now);
	}

	return pkt_pass(qh, id);
}

static int setup_queue(struct nfq_handle *h, struct nfq_q_handle **qh)
{
	if (nfq_unbind_pf(h, AF_INET) < 0)
		fprintf(stderr, "nfq_unbind_pf v4: %s\n", strerror(errno));
	if (nfq_bind_pf(h, AF_INET) < 0) {
		perror("nfq_bind_pf v4");
		return -1;
	}
	if (nfq_unbind_pf(h, AF_INET6) < 0)
		fprintf(stderr, "nfq_unbind_pf v6: %s\n", strerror(errno));
	if (nfq_bind_pf(h, AF_INET6) < 0) {
		perror("nfq_bind_pf v6");
		return -1;
	}

	*qh = nfq_create_queue(h, 0, cb, NULL);
	if (!*qh) {
		perror("nfq_create_queue");
		return -1;
	}
	if (nfq_set_mode(*qh, NFQNL_COPY_PACKET, 0xffff) < 0) {
		perror("nfq_set_mode");
		return -1;
	}

	return 0;
}

int main(void)
{
	struct nfq_handle *h;
	struct nfq_q_handle *qh = NULL;
	struct pollfd pfd;
	struct stat st;
	unsigned char buf[PKTBUF_SIZE];
	FILE *fp;
	time_t last, now;
	int rv;

	h = nfq_open();
	if (!h) {
		perror("nfq_open");
		return 1;
	}
	if (setup_queue(h, &qh) != 0)
		return 1;

	signal(SIGHUP, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	bl_load();
	syslog(LOG_INFO, "DPI started: blocklist %d entries", g_bl_n);

	fp = fopen(DPI_PIDFILE, "w");
	if (fp) {
		fprintf(fp, "%d\n", (int)getpid());
		fclose(fp);
	}

	pfd.fd = nfq_fd(h);
	pfd.events = POLLIN;
	last = time(NULL);

	while (!g_stop) {
		if (g_reload) {
			bl_load();
			g_reload = 0;
			syslog(LOG_INFO, "DPI reloaded: blocklist %d entries",
			       g_bl_n);
		}

		rv = poll(&pfd, 1, 15000);
		if (rv < 0) {
			if (errno == EINTR)
				continue;
			break;
		}

		now = time(NULL);
		if (now - last > BL_POLL_TTL) {
			int reload;

			if (stat(DPI_BLOCKLIST, &st) != 0)
				reload = (g_bl_mtime != 0);
			else
				reload = (st.st_mtime != g_bl_mtime);

			if (reload) {
				bl_load();
				syslog(LOG_INFO,
				       "DPI auto-reloaded: blocklist %d entries",
				       g_bl_n);
			}
			last = now;
		}

		if (!rv)
			continue;
		if (!(pfd.revents & POLLIN))
			continue;

		rv = recv(pfd.fd, buf, sizeof(buf), 0);
		if (rv < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		nfq_handle_packet(h, (char *)buf, rv);
	}

	nfq_destroy_queue(qh);
	nfq_close(h);
	bl_free();

	return 0;
}
