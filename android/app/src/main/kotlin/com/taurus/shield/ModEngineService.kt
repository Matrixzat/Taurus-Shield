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

class ModEngineService : Service() {

    companion object {
        const val PREFS       = "mod_engine_svc"
        const val KEY_RUNNING = "running"
        const val KEY_PHASE   = "phase"
        const val KEY_LOGS    = "logs"
        const val KEY_STATUS  = "result_status"
        const val KEY_RESULT  = "result"
        const val KEY_JOB_ID  = "job_id"

        const val ACTION_DUMP  = "com.taurus.shield.MOD_ENGINE_DUMP"
        const val ACTION_BUILD = "com.taurus.shield.MOD_ENGINE_BUILD"
        const val ACTION_STOP  = "com.taurus.shield.MOD_ENGINE_STOP"

        const val EXTRA_APK_PATH      = "apk_path"
        const val EXTRA_GAME_NAME     = "game_name"
        const val EXTRA_FEATURES_JSON = "features_json"

        private const val NOTIF_ID = 4001
        private const val DUMP_WORKFLOW  = "game-dump.yml"
        private const val MOD_WORKFLOW   = "mod-build.yml"

        fun prefs(ctx: Context): SharedPreferences =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    // Worker URL is stored in NativeSecrets — same as every other cloud service.
    private val WORKER by lazy { NativeSecrets.workerUrl() }

    private val executor  = Executors.newSingleThreadExecutor()
    private val isRunning = AtomicBoolean(false)
    private lateinit var prefs: SharedPreferences
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ModEngine::Lock")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        when (intent?.action) {
            ACTION_DUMP  -> handleDump(intent)
            ACTION_BUILD -> handleBuild(intent)
            ACTION_STOP  -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startForegroundCompat() {
        val notif = NotificationHelper.buildSilentNotification(
            this, "Mod Engine", "Processing…", NOTIF_ID)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    // ── DUMP ──────────────────────────────────────────────────────────────────
    private fun handleDump(intent: Intent) {
        val apkPath = intent.getStringExtra(EXTRA_APK_PATH) ?: return
        prefs.edit()
            .putBoolean(KEY_RUNNING, true)
            .putString(KEY_PHASE, "uploading")
            .putString(KEY_JOB_ID, "")
            .putString(KEY_LOGS, "")
            .putString(KEY_STATUS, "running")
            .apply()

        executor.execute {
            wakeLock?.acquire(30 * 60 * 1000L)
            try {
                log("Starting game dump…")
                updatePhase("uploading")

                // 1. Upload APK via worker (no GitHub URL in app)
                log("Uploading game APK to cloud…")
                val uploadBody = workerPost("/game-dump", File(apkPath))
                    ?: throw RuntimeException("Upload failed — check network")

                val uploadJson = JSONObject(uploadBody)
                val jobId      = uploadJson.getString("job_id")
                val assetId    = uploadJson.getLong("asset_id")
                val triggeredAt = uploadJson.optLong("triggered_at", System.currentTimeMillis())

                prefs.edit().putString(KEY_JOB_ID, jobId).apply()
                log("Uploaded — job=$jobId  triggering workflow…")
                updatePhase("dispatching")

                // 2. Wait for workflow to appear, then poll progress
                Thread.sleep(12_000L)
                log("Finding workflow run…")
                updatePhase("finding_run")
                val runId = findRun(triggeredAt, DUMP_WORKFLOW)
                    ?: throw RuntimeException("Workflow run not found after waiting")

                log("Workflow started (run=$runId) — analysing IL2CPP symbols…")
                updatePhase("analysing")
                pollUntilDone(runId)

                // 3. Download result (offsets.json) via worker
                log("Downloading dump results…")
                updatePhase("downloading")
                val outFile = File(getExternalFilesDir(null), "dump_${jobId}.json")
                val ok = workerDownloadToFile("/dump-result?job_id=$jobId", outFile)
                if (!ok) throw RuntimeException("Result not ready — workflow may have failed")

                log("Saved → ${outFile.absolutePath}")
                prefs.edit()
                    .putBoolean(KEY_RUNNING, false)
                    .putString(KEY_PHASE, "done")
                    .putString(KEY_STATUS, "success")
                    .putString(KEY_RESULT, outFile.absolutePath)
                    .apply()
                NotificationHelper.showResult(this,
                    "Game Dump Complete", "Tap to select features to mod", NOTIF_ID)

            } catch (e: Exception) {
                log("ERROR: ${e.message}")
                prefs.edit()
                    .putBoolean(KEY_RUNNING, false)
                    .putString(KEY_PHASE, "error")
                    .putString(KEY_STATUS, "error:${e.message}")
                    .apply()
            } finally {
                wakeLock?.release()
                stopSelf()
            }
        }
    }

    // ── BUILD ─────────────────────────────────────────────────────────────────
    private fun handleBuild(intent: Intent) {
        val apkPath      = intent.getStringExtra(EXTRA_APK_PATH)      ?: return
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
            wakeLock?.acquire(60 * 60 * 1000L)
            try {
                log("Starting mod build for '$gameName'…")
                updatePhase("uploading")

                // 1. Upload APK
                log("Uploading game APK…")
                val uploadBody = workerPost("/upload-asset?ext=apk", File(apkPath))
                    ?: throw RuntimeException("APK upload failed — check network")

                val uploadJson = JSONObject(uploadBody)
                val jobId   = uploadJson.getString("job_id")
                val assetId = uploadJson.getLong("asset_id")

                prefs.edit().putString(KEY_JOB_ID, jobId).apply()
                log("APK uploaded — job=$jobId")

                // 2. Dispatch mod-build workflow (features JSON in POST body)
                updatePhase("dispatching")
                log("Dispatching mod-build workflow…")
                val triggerAt = System.currentTimeMillis()
                val safeGame  = gameName.replace(" ", "_")
                val dispatchBody = workerPostJson(
                    "/dispatch-mod-build?asset_id=$assetId&job_id=$jobId&game_name=$safeGame",
                    featuresJson
                )
                if (dispatchBody == null) {
                    throw RuntimeException("Workflow dispatch failed")
                }
                log("Workflow dispatched — waiting for run to start…")

                // 3. Find run
                Thread.sleep(12_000L)
                updatePhase("finding_run")
                val runId = findRun(triggerAt, MOD_WORKFLOW)
                    ?: throw RuntimeException("Workflow run not found after waiting")

                log("Build started (run=$runId) — this takes ~30–45 min…")
                updatePhase("building")
                pollUntilDone(runId, maxPolls = 150)

                // 4. Download modded APK
                updatePhase("downloading")
                log("Downloading modded APK…")
                val outFile = File(getExternalFilesDir(null), "${safeGame}_modded_${jobId}.apk")
                val ok = workerDownloadToFile("/mod-result?job_id=$jobId", outFile)
                if (!ok) throw RuntimeException("Modded APK not ready — workflow may have failed")

                log("Saved → ${outFile.absolutePath}")
                prefs.edit()
                    .putBoolean(KEY_RUNNING, false)
                    .putString(KEY_PHASE, "done")
                    .putString(KEY_STATUS, "success")
                    .putString(KEY_RESULT, outFile.absolutePath)
                    .apply()
                NotificationHelper.showResult(this,
                    "Mod APK Ready!", "Tap to install $gameName modded APK", NOTIF_ID)

            } catch (e: Exception) {
                log("ERROR: ${e.message}")
                prefs.edit()
                    .putBoolean(KEY_RUNNING, false)
                    .putString(KEY_PHASE, "error")
                    .putString(KEY_STATUS, "error:${e.message}")
                    .apply()
            } finally {
                wakeLock?.release()
                stopSelf()
            }
        }
    }

    // ── Polling helpers (same pattern as AdsPatchService) ─────────────────────

    private fun findRun(afterMs: Long, workflow: String): Long? {
        repeat(20) { attempt ->
            Thread.sleep(6_000)
            val body = workerGet("/find-run?after=$afterMs&workflow=$workflow") ?: run {
                log("Waiting for run… (${(attempt + 1) * 6}s)")
                return@repeat
            }
            val json = JSONObject(body)
            if (json.optBoolean("found")) {
                val runId = json.getLong("run_id")
                log("Run found #${json.optInt("run_number")} (id=$runId)")
                return runId
            }
            log("Waiting for run… (${(attempt + 1) * 6}s)")
        }
        return null
    }

    private fun pollUntilDone(runId: Long, maxPolls: Int = 120): Boolean {
        var lastStep = ""
        var sameCount = 0

        repeat(maxPolls) { i ->
            Thread.sleep(15_000)

            val liveBody = workerGet("/job-live?run_id=$runId")
            if (liveBody != null) {
                try {
                    val lj   = JSONObject(liveBody)
                    val step = lj.optString("current_step", "")
                    val done = lj.optInt("completed_count", 0)
                    val tot  = lj.optInt("total_steps", 0)
                    if (step.isNotEmpty() && step != lastStep) {
                        val pct = if (tot > 0) " ($done/$tot)" else ""
                        log("⚙ $step$pct")
                        updatePhase(step)
                        lastStep = step
                        sameCount = 0
                    } else {
                        sameCount++
                        if (sameCount % 4 == 0) log("   ⏳ $lastStep — ${(i + 1) * 15}s elapsed")
                    }
                } catch (_: Exception) {}
            }

            val statusBody = workerGet("/status?run_id=$runId") ?: return@repeat
            val sj = JSONObject(statusBody)
            val status     = sj.optString("status", "")
            val conclusion = sj.optString("conclusion", "")

            if (status == "completed") {
                return conclusion == "success"
            }
        }
        return false
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

    /** POST a binary file (APK). Returns JSON response body on success. */
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

    /** POST a JSON string body (features_json dispatch). */
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

    /** Download worker response to a file. Returns true on success. */
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
        if (wakeLock?.isHeld == true) wakeLock?.release()
    }
}
