package com.stickdeath.studio.connect

import com.stickdeath.studio.billing.PlanCopy
import com.stickdeath.studio.billing.PlanTier
import com.stickdeath.studio.billing.SpatterUsage
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

/** Mirrors iOS `SpatterClientError`; local animation guidance stays available in every case. */
sealed class SpatterException(message: String) : Exception(message) {
    class NotConfigured : SpatterException("Spatter cloud is not configured. Local animation guidance remains available.")
    class NotAuthenticated : SpatterException("Sign in to use Spatter cloud. Local animation guidance remains available.")
    class InvalidRequest : SpatterException("This Spatter request is empty or too large. Shorten the conversation and try again.")
    class InvalidResponse : SpatterException("Spatter's backend returned an invalid response.")
    class EmptyResponse : SpatterException("Spatter's backend returned no answer.")
    class ResponseTooLarge : SpatterException("Spatter's backend response exceeded the size limit.")
    class NetworkUnavailable : SpatterException("Spatter's backend could not be reached. Try again later.")
    /** HTTP 402 `upgrade_required`: Free without credits. Nothing was counted or sent to a provider. */
    class UpgradeRequired : SpatterException(PlanCopy.SPATTER_UPGRADE_NOTE)
    /** Any other HTTP 402 (for example credits used up); the server's own text is not shown. */
    class PaymentRequired(val code: String?) : SpatterException("Spatter needs Creator, Pro or Spatter credits for this request. Buy credits or upgrade in Account, Plans.")
    class HttpStatus(val status: Int) : SpatterException(when (status) {
        401, 403 -> "Spatter's backend did not authorize this request."
        429 -> "Spatter's backend is rate-limited or your daily Spatter budget is used up. Try again later."
        503 -> "Spatter cloud is not configured on the server. Local animation guidance remains available."
        else -> "Spatter's backend reported an HTTP error."
    })
}

data class SpatterMessage(val role: Role, val content: String) {
    enum class Role(val wire: String) { System("system"), User("user"), Assistant("assistant") }
}
/** Server-reported allowance: display data only, never a client-side entitlement. */
data class SpatterBudget(val remaining: Int, val resetsAt: String?)
data class SpatterReply(val schemaVersion: Int, val reply: String, val usageUnits: Int?, val budget: SpatterBudget?)

/** The provider-neutral app backend (iOS `SpatterBackendClient`): the member's session JWT goes to
 * the owner's backend, which holds any model credentials. No provider key exists on the device and
 * provider hosts are refused as endpoints. Blocking; call from `Dispatchers.IO`. */
