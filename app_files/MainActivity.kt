package com.example.nikon_gallery

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "camera/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindWifi" -> result.success(bindWifi())
                    "resizeJpeg" -> {
                        val input = call.argument<String>("input")
                        val output = call.argument<String>("output")
                        val pixels = call.argument<Int>("pixels") ?: 2000000
                        if (input == null || output == null) {
                            result.error("args", "input/output missing", null)
                        } else {
                            Thread {
                                try {
                                    resizeJpeg(input, output, pixels)
                                    runOnUiThread { result.success(true) }
                                } catch (e: Throwable) {
                                    runOnUiThread { result.error("resize", e.message, null) }
                                }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun bindWifi(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        for (n in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(n)
            if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                return cm.bindProcessToNetwork(n)
            }
        }
        return false
    }

    private fun resizeJpeg(input: String, output: String, targetPixels: Int) {
        val bounds = BitmapFactory.Options()
        bounds.inJustDecodeBounds = true
        BitmapFactory.decodeFile(input, bounds)
        val w = bounds.outWidth
        val h = bounds.outHeight
        if (w <= 0 || h <= 0) throw IllegalStateException("Photo decode nahi hui")

        val scale = Math.sqrt(targetPixels.toDouble() / (w.toDouble() * h.toDouble()))
        if (scale >= 1.0) {
            File(input).copyTo(File(output), true)
            return
        }
        val tw = Math.max(1, (w * scale).toInt())
        val th = Math.max(1, (h * scale).toInt())

        var sample = 1
        while (w / (sample * 2) >= tw && h / (sample * 2) >= th) sample *= 2

        val opts = BitmapFactory.Options()
        opts.inSampleSize = sample
        val decoded = BitmapFactory.decodeFile(input, opts)
            ?: throw IllegalStateException("Photo decode nahi hui")
        val scaled = if (decoded.width == tw && decoded.height == th) {
            decoded
        } else {
            Bitmap.createScaledBitmap(decoded, tw, th, true)
        }
        FileOutputStream(output).use { scaled.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        if (scaled !== decoded) scaled.recycle()
        decoded.recycle()

        copyExif(input, output)
    }

    // Date, camera model, orientation wagairah naye file me bhi rakhta hai.
    private fun copyExif(input: String, output: String) {
        try {
            val src = ExifInterface(input)
            val dst = ExifInterface(output)
            val tags = arrayOf(
                "DateTime", "DateTimeOriginal", "DateTimeDigitized", "Make", "Model",
                "Orientation", "ExposureTime", "FNumber", "ISOSpeedRatings",
                "FocalLength", "Flash", "WhiteBalance"
            )
            for (t in tags) {
                val v = src.getAttribute(t)
                if (v != null) dst.setAttribute(t, v)
            }
            dst.saveAttributes()
        } catch (e: Exception) {
            // EXIF copy fail ho to bhi photo save hone do
        }
    }
}
