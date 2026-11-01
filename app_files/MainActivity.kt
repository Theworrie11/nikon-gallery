package com.example.nikon_gallery

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "camera/network")
            .setMethodCallHandler { call, result ->
                if (call.method == "bindWifi") {
                    val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    var bound = false
                    @Suppress("DEPRECATION")
                    for (n in cm.allNetworks) {
                        val caps = cm.getNetworkCapabilities(n)
                        if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                            bound = cm.bindProcessToNetwork(n)
                            break
                        }
                    }
                    result.success(bound)
                } else {
                    result.notImplemented()
                }
            }
    }
}
