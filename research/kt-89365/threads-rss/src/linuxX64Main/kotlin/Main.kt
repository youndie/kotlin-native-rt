@file:OptIn(kotlin.native.concurrent.ObsoleteWorkersApi::class, kotlinx.cinterop.ExperimentalForeignApi::class)

import kotlin.native.concurrent.TransferMode
import kotlin.native.concurrent.Worker
import platform.posix.fclose
import platform.posix.fgets
import platform.posix.fopen
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.toKString

// Each of N threads allocates one object in each of K size classes and keeps nothing: the pattern of a
// pool thread that serves a request and parks. Until the next collection every one of those threads
// still holds a page per class it touched (CustomAllocator::fixedBlockPages_), and the question is how
// much of each page is resident. Prints: threads, classes, VmRSS in KiB, then the same with all
// threads idle - no collection runs in between, so the pages are still held.
//
//   threads-rss.kexe <threads> <classes>
fun main(args: Array<String>) {
    val threads = args.getOrNull(0)?.toInt() ?: 1
    val classes = args.getOrNull(1)?.toInt() ?: 22
    val before = rssKib()
    val workers = List(threads) { Worker.start() }
    workers.map { w -> w.execute(TransferMode.SAFE, { classes }) { k -> touchClasses(k) } }.forEach { it.result }
    val after = rssKib()
    println("threads $threads classes $classes rss_before_kib $before rss_after_kib $after delta_per_thread_kib ${(after - before) / threads}")
    workers.forEach { it.requestTermination().result }
}

// A global the objects escape into: a release build allocates an object that does not escape its
// function on the stack, and a stack allocation touches no allocator page at all.
@kotlin.concurrent.Volatile
var sink: Any? = null

// A ByteArray of `n` bytes is a 16-byte header plus `n` rounded up to 8: one cell per 8 bytes, so
// sizes 8 bytes apart land in consecutive fixed-block size classes.
fun touchClasses(k: Int): Int {
    for (i in 0 until k) sink = ByteArray(8 * i)
    return k
}

fun rssKib(): Long = memScoped {
    val f = fopen("/proc/self/status", "r") ?: return -1
    val buf = allocArray<ByteVar>(256)
    var kib = -1L
    while (fgets(buf, 256, f) != null) {
        val line = buf.toKString()
        if (line.startsWith("VmRSS:")) kib = line.removePrefix("VmRSS:").trim().removeSuffix("kB").trim().toLong()
    }
    fclose(f)
    kib
}
