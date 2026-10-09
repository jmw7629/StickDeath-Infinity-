package com.stickdeath.studio

import org.json.JSONArray
import org.json.JSONObject

/** Recorded source metadata, not a rights authorization or a signature on an imported backup. */
data class AssetCredit(val assetID: String, val title: String, val author: String,
    val sourceURL: String, val originalSHA256: String, val license: String = "CC0-1.0") {
    fun validate() {
        listOf(assetID, title, author).forEach { require(it.isNotBlank() && it.length <= 240 && it.none(Char::isISOControl)) }
        require(Regex("[0-9a-f]{64}").matches(originalSHA256) && license == "CC0-1.0")
        require(sourceURL.length <= 2048 && sourceURL.none(Char::isISOControl))
        val uri = java.net.URI(sourceURL)
        require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.rawUserInfo == null)
    }
    fun json(): JSONObject { validate(); return JSONObject().put("assetID", assetID).put("title", title)
        .put("author", author).put("sourceURL", sourceURL).put("originalSHA256", originalSHA256).put("license", license) }
    companion object {
        fun decode(j: JSONObject) = AssetCredit(j.getString("assetID"), j.getString("title"), j.getString("author"),
            j.getString("sourceURL"), j.getString("originalSHA256"), j.getString("license")).also { it.validate() }
    }
}

object AssetCredits {
    fun manifest(document: Document): JSONObject {
        val credits = (document.frames.flatMap { it.strokes }.mapNotNull { it.assetCredit } +
            document.audioClips.mapNotNull { it.assetCredit }).distinct().sortedWith(compareBy({ it.assetID }, { it.originalSHA256 }))
        return JSONObject().put("format", "sdi-asset-credits").put("version", 1)
            .put("projectID", document.id).put("revision", document.revision)
            .put("scope", "All project assets, including hidden layers and muted clips. Original hashes precede normalization. Imported backup metadata is not independently certified.")
            .put("uncreditedImageOccurrences", document.frames.sumOf { f -> f.strokes.count { it.image != null && it.assetCredit == null } })
            .put("uncreditedAudioClips", document.audioClips.count { it.assetCredit == null })
            .put("assets", JSONArray(credits.map { it.json() }))
    }
}
