package dev.syndro.app

import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.nio.channels.ReadableByteChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class Target(val base: String, val token: String)

/**
 * Accepts either a full share URL (`http://[fd00::1]:47821/s/<token>`) or a
 * bare `host:port/s/<token>`. Rejecting anything else keeps a mistyped address
 * from sending a file to an unrelated HTTP server.
 */
fun parseTarget(input: String): Target? {
    val text = input.trim()
    if (text.isEmpty()) return null

    val uri = try {
        URI(text)
    } catch (_: Exception) {
        return null
    }

    val scheme = uri.scheme?.lowercase() ?: return null
    if (scheme != "http" && scheme != "https") return null
    val authority = uri.rawAuthority ?: return null

    val segments = uri.path?.split('/')?.filter { it.isNotEmpty() } ?: emptyList()
    val marker = segments.indexOf("s")
    val rawToken = if (marker >= 0) segments.getOrNull(marker + 1) else segments.lastOrNull()
    val token = rawToken?.let { Code.normalize(it) } ?: return null

    return Target("$scheme://$authority", token)
}

object Sender {

    private const val CHUNK = 4 * 1024 * 1024
    private const val MAX_ATTEMPTS = 4

    suspend fun send(
        target: Target,
        file: File,
        displayName: String,
        mime: String,
        onProgress: suspend (Long, Long) -> Unit,
    ): Unit = withContext(Dispatchers.IO) {
        val created = createUpload(target, displayName, file.length(), mime)
        val uploadId = created.getString("id")
        var offset = created.optLong("offset", 0)
        val total = file.length()

        FileInputStream(file).use { source ->
            val channel = source.channel
            while (offset < total) {
                val end = minOf(offset + CHUNK.toLong(), total)
                val size = (end - offset).toInt()
                var attempt = 0

                while (true) {
                    try {
                        val connection = open("PUT", "${target.base}/api/uploads/$uploadId?t=${target.token}")
                        try {
                            connection.setRequestProperty("x-syndro-offset", offset.toString())
                            connection.setFixedLengthStreamingMode(size)
                            channel.position(offset)
                            connection.outputStream().use { output -> copy(channel, output, size) }

                            when (val code = connection.responseCode()) {
                                HttpURLConnection.HTTP_CONFLICT -> {
                                    val conflict = JSONObject(connection.readText())
                                    offset = conflict.optLong("expected", offset)
                                }
                                !in 200..299 -> throw IOException("chunk rejected with $code")
                                else -> {
                                    offset = end
                                    withContext(Dispatchers.Main) { onProgress(offset, total) }
                                }
                            }
                        } finally {
                            connection.close()
                        }
                        break
                    } catch (error: Exception) {
                        attempt += 1
                        if (attempt >= MAX_ATTEMPTS) throw error
                        Thread.sleep(400L * attempt)
                    }
                }
            }
        }

        val done = open("POST", "${target.base}/api/uploads/$uploadId/complete?t=${target.token}")
        try {
            val code = done.responseCode()
            if (code !in 200..299) {
                throw IOException("complete failed with $code")
            }
        } finally {
            done.close()
        }
        withContext(Dispatchers.Main) { onProgress(total, total) }
    }

    private fun createUpload(target: Target, name: String, size: Long, mime: String): JSONObject {
        val connection = open("POST", "${target.base}/api/uploads?t=${target.token}")
        try {
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            val body = JSONObject()
                .put("name", name)
                .put("size", size)
                .put("mime", mime)
                .toString()
                .toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream().use { it.write(body) }

            val code = connection.responseCode()
            if (code !in 200..299) {
                throw IOException("could not create upload: $code")
            }
            return JSONObject(connection.readText())
        } finally {
            connection.close()
        }
    }

    private fun open(method: String, url: String): Wire = WireFactory.open(method, url)

    private fun copy(source: ReadableByteChannel, output: OutputStream, length: Int) {
        val buffer = java.nio.ByteBuffer.allocate(64 * 1024)
        var remaining = length
        while (remaining > 0) {
            buffer.clear()
            buffer.limit(minOf(buffer.capacity(), remaining))
            val read = source.read(buffer)
            if (read < 0) throw IOException("unexpected end of file")
            output.write(buffer.array(), 0, read)
            remaining -= read
        }
    }
}
