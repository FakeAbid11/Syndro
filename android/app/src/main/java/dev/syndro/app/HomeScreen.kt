package dev.syndro.app

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.progressSemantics
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val Mono = FontFamily.Monospace

private data class SendItem(
    val id: Long,
    val name: String,
    val total: Long,
    val sent: Long,
    val state: String,
)

private data class Prepared(val file: File, val name: String, val mime: String)

@Composable
fun HomeScreen() {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    val running by ShareState.running.collectAsState()
    val urls by ShareState.urls.collectAsState()
    val received by ShareState.received.collectAsState()
    val error by ShareState.error.collectAsState()

    var target by rememberSaveable { mutableStateOf("") }
    var scanning by remember { mutableStateOf(false) }
    var scanNote by remember { mutableStateOf<String?>(null) }
    var discovering by remember { mutableStateOf(false) }
    var discoveryNote by remember { mutableStateOf<String?>(null) }
    var pairDevice by remember { mutableStateOf<NearbyDevice?>(null) }
    var pairCode by rememberSaveable { mutableStateOf("") }
    val nearby = remember { mutableStateListOf<NearbyDevice>() }
    val outbox = remember { mutableStateListOf<SendItem>() }
    val targetValid = remember(target) { parseTarget(target) != null }
    val ownServerId = remember(context) { serverId(context) }

    DisposableEffect(discovering, context, ownServerId) {
        if (!discovering) {
            onDispose { }
        } else {
            nearby.clear()
            discoveryNote = null
            val browser = MdnsBrowser(
                context = context,
                excludeServerId = ownServerId,
                onFound = { device ->
                    val index = nearby.indexOfFirst { it.serviceName == device.serviceName }
                    if (index >= 0) nearby[index] = device else nearby.add(device)
                },
                onLost = { serviceName ->
                    nearby.removeAll { it.serviceName == serviceName }
                },
                onError = { message ->
                    discoveryNote = message
                    discovering = false
                },
            )
            browser.start()
            onDispose { browser.stop() }
        }
    }

    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { }

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        if (uris.isNotEmpty()) {
            scope.launch { runSends(context, uris, target, outbox) }
        }
    }

    fun startSharing() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        context.startForegroundService(Intent(context, ShareService::class.java))
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .systemBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Header()

        Panel(
            title = "Share this device",
            trailing = {
                StatusPill(running)
            },
        ) {
            if (!running) {
                Text(
                    "Receive files from any browser on this network. Nothing to install on the other device.",
                    style = MaterialTheme.typography.bodyMedium.copy(color = SyndroDim),
                )
                Spacer(Modifier.height(16.dp))
                Button(
                    onClick = { startSharing() },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SyndroText,
                        contentColor = SyndroBackground,
                    ),
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                ) {
                    Text("Start sharing", fontWeight = FontWeight.Medium)
                }
            } else {
                ShareBody(urls) { clipboard.setText(AnnotatedString(it)) }
                Spacer(Modifier.height(12.dp))
                Text(
                    "Keep the notification alive while transferring. Android suspends background apps otherwise.",
                    style = MaterialTheme.typography.bodySmall.copy(color = SyndroFaint),
                )
                Spacer(Modifier.height(8.dp))
                TextButton(
                    onClick = {
                        context.startService(
                            Intent(context, ShareService::class.java)
                                .setAction(ShareService.ACTION_STOP),
                        )
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = SyndroDim),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text("Stop sharing")
                }
            }

            error?.let {
                Spacer(Modifier.height(12.dp))
                Text(it, style = MaterialTheme.typography.bodySmall.copy(color = SyndroRed))
            }
        }

        Panel(title = "Send files") {
            Text(
                "Find a nearby Syndro device, or use its QR code when discovery is blocked.",
                style = MaterialTheme.typography.bodySmall.copy(color = SyndroDim),
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = target,
                onValueChange = { target = it; scanNote = null },
                singleLine = true,
                label = { Text("Receiver's share link") },
                placeholder = {
                    Text("http://192.168.1.20:47821/s/…", color = SyndroFaint, fontSize = 13.sp)
                },
                textStyle = MaterialTheme.typography.bodyMedium.copy(
                    fontFamily = Mono,
                    fontSize = 13.sp,
                ),
                shape = RoundedCornerShape(10.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = SyndroAmber,
                    unfocusedBorderColor = SyndroLine,
                    focusedContainerColor = SyndroSurfaceHigh,
                    unfocusedContainerColor = SyndroSurfaceHigh,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = { picker.launch(arrayOf("*/*")) },
                    enabled = targetValid,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SyndroAmber,
                        contentColor = Color(0xFF1A1206),
                        disabledContainerColor = SyndroLine,
                        disabledContentColor = SyndroFaint,
                    ),
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                ) {
                    Text("Choose files", fontWeight = FontWeight.Medium)
                }
                Spacer(Modifier.width(8.dp))
                OutlinedButton(
                    onClick = { scanning = true },
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = SyndroText),
                    border = BorderStroke(1.dp, SyndroLineStrong),
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                ) {
                    Text("Scan QR", fontWeight = FontWeight.Medium)
                }
            }
            Spacer(Modifier.height(8.dp))
            OutlinedButton(
                onClick = { discovering = !discovering },
                colors = ButtonDefaults.outlinedButtonColors(contentColor = SyndroText),
                border = BorderStroke(1.dp, SyndroLineStrong),
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            ) {
                Text(
                    if (discovering) "Stop nearby scan" else "Find nearby devices",
                    fontWeight = FontWeight.Medium,
                )
            }

            if (discovering || nearby.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                Text(
                    if (nearby.isEmpty()) "Searching for _syndro._tcp.local…" else "Nearby",
                    style = MaterialTheme.typography.labelMedium.copy(color = SyndroDim),
                )
                if (nearby.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    nearby.forEach { device ->
                        NearbyRow(device) {
                            pairCode = ""
                            pairDevice = device
                        }
                    }
                }
            }

            discoveryNote?.let { note ->
                Spacer(Modifier.height(8.dp))
                Text(
                    "$note. Scan the QR code instead.",
                    style = MaterialTheme.typography.bodySmall.copy(color = SyndroRed),
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                if (target.isEmpty()) "Waiting for a link" else if (targetValid) "Link looks valid" else "Not a Syndro link",
                style = MaterialTheme.typography.bodySmall.copy(
                    color = if (targetValid) SyndroGreen else SyndroFaint,
                ),
            )
            scanNote?.let { note ->
                Spacer(Modifier.height(4.dp))
                Text(
                    note,
                    style = MaterialTheme.typography.bodySmall.copy(color = SyndroRed),
                )
            }

            if (outbox.isNotEmpty()) {
                Spacer(Modifier.height(16.dp))
                Text(
                    "Outgoing",
                    style = MaterialTheme.typography.labelMedium.copy(color = SyndroDim),
                )
                Spacer(Modifier.height(8.dp))
                outbox.forEach { item -> SendRow(item) }
            }
        }

        Panel(title = "Received") {
            if (received.isEmpty()) {
                Text(
                    "Nothing yet",
                    style = MaterialTheme.typography.bodySmall.copy(color = SyndroFaint),
                )
            } else {
                received.forEach { file ->
                    ReceivedRow(
                        file = file,
                        onSave = {
                            val ok = saveToDownloads(context, file)
                            Toast.makeText(
                                context,
                                if (ok) "Saved to Downloads/Syndro" else "Could not save file",
                                Toast.LENGTH_SHORT,
                            ).show()
                        },
                        onShare = { shareFile(context, file) },
                    )
                }
            }
        }

        Spacer(Modifier.height(8.dp))
    }

    if (scanning) {
        QrScannerScreen(
            onResult = { raw ->
                scanning = false
                val scanned = raw.trim()
                if (parseTarget(scanned) != null) {
                    target = scanned
                    scanNote = null
                } else {
                    scanNote = "That QR is not a Syndro share link"
                }
            },
            onClose = { scanning = false },
        )
    }

    pairDevice?.let { device ->
        val normalized = Code.normalize(pairCode)
        AlertDialog(
            onDismissRequest = { pairDevice = null },
            containerColor = SyndroSurface,
            title = { Text("Pair with ${device.name}") },
            text = {
                Column {
                    Text(
                        "Enter the 8-character code shown on that device. Discovery never broadcasts the code.",
                        style = MaterialTheme.typography.bodyMedium.copy(color = SyndroDim),
                    )
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(
                        value = pairCode,
                        onValueChange = { pairCode = it.take(12) },
                        singleLine = true,
                        label = { Text("Pair code") },
                        placeholder = { Text("ABCD 2345") },
                        textStyle = MaterialTheme.typography.bodyLarge.copy(
                            fontFamily = Mono,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Medium,
                            letterSpacing = 0.sp,
                        ),
                        shape = RoundedCornerShape(10.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = SyndroAmber,
                            unfocusedBorderColor = SyndroLine,
                        ),
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "${device.host}:${device.port}",
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontFamily = Mono,
                            color = SyndroFaint,
                        ),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = normalized != null,
                    onClick = {
                        val code = normalized ?: return@TextButton
                        target = device.shareUrl(code)
                        scanNote = null
                        discoveryNote = null
                        pairDevice = null
                        discovering = false
                    },
                ) {
                    Text("Use device")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { pairDevice = null },
                    colors = ButtonDefaults.textButtonColors(contentColor = SyndroDim),
                ) {
                    Text("Cancel")
                }
            },
        )
    }
}

