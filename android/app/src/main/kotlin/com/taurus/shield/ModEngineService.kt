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
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

class ModEngineService : Service() {

    companion object {
        const val PREFS       = "mod_engine_svc"
        const val KEY_RUNNING = "running"
        const val KEY_PHASE   = "phase"
        const val KEY_LOGS    = "logs"
        const val KEY_STATUS  = "result_status"
        const val KEY_RESULT  = "result"
        const val KEY_JOB_ID  = "job_id"
        const val KEY_RUN_ID  = "run_id"

        const val ACTION_DUMP  = "com.taurus.shield.MOD_ENGINE_DUMP"
        const val ACTION_BUILD = "com.taurus.shield.MOD_ENGINE_BUILD"
        const val ACTION_STOP  = "com.taurus.shield.MOD_ENGINE_STOP"

        const val EXTRA_APK_PATH      = "apk_path"
        const val EXTRA_GAME_NAME     = "game_name"
        const val EXTRA_FEATURES_JSON = "features_json"

        private const val NOTIF_ID = 4001
        private const val DUMP_WORKFLOW  = "game-dump.yml"
        private const val MOD_WORKFLOW   = "mod-build.yml"

        private val cancelFlag = AtomicBoolean(false)
        private var workerThread: Thread? = null

        fun isRunning(context: Context): Boolean =
            context.getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_RUNNING, false)

        fun cancel(context: Context) {
            cancelFlag.set(true)
            workerThread?.interrupt()
            // Tell the cloud engine to stop the run immediately
            val runId = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getLong(KEY_RUN_ID, 0L)
            if (runId > 0L) {
                Thread {
                    try {
                        val workerUrl = NativeSecrets.workerUrl()
                        val conn = (java.net.URL("$workerUrl/cancel-run?run_id=$runId")
                            .openConnection() as java.net.HttpURLConnection).apply {
                            requestMethod = "POST"
                            connectTimeout = 10_000
                            readTimeout    = 10_000
                            doOutput = false
                        }
                        conn.responseCode
                        conn.disconnect()
                    } catch (_: Exception) {}
                }.start()
            }
            context.stopService(Intent(context, ModEngineService::class.java))
        }

        fun prefs(ctx: Context): SharedPreferences =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    private val WORKER by lazy { NativeSecrets.workerUrl() }

    private val executor  = Executors.newSingleThreadExecutor()
    private lateinit var prefs: SharedPreferences
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Acquire wakelock immediately — before any async work
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TaurusShield::ModEngine")
        wakeLock?.acquire(90 * 60 * 1000L)

        NotificationHelper.createChannels(this)
        startForegroundCompat()

        cancelFlag.set(false)

