package dev.syndro.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.util.UUID

/**
 * mDNS is the zero-typing path: a device on the same network browses
 * `_syndro._tcp` and learns host + port without scanning a QR code.
 *
 * The TXT record carries no token. Discovery only says *where* a share lives;
 * the 8-character code is still required, so multicast listeners learn nothing
 * they can use on their own.
 */
const val SYNDRO_SERVICE_TYPE = "_syndro._tcp"

data class NearbyDevice(
    val serviceName: String,
    val name: String,
    val host: String,
    val port: Int,
    val serverId: String?,
) {
    /** `http://[fe80::1%25wlan0]:47821/s/CODE`, or the plain IPv4 form. */
    fun shareUrl(code: String): String {
        val literal = host.removePrefix("[").removeSuffix("]").replace("%25", "%")
        val encoded = when {
            literal.contains(":") -> "[${literal.replace("%", "%25")}]"
            else -> literal
        }
        return "http://$encoded:$port/s/$code"
    }
}

class MdnsRegistrar(
    context: Context,
    private val port: Int,
    private val name: String,
    private val serverId: String,
) {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.RegistrationListener? = null

    fun start() {
        if (listener != null) return
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = SYNDRO_SERVICE_TYPE
            setPort(port)
            setAttribute("id", serverId)
            setAttribute("name", name)
            setAttribute("ver", "1")
        }
        val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        listener = registration
        try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration)
        } catch (_: Exception) {
            listener = null
        }
    }

    fun stop() {
        val current = listener ?: return
        listener = null
        try {
            nsd.unregisterService(current)
        } catch (_: Exception) {
        }
    }
}

class MdnsBrowser(
    context: Context,
    private val excludeServerId: String?,
    private val onFound: (NearbyDevice) -> Unit,
    private val onLost: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val queue = ArrayDeque<NsdServiceInfo>()
    private val seen = HashSet<String>()

    private var discovery: NsdManager.DiscoveryListener? = null
    private var resolving = false
    private var multicast: WifiManager.MulticastLock? = null

    fun start() {
        if (discovery != null) return

        // Some Android builds drop multicast packets unless a lock is held.
        try {
            val wifi = appContext.getSystemService(WifiManager::class.java)
            multicast = wifi.createMulticastLock("syndro-mdns").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                postError("Discovery could not start ($errorCode)")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceType.trimEnd('.') != SYNDRO_SERVICE_TYPE) return
                enqueue(info)
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                val key = info.serviceName
                main.post {
                    seen.remove(key)
                    onLost(key)
                }
            }
        }

        discovery = listener
        try {
            nsd.discoverServices(SYNDRO_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (error: Exception) {
            discovery = null
            postError(error.message ?: "Discovery failed")
        }
    }

    fun stop() {
        discovery?.let {
            try {
                nsd.stopServiceDiscovery(it)
            } catch (_: Exception) {
            }
        }
        discovery = null
        queue.clear()
        resolving = false
        try {
            multicast?.release()
        } catch (_: Exception) {
        }
        multicast = null
    }

    private fun enqueue(info: NsdServiceInfo) {
        main.post {
            queue.addLast(info)
            resolveNext()
        }
    }

    private fun resolveNext() {
        if (resolving) return
        val next = queue.removeFirstOrNull() ?: return
        resolving = true

        val resolver = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                resolving = false
                resolveNext()
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                resolving = false
                val host = info.host?.hostAddress
                if (host == null || info.port <= 0) {
                    resolveNext()
                    return
                }

                val id = info.attributes?.get("id")?.toString(Charsets.UTF_8)
                val label = info.attributes?.get("name")?.toString(Charsets.UTF_8)
                    ?.takeIf { it.isNotBlank() }
                    ?: info.serviceName
                    ?: host

                if (excludeServerId == null || id != excludeServerId) {
                    val device = NearbyDevice(
                        serviceName = info.serviceName ?: host,
                        name = label,
                        host = host,
                        port = info.port,
                        serverId = id,
                    )
                    main.post {
                        seen.add(device.serviceName)
                        onFound(device)
                    }
                }
                resolveNext()
            }
        }

        try {
            nsd.resolveService(next, resolver)
        } catch (_: Exception) {
            resolving = false
            resolveNext()
        }
    }

    private fun postError(message: String) {
        main.post { onError(message) }
    }
}

/** Stable per-install identity used for mDNS TXT and future reconnects. */
fun serverId(context: Context): String {
    val prefs = context.getSharedPreferences("syndro", Context.MODE_PRIVATE)
    val existing = prefs.getString("server_id", null)
    if (existing != null) return existing
    val generated = UUID.randomUUID().toString()
    prefs.edit().putString("server_id", generated).apply()
    return generated
}
