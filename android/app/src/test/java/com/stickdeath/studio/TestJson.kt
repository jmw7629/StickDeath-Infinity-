package com.stickdeath.studio

/** Tiny strict JSON reader for tests. The Android `org.json` classes are stubs on the plain JVM
 * test classpath, so manifests and portable exports are checked with this instead. Objects become
 * `Map<String, Any?>`, arrays `List<Any?>`, numbers `Double` (or `Long` when integral). */
object TestJson {
    fun parse(text: String): Any? {
        val reader = Reader(text)
        val value = reader.value()
        reader.skipSpace()
        check(reader.index == text.length) { "Trailing characters after JSON at ${reader.index}" }
        return value
    }
    @Suppress("UNCHECKED_CAST") fun obj(value: Any?): Map<String, Any?> = value as Map<String, Any?>
    @Suppress("UNCHECKED_CAST") fun list(value: Any?): List<Any?> = value as List<Any?>

    private class Reader(val text: String) {
        var index = 0
        fun skipSpace() { while (index < text.length && text[index].isWhitespace()) index++ }
        private fun expect(c: Char) { skipSpace(); check(index < text.length && text[index] == c) { "Expected '$c' at $index" }; index++ }
        fun value(): Any? {
            skipSpace()
            check(index < text.length) { "Unexpected end of JSON" }
            return when (val c = text[index]) {
                '{' -> {
                    index++; val result = linkedMapOf<String, Any?>()
                    skipSpace()
                    if (text[index] == '}') { index++; return result }
                    while (true) {
                        skipSpace(); val key = string(); expect(':'); result[key] = value(); skipSpace()
                        when (text[index++]) { ',' -> continue; '}' -> return result; else -> error("Bad object at $index") }
                    }
                    @Suppress("UNREACHABLE_CODE") result
                }
                '[' -> {
                    index++; val result = mutableListOf<Any?>()
                    skipSpace()
                    if (text[index] == ']') { index++; return result }
                    while (true) {
                        result += value(); skipSpace()
                        when (text[index++]) { ',' -> continue; ']' -> return result; else -> error("Bad array at $index") }
                    }
                    @Suppress("UNREACHABLE_CODE") result
                }
                '"' -> string()
                't' -> { literal("true"); true }
                'f' -> { literal("false"); false }
                'n' -> { literal("null"); null }
                else -> {
                    check(c == '-' || c.isDigit()) { "Unexpected '$c' at $index" }
                    val start = index
                    while (index < text.length && (text[index].isDigit() || text[index] in "+-.eE")) index++
                    val token = text.substring(start, index)
                    if (token.any { it in ".eE" }) token.toDouble() else token.toLong()
                }
            }
        }
        private fun literal(word: String) { check(text.startsWith(word, index)) { "Bad literal at $index" }; index += word.length }
        private fun string(): String {
            expect('"')
            val out = StringBuilder()
            while (true) {
                check(index < text.length) { "Unterminated string" }
                when (val c = text[index++]) {
                    '"' -> return out.toString()
                    '\\' -> when (val e = text[index++]) {
                        '"' -> out.append('"'); '\\' -> out.append('\\'); '/' -> out.append('/')
                        'n' -> out.append('\n'); 'r' -> out.append('\r'); 't' -> out.append('\t'); 'b' -> out.append('\b'); 'f' -> out.append('\u000C')
                        'u' -> { out.append(text.substring(index, index + 4).toInt(16).toChar()); index += 4 }
                        else -> error("Bad escape \\$e")
                    }
                    else -> { check(c >= ' ') { "Control character in string" }; out.append(c) }
                }
            }
        }
    }
}
