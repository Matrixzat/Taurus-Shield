package com.taurus.shield

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile

class AntiKillerService : Service() {

    companion object {
        const val PREFS          = "anti_killer_svc"
        const val KEY_RUNNING    = "running"
        const val KEY_PHASE      = "phase"
        const val KEY_LOGS       = "logs"
        const val KEY_STATUS     = "result_status"
        const val KEY_OUTPUT_DIR = "output_dir"
        const val KEY_ERROR      = "error"
        const val KEY_FILE_NAME  = "file_name"
        const val KEY_FILE_PATH  = "file_path"
        const val KEY_JOB_ID     = "job_id"
        const val KEY_ASSET_ID   = "asset_id"
        const val KEY_RUN_ID     = "run_id"
        const val KEY_TRIGGER_AT = "trigger_at"
        const val KEY_STEP       = "current_step"
        const val KEY_MAIN_ACT   = "main_activity"

        fun isRunning(context: Context): Boolean =
            context.getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_RUNNING, false)

        fun getState(context: Context): Map<String, Any?> {
            val p = context.getSharedPreferences(PREFS, MODE_PRIVATE)
            return mapOf(
                "running"      to p.getBoolean(KEY_RUNNING, false),
                "phase"        to (p.getString(KEY_PHASE, "") ?: ""),
                "logs"         to (p.getString(KEY_LOGS, "") ?: ""),
                "status"       to (p.getString(KEY_STATUS, "") ?: ""),
                "outputDir"    to (p.getString(KEY_OUTPUT_DIR, "") ?: ""),
                "error"        to (p.getString(KEY_ERROR, "") ?: ""),
                "fileName"     to (p.getString(KEY_FILE_NAME, "") ?: ""),
                "filePath"     to (p.getString(KEY_FILE_PATH, "") ?: ""),
                "jobId"        to (p.getString(KEY_JOB_ID, "") ?: ""),
                "runId"        to p.getLong(KEY_RUN_ID, 0),
                "currentStep"  to (p.getString(KEY_STEP, "") ?: ""),
                "mainActivity" to (p.getString(KEY_MAIN_ACT, "") ?: ""),
            )
        }

        fun clearState(context: Context) {
            context.getSharedPreferences(PREFS, MODE_PRIVATE).edit().clear().apply()
        }

        private val cancelFlag = AtomicBoolean(false)
        private var workerThread: Thread? = null

        fun cancel(context: Context) {
            cancelFlag.set(true)
            workerThread?.interrupt()
            context.stopService(Intent(context, AntiKillerService::class.java))
        }
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var prefs: SharedPreferences
    private val logBuf = StringBuilder()

    private val WORKER by lazy { NativeSecrets.workerUrl() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return bail()

        val filePath     = intent.getStringExtra("filePath")     ?: return bail()
        val outputDir    = intent.getStringExtra("outputDir")    ?: return bail()
        val fileName     = intent.getStringExtra("fileName")     ?: filePath.substringAfterLast('/')
        val mainActivity = intent.getStringExtra("mainActivity") ?: ""

        prefs = getSharedPreferences(PREFS, MODE_PRIVATE)

        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "TaurusShield:AntiKiller"
        ).apply { acquire(90 * 60 * 1000L) }

