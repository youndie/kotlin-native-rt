/*
 * iconv for the Unicode charsets, without glibc's gconv modules.
 *
 * glibc's iconv resolves every conversion through a module database under
 * /usr/lib/x86_64-linux-gnu/gconv and dlopen()s the modules it names - UTF-16 included, so a
 * statically linked executable in an image without that tree cannot convert UTF-8 to UTF-16, which
 * is the pivot ktor-io uses for every charset. This file answers iconv_open, iconv and iconv_close
 * for UTF-8, UTF-16LE, UTF-16BE, ISO-8859-1 and US-ASCII in both directions itself, and passes every
 * other request to glibc unchanged.
 *
 * It is linked with
 *
 *     --wrap=iconv_open --wrap=iconv --wrap=iconv_close
 *
 * so the executable's calls land here and glibc's own functions stay reachable as __real_*. Where
 * gconv is present, the charsets not handled here behave exactly as before; where it is absent they
 * fail as before, with EINVAL from iconv_open.
 *
 * The conversions reproduce glibc's, including its errors: EILSEQ at the first malformed or
 * unmappable character, EINVAL for an incomplete sequence at the end of the input, E2BIG when the
 * next character does not fit, and in each case the buffers advanced past exactly the characters
 * that were converted. iconv/test/differential.c holds this against glibc.
 */
#include <errno.h>
#include <iconv.h>
#include <stdint.h>
#include <stdlib.h>
#include <strings.h>

iconv_t __real_iconv_open(const char *tocode, const char *fromcode);
size_t __real_iconv(iconv_t cd, char **inbuf, size_t *inbytesleft, char **outbuf, size_t *outbytesleft);
int __real_iconv_close(iconv_t cd);

enum charset { CS_OTHER = 0, CS_UTF8, CS_UTF16LE, CS_UTF16BE, CS_LATIN1, CS_ASCII };

#define HANDLE_MAGIC 0x69637575u

struct handle {
    uint32_t magic;
    enum charset from, to; /* both CS_OTHER when real is used */
    iconv_t real;
};

static const struct {
    const char *name;
    enum charset charset;
} names[] = {
    /* only names glibc itself accepts for the same charset; the differential test checks this */
    {"UTF-8", CS_UTF8},
    {"UTF8", CS_UTF8},
    {"UTF-16LE", CS_UTF16LE},
    {"UTF-16BE", CS_UTF16BE},
    {"ISO-8859-1", CS_LATIN1},
    {"ISO8859-1", CS_LATIN1},
    {"ISO_8859-1", CS_LATIN1},
    {"LATIN1", CS_LATIN1},
    {"L1", CS_LATIN1},
    {"US-ASCII", CS_ASCII},
    {"ASCII", CS_ASCII},
    {"ANSI_X3.4-1968", CS_ASCII},
};

/* A name with a suffix ("//TRANSLIT", "//IGNORE") or an empty one (the locale's charset) is glibc's. */
static enum charset lookup(const char *name) {
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
        if (strcasecmp(name, names[i].name) == 0) return names[i].charset;
    return CS_OTHER;
}

/*
 * Decoders: return the length of the character at in, or 0 with *err set. EINVAL means the input
 * ends inside a character that could still be valid; EILSEQ, that it cannot be.
 */
/*
 * glibc's reading of UTF-8, which is the original one of RFC 2279 rather than the standard's: lead
 * bytes F5-FD start characters of four to six bytes up to 0x7FFFFFFF. Only a UTF-8 target writes
 * those back; the others refuse them as unmappable. Overlong forms and surrogates are illegal.
 */
static size_t decode_utf8(const unsigned char *in, size_t len, uint32_t *cp, int *err) {
    unsigned char b0 = in[0];
    size_t need, i;
    uint32_t c;
    if (b0 < 0x80) {
        *cp = b0;
        return 1;
    }
    if (b0 < 0xC2 || b0 > 0xFD) goto illegal; /* continuation byte, overlong C0/C1, or FE/FF */
    need = b0 < 0xE0 ? 2 : b0 < 0xF0 ? 3 : b0 < 0xF8 ? 4 : b0 < 0xFC ? 5 : 6;
    if (len < need) {
        /* incomplete, unless a byte already present is not a continuation byte */
        for (i = 1; i < len; i++)
            if ((in[i] & 0xC0) != 0x80) goto illegal;
        *err = EINVAL;
        return 0;
    }
    c = b0 & (0x7F >> need);
    for (i = 1; i < need; i++) {
        if ((in[i] & 0xC0) != 0x80) goto illegal;
        c = (c << 6) | (in[i] & 0x3F);
    }
    if ((need > 2 && (c >> (5 * need - 4)) == 0) || (c >= 0xD800 && c <= 0xDFFF)) goto illegal;
    *cp = c;
    return need;
illegal:
    *err = EILSEQ;
    return 0;
}

static size_t decode_utf16(const unsigned char *in, size_t len, int big, uint32_t *cp, int *err) {
    if (len < 2) {
        *err = EINVAL;
        return 0;
    }
    uint32_t u = big ? (uint32_t)in[0] << 8 | in[1] : (uint32_t)in[1] << 8 | in[0];
    if (u < 0xD800 || u > 0xDFFF) {
        *cp = u;
        return 2;
    }
    if (u >= 0xDC00) {
        *err = EILSEQ;
        return 0;
    }
    if (len < 4) {
        *err = EINVAL;
        return 0;
    }
    uint32_t l = big ? (uint32_t)in[2] << 8 | in[3] : (uint32_t)in[3] << 8 | in[2];
    if (l < 0xDC00 || l > 0xDFFF) {
        *err = EILSEQ;
        return 0;
    }
    *cp = 0x10000 + ((u - 0xD800) << 10) + (l - 0xDC00);
    return 4;
}

