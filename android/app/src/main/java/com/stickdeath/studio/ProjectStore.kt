package com.stickdeath.studio

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class ProjectEntry(val id: String, val name: String, val frames: Int, val modified: Long, val width: Int, val height: Int, val fps: Int, val ticks: Long, val revision: Long)
data class Library(val entries: List<ProjectEntry>, val unreadable: Int)

/** Private application storage. AtomicFile restores the previous file after an interrupted write. */
class ProjectStore(context: Context) {
    private val directory = File(context.filesDir, "studio-projects").apply { mkdirs() }
    private fun file(id: String): AtomicFile {
        require(UUID.fromString(id).toString() == id)
        return AtomicFile(File(directory, "$id.json"))
    }
    @Synchronized fun list(): Library {
        var failed = 0
        // Include interrupted AtomicFile backup records so they can recover.
        val ids = directory.listFiles().orEmpty().filter { it.name.endsWith(".json") || it.name.endsWith(".json.bak") }
            .map { it.name.removeSuffix(".bak").removeSuffix(".json") }.distinct()
        val entries = ids.mapNotNull { id ->
            try { val d = load(id); ProjectEntry(d.id, d.name, d.frames.size, d.modified, d.width, d.height, d.fps, d.frames.sumOf { it.hold.toLong() }, d.revision) }
            catch (_: Exception) { failed++; null }
        }.sortedByDescending { it.modified }
        return Library(entries, failed)
    }
    @Synchronized fun duplicate(entry: ProjectEntry): Document {
        val source = load(entry.id)
        require(source.revision == entry.revision && source.modified == entry.modified) { "Project changed. Refresh the library before duplicating." }
        return saveCopy(source, source.name.take(115) + " copy")
    }
    private fun saveCopy(source: Document, name: String): Document {
        val id = newID()
        require(!File(directory, "$id.json").exists() && !File(directory, "$id.json.bak").exists()) { "Project identity collision. Try again." }
        val layerIDs = source.layers.associate { it.id to newID() }
        val frameIDs = source.frames.associate { it.id to newID() }
        val duplicate = source.copy(id = id, name = name, revision = 0,
            modified = System.currentTimeMillis(), activeLayerID = layerIDs.getValue(source.activeLayerID),
            activeFrameID = frameIDs.getValue(source.activeFrameID),
            layers = source.layers.map { it.copy(id = layerIDs.getValue(it.id)) },
            frames = source.frames.map { frame -> frame.copy(id = frameIDs.getValue(frame.id),
                strokes = frame.strokes.map { it.copy(id = newID(), layerID = layerIDs.getValue(it.layerID)) }) }).validated()
        save(duplicate)
        return duplicate
    }
    @Synchronized fun load(id: String): Document = file(id).openRead().use { decode(it) }.also { require(it.id == id) }
    @Synchronized fun importProject(input: java.io.InputStream): Document {
        val source = decode(input)
        return saveCopy(source, source.name.take(111) + " restored")
    }
    private fun decode(input: java.io.InputStream): Document {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= 8 * 1024 * 1024) { "Project file exceeds the local format limit." }
            output.write(buffer, 0, count)
        }
        val bytes = output.toByteArray()
        val text = String(bytes, Charsets.UTF_8)
        var depth = 0; var quoted = false; var escaped = false
        text.forEach { character ->
            if (quoted) {
                if (escaped) escaped = false
                else if (character == '\\') escaped = true
                else if (character == '"') quoted = false
            } else when (character) {
                '"' -> quoted = true
                '{', '[' -> { depth++; require(depth <= 32) { "Project nesting exceeds the supported format." } }
                '}', ']' -> { depth--; require(depth >= 0) { "Invalid project structure." } }
            }
        }
        require(!quoted && depth == 0) { "Incomplete project file." }
        val j = JSONObject(text)
        require(j.getString("format") == "sdi-android-local" && j.getInt("version") in 1..13) { "Unsupported project format; original preserved." }
        fun array(a: JSONArray): List<JSONObject> = (0 until a.length()).map { a.getJSONObject(it) }
        require(j.getJSONArray("layers").length() in 1..32 && j.getJSONArray("frames").length() in 1..500)
        var strokeCount = 0; var pointCount = 0
        val layers = array(j.getJSONArray("layers")).map {
            Layer(it.getString("id"), it.getString("name"), it.getBoolean("visible"), it.getBoolean("locked"), it.getDouble("opacity").toFloat(),
                if (it.has("blend")) LayerBlend.valueOf(it.getString("blend")) else LayerBlend.Normal)
        }
        require(layers.all { FrameRenderer.supports(it.blend) }) { "This project uses a blend mode that requires Android 10 or later. Original preserved." }
        val frames = array(j.getJSONArray("frames")).map { f ->
            strokeCount += f.getJSONArray("strokes").length()
            require(strokeCount <= 10_000) { "Project has too many strokes." }
            Frame(f.getString("id"), array(f.getJSONArray("strokes")).map { s ->
                val points = s.getJSONArray("points")
                pointCount += points.length()
                require(points.length() in 1..10192 && pointCount <= 100_000) { "Project has too many drawing points." }
                Stroke(s.getString("id"), s.getString("layerID"), (0 until points.length()).map { n ->
                    val p = points.getJSONArray(n); Point(p.getDouble(0).toFloat(), p.getDouble(1).toFloat())
                }, s.getInt("color"), s.getDouble("width").toFloat(), Tool.valueOf(s.getString("tool")),
                    if (s.has("filled")) s.getBoolean("filled") else false,
                    if (s.has("opacity")) s.getDouble("opacity").toFloat() else 1f,
                    if (s.has("brush")) BrushFamily.valueOf(s.getString("brush")) else BrushFamily.Round,
                    if (s.has("brushSeed")) s.getInt("brushSeed") else s.getString("id").hashCode(),
                    if (s.has("brushTransform")) s.getJSONArray("brushTransform").let { t ->
                        require(t.length() == 4)
                        BrushTransform(t.getDouble(0).toFloat(),t.getDouble(1).toFloat(),t.getDouble(2).toFloat(),t.getDouble(3).toFloat())
                    } else BrushTransform(),
                    if (s.has("nibAngle")) s.getDouble("nibAngle").toFloat() else if (s.optString("brush") == "Hatch") -45f else 45f,
                    if (s.has("text")) s.getJSONObject("text").let { EditableText(it.getString("content"), it.getDouble("fontSize").toFloat()) } else null,
                    if (s.has("fill")) s.getJSONArray("fill").let { spans ->
                        require(j.getInt("version") >= 13 && spans.length() in 1..BucketFill.MAX_SPANS)
                        pointCount += spans.length() * 3
                        require(pointCount <= 100_000) { "Project fill capacity reached." }
                        (0 until spans.length()).map { index ->
                            val span = spans.getJSONArray(index)
                            require(span.length() == 3)
                            FillSpan(span.getInt(0), span.getInt(1), span.getInt(2))
                        }
                    } else null)
            }, f.getInt("hold"))
        }
        val onion = if (j.has("onion")) j.getJSONObject("onion").let {
            OnionSettings(it.getBoolean("enabled"), it.getInt("previous"), it.getInt("next"),
                it.getDouble("opacity").toFloat(), it.getBoolean("tinted"))
        } else OnionSettings()
        val grid = if (j.has("grid")) j.getJSONObject("grid").let {
            GridSettings(it.getBoolean("enabled"), it.getInt("spacing"), it.getDouble("opacity").toFloat(), it.getInt("color"))
        } else GridSettings()
        return Document(j.getString("id"), j.getString("name"), j.getInt("width"), j.getInt("height"), j.getInt("fps"),
            frames, layers, j.getString("activeFrameID"), j.getString("activeLayerID"), j.getLong("revision"), j.getLong("modified"), onion, if (j.has("backgroundColor")) j.getInt("backgroundColor") else -1, grid)
            .validated()
    }
    fun encode(document: Document): ByteArray {
        val d = document.validated()
        val j = JSONObject().put("format", "sdi-android-local").put("version", 13)
            .put("id", d.id).put("name", d.name).put("width", d.width).put("height", d.height).put("fps", d.fps)
            .put("activeFrameID", d.activeFrameID).put("activeLayerID", d.activeLayerID).put("revision", d.revision).put("modified", d.modified).put("backgroundColor", d.backgroundColor)
        j.put("grid", JSONObject().put("enabled", d.grid.enabled).put("spacing", d.grid.spacing).put("opacity", d.grid.opacity).put("color", d.grid.color))
        j.put("onion", JSONObject().put("enabled", d.onion.enabled).put("previous", d.onion.previous)
            .put("next", d.onion.next).put("opacity", d.onion.opacity).put("tinted", d.onion.tinted))
        j.put("layers", JSONArray(d.layers.map { l -> JSONObject().put("id", l.id).put("name", l.name)
            .put("visible", l.visible).put("locked", l.locked).put("opacity", l.opacity).put("blend", l.blend.name) }))
        j.put("frames", JSONArray(d.frames.map { f -> JSONObject().put("id", f.id).put("hold", f.hold)
            .put("strokes", JSONArray(f.strokes.map { s -> JSONObject().put("id", s.id).put("layerID", s.layerID)
                .put("color", s.color).put("width", s.width).put("tool", s.tool.name).put("filled", s.filled).put("opacity", s.opacity).put("brush", s.brush.name).put("brushSeed", s.brushSeed).put("nibAngle", s.nibAngle)
                .put("brushTransform", JSONArray(listOf(s.brushTransform.a,s.brushTransform.b,s.brushTransform.c,s.brushTransform.d)))
                .apply { s.text?.let { put("text", JSONObject().put("content", it.content).put("fontSize", it.fontSize)) } }
                .apply { s.fill?.let { spans -> put("fill", JSONArray(spans.map { JSONArray(listOf(it.y, it.start, it.end)) })) } }
                .put("points", JSONArray(s.points.map { JSONArray(listOf(it.x, it.y)) })) })) }))
        val bytes = j.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= 8 * 1024 * 1024) { "Project exceeds 8 MiB. Previous saved version preserved." }
        return bytes
    }
    @Synchronized fun save(document: Document) {
        val bytes = encode(document)
        val target = file(document.id); val stream = target.startWrite()
        try { stream.write(bytes); target.finishWrite(stream) }
        catch (error: Exception) { target.failWrite(stream); throw error }
    }
}