@Composable
private fun Header() {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(16.dp)
                .clip(RoundedCornerShape(4.dp))
                .background(SyndroAmber),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            "Syndro",
            style = MaterialTheme.typography.titleSmall.copy(
                fontSize = 18.sp,
            ),
        )
        Text(
            Build.MODEL ?: "Android",
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = Mono, color = SyndroDim),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.End,
            modifier = Modifier.weight(1f).padding(start = 16.dp),
        )
    }
}

@Composable
private fun StatusPill(running: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(if (running) SyndroGreen else SyndroFaint),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            if (running) "Live" else "Off",
            style = MaterialTheme.typography.labelSmall.copy(
                fontFamily = Mono,
                color = if (running) SyndroGreen else SyndroFaint,
            ),
        )
    }
}

@Composable
private fun ShareBody(urls: List<ShareUrl>, onCopy: (String) -> Unit) {
    val shareable = urls.filter { it.browserReachable }
    val qrSource = shareable.firstOrNull()?.url
    val bitmap = remember(qrSource) { qrSource?.let { Qr.bitmap(it) } }
    val pairCode = urls.firstOrNull()?.url
        ?.substringAfterLast('/')
        ?.takeIf { Code.isValid(it) }

    if (bitmap != null) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = "QR code for the share link",
                modifier = Modifier
                    .size(180.dp)
                    .clip(RoundedCornerShape(8.dp)),
            )
        }
    }

    if (pairCode != null) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Pair code", style = MaterialTheme.typography.bodySmall.copy(color = SyndroDim))
            Spacer(Modifier.width(8.dp))
            Text(
                Code.group(pairCode),
                style = MaterialTheme.typography.titleSmall.copy(fontFamily = Mono),
            )
        }
    }

    if (shareable.isEmpty()) {
        Text(
            "No browser-reachable address yet. Native Syndro clients can still discover a link-local IPv6 address; browsers need a ULA or private IPv4 address.",
            style = MaterialTheme.typography.bodySmall.copy(color = SyndroAmber),
        )
        return
    }

    shareable.forEach { entry ->
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 8.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(SyndroSurfaceHigh)
                .border(1.dp, SyndroLine, RoundedCornerShape(10.dp))
                .padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                entry.url,
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = Mono),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                tag(entry.kind),
                style = MaterialTheme.typography.labelSmall.copy(
                    fontFamily = Mono,
                    color = SyndroFaint,
                ),
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(min = 40.dp),
            )
            TextButton(
                onClick = { onCopy(entry.url) },
                colors = ButtonDefaults.textButtonColors(contentColor = SyndroDim),
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text("Copy", style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
private fun NearbyRow(device: NearbyDevice, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 8.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(SyndroSurfaceHigh)
            .border(1.dp, SyndroLine, RoundedCornerShape(10.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .heightIn(min = 64.dp)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                device.name,
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${device.host}:${device.port}",
                style = MaterialTheme.typography.labelSmall.copy(
                    fontFamily = Mono,
                    color = SyndroFaint,
                ),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(
            "Pair",
            style = MaterialTheme.typography.labelMedium.copy(color = SyndroDim),
        )
    }
}

@Composable
private fun SendRow(item: SendItem) {
    val fraction = if (item.total > 0) (item.sent.toFloat() / item.total).coerceIn(0f, 1f) else 1f
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 8.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(SyndroSurfaceHigh)
            .border(1.dp, SyndroLine, RoundedCornerShape(10.dp))
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                item.name,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                item.state.replaceFirstChar { it.uppercaseChar() },
                style = MaterialTheme.typography.labelSmall.copy(
                    fontFamily = Mono,
                    color = when (item.state) {
                        "sent" -> SyndroGreen
                        "failed" -> SyndroRed
                        else -> SyndroFaint
                    },
                ),
            )
        }
        Spacer(Modifier.height(8.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(4.dp)
                .progressSemantics(fraction)
                .clip(RoundedCornerShape(2.dp))
                .background(SyndroLine),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(fraction)
                    .height(4.dp)
                    .background(if (item.state == "failed") SyndroRed else SyndroAmber),
            )
        }
    }
}

