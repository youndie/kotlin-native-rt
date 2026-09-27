import io.ktor.utils.io.charsets.*
import io.ktor.utils.io.core.*
import kotlinx.io.Buffer

// Each charset through ktor-io's encoder and decoder - the calls that reach iconv; String.toByteArray
// short-circuits UTF-8 and would not. One line per charset, "ok" or the exception.
fun main() {
    val text = "café A-z"
    for (name in listOf("UTF-8", "ISO-8859-1", "US-ASCII", "UTF-16", "windows-1251")) {
        val result = runCatching {
            val charset = Charsets.forName(name)
            val sample = if (name == "US-ASCII") "cafe A-z" else text
            val bytes = charset.newEncoder().encodeToByteArray(sample, 0, sample.length)
            val back = StringBuilder()
            charset.newDecoder().decode(Buffer().apply { write(bytes) }, back, Int.MAX_VALUE)
            check(back.toString() == sample) { "round trip gave '$back'" }
            "ok, ${bytes.size} bytes"
        }.getOrElse { "${it::class.simpleName}: ${it.message}" }
        println("$name -> $result")
    }
    // a malformed input still fails as iconv made it fail
    val malformed = runCatching {
        Charsets.UTF_8.newDecoder().decode(Buffer().apply { write(byteArrayOf(0x61, 0xC3.toByte(), 0x28)) }, StringBuilder(), Int.MAX_VALUE)
    }.exceptionOrNull()
    println("malformed UTF-8 -> ${malformed?.let { it::class.simpleName } ?: "no exception"}")
}
