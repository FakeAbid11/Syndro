package dev.syndro.app

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.Collections

/**
 * Same policy as the desktop: rank addresses by how likely a browser is to
 * open them, and never present a link-local IPv6 address as shareable. Browsers
 * reject zone IDs, so `http://[fe80::1%25wlan0]:47821/` is a native-only URL.
 */
data class ShareUrl(
    val url: String,
    val address: String,
    val interfaceName: String,
    val kind: String,
    val browserReachable: Boolean,
)

object Addresses {

    fun localUrls(port: Int, pathSuffix: String): List<ShareUrl> {
        val found = mutableListOf<ShareUrl>()

        val interfaces = try {
            Collections.list(NetworkInterface.getNetworkInterfaces())
        } catch (_: Exception) {
            emptyList()
        }

        for (nif in interfaces) {
            val up = try {
                nif.isUp
            } catch (_: Exception) {
                false
            }
            if (!up || nif.isLoopback) continue

            for (raw in Collections.list(nif.inetAddresses)) {
                val kind = classify(raw) ?: continue
                val address = raw.hostAddress?.substringBefore('%') ?: continue
                val url = formatUrl(raw, port) + pathSuffix
                found += ShareUrl(
                    url = url,
                    address = address,
                    interfaceName = nif.name,
                    kind = kind,
                    browserReachable = kind != LINK_LOCAL,
                )
            }
        }

        return found
            .distinctBy { it.address }
            .sortedWith(
                compareBy<ShareUrl>(
                    { if (it.browserReachable) 0 else 1 },
                    { rank(it.kind) },
                    { it.address },
                ),
            )
    }

    fun pickShareUrl(port: Int, pathSuffix: String): ShareUrl? =
        localUrls(port, pathSuffix).firstOrNull { it.browserReachable }

    private const val LINK_LOCAL = "ipv6-link-local"

    private fun rank(kind: String): Int = when (kind) {
        "ipv6-ula" -> 0
        "ipv6-global" -> 10
        "ipv4-private" -> 20
        "ipv4-public" -> 30
        else -> 40
    }

    private fun classify(address: InetAddress): String? {
        if (address.isLoopbackAddress) return null

        if (address is Inet4Address) {
            val octets = address.address
            val first = octets[0].toInt() and 0xff
            val second = octets[1].toInt() and 0xff
            if (address.isLinkLocalAddress) return "ipv4-private"
            if (first == 10) return "ipv4-private"
            if (first == 172 && second in 16..31) return "ipv4-private"
            if (first == 192 && second == 168) return "ipv4-private"
            return "ipv4-public"
        }

        if (address is Inet6Address) {
            // IPv4-mapped addresses are just IPv4 with extra steps.
            if (address.hostAddress?.contains('.') == true) return null
            if (address.isLinkLocalAddress) return LINK_LOCAL
            if (address.isAnyLocalAddress || address.isMulticastAddress) return null

            val firstByte = address.address[0].toInt() and 0xff
            if ((firstByte and 0xfe) == 0xfc) return "ipv6-ula"
            if ((firstByte and 0xe0) == 0x20) return "ipv6-global"
            return null
        }

        return null
    }

    private fun formatUrl(address: InetAddress, port: Int): String {
        if (address !is Inet6Address) {
            return "http://${address.hostAddress}:$port"
        }
        val host = address.hostAddress?.substringBefore('%') ?: return "http://[$address]:$port"
        return if (address.isLinkLocalAddress) {
            "http://[$host%25${address.scopeId}]:$port"
        } else {
            "http://[$host]:$port"
        }
    }
}
