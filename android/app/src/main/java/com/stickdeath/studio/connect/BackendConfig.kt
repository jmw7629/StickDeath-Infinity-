package com.stickdeath.studio.connect

import org.json.JSONObject
import java.net.URI
import java.util.Base64

/** Identity providers Android can offer through Supabase's hosted OAuth (PKCE) flow. Apple is web
 * OAuth here (iOS uses native Sign in with Apple); every provider stays off until configured. */
enum class OAuthProvider(val wireName: String, val title: String, val scopes: String) {
    Apple("apple", "Apple", "name email"),
    Google("google", "Google", "openid email profile"),
    GitHub("github", "GitHub", "read:user user:email"),
    Microsoft("azure", "Microsoft", "openid email profile");
    companion object {
        fun parse(name: String): OAuthProvider? = when (name.trim().lowercase()) {
            "apple" -> Apple; "google" -> Google; "github" -> GitHub; "microsoft", "azure" -> Microsoft; else -> null
        }
    }
}

/** Validated public build configuration, mirroring iOS `AppConfig.supabaseConfiguration`: an
 * HTTPS project origin and a *publishable* key only (`sb_publishable_…` or a legacy anon JWT).
 * A service-role or malformed key is refused, so the build stays honestly unconfigured. */
data class BackendConfig(
    val supabaseUrl: String,
    val publishableKey: String,
    val spatterEndpoint: String?,
    val oauthProviders: Set<OAuthProvider>,
    /** Whether this build's merged manifest declares INTERNET (see app/build.gradle.kts). */
    val networkDeclared: Boolean,
) {
    override fun toString() = "BackendConfig(supabaseUrl=$supabaseUrl, publishableKey=<redacted>, spatter=${spatterEndpoint != null}, oauth=$oauthProviders, network=$networkDeclared)"

    companion object {
        /** Reads the values Gradle placed in BuildConfig; blank or invalid values yield null. */
        fun from(url: String?, key: String?, spatter: String?, providers: String?, networkDeclared: Boolean): BackendConfig? {
            val origin = origin(url) ?: return null
            val publishable = key?.trim()?.takeIf { isPublishableKey(it) } ?: return null
            return BackendConfig(origin, publishable, spatter?.let { SpatterEndpoint.validate(it) },
                parseProviders(providers), networkDeclared)
        }

        /** Unknown names fail closed (no provider at all), matching iOS. */
        fun parseProviders(raw: String?): Set<OAuthProvider> {
            val names = raw.orEmpty().split(',').map { it.trim() }.filter { it.isNotEmpty() }
            val parsed = names.map { OAuthProvider.parse(it) }
            return if (parsed.any { it == null }) emptySet() else parsed.filterNotNull().toSet()
        }

        /** `https://host` with no credentials, query, fragment, path or non-443 port. */
        fun origin(raw: String?): String? {
            val value = raw?.trim().orEmpty()
            if (value.isEmpty() || value.length > 2048 || value.contains("\${") || value.contains("$(")) return null
            if (value.any { it.isWhitespace() || it.isISOControl() }) return null
            val uri = runCatching { URI(value) }.getOrNull() ?: return null
            if (!uri.scheme.equals("https", ignoreCase = true)) return null
            val host = uri.host?.lowercase() ?: return null
            if (host.isEmpty() || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
            if (uri.port != -1 && uri.port != 443) return null
            if (!(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")) return null
            return "https://$host"
        }

        private val keyAlphabet = Regex("^[A-Za-z0-9_-]+$")

        fun isPublishableKey(key: String): Boolean {
            if (key.length > 8192) return false
            if (key.startsWith("sb_publishable_")) return keyAlphabet.matches(key.removePrefix("sb_publishable_"))
            val parts = key.split('.')
            if (parts.size != 3 || parts.any { !keyAlphabet.matches(it) }) return false
            val header = jwtObject(parts[0]) ?: return false
            val payload = jwtObject(parts[1]) ?: return false
            return header.optString("alg") == "HS256" && payload.optString("role") == "anon" && payload.optString("iss") == "supabase"
        }

        private fun jwtObject(part: String): JSONObject? = runCatching {
            JSONObject(String(Base64.getUrlDecoder().decode(part.padEnd((part.length + 3) / 4 * 4, '=')), Charsets.UTF_8))
        }.getOrNull()
    }
}

/** HTTPS app-backend endpoints only — never a model provider's own API host (iOS `SpatterEndpoint`). */
object SpatterEndpoint {
    private val providers = listOf("openai.com", "anthropic.com", "pollinations.ai",
        "generativelanguage.googleapis.com", "aiplatform.googleapis.com")
    fun validate(raw: String): String? {
        val value = raw.trim()
        if (value.isEmpty() || value.length > 2048 || value.any { it.isISOControl() || it.isWhitespace() }) return null
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (!uri.scheme.equals("https", ignoreCase = true)) return null
        val host = uri.host?.lowercase()?.trim('.') ?: return null
        if (host.isEmpty() || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
        if (uri.port != -1 && uri.port != 443) return null
        if (providers.any { host == it || host.endsWith(".$it") }) return null
        return value
    }
}
