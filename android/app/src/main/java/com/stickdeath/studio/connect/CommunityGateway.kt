package com.stickdeath.studio.connect

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.URLEncoder

/** Mirrors iOS `CommunityError`: every failure is one of these, and none leaks a response body. */
sealed class CommunityException(message: String) : Exception(message) {
    class NotConfigured : CommunityException("This service is not configured in this build. Nothing was sent.")
    class SignedOut : CommunityException("Sign in with a full account to continue.")
    class Transport(detail: String) : CommunityException(detail)
    class Server(message: String, val code: String?) : CommunityException(message) {
        val isRateLimited get() = code == "rate_limited"
        val isStepUpRequired get() = code == "step_up_required"
    }
    class InvalidResponse(detail: String) : CommunityException(detail)
    class Stale : CommunityException("The screen changed before the reply arrived. Refresh to continue.")
}

/** Supplies the member's own session; the gateway never holds tokens itself. */
interface SessionSource {
    val configured: BackendConfig?
    fun accessToken(): String?
    val generation: Long
}

fun SessionManager.asSessionSource(): SessionSource = object : SessionSource {
    override val configured get() = this@asSessionSource.config?.takeIf { it.networkDeclared }
    override fun accessToken() = try { this@asSessionSource.accessToken() } catch (e: AuthException.Busy) { null }
        catch (e: AuthException) { throw CommunityException.Transport(e.message ?: "The account service could not be reached.") }
    override val generation get() = this@asSessionSource.generation
}

/** PostgREST `rpc/<name>` and RLS-filtered row reads with the member's JWT (iOS `CommunityGateway`).
 * Parameters with null values are omitted so SQL defaults apply, exactly as the Swift encoder does. */
class CommunityGateway(private val session: SessionSource, private val transport: HttpTransport) {
    private fun headers(config: BackendConfig, token: String) = mapOf(
        "apikey" to config.publishableKey, "Authorization" to "Bearer $token",
        "Content-Type" to "application/json", "Accept" to "application/json")

    private fun prepare(): Triple<BackendConfig, String, Long> {
        val config = session.configured ?: throw CommunityException.NotConfigured()
        val generation = session.generation
        val token = session.accessToken() ?: throw CommunityException.SignedOut()
        return Triple(config, token, generation)
    }

    private fun exchange(request: HttpRequest, generation: Long): HttpResponse {
        val response = try { transport.send(request, MAXIMUM_BODY_BYTES) }
            catch (e: ResponseTooLargeException) { throw CommunityException.InvalidResponse("The reply was larger than this screen accepts.") }
            catch (e: IOException) { throw CommunityException.Transport("The service could not be reached. Check your connection and service configuration.") }
        if (session.generation != generation) throw CommunityException.Stale()
        if (response.status == 401 || response.status == 403) throw CommunityException.SignedOut()
        if (response.status !in 200..299) {
            // A PostgREST error body is not shown verbatim.
            throw CommunityException.Transport("The service refused or could not complete the request. Refresh before retrying.")
        }
        return response
    }

    /** Decoded reply object; a server `error` field becomes [CommunityException.Server]. */
    fun call(name: String, params: JSONObject = JSONObject()): JSONObject {
        val reply = callKeepingServerError(name, params)
        val problem = reply.optString("error")
        if (!reply.isNull("error") && problem.isNotEmpty()) throw CommunityException.Server(problem, reply.optString("code").takeIf { it.isNotEmpty() })
        return reply
    }

    /** Like [call] but returns a server `error` inside the object (e.g. a command conflict's head). */
    fun callKeepingServerError(name: String, params: JSONObject = JSONObject()): JSONObject {
        require(NAME.matches(name)) { "Invalid RPC name" }
        val (config, token, generation) = prepare()
        val body = withoutNulls(params).toString().toByteArray(Charsets.UTF_8)
        val response = exchange(HttpRequest("POST", "${config.supabaseUrl}/rest/v1/rpc/$name", headers(config, token), body), generation)
        return runCatching { JSONObject(response.text) }.getOrElse { throw CommunityException.InvalidResponse("The reply did not match the expected contract.") }
    }

    /** `GET /rest/v1/<table>?select=…&col=eq.value&limit=n` under row-level security. */
    fun rows(table: String, select: String = "*", filters: List<Pair<String, String>> = emptyList(), limit: Int = 100): JSONArray {
        require(NAME.matches(table) && limit in 1..1000)
        val (config, token, generation) = prepare()
        val query = buildList {
            add("select=" + enc(select))
            filters.forEach { (column, value) -> require(NAME.matches(column)); add("$column=eq." + enc(value)) }
            add("limit=$limit")
        }.joinToString("&")
        val response = exchange(HttpRequest("GET", "${config.supabaseUrl}/rest/v1/$table?$query", headers(config, token)), generation)
        val rows = runCatching { JSONArray(response.text) }.getOrElse { throw CommunityException.InvalidResponse("The rows did not match the expected contract.") }
        if (rows.length() > limit) throw CommunityException.InvalidResponse("The server returned more rows than requested.")
        return rows
    }

    private fun enc(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")

    companion object {
        const val MAXIMUM_BODY_BYTES = 4 * 1024 * 1024
        private val NAME = Regex("^[a-z_][a-z0-9_]{0,62}$")
        fun withoutNulls(source: JSONObject): JSONObject {
            val out = JSONObject()
            source.keys().forEach { key -> val value = source.opt(key); if (value != null && value != JSONObject.NULL) out.put(key, value) }
            return out
        }
        /** Same rule as iOS `CommunityMediaURL.checked`: HTTPS, a host, and no embedded credentials. */
        fun checkedMediaUrl(raw: String?): String? {
            val uri = runCatching { java.net.URI(raw ?: return null) }.getOrNull() ?: return null
            return raw.takeIf { uri.scheme.equals("https", true) && !uri.host.isNullOrEmpty() && uri.rawUserInfo == null }
        }
    }
}
