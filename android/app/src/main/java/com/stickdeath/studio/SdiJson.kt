package com.stickdeath.studio

import java.math.BigDecimal

/** Minimal deterministic JSON writer (sorted object keys, no Android dependency) used for the
 * manifests and Swift portable export so plain JVM tests can check the exact text. Values are
 * String, Boolean, Int, Long, Double, Float, null, List<*>, Map<String, *> or [SdiJson.Raw]. */
object SdiJson {
    /** Pre-encoded JSON text inserted verbatim (used for retained Swift brush descriptors). */
    class Raw(val text: String)

    fun encode(value: Any?, pretty: Boolean = true): String = StringBuilder().also { write(it, value, pretty, 0) }.toString()

    private fun write(out: StringBuilder, value: Any?, pretty: Boolean, depth: Int) {
        when (value) {
            null -> out.append("null")
            is Raw -> out.append(value.text)
            is String -> string(out, value)
            is Boolean -> out.append(if (value) "true" else "false")
            is Int, is Long, is Short, is Byte -> out.append(value.toString())
            is Float -> number(out, value.toDouble())
            is Double -> number(out, value)
            is Map<*, *> -> {
                val entries = value.entries.map { (it.key as? String ?: throw IllegalArgumentException("JSON keys must be strings")) to it.value }
                    .sortedBy { it.first }
                if (entries.isEmpty()) { out.append("{}"); return }
                out.append('{')
                entries.forEachIndexed { index, (key, item) ->
                    if (index > 0) out.append(',')
                    newline(out, pretty, depth + 1)
                    string(out, key); out.append(if (pretty) " : " else ":")
                    write(out, item, pretty, depth + 1)
                }
                newline(out, pretty, depth); out.append('}')
            }
            is List<*> -> {
                if (value.isEmpty()) { out.append("[]"); return }
                out.append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    newline(out, pretty, depth + 1)
                    write(out, item, pretty, depth + 1)
                }
                newline(out, pretty, depth); out.append(']')
            }
            else -> throw IllegalArgumentException("Unsupported JSON value: ${(value as Any).javaClass.name}")
        }
    }
    private fun newline(out: StringBuilder, pretty: Boolean, depth: Int) {
        if (!pretty) return
        out.append('\n'); repeat(depth) { out.append("  ") }
    }
    /** Whole numbers print without a fraction (Swift `1` rather than Kotlin `1.0`); other values use
     * the shortest round-trip text, expanded from exponent form so decoders stay strict. */
    fun number(out: StringBuilder, value: Double) {
        require(value.isFinite()) { "JSON cannot represent a non-finite number." }
        if (value == Math.rint(value) && kotlin.math.abs(value) < 1e15) { out.append(value.toLong()); return }
        val text = value.toString()
        out.append(if (text.contains('E') || text.contains('e')) BigDecimal(text).stripTrailingZeros().toPlainString() else text)
    }
    fun string(out: StringBuilder, text: String) {
        out.append('"')
        text.forEach { c ->
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (c < ' ') out.append(String.format(java.util.Locale.ROOT, "\\u%04x", c.code)) else out.append(c)
            }
        }
        out.append('"')
    }
}
