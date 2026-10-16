// MainActivity.kt v2 – 2026-10-16: uygulama içi güncelleme (indirilen APK için Android kurulum ekranını açar)
package com.example.mobil_app_yeni

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Diğer eklentilerin FileProvider'ıyla çakışmasın diye kendi alt sınıfımız
class GuncellemeFileProvider : FileProvider()

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "monur/guncelleme")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "izinVarMi" -> result.success(
                        if (Build.VERSION.SDK_INT >= 26) packageManager.canRequestPackageInstalls() else true
                    )
                    "izinAyari" -> {
                        if (Build.VERSION.SDK_INT >= 26) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                            )
                        }
                        result.success(true)
                    }
                    "kur" -> {
                        try {
                            val f = File(call.argument<String>("yol")!!)
                            val uri = FileProvider.getUriForFile(this, "$packageName.guncelleme", f)
                            val i = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(i)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("KUR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
