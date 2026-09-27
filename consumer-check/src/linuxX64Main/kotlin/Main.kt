@file:OptIn(kotlin.native.runtime.NativeRuntimeApi::class, kotlin.ExperimentalStdlibApi::class)

import kotlin.native.runtime.GC

// Fills the heap across many size classes, drops most of it and collects twice, so the allocator has
// used, ready and empty pages at the end of marking - the state both runtime patches act on.
fun main() {
    var kept = ArrayList<Any>()
    repeat(20) { round ->
        val batch = ArrayList<Any>()
        repeat(20_000) { i -> batch.add(ByteArray(8 + (i % 64) * 8)) }
        if (round % 4 == 0) kept.add(batch)
    }
    GC.collect()
    kept = ArrayList()
    GC.collect()
    val info = GC.lastGCInfo
    println("consumer-check ok: epoch ${info?.epoch}, kept ${kept.size}")
}