        when (intent?.action) {
            ACTION_DUMP  -> handleDump(intent)
            ACTION_BUILD -> handleBuild(intent)
            ACTION_STOP  -> { releaseWake(); stopForeground(true); stopSelf() }
        }
        return START_NOT_STICKY
    }

    private fun startForegroundCompat() {
        val notif = NotificationHelper.buildProcessingNotif(
            this, "Mod Engine", "Processing…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    // ── DUMP ──────────────────────────────────────────────────────────────────
    private fun handleDump(intent: Intent) {
        val apkPath = intent.getStringExtra(EXTRA_APK_PATH) ?: run { bail(); return }
        prefs.edit()
            .putBoolean(KEY_RUNNING, true)
            .putString(KEY_PHASE, "uploading")
            .putString(KEY_JOB_ID, "")
            .putString(KEY_LOGS, "")
            .putString(KEY_STATUS, "running")
            .apply()

        executor.execute {
            workerThread = Thread.currentThread()
            try {
                log("Starting game analysis…")
                updatePhase("extracting")

                log("Extracting IL2CPP files from APK…")
                val slimZip = extractIl2cppZip(apkPath)
                    ?: throw RuntimeException("libil2cpp.so or global-metadata.dat not found — is this a Unity IL2CPP game?")
                val slimMb = "%.1f MB".format(slimZip.length() / 1_048_576.0)
                log("Extracted → slim package $slimMb (libil2cpp.so + metadata)")

                updatePhase("uploading")
                log("Uploading to secure cluster…")
                val uploadBody = workerPost("/game-dump", slimZip)
                    ?: throw RuntimeException("Upload failed — check network")
                slimZip.delete()

                val uploadJson  = JSONObject(uploadBody)
                val jobId       = uploadJson.getString("job_id")
                val triggeredAt = uploadJson.optLong("triggered_at", System.currentTimeMillis())

                prefs.edit().putString(KEY_JOB_ID, jobId).apply()
                log("Upload complete — queuing analysis…")
                updatePhase("dispatching")

                Thread.sleep(12_000L)
                log("Connecting to cloud engine…")
                updatePhase("finding_run")

                val runId = findRun(triggeredAt, DUMP_WORKFLOW)
                    ?: throw RuntimeException("Cloud engine not ready — check connection and try again")

                prefs.edit().putLong(KEY_RUN_ID, runId).apply()

                log("Engine ready — analysing IL2CPP symbols…")
                updatePhase("analysing")
                pollUntilDone(runId)

                log("Downloading analysis results…")
                updatePhase("downloading")
                val outFile = File(getExternalFilesDir(null), "dump_${jobId}.json")
                val ok = workerDownloadToFile("/dump-result?job_id=$jobId", outFile)
                if (!ok) throw RuntimeException("Result not ready — cloud job may have failed")

                log("Analysis complete ✓")
                finishSuccess(outFile.absolutePath)
                NotificationHelper.showResult(this,
                    true, "Game Analysis Complete", "Tap to select features to mod")

            } catch (e: Exception) {
                if (cancelFlag.get() || e is InterruptedException) {
                    finishCancelled()
                } else {
                    log("Error: ${e.message}")
                    finishError(e.message ?: "Unknown error")
                }
            } finally {
                releaseWake()
                stopForeground(true)
                stopSelf()
            }
        }
    }

    // ── BUILD ─────────────────────────────────────────────────────────────────
    private fun handleBuild(intent: Intent) {
        val apkPath      = intent.getStringExtra(EXTRA_APK_PATH)      ?: run { bail(); return }
        val gameName     = intent.getStringExtra(EXTRA_GAME_NAME)      ?: "game"
        val featuresJson = intent.getStringExtra(EXTRA_FEATURES_JSON)  ?: "[]"

        prefs.edit()
            .putBoolean(KEY_RUNNING, true)
            .putString(KEY_PHASE, "uploading")
            .putString(KEY_JOB_ID, "")
            .putString(KEY_LOGS, "")
            .putString(KEY_STATUS, "running")
            .apply()

        executor.execute {
            workerThread = Thread.currentThread()
            try {
                val safeGame = gameName.replace(" ", "_")
                log("Starting mod build for '$gameName'…")
                updatePhase("uploading")

                log("Uploading game APK to cluster…")
                val uploadBody = workerPost("/upload-asset?ext=apk", File(apkPath))
                    ?: throw RuntimeException("APK upload failed — check network")

                val uploadJson = JSONObject(uploadBody)
                val jobId   = uploadJson.getString("job_id")
                val assetId = uploadJson.getLong("asset_id")

                prefs.edit().putString(KEY_JOB_ID, jobId).apply()
                log("APK uploaded — preparing mod build…")

                updatePhase("dispatching")
                log("Dispatching to cloud build engine…")
                val triggerAt = System.currentTimeMillis()
                val dispatchBody = workerPostJson(
                    "/dispatch-mod-build?asset_id=$assetId&job_id=$jobId&game_name=$safeGame",
                    featuresJson
                ) ?: throw RuntimeException("Cloud build failed to start — check network")

                log("Build queued — waiting for engine to start…")

                Thread.sleep(12_000L)
                updatePhase("finding_run")

                val runId = findRun(triggerAt, MOD_WORKFLOW)
                    ?: throw RuntimeException("Cloud engine not ready — try again")

                prefs.edit().putLong(KEY_RUN_ID, runId).apply()

                log("Build started — patching binary, this takes ~30–45 min…")
                updatePhase("building")
                pollUntilDone(runId, maxActivePolls = 150)

                updatePhase("downloading")
                log("Downloading modded APK…")
                val outFile = File(getExternalFilesDir(null), "${safeGame}_modded_${jobId}.apk")
                val ok = workerDownloadToFile("/mod-result?job_id=$jobId", outFile)
                if (!ok) throw RuntimeException("Modded APK not ready — cloud build may have failed")

                log("Mod APK ready ✓")
                finishSuccess(outFile.absolutePath)
                NotificationHelper.showResult(this,
                    true, "Mod APK Ready!", "Tap to install $gameName modded APK")

            } catch (e: Exception) {
                if (cancelFlag.get() || e is InterruptedException) {
                    finishCancelled()
                } else {
                    log("Error: ${e.message}")
                    finishError(e.message ?: "Unknown error")
                }
            } finally {
                releaseWake()
                stopForeground(true)
                stopSelf()
            }
        }
    }

    // ── Finish helpers ────────────────────────────────────────────────────────

    private fun finishSuccess(resultPath: String) {
        prefs.edit()
            .putBoolean(KEY_RUNNING, false)
            .putString(KEY_PHASE, "done")
            .putString(KEY_STATUS, "success")
            .putString(KEY_RESULT, resultPath)
            .apply()
    }

    private fun finishError(msg: String) {
        prefs.edit()
            .putBoolean(KEY_RUNNING, false)
            .putString(KEY_PHASE, "error")
            .putString(KEY_STATUS, "error:$msg")
            .apply()
    }

    private fun finishCancelled() {
        prefs.edit()
            .putBoolean(KEY_RUNNING, false)
            .putString(KEY_PHASE, "cancelled")
            .putString(KEY_STATUS, "cancelled")
            .apply()
    }

    private fun bail() { releaseWake(); stopForeground(true); stopSelf() }

    private fun releaseWake() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
    }

    // ── Polling helpers ───────────────────────────────────────────────────────

    private fun findRun(afterMs: Long, workflow: String): Long? {
        repeat(20) { attempt ->
            Thread.sleep(6_000)
            if (cancelFlag.get()) return null
            val body = workerGet("/find-run?after=$afterMs&workflow=$workflow") ?: run {
                log("Waiting for engine node… (${(attempt + 1) * 6}s)")
                return@repeat
            }
            val json = JSONObject(body)
            if (json.optBoolean("found")) {
                log("Engine node ready")
                return json.getLong("run_id")
            }
            log("Waiting for engine node… (${(attempt + 1) * 6}s)")
        }
        return null
    }

    private fun pollUntilDone(runId: Long, maxActivePolls: Int = 120): Boolean {
        var lastStep = ""
        var sameCount = 0
        var activePolls = 0
        var consecutiveNetFails = 0

        while (activePolls < maxActivePolls) {
            Thread.sleep(15_000)
            if (cancelFlag.get()) return false

            val elapsed    = activePolls * 15
            val elapsedStr = if (elapsed >= 60) "${elapsed / 60}m ${elapsed % 60}s" else "${elapsed}s"

            val liveBody = workerGet("/job-live?run_id=$runId")
            var gotLive = false
            if (liveBody != null) {
                try {
                    val lj   = JSONObject(liveBody)
                    val step = lj.optString("current_step", "")
                    val done = lj.optInt("completed_count", 0)
                    val tot  = lj.optInt("total_steps", 0)
                    if (step.isNotEmpty()) {
                        gotLive = true
                        val friendly = friendlyStepName(step)
                        if (step != lastStep) {
                            val pct = if (tot > 0) " ($done/$tot)" else ""
                            log("⚙ $friendly$pct")
                            updatePhase(friendly)
                            lastStep = step
                            sameCount = 0
                        } else {
                            sameCount++
                            if (sameCount % 2 == 0) {
                                log("   ⏳ $friendly — $elapsedStr")
                                updatePhase("$friendly ($elapsedStr)")
                            }
                        }
                    }
                } catch (_: Exception) {}
            }

            val statusBody = workerGet("/status?run_id=$runId")
            if (statusBody == null) {
                consecutiveNetFails++
                if (!gotLive) {
                    log("   ⚠ Network unavailable — retrying… ($consecutiveNetFails)")
                    updatePhase("Waiting for network…")
                }
                continue  // don't count network failures as a poll
            }
            consecutiveNetFails = 0
            activePolls++

            if (!gotLive) log("   ⏳ building… $elapsedStr")

            val sj = JSONObject(statusBody)
            val status     = sj.optString("status", "")
            val conclusion = sj.optString("conclusion", "")

            if (status == "completed") {
                return conclusion == "success"
            }
        }
        log("Timed out waiting for cloud engine.")
        return false
    }

    private fun friendlyStepName(step: String): String = when {
        step.contains("Set up job",      ignoreCase = true) -> "Preparing environment…"
        step.contains("Download",        ignoreCase = true) -> "Downloading game file…"
        step.contains("Extract",         ignoreCase = true) -> "Extracting binaries…"
        step.contains("Install",         ignoreCase = true) -> "Installing build tools…"
        step.contains("dependencies",    ignoreCase = true) -> "Installing build tools…"
        step.contains("patch",           ignoreCase = true) -> "Patching binary…"
        step.contains("sign",            ignoreCase = true) -> "Signing APK…"
        step.contains("upload",          ignoreCase = true) -> "Packaging output…"
        step.contains("Complete job",    ignoreCase = true) -> "Finalising…"
        step.contains("Queued",          ignoreCase = true) -> "Waiting for build node…"
        step.contains("analysis",        ignoreCase = true) -> "Analysing symbols…"
        step.contains("dump",            ignoreCase = true) -> "Dumping IL2CPP metadata…"
        step.contains("extract",         ignoreCase = true) -> "Extracting binaries…"
        else -> step
    }

    // ── IL2CPP slim-zip extractor ─────────────────────────────────────────────
    // Reads the game APK, pulls out ONLY libil2cpp.so + global-metadata.dat,
    // writes them into a tiny zip at cacheDir — far smaller than the full APK.
    private fun extractIl2cppZip(apkPath: String): File? {
        return try {
            val outFile = File(cacheDir, "il2cpp_slim_${System.currentTimeMillis()}.zip")
            ZipFile(apkPath).use { apk ->
                val entries = apk.entries().toList()

                // Prefer arm64-v8a, fall back to armeabi-v7a
                val soEntry = entries.firstOrNull { it.name.contains("arm64-v8a/libil2cpp.so") }
                    ?: entries.firstOrNull { it.name.contains("libil2cpp.so") }

                val metaEntry = entries.firstOrNull { it.name.contains("global-metadata.dat") }

                if (soEntry == null || metaEntry == null) return null

                ZipOutputStream(FileOutputStream(outFile)).use { zos ->
                    // Write libil2cpp.so flat at root of zip
                    zos.putNextEntry(ZipEntry("libil2cpp.so"))
                    apk.getInputStream(soEntry).use { it.copyTo(zos) }
                    zos.closeEntry()

                    // Write global-metadata.dat flat at root of zip
                    zos.putNextEntry(ZipEntry("global-metadata.dat"))
                    apk.getInputStream(metaEntry).use { it.copyTo(zos) }
                    zos.closeEntry()
                }
            }
            if (outFile.exists() && outFile.length() > 0) outFile else null
        } catch (_: Exception) { null }
    }

    // ── HTTP helpers ──────────────────────────────────────────────────────────

    private fun workerGet(path: String): String? {
        return try {
            val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000; readTimeout = 30_000
            }
            val code = conn.responseCode
            val body = try { conn.inputStream.bufferedReader().readText() } catch (_: Exception) { null }
            conn.disconnect()
            if (code in 200..299) body else null
        } catch (_: Exception) { null }
    }

    private fun workerPost(path: String, file: File): String? {
        return try {
            val total = file.length()
            val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Content-Type", "application/octet-stream")
                setRequestProperty("Content-Length", total.toString())
                connectTimeout = 30_000; readTimeout = 600_000
                doOutput = true
                setFixedLengthStreamingMode(total)
            }
            val buf = ByteArray(65_536)
            file.inputStream().use { inp ->
                conn.outputStream.use { out ->
                    var n: Int
                    while (inp.read(buf).also { n = it } != -1) out.write(buf, 0, n)
                }
            }
            val code = conn.responseCode
            val body = try { conn.inputStream.bufferedReader().readText() } catch (_: Exception) { null }
            conn.disconnect()
            if (code in 200..299) body else null
        } catch (_: Exception) { null }
    }

    private fun workerPostJson(path: String, json: String): String? {
        return try {
            val bytes = json.toByteArray(Charsets.UTF_8)
            val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Content-Length", bytes.size.toString())
                connectTimeout = 15_000; readTimeout = 30_000
                doOutput = true
            }
            conn.outputStream.write(bytes)
            val code = conn.responseCode
            val body = try { conn.inputStream.bufferedReader().readText() } catch (_: Exception) { null }
            conn.disconnect()
            if (code in 200..299) body else null
        } catch (_: Exception) { null }
    }

    private fun workerDownloadToFile(path: String, outFile: File): Boolean {
        return try {
            val conn = (URL(WORKER + path).openConnection() as HttpURLConnection).apply {
                connectTimeout = 30_000; readTimeout = 180_000
            }
            if (conn.responseCode !in 200..299) { conn.disconnect(); return false }
            val buf = ByteArray(32_768)
            conn.inputStream.use { inp ->
                FileOutputStream(outFile).use { out ->
                    var n: Int
                    while (inp.read(buf).also { n = it } != -1) out.write(buf, 0, n)
                }
            }
            conn.disconnect()
            outFile.exists() && outFile.length() > 0
        } catch (_: Exception) { false }
    }

    // ── Logging ───────────────────────────────────────────────────────────────

    private fun log(msg: String) {
        val existing = prefs.getString(KEY_LOGS, "") ?: ""
        prefs.edit()
            .putString(KEY_LOGS, (if (existing.isEmpty()) msg else "$existing\n$msg").takeLast(8000))
            .apply()
    }

    private fun updatePhase(phase: String) {
        prefs.edit().putString(KEY_PHASE, phase).apply()
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
        releaseWake()
    }
}