@Composable
private fun ReceivedRow(file: StoredFile, onSave: () -> Unit, onShare: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 8.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(SyndroSurfaceHigh)
            .border(1.dp, SyndroLine, RoundedCornerShape(10.dp))
            .padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                file.name,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                formatBytes(file.size),
                style = MaterialTheme.typography.labelSmall.copy(
                    fontFamily = Mono,
                    color = SyndroDim,
                ),
            )
        }
        TextButton(
            onClick = onSave,
            colors = ButtonDefaults.textButtonColors(contentColor = SyndroText),
            shape = RoundedCornerShape(6.dp),
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text("Save", style = MaterialTheme.typography.labelMedium)
        }
        TextButton(
            onClick = onShare,
            colors = ButtonDefaults.textButtonColors(contentColor = SyndroDim),
            shape = RoundedCornerShape(6.dp),
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text("Share", style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable
private fun Panel(
    title: String,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = SyndroSurface,
        border = BorderStroke(1.dp, SyndroLine),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleSmall.copy(color = SyndroText),
                    modifier = Modifier.weight(1f),
                )
                trailing?.invoke()
            }
            Spacer(Modifier.height(12.dp))
            content()
        }
    }
}

private suspend fun runSends(
    context: Context,
    uris: List<Uri>,
    targetText: String,
    outbox: SnapshotStateList<SendItem>,
) {
    val target = parseTarget(targetText) ?: return

    for (uri in uris) {
        val prepared = withContext(Dispatchers.IO) { prepare(context, uri) }
        if (prepared == null) {
            outbox.add(0, SendItem(System.nanoTime(), "Unreadable file", 0, 0, "failed"))
            continue
        }

        val id = System.nanoTime()
        val total = prepared.file.length()
        outbox.add(0, SendItem(id, prepared.name, total, 0, "sending"))

        try {
            Sender.send(target, prepared.file, prepared.name, prepared.mime) { sent, bytes ->
                replace(outbox, id) { it.copy(sent = sent, total = bytes, state = "sending") }
            }
            replace(outbox, id) { it.copy(sent = total, total = total, state = "sent") }
        } catch (_: Exception) {
            replace(outbox, id) { it.copy(state = "failed") }
        } finally {
            withContext(Dispatchers.IO) { prepared.file.delete() }
        }
    }
}

