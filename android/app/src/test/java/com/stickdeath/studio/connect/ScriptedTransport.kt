package com.stickdeath.studio.connect

import java.io.IOException

/** Records every request and answers from a script. Nothing here opens a socket. */
class ScriptedTransport(private val handler: (HttpRequest) -> HttpResponse) : HttpTransport {
    val requests = mutableListOf<HttpRequest>()
    override fun send(request: HttpRequest, responseLimit: Int): HttpResponse {
        requests += request
        val response = handler(request)
        if (response.body.size > responseLimit) throw ResponseTooLargeException()
        return response
    }
    companion object {
        fun json(status: Int, body: String) = HttpResponse(status, body.toByteArray(), "application/json; charset=utf-8")
        fun offline() = ScriptedTransport { throw IOException("offline") }
    }
}

object Fixtures {
    const val URL = "https://project.example.test"
    const val KEY = "sb_publishable_fixture_only"
    const val USER = "11111111-2222-4333-8444-555555555555"
    const val OTHER = "66666666-7777-4888-8999-aaaaaaaaaaaa"
    fun config(network: Boolean = true, providers: String = "google,github", spatter: String? = "https://spatter.example.test/v1/chat") =
        BackendConfig.from(URL, KEY, spatter, providers, network)!!
    fun tokenBody(access: String = "access-1", refresh: String = "refresh-1", expiresIn: Long = 3600, anonymous: Boolean = false, email: String? = "creator@example.test") =
        """{"access_token":"$access","token_type":"bearer","expires_in":$expiresIn,"refresh_token":"$refresh","user":{"id":"$USER","email":${email?.let { "\"$it\"" } ?: "null"},"is_anonymous":$anonymous}}"""
}

/** A fixed session source for client tests. */
class FixedSession(var token: String? = "member-token", override var generation: Long = 1, override val configured: BackendConfig? = Fixtures.config()) : SessionSource {
    var onToken: () -> Unit = {}
    override fun accessToken(): String? { onToken(); return token }
}
