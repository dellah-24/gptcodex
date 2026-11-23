package zw.co.tempest.tapcard

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

object QrCodeGenerator {
    fun create(content: String, size: Int = 800): Bitmap {
        val matrix = QRCodeWriter().encode(
            content,
            BarcodeFormat.QR_CODE,
            size,
            size,
            mapOf(EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 1)
        )
        return Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).apply {
            for (x in 0 until size) for (y in 0 until size) {
                setPixel(x, y, if (matrix[x, y]) Color.rgb(8, 117, 92) else Color.WHITE)
            }
        }
    }
}