class SpatterClient(private val endpoint: String?, private val session: SessionSource, private val transport: HttpTransport) {
    fun complete(messages: List<SpatterMessage>): SpatterReply {
        val url = endpoint?.let { SpatterEndpoint.validate(it) } ?: throw SpatterException.NotConfigured()
        if (session.configured == null) throw SpatterException.NotConfigured()
        val token = try { session.accessToken() } catch (e: Exception) { null }
        if (token.isNullOrEmpty() || token.length > 16_384 || token.any { it.code <= 32 || it.code >= 127 }) throw SpatterException.NotAuthenticated()
        if (messages.isEmpty() || messages.size > 41 || messages.any { it.content.isBlank() || it.content.toByteArray().size > 32_768 }) throw SpatterException.InvalidRequest()
        val payload = JSONObject().put("schemaVersion", SCHEMA_VERSION)
            .put("messages", JSONArray(messages.map { JSONObject().put("content", it.content).put("role", it.role.wire) }))
            .put("max_tokens", 500).put("temperature", 0.8)
        val body = payload.toString().toByteArray(Charsets.UTF_8)
        if (body.size > REQUEST_LIMIT) throw SpatterException.InvalidRequest()
        val headers = mapOf("Content-Type" to "application/json", "Accept" to "application/json", "Authorization" to "Bearer $token")
        val response = try { transport.send(HttpRequest("POST", url, headers, body), RESPONSE_LIMIT) }
            catch (e: ResponseTooLargeException) { throw SpatterException.ResponseTooLarge() }
            catch (e: IOException) { throw SpatterException.NetworkUnavailable() }
        if (response.status == 402) {
            val code = runCatching { JSONObject(response.text).optString("code").takeIf { it.isNotEmpty() } }.getOrNull()
            throw if (code == "upgrade_required") SpatterException.UpgradeRequired() else SpatterException.PaymentRequired(code)
        }
        if (response.status !in 200..299) throw SpatterException.HttpStatus(response.status)
        if (response.body.size > RESPONSE_LIMIT) throw SpatterException.ResponseTooLarge()
        if (response.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw SpatterException.InvalidResponse()
        return decode(response.text)
    }

    companion object {
        const val SCHEMA_VERSION = 1
        const val REQUEST_LIMIT = 128 * 1024
        const val RESPONSE_LIMIT = 128 * 1024

        /** Accepts schemaVersion 1 or the legacy `choices` shape; a future version is refused, never guessed. */
        fun decode(text: String): SpatterReply {
            val o = runCatching { JSONObject(text) }.getOrElse { throw SpatterException.InvalidResponse() }
            if (o.has("schemaVersion")) {
                if (o.optInt("schemaVersion", -1) != SCHEMA_VERSION) throw SpatterException.InvalidResponse()
                val reply = o.optString("reply").takeIf { !o.isNull("reply") && it.isNotBlank() } ?: throw SpatterException.EmptyResponse()
                val budget = o.optJSONObject("budget")?.let { b ->
                    val remaining = (b.opt("remaining") as? Number)?.toInt()
                    remaining?.takeIf { it in 0..1_000_000 }?.let { SpatterBudget(it, b.optString("resetsAt").takeIf { s -> s.isNotEmpty() && !b.isNull("resetsAt") }) }
                }
                val units = (o.optJSONObject("usage")?.opt("units") as? Number)?.toInt()?.takeIf { it in 0..1_000_000_000 }
                return SpatterReply(SCHEMA_VERSION, reply, units, budget)
            }
            val content = o.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")?.optString("content")
                ?: throw SpatterException.InvalidResponse()
            if (content.isBlank()) throw SpatterException.EmptyResponse()
            return SpatterReply(0, content, null, null)
        }
    }
}

/** Reads the signed-in account's Spatter plan, allowance and credits from `public.sdi_spatter_my_usage`.
 * The device never counts prompts itself. */
class SpatterUsageClient(private val gateway: CommunityGateway) {
    fun myUsage(): SpatterUsage = SpatterUsageDecoder.decode(gateway.call("sdi_spatter_my_usage"))
}

object SpatterUsageDecoder {
    /** Strict on the plan (an unknown plan is not an allowance), tolerant on everything else:
     * an absent, null or out-of-range count is reported as unknown, never invented. */
    fun decode(o: JSONObject): SpatterUsage {
        if (!o.isNull("error") && o.optString("error").isNotEmpty()) throw SpatterException.InvalidResponse()
        val plan = PlanTier.fromWire(if (o.isNull("plan")) null else o.optString("plan")) ?: throw SpatterException.InvalidResponse()
        fun count(key: String): Int? = if (!o.has(key) || o.isNull(key)) null
            else (o.opt(key) as? Number)?.takeIf { it.toDouble() == Math.floor(it.toDouble()) }?.toLong()?.takeIf { it in 0..1_000_000 }?.toInt()
        fun flag(key: String): Boolean? = if (!o.has(key) || o.isNull(key)) null else o.opt(key) as? Boolean
        val resets = if (o.isNull("resets_at")) null else o.optString("resets_at").takeIf { it.isNotEmpty() && it.length <= 64 }
        val unlimited = plan == PlanTier.Pro || flag("unlimited") == true
        return SpatterUsage(plan, unlimited,
            limit = if (plan == PlanTier.Pro) null else count("limit"),
            remaining = if (plan == PlanTier.Pro) null else count("remaining"),
            credits = count("credits"), available = flag("available"), resetsAt = resets,
            paused = !o.isNull("service") && o.optString("service") == "paused")
    }
    fun decode(text: String): SpatterUsage = decode(runCatching { JSONObject(text) }.getOrElse { throw SpatterException.InvalidResponse() })
}
