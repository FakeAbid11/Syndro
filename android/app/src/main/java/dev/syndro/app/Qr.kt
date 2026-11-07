package dev.syndro.app

import android.graphics.Bitmap
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.encoder.ByteMatrix
import com.google.zxing.qrcode.encoder.Encoder

object Qr {

    private const val QUIET_ZONE = 2

    private fun matrix(text: String): ByteMatrix {
        val hints = HashMap<EncodeHintType, Any>()
        hints[EncodeHintType.CHARACTER_SET] = "UTF-8"
        hints[EncodeHintType.MARGIN] = QUIET_ZONE
        return Encoder.encode(text, ErrorCorrectionLevel.M, hints).matrix
    }

    fun svg(text: String): String {
        val data = matrix(text)
        val width = data.width + QUIET_ZONE * 2
        val height = data.height + QUIET_ZONE * 2

        val path = StringBuilder()
        for (y in 0 until data.height) {
            for (x in 0 until data.width) {
                if (data.get(x, y).toInt() != 1) continue
                path.append('M').append(x + QUIET_ZONE).append(' ').append(y + QUIET_ZONE)
                path.append("h1v1h-1z")
            }
        }

        return buildString {
            append("""<svg xmlns="http://www.w3.org/2000/svg" """)
            append("""viewBox="0 0 $width $height" shape-rendering="crispEdges">""")
            append("""<rect width="$width" height="$height" fill="#ffffff"/>""")
            append("""<path fill="#0b0b0c" d="$path"/>""")
            append("</svg>")
        }
    }

    fun bitmap(text: String, targetPx: Int = 720): Bitmap {
        val data = matrix(text)
        val modules = data.width + QUIET_ZONE * 2
        val scale = maxOf(1, targetPx / modules)
        val size = modules * scale

        val pixels = IntArray(size * size) { 0xFFFFFFFF.toInt() }
        val black = 0xFF000000.toInt()

        for (y in 0 until data.height) {
            for (x in 0 until data.width) {
                if (data.get(x, y).toInt() != 1) continue
                val left = (x + QUIET_ZONE) * scale
                val top = (y + QUIET_ZONE) * scale
                for (dy in 0 until scale) {
                    val rowStart = (top + dy) * size + left
                    java.util.Arrays.fill(pixels, rowStart, rowStart + scale, black)
                }
            }
        }

        return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
    }
}
