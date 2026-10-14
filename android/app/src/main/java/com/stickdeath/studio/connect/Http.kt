package com.stickdeath.studio.connect

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI

/** One HTTPS exchange. Headers never appear in [toString], so a bearer token cannot reach a log. */
class HttpRequest(val method: String, val url: String, val headers: Map<String, String>, val body: ByteArray? = null) {
    override fun toString() = "HttpRequest($method $url)"
}
class HttpResponse(val status: Int, val body: ByteArray, val contentType: String? = null, val date: String? = null) {
    val text: String get() = String(body, Charsets.UTF_8)
}

/** Raised when the bounded body exceeds the caller's limit. */
class ResponseTooLargeException : IOException("The reply was larger than this screen accepts.")

/** The single network seam. Production uses [UrlConnectionTransport]; JVM tests script replies. */
fun interface HttpTransport {
    @Throws(IOException::class)
    fun send(request: HttpRequest, responseLimit: Int): HttpResponse
}

/** Blocking HTTPS through the platform stack; call it from `Dispatchers.IO`. Plain HTTP is refused. */
class UrlConnectionTransport(private val connectTimeoutMs: Int = 15_000, private val readTimeoutMs: Int = 30_000) : HttpTransport {
    override fun send(request: HttpRequest, responseLimit: Int): HttpResponse {
        val url = URI(request.url).toURL()
        if (!url.protocol.equals("https", ignoreCase = true)) throw IOException("Only HTTPS is permitted.")
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.requestMethod = request.method
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            request.body?.let { body ->
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val body = stream?.use { readBounded(it, responseLimit) } ?: ByteArray(0)
            return HttpResponse(status, body, connection.contentType, connection.getHeaderField("Date"))
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        fun readBounded(input: InputStream, limit: Int): ByteArray {
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (out.size() + read > limit) throw ResponseTooLargeException()
                out.write(buffer, 0, read)
            }
            return out.toByteArray()
        }
    }
}
