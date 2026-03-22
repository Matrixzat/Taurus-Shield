package com.taurus.shield

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

    private val HBC_CHANNEL   = "com.taurus.shield/hbc"
    private val STORE_CHANNEL = "com.taurus.shield/storage"
    private val LOG_CHANNEL   = "com.taurus.shield/log_stream"
    private val NOTIF_CHANNEL = "com.taurus.shield/notification"

    private val executor    = Executors.newSingleThreadExecutor()
    private val logExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }

        NotificationHelper.createChannels(this)

        // ── Live log streaming ───────────────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOG_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val pumping = AtomicBoolean(true)
                    logExecutor.execute {
                        while (pumping.get()) {
                            val line = LogBridge.poll(100L)
                            when {
                                line == null       -> { }
                                line == LogBridge.DONE -> {
                                    pumping.set(false)
                                    mainHandler.post { events.endOfStream() }
                                }
                                else -> mainHandler.post { events.success(line) }
                            }
                        }
                    }
                }
                override fun onCancel(arguments: Any?) { LogBridge.done() }
            })

        // ── Storage utilities ────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getRootDir" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                    "hasManagePermission" -> {
                        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                            Environment.isExternalStorageManager() else true
                        result.success(granted)
                    }
                    "openManagePermissionSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            try {
                                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                                    .apply { data = Uri.parse("package:$packageName") })
                            } catch (_: Exception) {
                                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                            }
                        }
                        result.success(null)
                    }
                    "ensureOutputDir" -> {
                        val path = call.argument<String>("path") ?: run {
                            result.error("INVALID_ARG", "path required", null); return@setMethodCallHandler
                        }
                        val dir = File(path); dir.mkdirs()
                        result.success(dir.exists())
                    }
                    "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "openFolder" -> {
                        val path = call.argument<String>("path") ?: run { result.success(null); return@setMethodCallHandler }
                        try {
                            val uri = androidx.core.content.FileProvider.getUriForFile(
                                this, "$packageName.fileprovider", File(path))
                            startActivity(Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "resource/folder")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            })
                        } catch (_: Exception) {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(android.net.Uri.parse("file://$path"), "*/*")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                })
                            } catch (_: Exception) {}
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Notifications ────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            val perm = Manifest.permission.POST_NOTIFICATIONS
                            if (ContextCompat.checkSelfPermission(this, perm) != PackageManager.PERMISSION_GRANTED)
                                ActivityCompat.requestPermissions(this, arrayOf(perm), 9001)
                        }
                        result.success(true)
                    }
                    "showProcessing" -> {
                        NotificationHelper.showProcessing(this,
                            call.argument("title") ?: "Taurus Shield",
                            call.argument("body")  ?: "Processing…")
                        result.success(null)
                    }
                    "showResult" -> {
                        NotificationHelper.showResult(this,
                            call.argument<Boolean>("success") ?: true,
                            call.argument("title") ?: "Taurus Shield",
                            call.argument("body")  ?: "")
                        result.success(null)
                    }
                    "cancelProcessing" -> { NotificationHelper.cancelProcessing(this); result.success(null) }
                    else -> result.notImplemented()
                }
            }

        // ── HBC / Blutter channel ────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HBC_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "startProcessing" -> {
                        val filePath  = call.argument<String>("filePath")  ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val fileName  = call.argument<String>("fileName")  ?: ""
                        val mode      = call.argument<String>("mode")      ?: "dsm"
                        val outputDir = call.argument<String>("outputDir") ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val intent = Intent(this, ProcessingService::class.java).apply {
                            putExtra("filePath", filePath); putExtra("fileName", fileName)
                            putExtra("mode", mode);         putExtra("outputDir", outputDir)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(true)
                    }

                    "getProcessingState" -> result.success(ProcessingService.getState(this))

                    "disassemble" -> {
                        val hbcFilePath = call.argument<String>("hbcFilePath") ?: run { result.error("INVALID_ARG", "hbcFilePath required", null); return@setMethodCallHandler }
                        val outputDir   = call.argument<String>("outputDir")   ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        LogBridge.clear()
                        executor.execute {
                            val res = runPython("do_disassemble", hbcFilePath, outputDir)
                            LogBridge.done()
                            mainHandler.post { result.success(res) }
                        }
                    }

                    "assemble" -> {
                        val hasmFilePath = call.argument<String>("hasmFilePath") ?: run { result.error("INVALID_ARG", "hasmFilePath required", null); return@setMethodCallHandler }
                        val outputDir    = call.argument<String>("outputDir")    ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        LogBridge.clear()
                        executor.execute {
                            val res = runPython("do_assemble", hasmFilePath, outputDir)
                            LogBridge.done()
                            mainHandler.post { result.success(res) }
                        }
                    }

                    "blutter_analyze" -> {
                        if (BlutterCloudService.isRunning(this)) {
                            result.success(mapOf("success" to false, "started" to false, "error" to "Analysis already in progress"))
                            return@setMethodCallHandler
                        }
                        val filePath  = call.argument<String>("filePath")  ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val outputDir = call.argument<String>("outputDir") ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val fileName  = call.argument<String>("fileName")  ?: filePath.substringAfterLast('/')
                        val intent = Intent(this, BlutterCloudService::class.java).apply {
                            putExtra("filePath", filePath)
                            putExtra("fileName", fileName)
                            putExtra("outputDir", outputDir)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(mapOf("success" to true, "started" to true))
                    }

                    "blutter_cloud_state" -> {
                        result.success(BlutterCloudService.getState(this))
                    }

                    "blutter_clear_state" -> {
                        BlutterCloudService.clearState(this)
                        result.success(null)
                    }

                    "blutter_cancel" -> {
                        BlutterCloudService.cancel(this)
                        result.success(null)
                    }

                    "dex2c_analyze" -> {
                        if (Dex2CCloudService.isRunning(this)) {
                            result.success(mapOf("success" to false, "started" to false, "error" to "Protection already in progress"))
                            return@setMethodCallHandler
                        }
                        val filePath  = call.argument<String>("filePath")  ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val outputDir = call.argument<String>("outputDir") ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val fileName  = call.argument<String>("fileName")  ?: filePath.substringAfterLast('/')
                        val signApk   = call.argument<Boolean>("signApk") ?: true
                        val intent = Intent(this, Dex2CCloudService::class.java).apply {
                            putExtra("filePath", filePath)
                            putExtra("fileName", fileName)
                            putExtra("outputDir", outputDir)
                            putExtra("signApk", signApk)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(mapOf("success" to true, "started" to true))
                    }

                    "dex2c_cloud_state" -> {
                        result.success(Dex2CCloudService.getState(this))
                    }

                    "dex2c_clear_state" -> {
                        Dex2CCloudService.clearState(this)
                        result.success(null)
                    }

                    "dex2c_cancel" -> {
                        Dex2CCloudService.cancel(this)
                        result.success(null)
                    }

                    "dptshell_analyze" -> {
                        if (DptShellCloudService.isRunning(this)) {
                            result.success(mapOf("success" to false, "started" to false, "error" to "Shell protection already in progress"))
                            return@setMethodCallHandler
                        }
                        val filePath  = call.argument<String>("filePath")  ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val outputDir = call.argument<String>("outputDir") ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val fileName  = call.argument<String>("fileName")  ?: filePath.substringAfterLast('/')
                        val signApk   = call.argument<Boolean>("signApk") ?: true
                        val intent = Intent(this, DptShellCloudService::class.java).apply {
                            putExtra("filePath", filePath)
                            putExtra("fileName", fileName)
                            putExtra("outputDir", outputDir)
                            putExtra("signApk", signApk)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(mapOf("success" to true, "started" to true))
                    }

                    "dptshell_cloud_state" -> {
                        result.success(DptShellCloudService.getState(this))
                    }

                    "dptshell_clear_state" -> {
                        DptShellCloudService.clearState(this)
                        result.success(null)
                    }

                    "dptshell_cancel" -> {
                        DptShellCloudService.cancel(this)
                        result.success(null)
                    }

                    "apktool_analyze" -> {
                        if (ApkToolCloudService.isRunning(this)) {
                            result.success(mapOf("success" to false, "started" to false, "error" to "APK Tool operation already in progress"))
                            return@setMethodCallHandler
                        }
                        val filePath  = call.argument<String>("filePath")  ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val outputDir = call.argument<String>("outputDir") ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val fileName  = call.argument<String>("fileName")  ?: filePath.substringAfterLast('/')
                        val mode      = call.argument<String>("mode")      ?: "decompile"
                        val signApk   = call.argument<Boolean>("signApk") ?: false
                        val intent = Intent(this, ApkToolCloudService::class.java).apply {
                            putExtra("filePath",  filePath)
                            putExtra("fileName",  fileName)
                            putExtra("outputDir", outputDir)
                            putExtra("mode",      mode)
                            putExtra("signApk",   signApk)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(mapOf("success" to true, "started" to true))
                    }

                    "apktool_cloud_state" -> {
                        result.success(ApkToolCloudService.getState(this))
                    }

                    "apktool_clear_state" -> {
                        ApkToolCloudService.clearState(this)
                        result.success(null)
                    }

                    "apktool_cancel" -> {
                        ApkToolCloudService.cancel(this)
                        result.success(null)
                    }

                    "androidIdSpoof_analyze" -> {
                        if (AndroidIdSpoofService.isRunning(this)) {
                            result.success(mapOf("success" to false, "started" to false, "error" to "Spoof already in progress"))
                            return@setMethodCallHandler
                        }
                        val filePath  = call.argument<String>("filePath")  ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val outputDir = call.argument<String>("outputDir") ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val fileName  = call.argument<String>("fileName")  ?: filePath.substringAfterLast('/')
                        val androidId = call.argument<String>("androidId") ?: run { result.error("INVALID_ARG", "androidId required", null); return@setMethodCallHandler }
                        val signApk   = call.argument<Boolean>("signApk") ?: true
                        val intent = Intent(this, AndroidIdSpoofService::class.java).apply {
                            putExtra("filePath",  filePath)
                            putExtra("fileName",  fileName)
                            putExtra("outputDir", outputDir)
                            putExtra("androidId", androidId)
                            putExtra("signApk",   signApk)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(mapOf("success" to true, "started" to true))
                    }

                    "androidIdSpoof_cloud_state" -> {
                        result.success(AndroidIdSpoofService.getState(this))
                    }

                    "androidIdSpoof_clear_state" -> {
                        AndroidIdSpoofService.clearState(this)
                        result.success(null)
                    }

                    "androidIdSpoof_cancel" -> {
                        AndroidIdSpoofService.cancel(this)
                        result.success(null)
                    }

                    "jsEncryptor_analyze" -> {
                        if (JsEncryptorService.isRunning(this)) {
                            result.success(mapOf("success" to false, "started" to false, "error" to "Encryption already in progress"))
                            return@setMethodCallHandler
                        }
                        val filePath    = call.argument<String>("filePath")    ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val outputDir   = call.argument<String>("outputDir")   ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val fileName    = call.argument<String>("fileName")    ?: filePath.substringAfterLast('/')
                        val method      = call.argument<String>("method")      ?: "encmatrix"
                        val subzeroKey  = call.argument<String>("subzeroKey") ?: ""
                        val intent = Intent(this, JsEncryptorService::class.java).apply {
                            putExtra("filePath",    filePath)
                            putExtra("fileName",    fileName)
                            putExtra("outputDir",   outputDir)
                            putExtra("method",      method)
                            if (subzeroKey.isNotEmpty()) putExtra("subzeroKey", subzeroKey)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(mapOf("success" to true, "started" to true))
                    }

                    "jsEncryptor_state" -> {
                        result.success(JsEncryptorService.getState(this))
                    }

                    "jsEncryptor_clear_state" -> {
                        JsEncryptorService.clearState(this)
                        result.success(null)
                    }

                    "jsEncryptor_cancel" -> {
                        JsEncryptorService.cancel(this)
                        result.success(null)
                    }

                    "adsPatch_analyze" -> {
                        if (AdsPatchService.isRunning(this)) {
                            result.success(mapOf("success" to false, "started" to false, "error" to "Ads patch already in progress"))
                            return@setMethodCallHandler
                        }
                        val filePath   = call.argument<String>("filePath")   ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val outputDir  = call.argument<String>("outputDir")  ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val fileName   = call.argument<String>("fileName")   ?: filePath.substringAfterLast('/')
                        val patchLevel = call.argument<String>("patchLevel") ?: "advance"
                        val signApk    = call.argument<Boolean>("signApk")   ?: true
                        val intent = Intent(this, AdsPatchService::class.java).apply {
                            putExtra("filePath",   filePath)
                            putExtra("fileName",   fileName)
                            putExtra("outputDir",  outputDir)
                            putExtra("patchLevel", patchLevel)
                            putExtra("signApk",    signApk)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(mapOf("success" to true, "started" to true))
                    }

                    "adsPatch_cloud_state" -> {
                        result.success(AdsPatchService.getState(this))
                    }

                    "adsPatch_clear_state" -> {
                        AdsPatchService.clearState(this)
                        result.success(null)
                    }

                    "adsPatch_cancel" -> {
                        AdsPatchService.cancel(this)
                        result.success(null)
                    }

                    "antiKiller_analyze" -> {
                        if (AntiKillerService.isRunning(this)) {
                            result.success(mapOf("success" to false, "started" to false, "error" to "Anti-killer already in progress"))
                            return@setMethodCallHandler
                        }
                        val filePath     = call.argument<String>("filePath")     ?: run { result.error("INVALID_ARG", "filePath required", null); return@setMethodCallHandler }
                        val outputDir    = call.argument<String>("outputDir")    ?: run { result.error("INVALID_ARG", "outputDir required", null); return@setMethodCallHandler }
                        val fileName     = call.argument<String>("fileName")     ?: filePath.substringAfterLast('/')
                        val mainActivity = call.argument<String>("mainActivity") ?: ""
                        val signApk      = call.argument<Boolean>("signApk")     ?: true
                        val intent = Intent(this, AntiKillerService::class.java).apply {
                            putExtra("filePath",     filePath)
                            putExtra("fileName",     fileName)
                            putExtra("outputDir",    outputDir)
                            putExtra("mainActivity", mainActivity)
                            putExtra("signApk",      signApk)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                        result.success(mapOf("success" to true, "started" to true))
                    }

                    "antiKiller_cloud_state" -> {
                        result.success(AntiKillerService.getState(this))
                    }

                    "antiKiller_clear_state" -> {
                        AntiKillerService.clearState(this)
                        result.success(null)
                    }

                    "antiKiller_cancel" -> {
                        AntiKillerService.cancel(this)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ── HBC Python bridge ─────────────────────────────────────────────────────

    private fun runPython(method: String, arg1: String, arg2: String): Map<String, Any?> {
        return try {
            val py     = Python.getInstance()
            val bridge = py.getModule("api_bridge")
            val fn     = bridge[method] ?: return mapOf("status" to "error", "log" to "Function '$method' not found", "outputDir" to arg2)
            val map    = fn.call(arg1, arg2).asMap().entries.associate { it.key.toString() to it.value }
            mapOf(
                "status"     to (map["status"]?.toString()      ?: "error"),
                "log"        to (map["log"]?.toString()         ?: ""),
                "outputDir"  to (map["output_dir"]?.toString()  ?: arg2),
                "outputPath" to (map["output_path"]?.toString() ?: ""),
                "error"      to (map["error"]?.toString()       ?: "")
            )
        } catch (e: Exception) {
            mapOf("status" to "error", "log" to "Python error: ${e.message}", "outputDir" to arg2, "error" to (e.message ?: ""))
        }
    }
}