static size_t decode(enum charset cs, const unsigned char *in, size_t len, uint32_t *cp, int *err) {
    switch (cs) {
    case CS_UTF8: return decode_utf8(in, len, cp, err);
    case CS_UTF16LE: return decode_utf16(in, len, 0, cp, err);
    case CS_UTF16BE: return decode_utf16(in, len, 1, cp, err);
    case CS_LATIN1: *cp = in[0]; return 1;
    case CS_ASCII:
        if (in[0] < 0x80) {
            *cp = in[0];
            return 1;
        }
        *err = EILSEQ;
        return 0;
    default: *err = EINVAL; return 0;
    }
}

/*
 * Encoders: return the bytes written, or 0 with *err set - EILSEQ if cp has no encoding here,
 * E2BIG if it does not fit; 0 with *err clear means the character is dropped. Nothing is written
 * in any of these cases. As in glibc, room for the smallest
 * character is checked before the character itself: with no room at all the answer is E2BIG even
 * for a character the target cannot hold.
 */
static size_t encode(enum charset cs, uint32_t cp, unsigned char *out, size_t len, int *err) {
    size_t n;
    if (len < (cs == CS_UTF16LE || cs == CS_UTF16BE ? 2u : 1u)) {
        *err = E2BIG;
        return 0;
    }
    switch (cs) {
    case CS_UTF8:
        if (cp < 0x80) {
            out[0] = (unsigned char)cp;
            return 1;
        }
        n = cp < 0x800 ? 2 : cp < 0x10000 ? 3 : cp < 0x200000 ? 4 : cp < 0x4000000 ? 5 : 6;
        if (len < n) break;
        for (size_t i = n - 1; i > 0; i--, cp >>= 6) out[i] = (unsigned char)(0x80 | (cp & 0x3F));
        out[0] = (unsigned char)((0xFF00 >> n) | cp);
        return n;
    case CS_UTF16LE:
    case CS_UTF16BE: {
        int big = cs == CS_UTF16BE;
        uint32_t units[2];
        if (cp > 0x10FFFF) {
            *err = EILSEQ;
            return 0;
        }
        if (cp < 0x10000) {
            units[0] = cp; n = 2;
        } else {
            units[0] = 0xD800 + ((cp - 0x10000) >> 10); units[1] = 0xDC00 + ((cp - 0x10000) & 0x3FF); n = 4;
        }
        if (len < n) break;
        for (size_t i = 0; i < n / 2; i++) {
            out[2 * i + big] = (unsigned char)(units[i] & 0xFF);
            out[2 * i + !big] = (unsigned char)(units[i] >> 8);
        }
        return n;
    }
    case CS_LATIN1:
    case CS_ASCII:
        if (cp > (cs == CS_LATIN1 ? 0xFFu : 0x7Fu)) {
            /* glibc drops the Unicode language tags U+E0000..U+E007F silently where the target
               cannot hold them: consumed, nothing written, not an error */
            *err = (cp >> 7) == (0xE0000 >> 7) ? 0 : EILSEQ;
            return 0;
        }
        if (len < 1) break;
        out[0] = (unsigned char)cp;
        return 1;
    default: *err = EINVAL; return 0;
    }
    *err = E2BIG;
    return 0;
}

iconv_t __wrap_iconv_open(const char *tocode, const char *fromcode) {
    enum charset to = lookup(tocode), from = lookup(fromcode);
    struct handle *h = malloc(sizeof *h);
    if (h == NULL) {
        errno = ENOMEM;
        return (iconv_t)-1;
    }
    h->magic = HANDLE_MAGIC;
    if (to != CS_OTHER && from != CS_OTHER) {
        h->from = from; h->to = to; h->real = (iconv_t)-1;
        return (iconv_t)h;
    }
    h->from = h->to = CS_OTHER;
    h->real = __real_iconv_open(tocode, fromcode);
    if (h->real == (iconv_t)-1) {
        int saved = errno;
        free(h);
        errno = saved;
        return (iconv_t)-1;
    }
    return (iconv_t)h;
}

size_t __wrap_iconv(iconv_t cd, char **inbuf, size_t *inbytesleft, char **outbuf, size_t *outbytesleft) {
    struct handle *h = (struct handle *)cd;
    if (cd == (iconv_t)-1 || h->magic != HANDLE_MAGIC) {
        errno = EBADF;
        return (size_t)-1;
    }
    if (h->from == CS_OTHER) return __real_iconv(h->real, inbuf, inbytesleft, outbuf, outbytesleft);
    /* none of these charsets has a shift state: a reset or flush call has nothing to do */
    if (inbuf == NULL || *inbuf == NULL) return 0;

    const unsigned char *in = (const unsigned char *)*inbuf;
    unsigned char *out = (unsigned char *)*outbuf;
    size_t il = *inbytesleft, ol = *outbytesleft;
    int err = 0;
    while (il > 0) {
        uint32_t cp;
        size_t n = decode(h->from, in, il, &cp, &err);
        if (n == 0) break;
        size_t m = encode(h->to, cp, out, ol, &err);
        if (err != 0) break;
        in += n; il -= n; out += m; ol -= m;
    }
    *inbuf = (char *)in; *inbytesleft = il;
    *outbuf = (char *)out; *outbytesleft = ol;
    if (err != 0) {
        errno = err;
        return (size_t)-1;
    }
    return 0;
}

int __wrap_iconv_close(iconv_t cd) {
    struct handle *h = (struct handle *)cd;
    if (cd == (iconv_t)-1 || h->magic != HANDLE_MAGIC) {
        errno = EBADF;
        return -1;
    }
    int result = 0;
    if (h->from == CS_OTHER) result = __real_iconv_close(h->real);
    h->magic = 0;
    free(h);
    return result;
}