private inline fun replace(
    list: SnapshotStateList<SendItem>,
    id: Long,
    transform: (SendItem) -> SendItem,
) {
    val index = list.indexOfFirst { it.id == id }
    if (index >= 0) list[index] = transform(list[index])
}

private fun prepare(context: Context, uri: Uri): Prepared? {
    val resolver = context.contentResolver
    var name = "file"
    try {
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                name = cursor.getString(index) ?: name
            }
        }
    } catch (_: Exception) {
    }

    val safe = name.substringAfterLast('/').substringAfterLast('\\').take(120).ifEmpty { "file" }
    val temp = File(context.cacheDir, "upload-${System.nanoTime()}-$safe")

    return try {
        resolver.openInputStream(uri)?.use { input ->
            temp.outputStream().use { output -> input.copyTo(output) }
        } ?: return null
        Prepared(temp, safe, resolver.getType(uri) ?: "application/octet-stream")
    } catch (_: Exception) {
        temp.delete()
        null
    }
}

private fun shareFile(context: Context, stored: StoredFile) {
    val uri = FileProvider.getUriForFile(context, "dev.syndro.app.files", stored.file)
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = stored.mime
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, "Share ${stored.name}"))
}

private fun saveToDownloads(context: Context, stored: StoredFile): Boolean {
    val values = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, stored.name)
        put(MediaStore.MediaColumns.MIME_TYPE, stored.mime)
        put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Syndro")
    }

    val resolver = context.contentResolver
    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return false

    return try {
        val copied = resolver.openOutputStream(uri)?.use { output ->
            stored.file.inputStream().use { input -> input.copyTo(output) }
        }
        copied != null
    } catch (_: Exception) {
        false
    }
}

private fun tag(kind: String): String = when (kind) {
    "ipv6-ula" -> "ULA"
    "ipv6-global" -> "IPv6"
    "ipv4-private", "ipv4-public" -> "IPv4"
    else -> "Link"
}

private fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble() / 1024
    var unit = 0
    while (value >= 1024 && unit < units.size - 1) {
        value /= 1024
        unit++
    }
    return if (value >= 100) "%.0f %s".format(value, units[unit])
    else if (value >= 10) "%.1f %s".format(value, units[unit])
    else "%.2f %s".format(value, units[unit])
}
