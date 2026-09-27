/*
 * iconv_unicode.c against glibc's iconv, call for call.
 *
 * Linked with --wrap, so iconv_open() here is the replacement and __real_iconv_open() is glibc's.
 * Must run where glibc has its gconv modules. Every input goes through both, and the two must
 * agree on the return value, errno, how far each buffer advanced, and the bytes written.
 *
 *     gcc -O2 -Wall -o differential test/differential.c src/iconv_unicode.c \
 *         -Wl,--wrap=iconv_open,--wrap=iconv,--wrap=iconv_close
 *     ./differential [random-cases]
 */
#include <errno.h>
#include <iconv.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

iconv_t __real_iconv_open(const char *tocode, const char *fromcode);
size_t __real_iconv(iconv_t cd, char **inbuf, size_t *inbytesleft, char **outbuf, size_t *outbytesleft);
int __real_iconv_close(iconv_t cd);

static const char *charsets[] = {"UTF-8", "UTF-16LE", "UTF-16BE", "ISO-8859-1", "US-ASCII"};
#define NCS 5

/* every name the replacement accepts, with the charset glibc must take it for */
static const char *aliases[][2] = {
    {"UTF-8", "UTF-8"}, {"UTF8", "UTF-8"}, {"utf-8", "UTF-8"}, {"Utf8", "UTF-8"},
    {"UTF-16LE", "UTF-16LE"}, {"utf-16le", "UTF-16LE"}, {"UTF-16BE", "UTF-16BE"},
    {"ISO-8859-1", "ISO-8859-1"}, {"ISO8859-1", "ISO-8859-1"}, {"ISO_8859-1", "ISO-8859-1"},
    {"LATIN1", "ISO-8859-1"}, {"latin1", "ISO-8859-1"}, {"L1", "ISO-8859-1"},
    {"US-ASCII", "US-ASCII"}, {"ASCII", "US-ASCII"}, {"ANSI_X3.4-1968", "US-ASCII"},
};

static long cases, failures;

struct outcome {
    size_t ret;
    int err;
    size_t consumed, produced;
    unsigned char out[256];
};

static void run(iconv_t cd, int real, const unsigned char *in, size_t inlen, size_t outlen, struct outcome *o) {
    char *ip = (char *)in, *op = (char *)o->out;
    size_t il = inlen, ol = outlen;
    memset(o->out, 0xAA, sizeof o->out);
    errno = 0;
    o->ret = real ? __real_iconv(cd, &ip, &il, &op, &ol) : iconv(cd, &ip, &il, &op, &ol);
    o->err = o->ret == (size_t)-1 ? errno : 0;
    o->consumed = (size_t)(ip - (char *)in);
    o->produced = (size_t)(op - (char *)o->out);
    if (o->consumed + il != inlen || o->produced + ol != outlen) {
        fprintf(stderr, "inconsistent counters (real=%d)\n", real);
        exit(2);
    }
}

static void dump(const char *label, const unsigned char *b, size_t n) {
    fprintf(stderr, "  %s:", label);
    for (size_t i = 0; i < n && i < 32; i++) fprintf(stderr, " %02X", b[i]);
    fprintf(stderr, "\n");
}

static void check(int from, int to, iconv_t ours, iconv_t theirs, const unsigned char *in, size_t inlen, size_t outlen) {
    struct outcome a, b;
    run(ours, 0, in, inlen, outlen, &a);
    run(theirs, 1, in, inlen, outlen, &b);
    cases++;
    if (a.ret == b.ret && a.err == b.err && a.consumed == b.consumed && a.produced == b.produced &&
        memcmp(a.out, b.out, a.produced) == 0)
        return;
    /* one example of each kind of disagreement */
    static unsigned char seen[NCS][NCS][4][4];
    int ka = a.err == EILSEQ ? 1 : a.err == EINVAL ? 2 : a.err == E2BIG ? 3 : 0;
    int kb = b.err == EILSEQ ? 1 : b.err == EINVAL ? 2 : b.err == E2BIG ? 3 : 0;
    if (++failures, !seen[from][to][ka][kb]++) {
        fprintf(stderr, "MISMATCH %s -> %s, out %zu\n", charsets[from], charsets[to], outlen);
        dump("in", in, inlen);
        fprintf(stderr, "  ours:  ret %ld errno %d consumed %zu produced %zu\n", (long)a.ret, a.err, a.consumed, a.produced);
        fprintf(stderr, "  glibc: ret %ld errno %d consumed %zu produced %zu\n", (long)b.ret, b.err, b.consumed, b.produced);
        dump("ours out", a.out, a.produced);
        dump("glibc out", b.out, b.produced);
    }
}

static iconv_t ours[NCS][NCS], theirs[NCS][NCS];

