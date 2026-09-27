package io.github.youndie.iconv.unicode

/**
 * The library has no Kotlin API. Depending on it links `src/iconv_unicode.c` into the executable and
 * routes `iconv_open`, `iconv` and `iconv_close` through it; see the README. This declaration exists
 * because a Kotlin/Native library without Kotlin sources produces no klib to publish.
 */
internal object IconvUnicode