        val notification = NotificationHelper.buildProcessingNotif(this, "Anti-Dialog Killer", "Uploading APK...")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NotificationHelper.NOTIF_PROCESSING, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NotificationHelper.NOTIF_PROCESSING, notification)
        }

        prefs.edit()
            .putBoolean(KEY_RUNNING, true)
            .putString(KEY_PHASE, "uploading")
            .putString(KEY_LOGS, "")
            .putString(KEY_STATUS, "")
            .putString(KEY_OUTPUT_DIR, outputDir)
            .putString(KEY_ERROR, "")
            .putString(KEY_FILE_NAME, fileName)
            .putString(KEY_FILE_PATH, filePath)
            .putString(KEY_MAIN_ACT, mainActivity)
            .putString(KEY_JOB_ID, "")
            .putLong(KEY_ASSET_ID, 0)
            .putLong(KEY_RUN_ID, 0)
            .putString(KEY_STEP, "Uploading APK...")
            .apply()

        cancelFlag.set(false)
        logBuf.clear()
        LogBridge.clear()

        executor.execute { workerThread = Thread.currentThread(); runCloudOperation(filePath, fileName, outputDir, mainActivity) }
        return START_NOT_STICKY
    }

    private fun bail(): Int { stopSelf(); return START_NOT_STICKY }

    private fun log(line: String) {
        LogBridge.push(line)
        logBuf.appendLine(line)
        prefs.edit().putString(KEY_LOGS, logBuf.toString()).apply()
    }

    private fun updateStep(step: String) {
        prefs.edit().putString(KEY_STEP, step).apply()
        NotificationHelper.showProcessing(this, "Anti-Dialog Killer", step)
    }

    private fun finish(success: Boolean, outputDir: String, error: String) {
        LogBridge.done()
        prefs.edit()
            .putBoolean(KEY_RUNNING, false)
            .putString(KEY_STATUS, if (success) "success" else "error")
            .putString(KEY_OUTPUT_DIR, outputDir)
            .putString(KEY_ERROR, error)
            .putString(KEY_PHASE, "done")
            .apply()
        NotificationHelper.showResult(
            this, success, "Anti-Dialog Killer",
            if (success) "Patch complete. Tap to view results."
            else "Patch failed: $error"
        )
        releaseWake()
        stopForeground(true)
        stopSelf()
    }

    private fun finishCancelled(outputDir: String) {
        cancelFlag.set(false)
        val runId = prefs.getLong(KEY_RUN_ID, 0L)
        if (runId != 0L) {
            try { workerPost("/cancel-run?run_id=$runId") } catch (_: Exception) {}
        }
        LogBridge.push("Operation cancelled by user.")
        LogBridge.done()
        prefs.edit()
            .putBoolean(KEY_RUNNING, false)
            .putString(KEY_STATUS, "cancelled")
            .putString(KEY_OUTPUT_DIR, outputDir)
            .putString(KEY_ERROR, "Cancelled by user")
            .putString(KEY_PHASE, "done")
            .apply()
        NotificationHelper.cancelProcessing(this)
        releaseWake()
        stopForeground(true)
        stopSelf()
    }

    private fun runCloudOperation(
        filePath: String, fileName: String,
        outputDir: String, mainActivity: String
    ) {
        Thread.interrupted()
        val file   = File(filePath)
        val sizeMb = String.format("%.1f", file.length() / 1_048_576.0)

        try {
            log("Anti-Dialog Killer")
            log("File: $fileName ($sizeMb MB)")
            if (mainActivity.isNotBlank()) log("Activity: $mainActivity")
            log("Uploading to cloud...")

            val slotBody = workerGet("/prepare-upload?ext=apk")
            if (slotBody == null) {
                log("Upload failed — check your connection")
                finish(false, outputDir, "Upload failed"); return
            }
            val slotJson  = JSONObject(slotBody)
            val jobId     = slotJson.optString("job_id")
            val uploadUrl = slotJson.optString("upload_url")
            val assetName = slotJson.optString("asset_name")
            val authHdr   = slotJson.optString("auth")

            updateStep("Uploading APK...")
            val assetId = uploadDirectToGitHub(uploadUrl, assetName, authHdr, file)
            if (assetId == 0L) {
                log("Upload failed — check your connection")
                finish(false, outputDir, "Upload failed"); return
            }

            updateStep("Dispatching to cluster...")
            val triggerAt    = System.currentTimeMillis()
            val actEncoded   = java.net.URLEncoder.encode(mainActivity, "UTF-8")
            val dispatchPath = "/dispatch-job?workflow=anti-killer.yml" +
                "&asset_id=$assetId&job_id=$jobId" +
                "&main_activity=$actEncoded"
            val (dispatchCode, dispatchBody) = workerGetWithCode(dispatchPath)
            if (dispatchCode !in 200..299 || dispatchBody == null) {
                log("Dispatch failed (HTTP $dispatchCode): $dispatchBody")
                finish(false, outputDir, "Dispatch failed (HTTP $dispatchCode)"); return
            }

            prefs.edit()
                .putString(KEY_JOB_ID, jobId)
                .putLong(KEY_ASSET_ID, assetId)
                .putLong(KEY_TRIGGER_AT, triggerAt)
                .putString(KEY_PHASE, "finding_run")
                .apply()

            log("Dispatching to processing cluster...")
            Thread.sleep(12_000)
            if (cancelFlag.get()) { finishCancelled(outputDir); return }

            val runId = findRun(triggerAt)
            if (cancelFlag.get()) { finishCancelled(outputDir); return }
            if (runId == null) {
                workerDelete("/asset?asset_id=$assetId")
                log("Could not reach the processing engine")
                finish(false, outputDir, "Could not reach processing engine"); return
            }

            prefs.edit()
                .putLong(KEY_RUN_ID, runId)
                .putString(KEY_PHASE, "polling")
                .apply()

            log("Patch engine started — streaming live progress...")
            val success = pollUntilDone(runId)
            if (cancelFlag.get()) { finishCancelled(outputDir); return }
            if (!success) {
                log("Processing engine returned a failure")
                finish(false, outputDir, "Patch failed"); return
            }

            prefs.edit().putString(KEY_PHASE, "downloading").apply()
            updateStep("Downloading patched APK...")
            log("Downloading patched APK...")

            File(outputDir).mkdirs()
            val tmpZip = File(outputDir, "_artifact_tmp.zip")
            val downloaded = workerDownloadToFile(
                "/artifact?run_id=$runId&job_id=$jobId&prefix=anti-killer", tmpZip)

            if (!downloaded) {
                log("Artifact download failed")
                finish(false, outputDir, "Download failed"); return
            }

            updateStep("Extracting patched APK...")
            log("Extracting results...")
            val outRoot = File(outputDir).canonicalFile
            ZipFile(tmpZip).use { zf ->
                for (entry in zf.entries().toList()) {
                    if (entry.isDirectory) continue
                    val outFile = File(outputDir, entry.name).canonicalFile
                    if (!outFile.path.startsWith(outRoot.path)) continue
                    outFile.parentFile?.mkdirs()
                    zf.getInputStream(entry).use { inp ->
                        outFile.outputStream().use { out -> inp.copyTo(out) }
                    }
                }
            }
            tmpZip.delete()

            val outApk = File(outputDir, "out.apk")
            if (!outApk.exists()) {
                log("ERROR: Patched APK not found in output")
                finish(false, outputDir, "Patched APK not found"); return
            }
            log("Patch complete — APK: ${outApk.length() / 1024}KB saved.")
            finish(true, outputDir, "")

        } catch (e: Throwable) {
            if (cancelFlag.get() || e is InterruptedException) {
                finishCancelled(outputDir)
            } else {
                try { log("Cloud error: ${e.message}") } catch (_: Throwable) {}
                try { finish(false, outputDir, e.message ?: "Unknown error") } catch (_: Throwable) {}
            }
        }
    }

    private fun findRun(afterMs: Long): Long? {
        repeat(20) { attempt ->
            Thread.sleep(6_000)
            if (cancelFlag.get()) return null
            val body = workerGet("/find-run?after=$afterMs&workflow=anti-killer.yml") ?: run {
                log("Waiting for cluster node... (${(attempt + 1) * 6}s)"); return@repeat
            }
            val json = JSONObject(body)
            if (json.optBoolean("found")) {
                val runId = json.getLong("run_id")
                log("Node acquired (task #${json.optInt("run_number")})")
                updateStep("Node acquired")
                return runId
            }
            log("Waiting for cluster node... (${(attempt + 1) * 6}s)")
        }
        return null
    }

    private fun pollUntilDone(runId: Long): Boolean {
        var lastStep = ""
        var sameStepCount = 0
        repeat(120) { attempt ->
            Thread.sleep(15_000)
            if (cancelFlag.get()) return false

            val elapsed    = (attempt + 1) * 15
            val elapsedStr = if (elapsed >= 60) "${elapsed / 60}m ${elapsed % 60}s" else "${elapsed}s"

            val liveBody = workerGet("/job-live?run_id=$runId")
            var gotLive  = false
            if (liveBody != null) {
                try {
                    val liveJson    = JSONObject(liveBody)
                    val currentStep = liveJson.optString("current_step", "")
                    val done        = liveJson.optInt("completed_count", 0)
                    val total       = liveJson.optInt("total_steps", 0)
                    if (currentStep.isNotEmpty()) {
                        gotLive = true
                        if (currentStep != lastStep) {
                            sameStepCount = 0
                            val progress = if (total > 0) " ($done/$total)" else ""
                            val friendly = friendlyStepName(currentStep)
                            log("⚙ $friendly$progress")
                            updateStep(friendly)
                            lastStep = currentStep
                        } else {
                            sameStepCount++
                            if (sameStepCount % 2 == 0) {
                                val friendly = friendlyStepName(currentStep)
                                log("   ⏳ $friendly — $elapsedStr")
                                updateStep("$friendly ($elapsedStr)")
                            }
                        }
                    }
                } catch (_: Exception) {}
            }

            if (!gotLive) log("   ⏳ waiting... $elapsedStr")

            val statusBody = workerGet("/status?run_id=$runId") ?: return@repeat
            val json       = JSONObject(statusBody)
            val status     = json.optString("status")
            val conclusion = json.optString("conclusion")

            if (status == "completed") {
                if (conclusion != "success") {
                    log("── Processing engine error ──")
                    try {
                        val errorDetail = workerGet("/job-error?run_id=$runId")
                        if (!errorDetail.isNullOrBlank()) {
                            errorDetail.lines().map { it.trim() }.filter { it.isNotEmpty() }
                                .takeLast(12).forEach { log(it) }
                        }
                    } catch (_: Exception) {}
                }
                return conclusion == "success"
            }
        }
        log("Timed out waiting for patch engine.")
        return false
    }

    private fun friendlyStepName(step: String): String = when {
        step.contains("Set up Java", true)                                       -> "Preparing Java environment..."
        step.contains("Download", true) && step.contains("APK", true)           -> "Downloading APK from storage..."
        step.contains("APKTool", true) || step.contains("baksmali", true)       -> "Downloading patch tools..."
        step.contains("Decompil", true)                                          -> "Decompiling APK..."
        step.contains("Anti-Dialog", true) && step.contains("DEX", true)        -> "Fetching Anti-Killer DEX..."
        step.contains("injection", true) || step.contains("Inject", true)       -> "Injecting hooks..."
        step.contains("Recompil", true) || step.contains("multi-strategy", true) -> "Recompiling patched APK..."
        step.contains("Sign APK", true) && step.contains("intermediate", true)  -> "Signing APK (step 1)..."
        step.contains("integrity", true) || step.contains("hash", true)         -> "Computing integrity hashes..."
        step.contains("Sign APK", true) && step.contains("final", true)         -> "Signing APK (final)..."
        step.contains("Rename", true)                                            -> "Finalizing APK..."
        step.contains("Delete", true) && step.contains("asset", true)           -> "Cleaning up..."
        step.contains("Upload", true) && step.contains("artifact", true)        -> "Uploading result..."
        step.contains("Queued", true)                                            -> "Waiting for cluster node..."
        step.contains("Set up job", true)                                        -> "Preparing environment..."
        step.contains("Complete job", true)                                      -> "Finalizing..."
        else -> step
    }

    private fun workerPost(path: String): String? {
        val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"; connectTimeout = 15_000; readTimeout = 30_000; doOutput = true
        }
        val code = conn.responseCode
        val body = try { conn.inputStream.bufferedReader().readText() } catch (_: Exception) { null }
        conn.disconnect()
        return if (code in 200..299) body else null
    }

    private fun workerGet(path: String): String? {
        val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000; readTimeout = 30_000
        }
        val code = conn.responseCode
        val body = try { conn.inputStream.bufferedReader().readText() } catch (_: Exception) { null }
        conn.disconnect()
        return if (code in 200..299) body else null
    }

    private fun workerGetWithCode(path: String): Pair<Int, String?> {
        return try {
            val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000; readTimeout = 30_000
            }
            val code = conn.responseCode
            val body = try {
                if (code in 200..299) conn.inputStream.bufferedReader().readText()
                else conn.errorStream?.bufferedReader()?.readText()
                    ?: conn.inputStream.bufferedReader().readText()
            } catch (_: Exception) { null }
            conn.disconnect()
            Pair(code, body)
        } catch (e: Exception) {
            Pair(-1, e.message)
        }
    }

    private fun workerDelete(path: String) {
        try {
            val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
                requestMethod = "DELETE"; connectTimeout = 10_000; readTimeout = 15_000
            }
            conn.responseCode
            conn.disconnect()
        } catch (_: Exception) {}
    }

    private fun uploadDirectToGitHub(
        baseUrl: String, assetName: String, auth: String, file: File
    ): Long {
        val total     = file.length()
        val uploadUrl = "$baseUrl?name=${java.net.URLEncoder.encode(assetName, "UTF-8")}"
        val conn = (URL(uploadUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("Authorization", auth)
            setRequestProperty("Content-Type", "application/zip")
            setRequestProperty("Content-Length", total.toString())
            setRequestProperty("Accept", "application/vnd.github.v3+json")
            setRequestProperty("User-Agent", "TaurusShield-Android/1.0")
            connectTimeout = 30_000
            readTimeout    = 600_000
            doOutput       = true
            setFixedLengthStreamingMode(total)
        }
        var sent = 0L; var lastPct = -1
        val buf  = ByteArray(65_536)
        file.inputStream().use { inp ->
            conn.outputStream.use { out ->
                var n: Int
                while (inp.read(buf).also { n = it } != -1) {
                    out.write(buf, 0, n); sent += n
                    val pct = ((sent * 99) / total).toInt()
                    if (pct != lastPct) {
                        lastPct = pct
                        LogBridge.push("DOWNLOAD_PROGRESS:$pct")
                        if (pct % 10 == 0) updateStep("Uploading... $pct%")
                    }
                }
            }
        }
        LogBridge.push("DOWNLOAD_PROGRESS:100")
        val code = conn.responseCode
        val body = if (code in 200..299) {
            try { conn.inputStream.bufferedReader().readText() } catch (_: Exception) { null }
        } else {
            val err = try { conn.errorStream?.bufferedReader()?.readText() } catch (_: Exception) { null }
            log("GitHub upload error HTTP $code: $err")
            null
        }
        conn.disconnect()
        return if (body != null) JSONObject(body).optLong("id") else 0L
    }

    private fun workerDownloadToFile(path: String, outFile: File): Boolean {
        val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000; readTimeout = 180_000
        }
        if (conn.responseCode !in 200..299) { conn.disconnect(); return false }
        val total  = conn.contentLengthLong.takeIf { it > 0 } ?: 1L
        var done   = 0L; var lastPct = -1
        val buf    = ByteArray(32_768)
        conn.inputStream.use { inp ->
            FileOutputStream(outFile).use { out ->
                var n: Int
                while (inp.read(buf).also { n = it } != -1) {
                    out.write(buf, 0, n); done += n
                    val pct = ((done * 100) / total).toInt().coerceIn(0, 100)
                    if (pct != lastPct) {
                        lastPct = pct
                        LogBridge.push("DOWNLOAD_PROGRESS:$pct")
                        if (pct % 10 == 0) updateStep("Downloading... $pct%")
                    }
                }
            }
        }
        conn.disconnect()
        return outFile.exists() && outFile.length() > 0
    }

    private fun releaseWake() {
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
    }
}
