package dev.syndro.app

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.FilterOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Inet6Address
import java.net.NetworkInterface
import java.net.Socket
import java.net.URL

/**
 * `HttpURLConnection` cannot reach a scoped link-local IPv6 target: it refuses
 * the `%25zone` host that is valid in a URL. Routers that isolate IPv4 clients
 * sometimes still forward IPv6 between them, so those addresses are a real
 * fallback — they just need a socket that carries the zone ID.
 *
 * Everything normal stays on `HttpURLConnection`; only scoped IPv6 goes through
 * the small HTTP/1.1 client below.
 */
interface Wire {
    fun setRequestProperty(name: String, value: String)
    fun setFixedLengthStreamingMode(length: Int)
    fun outputStream(): OutputStream
    fun responseCode(): Int
    fun readText(): String
    fun close()
}

private data class ParsedUrl(
    val scheme: String,
    val host: String,
    val port: Int,
    val path: String,
    val scoped: Boolean,
)

object WireFactory {

    fun open(method: String, url: String): Wire {
        val parsed = parse(url) ?: throw IOException("invalid URL")
        if (parsed.scoped && parsed.scheme != "http") {
            throw IOException("scoped link-local IPv6 is supported only over HTTP")
        }
        return if (parsed.scoped) ScopedWire(method, parsed) else ConnectionWire(method, url)
    }

    private val URL_PATTERN =
        Regex("""^([a-zA-Z][a-zA-Z0-9+.\-]*)://(\[[^\]]+\]|[^/:?#]+)(?::(\d+))?(.*)$""")

    private fun parse(url: String): ParsedUrl? {
        val match = URL_PATTERN.find(url) ?: return null
        val scheme = match.groupValues[1].lowercase()
        val rawHost = match.groupValues[2]
        val host = if (rawHost.startsWith("[") && rawHost.endsWith("]")) {
            rawHost.substring(1, rawHost.length - 1)
        } else {
            rawHost
        }.replace("%25", "%")

        val port = match.groupValues[3].takeIf { it.isNotEmpty() }?.toIntOrNull()
            ?: if (scheme == "https") 443 else 80
        val path = match.groupValues[4].takeIf { it.isNotEmpty() } ?: "/"
        return ParsedUrl(scheme, host, port, path, host.contains('%'))
    }
}

private class ConnectionWire(method: String, url: String) : Wire {
    private val connection = (URL(url).openConnection() as HttpURLConnection).apply {
        requestMethod = method
        doOutput = method != "GET" && method != "HEAD"
        connectTimeout = 8_000
        readTimeout = 60_000
        useCaches = false
    }
    private var status = 0

    override fun setRequestProperty(name: String, value: String) {
        connection.setRequestProperty(name, value)
    }

    override fun setFixedLengthStreamingMode(length: Int) {
        connection.setFixedLengthStreamingMode(length)
    }

    override fun outputStream(): OutputStream = connection.outputStream

    override fun responseCode(): Int {
        status = connection.responseCode
        return status
    }

    override fun readText(): String {
        if (status == 0) status = connection.responseCode
        val stream: InputStream? = try {
            if (status in 200..299) connection.inputStream else connection.errorStream
        } catch (_: IOException) {
            null
        }
        return stream?.bufferedReader()?.use { it.readText() }.orEmpty()
    }

    override fun close() {
        connection.disconnect()
    }
}

private class ScopedWire(private val method: String, private val target: ParsedUrl) : Wire {
    private val headers = LinkedHashMap<String, String>()
    private var bodyLength = 0
    private var socket: Socket? = null
    private var bodyOut: OutputStream? = null
    private var requestSent = false
    private var status = 0
    private var text: String? = null

    private fun sendHeaders() {
        val client = connect()
        val args = StringBuilder()
        args.append(method).append(' ').append(target.path).append(" HTTP/1.1\r\n")
        val hostHeader = if (target.host.contains(':')) "[${target.host}]" else target.host
        args.append("Host: ").append(hostHeader).append(':').append(target.port).append("\r\n")
        args.append("Connection: close\r\n")
        args.append("Content-Length: ").append(bodyLength).append("\r\n")
        for ((name, value) in headers) {
            args.append(name).append(": ").append(value).append("\r\n")
        }
        args.append("\r\n")
        val out = client.getOutputStream()
        out.write(args.toString().toByteArray(Charsets.ISO_8859_1))
        out.flush()
        requestSent = true
    }