static void open_all(void) {
    for (int f = 0; f < NCS; f++)
        for (int t = 0; t < NCS; t++) {
            ours[f][t] = iconv_open(charsets[t], charsets[f]);
            theirs[f][t] = __real_iconv_open(charsets[t], charsets[f]);
            if (ours[f][t] == (iconv_t)-1 || theirs[f][t] == (iconv_t)-1) {
                fprintf(stderr, "cannot open %s -> %s (is gconv installed?)\n", charsets[f], charsets[t]);
                exit(2);
            }
        }
}

/* every input to every target, with room to spare, and with each output size from 0 up */
static void all_targets(int from, const unsigned char *in, size_t n, int sizes) {
    for (int t = 0; t < NCS; t++) {
        check(from, t, ours[from][t], theirs[from][t], in, n, 256);
        if (sizes)
            for (size_t o = 0; o <= 4 * n + 1 && o < 256; o++) check(from, t, ours[from][t], theirs[from][t], in, n, o);
    }
}

static uint64_t rng = 0x9E3779B97F4A7C15u;
static uint32_t next(void) {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return (uint32_t)rng;
}

static const uint32_t interesting_units[] = {0x0000, 0x0041, 0x007F, 0x0080, 0x00E9, 0x00FF, 0x0100, 0x07FF, 0x0800,
                                             0x20AC, 0xD7FF, 0xD800, 0xDB40, 0xDBFF, 0xDC00, 0xDC7F, 0xDC80, 0xDFFF, 0xE000, 0xFEFF, 0xFFFE, 0xFFFF};
#define NUNITS (sizeof interesting_units / sizeof interesting_units[0])

static const unsigned char interesting_bytes[] = {0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2,
                                                   0xDF, 0xE0, 0xED, 0xEF, 0xF0, 0xF3, 0xF4, 0xF5, 0xF7, 0xF8, 0xFF};
#define NBYTES sizeof interesting_bytes

