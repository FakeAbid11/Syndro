package dev.syndro.app

import org.json.JSONObject
import org.json.JSONException
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.nio.channels.ReadableByteChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class Target(val base: String, val token: String)

data class AppReceiver(val target: Target, val name: String)

/**
 * Accepts a full share URL, including a native scoped IPv6 fallback. Pairing
 * must use the receiver's link, not an unrelated path, credentials, or query.
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
    if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
    if (uri.host.isNullOrBlank() || (uri.port != -1 && uri.port !in 1..65535)) return null

    val path = Regex("^/s/([^/]+)/?$").matchEntire(uri.path ?: return null) ?: return null
    val token = Code.normalize(path.groupValues[1]) ?: return null

    return Target("$scheme://$authority", token)
}

internal fun receiverFromInfo(target: Target, info: JSONObject, ownServerId: String): AppReceiver {
    if (ownServerId.isNotBlank() && info.opt("serverId") == ownServerId) {
        throw IOException("That is this device's own link. Use the receiving app's link instead.")
    }
    val name = (info.opt("deviceName") as? String)?.trim().orEmpty()
    if (name.isEmpty() || info.opt("token") != target.token || info.optJSONArray("files") == null) {
        throw IOException("That address is not a valid Syndro receiver. Copy its current share link.")
    }
    return AppReceiver(target, name.take(120))
}

internal fun requireConfirmedFile(reply: JSONObject, id: String, size: Long) {
    val file = reply.optJSONObject("file")
    val confirmedSize = file?.opt("size") as? Number
    if (file?.opt("id") != id || confirmedSize == null ||
        confirmedSize.toLong() != size || confirmedSize.toDouble() != size.toDouble()
    ) {
        throw IOException("The receiver did not confirm the completed file.")
    }
}

object Sender {

    private const val CHUNK = 4 * 1024 * 1024
    private const val MAX_ATTEMPTS = 4

    suspend fun connect(input: String, ownServerId: String): AppReceiver = withContext(Dispatchers.IO) {
        val target = parseTarget(input)
            ?: throw IOException("Paste the receiving app's full http://…/s/CODE share link.")
        val connection = open("GET", "${target.base}/api/info?t=${target.token}")
        try {
            val code = connection.responseCode()
            if (code == HttpURLConnection.HTTP_UNAUTHORIZED) {
                throw IOException("Pair code rejected. Copy the receiver's current link or scan its QR code.")
            }
            if (code !in 200..299) {
                throw IOException("Could not pair (HTTP $code). Keep the receiving app running on this network.")
            }
            val info = try {
                JSONObject(connection.readText())
            } catch (_: JSONException) {
                throw IOException("The receiver did not return a valid Syndro response.")
            }
            receiverFromInfo(target, info, ownServerId)
        } finally {
            connection.close()
        }
    }

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
                    } catch (error: CancellationException) {
                        throw error
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
            val reply = try {
                JSONObject(done.readText())
            } catch (_: JSONException) {
                throw IOException("The receiver did not confirm the completed file.")
            }
            requireConfirmedFile(reply, uploadId, total)
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
