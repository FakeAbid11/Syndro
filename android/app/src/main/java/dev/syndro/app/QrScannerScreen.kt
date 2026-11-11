package dev.syndro.app

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size as GeometrySize
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "SyndroQr"

/**
 * Camera preview plus ZXing decoding, with no Google Play Services dependency.
 * The frame is copied out as RGBA, turned into a luminance source, and decoded
 * on a single background executor. The first successful read wins.
 */
@Composable
fun QrScannerScreen(onResult: (String) -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    var error by remember { mutableStateOf<String?>(null) }

    val handled = remember { AtomicBoolean(false) }
    val executor = remember { Executors.newSingleThreadExecutor() }

    DisposableEffect(Unit) {
        onDispose { executor.shutdownNow() }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { ok ->
        granted = ok
        if (!ok) error = "Camera permission is required to scan a QR code"
    }

    LaunchedEffect(Unit) {
        if (!granted) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = Color.Black) {
            Box(Modifier.fillMaxSize()) {
                if (granted) {
                    val previewView = remember {
                        PreviewView(context).apply {
                            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                        }
                    }

                    AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())

                    DisposableEffect(previewView, lifecycleOwner) {
                        val future = ProcessCameraProvider.getInstance(context)
                        var provider: ProcessCameraProvider? = null
                        var active = true

                        future.addListener({
                            if (!active) return@addListener
                            try {
                                val bound = future.get()
                                provider = bound

                                val preview = Preview.Builder().build().also {
                                    it.setSurfaceProvider(previewView.surfaceProvider)
                                }
                                @Suppress("DEPRECATION")
                                val analysis = ImageAnalysis.Builder()
                                    .setTargetResolution(Size(1280, 720))
                                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                    .build()

                                analysis.setAnalyzer(executor) { image ->
                                    if (handled.get()) {
                                        image.close()
                                        return@setAnalyzer
                                    }
                                    val text = decodeQr(image)
                                    if (text != null && handled.compareAndSet(false, true)) {
                                        ContextCompat.getMainExecutor(context).execute {
                                            onResult(text)
                                        }
                                    }
                                }

                                bound.unbindAll()
                                bound.bindToLifecycle(
                                    lifecycleOwner,
                                    CameraSelector.DEFAULT_BACK_CAMERA,
                                    preview,
                                    analysis,
                                )
                            } catch (failure: Exception) {
                                Log.w(TAG, "cannot start camera", failure)
                                error = "Camera unavailable: ${failure.message ?: "unknown error"}"
                            }
                        }, ContextCompat.getMainExecutor(context))

                        onDispose {
                            active = false
                            runCatching { provider?.unbindAll() }
                        }
                    }

                    Canvas(Modifier.fillMaxSize()) {
                        val half = 130.dp.toPx()
                        val centreX = size.width / 2f
                        val centreY = size.height / 2f
                        val shade = Color.Black.copy(alpha = 0.55f)
                        drawRect(shade, Offset(0f, 0f), GeometrySize(size.width, centreY - half))
                        drawRect(
                            shade,
                            Offset(0f, centreY + half),
                            GeometrySize(size.width, size.height - centreY - half),
                        )
                        drawRect(
                            shade,
                            Offset(0f, centreY - half),
                            GeometrySize(centreX - half, half * 2),
                        )
                        drawRect(
                            shade,
                            Offset(centreX + half, centreY - half),
                            GeometrySize(size.width - centreX - half, half * 2),
                        )
                    }

                    Box(
                        Modifier
                            .align(Alignment.Center)
                            .size(260.dp)
                            .border(2.dp, SyndroAmber, RoundedCornerShape(12.dp)),
                    )
                }

                Column(
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = 40.dp, start = 24.dp, end = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        "Scan the other device",
                        color = MaterialTheme.colorScheme.onSurface,
                        style = MaterialTheme.typography.titleLarge,
                    )
                    Text(
                        "Syndro → Share this device → QR",
                        color = SyndroDim,
                        fontSize = 12.sp,
                    )
                }

                error?.let { message ->
                    Box(
                        Modifier
                            .align(Alignment.Center)
                            .padding(24.dp)
                            .background(SyndroSurface.copy(alpha = 0.92f), RoundedCornerShape(12.dp))
                            .padding(16.dp),
                    ) {
                        Text(message, color = SyndroText, fontSize = 13.sp)
                    }
                }

                TextButton(
                    onClick = onClose,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 36.dp),
                ) {
                    Text("Cancel", color = SyndroText)
                }
            }
        }
    }
}

/** RGBA frame -> Bitmap -> ZXing. Always closes the proxy or CameraX stalls. */
private fun decodeQr(image: ImageProxy): String? {
    val created = ArrayList<Bitmap>(3)
    try {
        if (image.width <= 0 || image.height <= 0) return null
        val plane = image.planes.firstOrNull() ?: return null

        val buffer = plane.buffer
        buffer.rewind()
        val pixelStride = plane.pixelStride.coerceAtLeast(1)
        val rowStride = plane.rowStride
        val width = image.width
        val height = image.height
        val paddedWidth = width + (rowStride - pixelStride * width) / pixelStride
        if (paddedWidth < width) return null

        val raw = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
        created.add(raw)
        raw.copyPixelsFromBuffer(buffer)

        val cropped = if (paddedWidth != width) {
            Bitmap.createBitmap(raw, 0, 0, width, height).also { created.add(it) }
        } else {
            raw
        }

        val rotation = image.imageInfo.rotationDegrees
        val upright = if (rotation == 0) {
            cropped
        } else {
            val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
            Bitmap.createBitmap(cropped, 0, 0, cropped.width, cropped.height, matrix, true)
                .also { created.add(it) }
        }

        val pixels = IntArray(upright.width * upright.height)
        upright.getPixels(pixels, 0, upright.width, 0, 0, upright.width, upright.height)

        val source = RGBLuminanceSource(upright.width, upright.height, pixels)
        val binary = BinaryBitmap(HybridBinarizer(source))
        val hints = mapOf<DecodeHintType, Any>(
            DecodeHintType.TRY_HARDER to true,
            DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        )
        return MultiFormatReader().apply { setHints(hints) }.decodeWithState(binary).text
    } catch (_: NotFoundException) {
        return null
    } catch (failure: Exception) {
        Log.d(TAG, "frame skipped: ${failure.message}")
        return null
    } finally {
        for (bitmap in created) {
            if (!bitmap.isRecycled) bitmap.recycle()
        }
        image.close()
    }
}