int main(int argc, char **argv) {
    long random_cases = argc > 1 ? atol(argv[1]) : 2000000;
    unsigned char in[64];

    /* names: whatever the replacement accepts, glibc accepts as the same charset */
    for (size_t i = 0; i < sizeof aliases / sizeof aliases[0]; i++) {
        iconv_t g = __real_iconv_open("UTF-16LE", aliases[i][0]);
        if (g == (iconv_t)-1) {
            fprintf(stderr, "glibc does not accept the name %s\n", aliases[i][0]);
            failures++;
            continue;
        }
        iconv_t o = iconv_open("UTF-16LE", aliases[i][1]);
        for (int b = 0; b < 256; b++) {
            in[0] = (unsigned char)b;
            struct outcome x, y;
            run(o, 0, in, 1, 8, &x);
            run(g, 1, in, 1, 8, &y);
            cases++;
            if (x.ret != y.ret || x.err != y.err || x.produced != y.produced || memcmp(x.out, y.out, x.produced)) {
                fprintf(stderr, "name %s differs from %s at byte %02X\n", aliases[i][0], aliases[i][1], b);
                failures++;
                break;
            }
        }
        iconv_close(o);
        __real_iconv_close(g);
    }
    /* and a name the replacement does not know is glibc's answer, not ours */
    if (iconv_open("UTF-8", "WINDOWS-1251") == (iconv_t)-1 || iconv_open("UTF-8", "NO-SUCH-CHARSET") != (iconv_t)-1 ||
        errno != EINVAL) {
        fprintf(stderr, "delegation to glibc is wrong\n");
        failures++;
    }

    open_all();

    /* single-byte sources: every byte, every pair */
    for (int f = 0; f < NCS; f++)
        for (int x = 0; x < 256; x++) {
            in[0] = (unsigned char)x;
            all_targets(f, in, 1, 1);
            for (int y = 0; y < 256; y++) {
                in[1] = (unsigned char)y;
                all_targets(f, in, 2, 0);
            }
        }
    fprintf(stderr, "pairs: %ld cases, %ld mismatches\n", cases, failures);

    /* UTF-8: every three-byte input */
    for (uint32_t v = 0; v < 1u << 24; v++) {
        in[0] = v >> 16; in[1] = v >> 8; in[2] = v;
        for (int t = 0; t < NCS; t++) check(0, t, ours[0][t], theirs[0][t], in, 3, 256);
    }
    fprintf(stderr, "utf-8 x3: %ld cases, %ld mismatches\n", cases, failures);

    /* UTF-8: four and five bytes from the bytes where decoders disagree, with every output size */
    for (size_t a = 0; a < NBYTES; a++)
        for (size_t b = 0; b < NBYTES; b++)
            for (size_t c = 0; c < NBYTES; c++)
                for (size_t d = 0; d < NBYTES; d++) {
                    in[0] = interesting_bytes[a]; in[1] = interesting_bytes[b];
                    in[2] = interesting_bytes[c]; in[3] = interesting_bytes[d];
                    all_targets(0, in, 4, a % 3 == 0);
                    in[4] = 0x41;
                    all_targets(0, in, 5, 0);
                }
    fprintf(stderr, "utf-8 x4: %ld cases, %ld mismatches\n", cases, failures);

    /* UTF-8: the five- and six-byte forms glibc still reads, whole, cut short and overlong */
    static const unsigned char leads[] = {0xF8, 0xF9, 0xFB, 0xFC, 0xFD};
    static const unsigned char trails[] = {0x80, 0x81, 0x87, 0x88, 0x8F, 0xBF, 0x41};
    for (size_t l = 0; l < sizeof leads; l++)
        for (uint32_t v = 0; v < 7 * 7 * 7 * 7 * 7; v++) {
            uint32_t w = v;
            in[0] = leads[l];
            for (int i = 1; i <= 5; i++, w /= 7) in[i] = trails[w % 7];
            for (size_t n = 1; n <= 6; n++) all_targets(0, in, n, n == 6 && v % 5 == 0);
        }
    fprintf(stderr, "utf-8 x6: %ld cases, %ld mismatches\n", cases, failures);

    /* UTF-16: every sequence of up to three interesting units, whole and cut short by a byte */
    for (int f = 1; f <= 2; f++) {
        int big = f == 2;
        for (size_t a = 0; a < NUNITS; a++)
            for (size_t b = 0; b < NUNITS; b++)
                for (size_t c = 0; c < NUNITS; c++) {
                    uint32_t u[3] = {interesting_units[a], interesting_units[b], interesting_units[c]};
                    for (int i = 0; i < 3; i++) {
                        in[2 * i + big] = u[i] & 0xFF;
                        in[2 * i + !big] = u[i] >> 8;
                    }
                    for (size_t n = 1; n <= 6; n++) all_targets(f, in, n, n == 6);
                }
    }
    fprintf(stderr, "utf-16: %ld cases, %ld mismatches\n", cases, failures);

    /* random: text built from whole characters, stray bytes and cuts, random output sizes */
    for (long r = 0; r < random_cases; r++) {
        int f = next() % NCS, t = next() % NCS;
        size_t n = 0, want = 1 + next() % 40;
        while (n < want) {
            uint32_t k = next() % 16, cp;
            if (k < 10) {
                static const uint32_t ranges[][2] = {{0, 0x7F}, {0x80, 0xFF}, {0x100, 0x7FF}, {0x800, 0xD7FF},
                                                     {0xE000, 0xFFFF}, {0x10000, 0x10FFFF}};
                uint32_t which = next() % 6;
                cp = ranges[which][0] + next() % (ranges[which][1] - ranges[which][0] + 1);
                /* the character in the source charset, as glibc writes it; skipped if it cannot */
                static iconv_t from_ucs4[NCS];
                if (!from_ucs4[f]) from_ucs4[f] = __real_iconv_open(charsets[f], "UCS-4LE");
                char *ip = (char *)&cp, *op = (char *)in + n;
                size_t il = 4, ol = sizeof in - n;
                __real_iconv(from_ucs4[f], &ip, &il, &op, &ol);
                n = (size_t)(op - (char *)in);
            } else if (n < sizeof in) {
                in[n++] = (unsigned char)next();
            }
            if (n >= sizeof in - 4) break;
        }
        if (next() % 4 == 0 && n > 1) n -= 1 + next() % (n < 3 ? n - 1 : 3);
        size_t outlen = next() % 3 == 0 ? next() % (4 * n + 2) : 256;
        if (n > 0) check(f, t, ours[f][t], theirs[f][t], in, n, outlen);
    }
    fprintf(stderr, "random: %ld cases, %ld mismatches\n", cases, failures);

    /* reset and flush calls */
    for (int f = 0; f < NCS; f++)
        for (int t = 0; t < NCS; t++) {
            char buf[8], *op = buf;
            size_t ol = sizeof buf;
            size_t x = iconv(ours[f][t], NULL, NULL, &op, &ol);
            size_t y = __real_iconv(theirs[f][t], NULL, NULL, &op, &ol);
            size_t z = iconv(ours[f][t], NULL, NULL, NULL, NULL);
            cases++;
            if (x != y || z != 0 || op != buf) {
                fprintf(stderr, "reset %s -> %s differs\n", charsets[f], charsets[t]);
                failures++;
            }
        }

    printf("%s: %ld cases, %ld mismatches\n", failures ? "FAIL" : "OK", cases, failures);
    return failures ? 1 : 0;
}
