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
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val Mono = FontFamily.Monospace

private enum class PhoneTask { Receive, Send }

private data class SendItem(
    val id: Long,
    val name: String,
    val total: Long,
    val sent: Long,
    val state: String,
    val destination: String,
    val error: String? = null,
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
    var taskName by rememberSaveable { mutableStateOf(PhoneTask.Receive.name) }
    var showManualLink by rememberSaveable { mutableStateOf(false) }
    var receiver by remember { mutableStateOf<AppReceiver?>(null) }
    var pairingError by remember { mutableStateOf<String?>(null) }
    var connecting by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var pickerReceiver by remember { mutableStateOf<AppReceiver?>(null) }
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
    val busy = connecting || choosing || sending
    val paired = receiver
    val task = PhoneTask.entries.firstOrNull { it.name == taskName } ?: PhoneTask.Receive

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
        // Freeze the receiver before opening the system picker. Never deliver
        // a late picker result to a different app or a newly restored link.
        val destination = pickerReceiver
        pickerReceiver = null
        choosing = false
        if (uris.isNotEmpty() && destination != null) {
            sending = true
            scope.launch {
                try {
                    runSends(context, uris, destination, outbox)
                } finally {
                    sending = false
                }
            }
        }
    }

    fun connectToApp(link: String) {
        if (connecting || choosing || sending || receiver != null) return
        target = link
        receiver = null
        pairingError = null
        scanNote = null
        discoveryNote = null
        discovering = false
        pairDevice = null
        connecting = true
        scope.launch {
            try {
                receiver = Sender.connect(link, ownServerId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                pairingError = error.message?.take(300)
                    ?: "Could not pair. Keep the receiver running on the same Wi-Fi or hotspot."
            } finally {
                connecting = false
            }
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

        TaskSelector(
            task = task,
            receiving = running,
            receiverName = paired?.name,
            enabled = !busy,
            onSelect = { selected ->
                taskName = selected.name
                if (selected == PhoneTask.Receive) {
                    discovering = false
                    nearby.clear()
                    pairDevice = null
                    scanning = false
                }
            },
        )

        when (task) {
            PhoneTask.Receive -> Panel(
                title = "Receive files",
                trailing = { StatusPill(running) },
            ) {
                if (!running) {
                    StepHeading(number = "1", text = "Start receiving")
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Syndro will show a QR code and pairing code for the sending device. Keep both devices on the same Wi-Fi or hotspot.",
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
                        Text("Start receiving", fontWeight = FontWeight.Medium)
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "No account or internet connection is needed",
                        style = MaterialTheme.typography.bodySmall.copy(color = SyndroFaint),
                    )
                } else {
                    StepHeading(number = "2", text = "Pair the sending device")
                    Spacer(Modifier.height(12.dp))
                    ShareBody(urls) {
                        clipboard.setText(AnnotatedString(it))
                        Toast.makeText(context, "Receiver link copied", Toast.LENGTH_SHORT).show()
                    }
                    Spacer(Modifier.height(12.dp))
                    ReadyNote("Ready for files. New files will appear below as they arrive.")
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Keep the Syndro notification active during transfers",
                        style = MaterialTheme.typography.bodySmall.copy(color = SyndroFaint),
                    )
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
                        Text("Stop receiving")
                    }
                }

                error?.let {
                    Spacer(Modifier.height(12.dp))
                    Text(it, style = MaterialTheme.typography.bodySmall.copy(color = SyndroRed))
                }
            }

            PhoneTask.Send -> Panel(title = "Send files") {
                if (paired == null) {
                    StepHeading(number = "1", text = "Choose the receiving device")
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "On the other device, open Syndro and choose Receive. Then use one pairing method below.",
                        style = MaterialTheme.typography.bodyMedium.copy(color = SyndroDim),
                    )
                    Spacer(Modifier.height(16.dp))
                    Button(
                        onClick = {
                            if (discovering) {
                                discovering = false
                                nearby.clear()
                            } else {
                                discovering = true
                            }
                        },
                        enabled = !busy,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = SyndroText,
                            contentColor = SyndroBackground,
                            disabledContainerColor = SyndroLine,
                            disabledContentColor = SyndroFaint,
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    ) {
                        Text(if (discovering) "Stop looking" else "Find nearby devices", fontWeight = FontWeight.Medium)
                    }
                    Spacer(Modifier.height(8.dp))
                    OutlinedButton(
                        onClick = { scanning = true },
                        enabled = !busy,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = SyndroText),
                        border = BorderStroke(1.dp, SyndroLineStrong),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    ) {
                        Text("Scan receiver QR code", fontWeight = FontWeight.Medium)
                    }

                    if (discovering || nearby.isNotEmpty()) {
                        Spacer(Modifier.height(16.dp))
                        Text(
                            if (nearby.isEmpty()) "Looking for Syndro devices…" else "Nearby devices",
                            style = MaterialTheme.typography.labelMedium.copy(color = SyndroDim),
                        )
                        if (nearby.isNotEmpty()) {
                            Spacer(Modifier.height(8.dp))
                            nearby.forEach { device ->
                                NearbyRow(device, enabled = !busy) {
                                    pairCode = ""
                                    pairDevice = device
                                }
                            }
                        }
                    }

                    discoveryNote?.let { note ->
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "$note. Scan the receiver's QR code instead.",
                            style = MaterialTheme.typography.bodySmall.copy(color = SyndroRed),
                        )
                    }

                    Spacer(Modifier.height(12.dp))
                    TextButton(
                        onClick = { showManualLink = !showManualLink },
                        enabled = !busy,
                        colors = ButtonDefaults.textButtonColors(contentColor = SyndroDim),
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Text(if (showManualLink) "Hide link entry" else "Enter a receiver link instead")
                    }

                    if (showManualLink) {
                        Spacer(Modifier.height(4.dp))
                        OutlinedTextField(
                            value = target,
                            onValueChange = { target = it; pairingError = null; scanNote = null },
                            enabled = !busy,
                            singleLine = true,
                            label = { Text("Receiver link") },
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
                                unfocusedBorderColor = SyndroLineStrong,
                                focusedContainerColor = SyndroSurfaceHigh,
                                unfocusedContainerColor = SyndroSurfaceHigh,
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Spacer(Modifier.height(8.dp))
                        Button(
                            onClick = { connectToApp(target) },
                            enabled = !busy && targetValid,
                            colors = ButtonDefaults.buttonColors(
                                containerColor = SyndroAmber,
                                contentColor = Color(0xFF1A1206),
                                disabledContainerColor = SyndroLine,
                                disabledContentColor = SyndroFaint,
                            ),
                            shape = RoundedCornerShape(10.dp),
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                        ) {
                            Text(if (connecting) "Checking receiver…" else "Connect", fontWeight = FontWeight.Medium)
                        }
                    }

                    val connectionError = pairingError ?: scanNote
                    if (connecting || connectionError != null) {
                        Spacer(Modifier.height(12.dp))
                        Text(
                            connectionError ?: "Checking the receiving app…",
                            style = MaterialTheme.typography.bodySmall.copy(
                                color = if (connectionError != null) SyndroRed else SyndroDim,
                            ),
                            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                        )
                    }
                } else {
                    StepHeading(number = "2", text = "Choose files")
                    Spacer(Modifier.height(12.dp))
                    ReceiverCard(
                        receiver = paired,
                        enabled = !busy,
                        onDisconnect = {
                            receiver = null
                            target = ""
                            pairingError = null
                            scanNote = null
                            showManualLink = false
                        },
                    )
                    Spacer(Modifier.height(16.dp))
                    Button(
                        onClick = {
                            val destination = receiver ?: return@Button
                            pickerReceiver = destination
                            choosing = true
                            picker.launch(arrayOf("*/*"))
                        },
                        enabled = !busy,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = SyndroAmber,
                            contentColor = Color(0xFF1A1206),
                            disabledContainerColor = SyndroLine,
                            disabledContentColor = SyndroFaint,
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    ) {
                        Text(if (choosing) "Waiting for file selection…" else "Choose files", fontWeight = FontWeight.Medium)
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Files go directly to ${paired.name}. Sent appears only after that device confirms the complete file.",
                        style = MaterialTheme.typography.bodySmall.copy(color = SyndroDim),
                    )
                }

                if (outbox.isNotEmpty()) {
                    Spacer(Modifier.height(20.dp))
                    Text(
                        "Outgoing",
                        style = MaterialTheme.typography.labelMedium.copy(color = SyndroDim),
                    )
                    Spacer(Modifier.height(8.dp))
                    outbox.forEach { item -> SendRow(item) }
                }
            }
        }

        if (task == PhoneTask.Receive || received.isNotEmpty()) {
            Panel(
                title = "Received files",
                trailing = {
                    if (received.isNotEmpty()) {
                        Text(
                            "${received.size} ${if (received.size == 1) "file" else "files"}",
                            style = MaterialTheme.typography.labelSmall.copy(fontFamily = Mono, color = SyndroDim),
                        )
                    }
                },
            ) {
                if (received.isEmpty()) {
                    Text(
                        if (running) "Waiting for the first file…" else "Files received on this phone will appear here",
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
        }

        Spacer(Modifier.height(8.dp))
    }

    if (scanning) {
        QrScannerScreen(
            onResult = { raw ->
                scanning = false
                val scanned = raw.trim()
                if (parseTarget(scanned) != null) {
                    connectToApp(scanned)
                } else {
                    scanNote = "That is not a Syndro receiver QR code"
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
            title = { Text("Enter code for ${device.name}") },
            text = {
                Column {
                    Text(
                        "Enter the 8-character code shown on the receiving device. This confirms you picked the right device.",
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
                }
            },
            confirmButton = {
                TextButton(
                    enabled = normalized != null && !busy && paired == null,
                    onClick = {
                        val code = normalized ?: return@TextButton
                        connectToApp(device.shareUrl(code))
                    },
                ) {
                    Text("Pair")
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
private fun TaskSelector(
    task: PhoneTask,
    receiving: Boolean,
    receiverName: String?,
    enabled: Boolean,
    onSelect: (PhoneTask) -> Unit,
) {
    Panel(title = "What do you want to do?") {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TaskOption(
                title = "Receive",
                detail = if (receiving) "Ready for incoming files" else "Show a QR and wait for files",
                selected = task == PhoneTask.Receive,
                enabled = enabled,
                onClick = { onSelect(PhoneTask.Receive) },
                modifier = Modifier.weight(1f),
            )
            TaskOption(
                title = "Send",
                detail = receiverName?.let { "Paired with $it" } ?: "Pair, then choose files",
                selected = task == PhoneTask.Send,
                enabled = enabled,
                onClick = { onSelect(PhoneTask.Send) },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun TaskOption(
    title: String,
    detail: String,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(10.dp)
    val isSelected = selected
    Surface(
        shape = shape,
        color = if (selected) SyndroSurfaceHigh else SyndroSurface,
        border = BorderStroke(1.dp, if (selected) SyndroAmber else SyndroLineStrong),
        modifier = modifier
            .heightIn(min = 88.dp)
            .clip(shape)
            .semantics { this.selected = isSelected }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.bodyMedium.copy(
                    color = if (enabled) SyndroText else SyndroFaint,
                    fontWeight = FontWeight.Medium,
                ),
            )
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall.copy(color = if (enabled) SyndroDim else SyndroFaint),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun StepHeading(number: String, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(RoundedCornerShape(8.dp))
                .border(1.dp, SyndroAmber, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                number,
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = Mono, color = SyndroAmber),
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(text, style = MaterialTheme.typography.titleSmall)
    }
}

@Composable
private fun ReadyNote(text: String) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = SyndroSurfaceHigh,
        border = BorderStroke(1.dp, SyndroLine),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(SyndroGreen),
            )
            Spacer(Modifier.width(8.dp))
            Text(text, style = MaterialTheme.typography.bodySmall.copy(color = SyndroDim))
        }
    }
}

@Composable
private fun ReceiverCard(receiver: AppReceiver, enabled: Boolean, onDisconnect: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = SyndroSurfaceHigh,
        border = BorderStroke(1.dp, SyndroLine),
        modifier = Modifier
            .fillMaxWidth()
            .semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        Row(
            modifier = Modifier.padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(SyndroGreen),
            )
            Spacer(Modifier.width(8.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Paired with ${receiver.name}",
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    receiver.target.base,
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = Mono, color = SyndroDim),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            TextButton(
                onClick = onDisconnect,
                enabled = enabled,
                colors = ButtonDefaults.textButtonColors(contentColor = SyndroDim),
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text("Change")
            }
        }
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
            if (running) "Ready" else "Off",
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
    val primary = shareable.firstOrNull() ?: urls.firstOrNull()
    val qrSource = primary?.url
    val bitmap = remember(qrSource) { qrSource?.let { Qr.bitmap(it) } }
    var showLinks by rememberSaveable(qrSource) { mutableStateOf(false) }
    val pairCode = urls.firstOrNull()?.url
        ?.substringAfterLast('/')
        ?.takeIf { Code.isValid(it) }

    if (bitmap != null) {
        Text(
            "Scan this QR in the sending app",
            style = MaterialTheme.typography.bodySmall.copy(color = SyndroDim),
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = "QR code for receiving files on this phone",
                modifier = Modifier
                    .size(180.dp)
                    .clip(RoundedCornerShape(8.dp)),
            )
        }
    }

    if (pairCode != null) {
        Surface(
            shape = RoundedCornerShape(10.dp),
            color = SyndroSurfaceHigh,
            border = BorderStroke(1.dp, SyndroLine),
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
        ) {
            Row(
                modifier = Modifier.padding(12.dp),
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
    }

    if (primary == null) {
        Text(
            "Waiting for a Wi-Fi or hotspot address",
            style = MaterialTheme.typography.bodySmall.copy(color = SyndroAmber),
        )
        return
    }

    Button(
        onClick = { onCopy(primary.url) },
        colors = ButtonDefaults.buttonColors(
            containerColor = SyndroText,
            contentColor = SyndroBackground,
        ),
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
    ) {
        Text("Copy receiver link", fontWeight = FontWeight.Medium)
    }
    Spacer(Modifier.height(8.dp))
    Text(
        if (shareable.isNotEmpty()) "The copied link also works in a browser on this network"
        else "This network link works in the Syndro app, but not in a browser",
        style = MaterialTheme.typography.bodySmall.copy(color = SyndroFaint),
    )

    if (urls.size > 1) {
        Spacer(Modifier.height(4.dp))
        TextButton(
            onClick = { showLinks = !showLinks },
            colors = ButtonDefaults.textButtonColors(contentColor = SyndroDim),
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text(if (showLinks) "Hide network links" else "Show network links")
        }
        if (showLinks) {
            urls.forEach { entry -> NetworkLinkRow(entry, onCopy) }
        }
    }
}

@Composable
private fun NetworkLinkRow(entry: ShareUrl, onCopy: (String) -> Unit) {
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
            style = MaterialTheme.typography.labelSmall.copy(fontFamily = Mono, color = SyndroFaint),
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(min = 48.dp),
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

@Composable
private fun NearbyRow(device: NearbyDevice, enabled: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 8.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(SyndroSurfaceHigh)
            .border(1.dp, SyndroLine, RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
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
            "Choose",
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
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    item.name,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "To ${item.destination} · ${formatBytes(item.total)}",
                    style = MaterialTheme.typography.bodySmall.copy(color = SyndroDim),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
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
        item.error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, style = MaterialTheme.typography.bodySmall.copy(color = SyndroRed))
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
    receiver: AppReceiver,
    outbox: SnapshotStateList<SendItem>,
) {
    for (uri in uris) {
        val prepared = withContext(Dispatchers.IO) { prepare(context, uri) }
        if (prepared == null) {
            outbox.add(0, SendItem(
                System.nanoTime(), "Unreadable file", 0, 0, "failed", receiver.name,
                "Could not read the selected file.",
            ))
            continue
        }

        val id = System.nanoTime()
        val total = prepared.file.length()
        outbox.add(0, SendItem(id, prepared.name, total, 0, "sending", receiver.name))

        try {
            Sender.send(receiver.target, prepared.file, prepared.name, prepared.mime) { sent, bytes ->
                replace(outbox, id) {
                    it.copy(sent = sent, total = bytes, state = if (sent >= bytes) "confirming" else "sending")
                }
            }
            replace(outbox, id) { it.copy(sent = total, total = total, state = "sent") }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            replace(outbox, id) {
                it.copy(state = "failed", error = error.message?.take(300) ?: "The receiver did not accept this file.")
            }
        } finally {
            withContext(NonCancellable + Dispatchers.IO) { prepared.file.delete() }
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
    "ipv6-link-local" -> "Native"
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