    private fun connect(): Socket {
        socket?.let { return it }
        val address = scopedAddress(target.host)
        val created = Socket()
        created.connect(java.net.InetSocketAddress(address, target.port), 8_000)
        created.soTimeout = 60_000
        socket = created
        return created
    }

    private fun scopedAddress(host: String): InetAddress {
        val percent = host.lastIndexOf('%')
        if (percent <= 0 || percent == host.lastIndex) return InetAddress.getByName(host)

        val literal = host.substring(0, percent)
        val zone = host.substring(percent + 1)
        val raw = InetAddress.getByName(literal)
        if (raw !is Inet6Address) return raw

        val scopeId = zone.toIntOrNull()
        return if (scopeId != null) {
            Inet6Address.getByAddress(null, raw.address, scopeId)
        } else {
            val network = NetworkInterface.getByName(zone)
                ?: throw IOException("network interface '$zone' is unavailable")
            Inet6Address.getByAddress(null, raw.address, network)
        }
    }

    override fun setRequestProperty(name: String, value: String) {
        headers[name] = value
    }

    override fun setFixedLengthStreamingMode(length: Int) {
        bodyLength = length
    }

    override fun outputStream(): OutputStream {
        bodyOut?.let { return it }
        if (!requestSent) sendHeaders()
        val raw = connect().getOutputStream()
        // Closing a socket's output stream closes the whole socket, which would
        // discard the response. Flush instead, and read the reply afterwards.
        val wrapped = object : FilterOutputStream(raw) {
            override fun close() {
                flush()
            }
        }
        bodyOut = wrapped
        return wrapped
    }

    override fun responseCode(): Int {
        if (text != null) return status
        if (!requestSent) sendHeaders()
        bodyOut?.flush()

        val client = socket ?: throw IOException("not connected")
        val input = BufferedInputStream(client.getInputStream())
        val statusLine = readLine(input) ?: throw IOException("empty response")
        status = statusLine.split(' ').getOrNull(1)?.toIntOrNull()
            ?: throw IOException("bad status line: $statusLine")

        var contentLength = -1L
        var chunked = false
        while (true) {
            val line = readLine(input) ?: break
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val name = line.substring(0, colon).trim().lowercase()
            val value = line.substring(colon + 1).trim()
            if (name == "content-length") contentLength = value.toLongOrNull() ?: -1L
            if (name == "transfer-encoding" && value.contains("chunked", ignoreCase = true)) {
                chunked = true
            }
        }

        text = when {
            chunked -> readChunked(input)
            contentLength >= 0 -> readExactly(input, contentLength)
            else -> input.readBytes().toString(Charsets.UTF_8)
        }

        try {
            client.close()
        } catch (_: IOException) {
        }
        return status
    }

    override fun readText(): String {
        if (text == null) responseCode()
        return text.orEmpty()
    }

    override fun close() {
        bodyOut?.let {
            try {
                it.flush()
            } catch (_: IOException) {
            }
        }
        try {
            socket?.close()
        } catch (_: IOException) {
        }
        socket = null
    }

    private fun readLine(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        var previous = -1
        while (true) {
            val next = input.read()
            if (next < 0) return if (buffer.size() == 0) null else buffer.toString("ISO-8859-1")
            if (previous == '\r'.code && next == '\n'.code) {
                val bytes = buffer.toByteArray()
                return String(bytes, 0, maxOf(0, bytes.size - 1), Charsets.ISO_8859_1)
            }
            buffer.write(next)
            previous = next
        }
    }

    private fun readExactly(input: InputStream, length: Long): String {
        return String(readExactlyBytes(input, length), Charsets.UTF_8)
    }

    private fun readExactlyBytes(input: InputStream, length: Long): ByteArray {
        if (length <= 0) return ByteArray(0)
        val bytes = ByteArray(length.toInt())
        var read = 0
        while (read < bytes.size) {
            val count = input.read(bytes, read, bytes.size - read)
            if (count < 0) break
            read += count
        }
        return if (read == bytes.size) bytes else bytes.copyOf(read)
    }

    private fun readChunked(input: InputStream): String {
        val output = ByteArrayOutputStream()
        while (true) {
            val header = readLine(input) ?: break
            val size = header.substringBefore(';').trim().toLongOrNull(16) ?: break
            if (size == 0L) {
                readLine(input)
                break
            }
            output.write(readExactlyBytes(input, size))
            readLine(input)
        }
        return output.toString("UTF-8")
    }
}
