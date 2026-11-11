package dev.syndro.app

import android.content.res.AssetManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale
import java.util.concurrent.Executors

data class StoredFile(
    val id: String,
    val name: String,
    val size: Long,
    val mime: String,
    val receivedAt: Long,
    val file: File,
)

/**
 * The Android implementation of the Syndro transfer protocol. It deliberately
 * speaks exactly the same HTTP API as the desktop server, so the embedded web
 * UI is byte-for-byte the same page a browser gets from a PC.
 */
class ShareServer(
    private val token: String,
    private val deviceName: String,
    private val assets: AssetManager,
    rootDir: File,
    private val port: Int = DEFAULT_PORT,
    private val onFilesChanged: (List<StoredFile>) -> Unit = {},
    private val serverId: String = "",
) {

    companion object {
        const val DEFAULT_PORT = 47821
        private const val MAX_CHUNK = 16L * 1024 * 1024
        private const val MAX_JSON = 64 * 1024
        private const val MAX_FILE = 64L * 1024 * 1024 * 1024
        private val HEX_ID = Regex("^[a-f0-9]{24}$")
    }

    private class Upload(
        val id: String,
        val name: String,
        val size: Long,
        val mime: String,
        val temp: File,
    ) {
        var received: Long = 0
    }

    private val filesDir = File(rootDir, "files")
    private val tmpDir = File(rootDir, "tmp")
    private val files = LinkedHashMap<String, StoredFile>()
    private val uploads = HashMap<String, Upload>()
    private val lock = Any()
    private val random = SecureRandom()
    private val pool = Executors.newCachedThreadPool()

    @Volatile
    private var running = false
    private var serverSocket: ServerSocket? = null

    var boundPort: Int = port
        private set

    fun start(): Int {
        filesDir.mkdirs()
        tmpDir.mkdirs()
        loadIndex()

        val socket = bind()
        serverSocket = socket
        boundPort = socket.localPort
        running = true

        Thread({ acceptLoop(socket) }, "syndro-accept").apply {
            isDaemon = true
            start()
        }
        return boundPort
    }

    fun stop() {
        running = false
        try {
            serverSocket?.close()
        } catch (_: IOException) {
        }
        serverSocket = null
        pool.shutdownNow()
    }

    fun files(): List<StoredFile> = synchronized(lock) {
        files.values.sortedByDescending { it.receivedAt }
    }

    /* ------------------------------------------------------------- sockets */

    private fun bind(): ServerSocket {
        var last: Exception? = null
        for (candidate in intArrayOf(port, 0)) {
            for (host in arrayOf("::", "0.0.0.0")) {
                try {
                    val socket = ServerSocket()
                    socket.reuseAddress = true
                    socket.bind(InetSocketAddress(InetAddress.getByName(host), candidate), 64)
                    return socket
                } catch (error: Exception) {
                    last = error
                }
            }
        }
        throw IOException("could not bind a socket", last)
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (running) {
            val client = try {
                socket.accept()
            } catch (_: IOException) {
                if (running) continue else break
            }
            try {
                pool.execute { handleClient(client) }
            } catch (_: Exception) {
                try {
                    client.close()
                } catch (_: IOException) {
                }
            }
        }
    }

    private fun handleClient(client: Socket) {
        try {
            client.use { socket ->
                socket.soTimeout = 120_000
                val input = BufferedInputStream(socket.getInputStream())
                val output = BufferedOutputStream(socket.getOutputStream())

                val requestLine = readLine(input) ?: return
                val parts = requestLine.split(' ')
                if (parts.size < 2) return

                val method = parts[0].uppercase(Locale.US)
                val target = parts[1]
                val headers = HashMap<String, String>()

                while (true) {
                    val line = readLine(input) ?: return
                    if (line.isEmpty()) break
                    val colon = line.indexOf(':')
                    if (colon > 0) {
                        headers[line.substring(0, colon).trim().lowercase(Locale.US)] =
                            line.substring(colon + 1).trim()
                    }
                }

                val question = target.indexOf('?')
                val rawPath = if (question >= 0) target.substring(0, question) else target
                val rawQuery = if (question >= 0) target.substring(question + 1) else ""
                val path = URLDecoderCompat.decode(rawPath)
                val query = parseQuery(rawQuery)
                val length = headers["content-length"]?.toLongOrNull() ?: 0L

                route(method, path, query, headers, input, length, output)
                output.flush()
            }
        } catch (_: Exception) {
            // A client that disappears mid-transfer is normal on Wi-Fi.
        }
    }

    /* -------------------------------------------------------------- routing */

    private fun route(
        method: String,
        path: String,
        query: Map<String, String>,
        headers: Map<String, String>,
        input: InputStream,
        length: Long,
        out: OutputStream,
    ) {
        if (method == "GET" && path == "/") {
            respond(out, 302, "Found", mapOf("Location" to "/s/$token"), ByteArray(0))
            return
        }

        if (method == "GET" && path == "/favicon.ico") {
            respond(out, 204, "No Content", emptyMap(), ByteArray(0))
            return
        }

        if (method == "GET" && path == "/s/$token") {
            val html = readAsset("web/index.html")
            if (html == null) {
                sendJson(out, 500, errorJson("web UI is missing"))
                return
            }
            respond(
                out,
                200,
                "OK",
                mapOf(
                    "Content-Type" to "text/html; charset=utf-8",
                    "Cache-Control" to "no-store",
                    "X-Content-Type-Options" to "nosniff",
                ),
                html,
            )
            return
        }

        if (method == "GET" && path.startsWith("/assets/")) {
            val name = path.removePrefix("/assets/")
            if (!name.matches(Regex("^[a-zA-Z0-9._-]+$")) || name.contains("..")) {
                sendJson(out, 404, errorJson("not found"))
                return
            }
            val data = readAsset("web/assets/$name")
            if (data == null) {
                sendJson(out, 404, errorJson("not found"))
                return
            }
            val type = when (name.substringAfterLast('.', "").lowercase(Locale.US)) {
                "js" -> "text/javascript; charset=utf-8"
                "css" -> "text/css; charset=utf-8"
                "svg" -> "image/svg+xml"
                else -> "application/octet-stream"
            }
            respond(out, 200, "OK", mapOf("Content-Type" to type, "Cache-Control" to "no-cache"), data)
            return
        }

        if (!path.startsWith("/api/")) {
            sendJson(out, 404, errorJson("not found"))
            return
        }

        if (!authorized(query, headers)) {
            sendJson(out, 401, errorJson("invalid or missing token"))
            return
        }

        when {
            method == "GET" && path == "/api/info" -> {
                sendInfo(out)
            }

            method == "GET" && path == "/api/qr.svg" -> {
                val target = Addresses.pickShareUrl(boundPort, "/s/$token")?.url
                    ?: "http://127.0.0.1:$boundPort/s/$token"
                respond(
                    out,
                    200,
                    "OK",
                    mapOf("Content-Type" to "image/svg+xml; charset=utf-8", "Cache-Control" to "no-store"),
                    Qr.svg(target).toByteArray(Charsets.UTF_8),
                )
            }

            method == "GET" && path == "/api/events" -> {
                streamEvents(out)
            }

            method == "GET" && path == "/api/files" -> {
                sendJson(out, 200, JSONObject().put("files", filesJson()))
            }

            method == "POST" && path == "/api/uploads" -> {
                val body = readBody(input, length, MAX_JSON)
                val request = try {
                    JSONObject(body.toString(Charsets.UTF_8))
                } catch (_: Exception) {
                    sendJson(out, 400, errorJson("invalid JSON"))
                    return
                }
                val upload = createUpload(request)
                if (upload == null) {
                    sendJson(out, 413, errorJson("invalid or oversized file"))
                    return
                }
                sendJson(
                    out,
                    201,
                    JSONObject()
                        .put("id", upload.id)
                        .put("name", upload.name)
                        .put("size", upload.size)
                        .put("offset", 0)
                        .put("chunkSize", MAX_CHUNK),
                )
            }

            path.startsWith("/api/uploads/") -> {
                handleUpload(method, path, headers, input, length, out)
            }

            path.startsWith("/api/files/") -> {
                val id = path.removePrefix("/api/files/")
                if (method != "GET" || !HEX_ID.matches(id)) {
                    sendJson(out, 404, errorJson("not found"))
                    return
                }
                val stored = synchronized(lock) { files[id] }
                if (stored == null) {
                    sendJson(out, 404, errorJson("unknown file"))
                    return
                }
                sendStoredFile(out, stored, headers)
            }

            else -> sendJson(out, 404, errorJson("not found"))
        }
    }

    private fun handleUpload(
        method: String,
        path: String,
        headers: Map<String, String>,
        input: InputStream,
        length: Long,
        out: OutputStream,
    ) {
        val rest = path.removePrefix("/api/uploads/")
        val segments = rest.split('/')
        val id = segments.getOrNull(0) ?: ""
        if (!HEX_ID.matches(id)) {
            sendJson(out, 404, errorJson("not found"))
            return
        }

        if (segments.size == 2 && segments[1] == "complete" && method == "POST") {
            val stored = completeUpload(id)
            if (stored == null) {
                sendJson(out, 409, errorJson("upload is incomplete"))
                return
            }
            sendJson(out, 201, JSONObject().put("file", fileJson(stored)))
            onFilesChanged(files())
            return
        }

        if (segments.size != 1) {
            sendJson(out, 404, errorJson("not found"))
            return
        }

        when (method) {
            "GET" -> {
                val upload = synchronized(lock) { uploads[id] }
                if (upload == null) {
                    sendJson(out, 404, errorJson("unknown upload"))
                    return
                }
                sendJson(
                    out,
                    200,
                    JSONObject()
                        .put("id", upload.id)
                        .put("offset", upload.received)
                        .put("size", upload.size),
                )
            }

            "PUT" -> {
                val upload = synchronized(lock) { uploads[id] }
                if (upload == null) {
                    sendJson(out, 404, errorJson("unknown upload"))
                    return
                }
                val offset = headers["x-syndro-offset"]?.toLongOrNull()
                if (offset == null || offset < 0) {
                    sendJson(out, 400, errorJson("x-syndro-offset header is required"))
                    return
                }
                if (length > MAX_CHUNK) {
                    sendJson(out, 413, errorJson("chunk too large"))
                    return
                }
                if (offset != upload.received) {
                    sendJson(out, 409, JSONObject().put("error", "offset mismatch").put("expected", upload.received))
                    return
                }
                if (upload.received + length > upload.size) {
                    sendJson(out, 413, errorJson("chunk exceeds the declared file size"))
                    return
                }
                FileOutputStream(upload.temp, true).use { target ->
                    copyExact(input, target, length)
                }
                synchronized(lock) { upload.received += length }
                sendJson(
                    out,
                    200,
                    JSONObject()
                        .put("id", upload.id)
                        .put("offset", upload.received)
                        .put("size", upload.size),
                )
            }

            "DELETE" -> {
                val upload = synchronized(lock) { uploads.remove(id) }
                upload?.temp?.delete()
                sendJson(out, 200, JSONObject().put("ok", true))
            }

            else -> sendJson(out, 404, errorJson("not found"))
        }
    }

    private fun sendInfo(out: OutputStream) {
        val urls = JSONArray()
        for (entry in Addresses.localUrls(boundPort, "/s/$token")) {
            urls.put(
                JSONObject()
                    .put("url", entry.url)
                    .put("address", entry.address)
                    .put("interfaceName", entry.interfaceName)
                    .put("kind", entry.kind)
                    .put("browserReachable", entry.browserReachable),
            )
        }

        sendJson(
            out,
            200,
            JSONObject()
                .put("deviceName", deviceName)
                .put("serverId", serverId)
                .put("token", token)
                .put("expiresAt", 0)
                .put("ipv6First", true)
                .put("urls", urls)
                .put("files", filesJson()),
        )
    }

    private fun filesJson(): JSONArray {
        val array = JSONArray()
        for (entry in files()) array.put(fileJson(entry))
        return array
    }

    private fun fileJson(entry: StoredFile): JSONObject = JSONObject()
        .put("id", entry.id)
        .put("name", entry.name)
        .put("size", entry.size)
        .put("mime", entry.mime)
        .put("receivedAt", entry.receivedAt)
        .put("origin", "received")

    /* -------------------------------------------------------------- storage */

    private fun createUpload(request: JSONObject): Upload? {
        val size = request.optLong("size", -1)
        if (size < 0 || size > MAX_FILE) return null

        val id = hexId()
        val name = sanitizeName(request.optString("name", "file"))
        val mime = request.optString("mime", "application/octet-stream").take(160)
        val temp = File(tmpDir, "$id.part")
        temp.createNewFile()

        val upload = Upload(id, name, size, mime, temp)
        synchronized(lock) { uploads[id] = upload }
        return upload
    }

    private fun completeUpload(id: String): StoredFile? {
        val upload = synchronized(lock) { uploads[id] } ?: return null
        if (upload.received != upload.size) return null

        val target = File(filesDir, id)
        if (!upload.temp.renameTo(target)) {
            upload.temp.copyTo(target, overwrite = true)
            upload.temp.delete()
        }

        val stored = StoredFile(id, upload.name, upload.size, upload.mime, System.currentTimeMillis(), target)
        synchronized(lock) {
            uploads.remove(id)
            files[id] = stored
        }

        val meta = JSONObject()
            .put("id", stored.id)
            .put("name", stored.name)
            .put("size", stored.size)
            .put("mime", stored.mime)
            .put("receivedAt", stored.receivedAt)
        File(filesDir, "$id.json").writeText(meta.toString(), Charsets.UTF_8)
        return stored
    }

    private fun loadIndex() {
        val entries = filesDir.listFiles() ?: return
        for (meta in entries) {
            if (!meta.name.endsWith(".json")) continue
            try {
                val json = JSONObject(meta.readText(Charsets.UTF_8))
                val id = json.getString("id")
                if (!HEX_ID.matches(id)) continue
                val file = File(filesDir, id)
                if (!file.exists()) continue
                files[id] = StoredFile(
                    id = id,
                    name = json.optString("name", "file"),
                    size = json.optLong("size", file.length()),
                    mime = json.optString("mime", "application/octet-stream"),
                    receivedAt = json.optLong("receivedAt", file.lastModified()),
                    file = file,
                )
            } catch (_: Exception) {
                // Unreadable metadata must not stop the server from starting.
            }
        }
    }

    fun deleteFile(id: String) {
        val stored = synchronized(lock) { files.remove(id) } ?: return
        stored.file.delete()
        File(filesDir, "$id.json").delete()
        onFilesChanged(files())
    }

    /* ------------------------------------------------------------ responses */

    private fun sendStoredFile(out: OutputStream, stored: StoredFile, headers: Map<String, String>) {
        val total = stored.file.length()
        var start = 0L
        var end = total - 1
        var status = 200

        val range = headers["range"]
        if (range != null && range.startsWith("bytes=")) {
            val spec = range.removePrefix("bytes=").split('-')
            val from = spec.getOrNull(0)?.toLongOrNull()
            val to = spec.getOrNull(1)?.toLongOrNull()
            if (from == null) {
                sendJson(out, 416, errorJson("unsupported range"))
                return
            }
            start = from
            if (to != null) end = minOf(to, total - 1)
            if (total == 0L || start >= total || start > end) {
                respond(
                    out,
                    416,
                    "Range Not Satisfiable",
                    mapOf("Content-Range" to "bytes */$total"),
                    ByteArray(0),
                )
                return
            }
            status = 206
        }

        val length = if (total == 0L) 0L else end - start + 1
        val head = StringBuilder()
        head.append("HTTP/1.1 ").append(status)
        head.append(if (status == 206) " Partial Content\r\n" else " OK\r\n")
        head.append("Content-Type: ").append(stored.mime).append("\r\n")
        head.append("Content-Length: ").append(length).append("\r\n")
        head.append("Content-Disposition: ").append(contentDisposition(stored.name)).append("\r\n")
        head.append("Accept-Ranges: bytes\r\n")
        head.append("Cache-Control: no-store\r\n")
        if (status == 206) {
            head.append("Content-Range: bytes ").append(start).append('-').append(end)
                .append('/').append(total).append("\r\n")
        }
        head.append("Connection: close\r\n\r\n")
        out.write(head.toString().toByteArray(Charsets.ISO_8859_1))

        if (length > 0) {
            FileInputStream(stored.file).use { source ->
                source.channel.position(start)
                copyN(source, out, length)
            }
        }
        out.flush()
    }

    private fun streamEvents(out: OutputStream) {
        val head = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/event-stream; charset=utf-8\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n"
        out.write(head.toByteArray(Charsets.ISO_8859_1))
        out.write(": connected\n\n".toByteArray(Charsets.UTF_8))
        out.flush()

        var ticks = 0
        while (running && ticks < 900) {
            try {
                Thread.sleep(20_000)
                out.write(": ping\n\n".toByteArray(Charsets.UTF_8))
                out.flush()
            } catch (_: Exception) {
                break
            }
            ticks++
        }
    }

    private fun respond(
        out: OutputStream,
        status: Int,
        reason: String,
        headers: Map<String, String>,
        body: ByteArray,
    ) {
        val head = StringBuilder()
        head.append("HTTP/1.1 ").append(status).append(' ').append(reason).append("\r\n")
        for ((key, value) in headers) head.append(key).append(": ").append(value).append("\r\n")
        head.append("Content-Length: ").append(body.size).append("\r\n")
        head.append("Connection: close\r\n\r\n")
        out.write(head.toString().toByteArray(Charsets.ISO_8859_1))
        if (body.isNotEmpty()) out.write(body)
        out.flush()
    }

    private fun sendJson(out: OutputStream, status: Int, json: JSONObject) {
        respond(
            out,
            status,
            if (status in 200..299) "OK" else "Error",
            mapOf("Content-Type" to "application/json; charset=utf-8", "Cache-Control" to "no-store"),
            json.toString().toByteArray(Charsets.UTF_8),
        )
    }

    private fun errorJson(message: String): JSONObject = JSONObject().put("error", message)

    /* -------------------------------------------------------------- helpers */

    private fun authorized(query: Map<String, String>, headers: Map<String, String>): Boolean {
        val provided = headers["x-syndro-token"] ?: query["t"] ?: return false
        return MessageDigest.isEqual(
            provided.toByteArray(Charsets.UTF_8),
            token.toByteArray(Charsets.UTF_8),
        )
    }

    private fun readAsset(path: String): ByteArray? = try {
        assets.open(path).use { it.readBytes() }
    } catch (_: IOException) {
        null
    }

    private fun hexId(): String {
        val bytes = ByteArray(12)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun sanitizeName(raw: String): String {
        val base = raw.substringAfterLast('/').substringAfterLast('\\')
        val cleaned = base
            .filter { it.code >= 0x20 && it != '\u007f' }
            .map { if (it in "<>:\"|?*") '_' else it }
            .joinToString("")
            .trimStart('.')
            .trim()
        return (cleaned.ifEmpty { "file" }).take(180)
    }

    private fun contentDisposition(name: String): String {
        val ascii = name.map { if (it.code in 0x20..0x7e && it != '"' && it != '\\') it else '_' }
            .joinToString("")
        val encoded = URLEncoderCompat.encode(name)
        return "attachment; filename=\"$ascii\"; filename*=UTF-8''$encoded"
    }

    private fun parseQuery(raw: String): Map<String, String> {
        if (raw.isEmpty()) return emptyMap()
        val result = HashMap<String, String>()
        for (pair in raw.split('&')) {
            if (pair.isEmpty()) continue
            val index = pair.indexOf('=')
            val key = if (index >= 0) pair.substring(0, index) else pair
            val value = if (index >= 0) pair.substring(index + 1) else ""
            result[URLDecoderCompat.decode(key)] = URLDecoderCompat.decode(value)
        }
        return result
    }

    private fun readLine(input: InputStream): String? {
        val buffer = StringBuilder()
        while (true) {
            val value = input.read()
            if (value == -1) return if (buffer.isEmpty()) null else buffer.toString()
            if (value == '\n'.code) return buffer.toString().trimEnd('\r')
            if (buffer.length > 8192) return null
            buffer.append(value.toChar())
        }
    }

    private fun readBody(input: InputStream, length: Long, limit: Int): ByteArray {
        if (length < 0 || length > limit) throw IOException("body too large")
        val data = ByteArray(length.toInt())
        var offset = 0
        while (offset < data.size) {
            val read = input.read(data, offset, data.size - offset)
            if (read < 0) throw IOException("unexpected end of body")
            offset += read
        }
        return data
    }

    private fun copyExact(input: InputStream, output: OutputStream, length: Long) {
        val buffer = ByteArray(64 * 1024)
        var remaining = length
        while (remaining > 0) {
            val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (read < 0) throw IOException("unexpected end of body")
            output.write(buffer, 0, read)
            remaining -= read
        }
    }

    private fun copyN(input: InputStream, output: OutputStream, length: Long) {
        val buffer = ByteArray(64 * 1024)
        var remaining = length
        while (remaining > 0) {
            val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (read < 0) break
            output.write(buffer, 0, read)
            remaining -= read
        }
    }
}

private object URLDecoderCompat {
    fun decode(value: String): String = java.net.URLDecoder.decode(value, "UTF-8")
}

private object URLEncoderCompat {
    fun encode(value: String): String =
        java.net.URLEncoder.encode(value, "UTF-8").replace("+", "%20")
}
