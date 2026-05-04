package com.taurus.shield

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.os.PowerManager
import com.chaquo.python.Python
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class CocosService : Service() {

    companion object {
        const val PREFS        = "cocos_svc"
        const val KEY_RUNNING  = "running"
        const val KEY_PHASE    = "phase"
        const val KEY_LOGS     = "logs"
        const val KEY_STATUS   = "result_status"
        const val KEY_RESULT   = "result"
        const val KEY_PROGRESS = "progress"
        const val KEY_GAME_TYPE = "game_type"

        const val ACTION_ANALYSE      = "com.taurus.shield.COCOS_ANALYSE"
        const val ACTION_PATCH_NATIVE = "com.taurus.shield.COCOS_PATCH_NATIVE"
        const val ACTION_PATCH_SCRIPT = "com.taurus.shield.COCOS_PATCH_SCRIPT"
        const val ACTION_STOP         = "com.taurus.shield.COCOS_STOP"

        const val EXTRA_APK_PATH      = "apk_path"
        const val EXTRA_GAME_NAME     = "game_name"
        const val EXTRA_FEATURES_JSON = "features_json"
        const val EXTRA_PATCHES_JSON  = "patches_json"

        private const val NOTIF_ID = 5001

        private val cancelFlag   = AtomicBoolean(false)
        private var workerThread: Thread? = null

        fun cancel(ctx: Context) {
            cancelFlag.set(true)
            workerThread?.interrupt()
            ctx.startService(Intent(ctx, CocosService::class.java).apply {
                action = ACTION_STOP
            })
        }

        fun clearState(ctx: Context) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        }

        fun getState(ctx: Context): Map<String, Any?> {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return mapOf(
                "running"      to p.getBoolean(KEY_RUNNING, false),
                "phase"        to (p.getString(KEY_PHASE, "") ?: ""),
                "logs"         to (p.getString(KEY_LOGS, "") ?: ""),
                "result_status" to (p.getString(KEY_STATUS, "") ?: ""),
                "result"       to (p.getString(KEY_RESULT, "") ?: ""),
                "progress"     to p.getInt(KEY_PROGRESS, -1),
                "game_type"    to (p.getString(KEY_GAME_TYPE, "") ?: ""),
            )
        }
    }

    private lateinit var prefs:    SharedPreferences
    private val executor  = Executors.newSingleThreadExecutor()
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createChannels(this)
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: return START_NOT_STICKY

        if (action == ACTION_STOP) {
            cancelFlag.set(true)
            workerThread?.interrupt()
            stopForeground(true)
            stopSelf()
            return START_NOT_STICKY
        }

        cancelFlag.set(false)
        acquireWake()
        startForeground(NOTIF_ID, NotificationHelper.buildProcessingNotif(this,
            "Cocos Analyser", "Working…"), foregroundType())

        when (action) {
            ACTION_ANALYSE      -> handleAnalyse(intent)
            ACTION_PATCH_NATIVE -> handlePatchNative(intent)
            ACTION_PATCH_SCRIPT -> handlePatchScript(intent)
        }
        return START_NOT_STICKY
    }

    // ── ANALYSE — on-device Python ────────────────────────────────────────────
    private fun handleAnalyse(intent: Intent) {
        val apkPath  = intent.getStringExtra(EXTRA_APK_PATH)  ?: run { bail(); return }
        val gameName = intent.getStringExtra(EXTRA_GAME_NAME) ?: "game"

        prefs.edit()
            .putBoolean(KEY_RUNNING,  true)
            .putString(KEY_PHASE,    "analysing")
            .putString(KEY_LOGS,     "")
            .putString(KEY_STATUS,   "running")
            .putInt(KEY_PROGRESS,    -1)
            .apply()

        executor.execute {
            workerThread = Thread.currentThread()
            try {
                val outDir = File(
                    Environment.getExternalStorageDirectory(),
                    "Taurus-Shield/output/cocos/${gameName.replace(" ", "_")}"
                ).also { it.mkdirs() }

                log("Taurus Cocos Analyser — $gameName")
                log("APK: ${File(apkPath).name}")
                updatePhase("analysing")

                val py     = Python.getInstance()
                val bridge = py.getModule("cocos_analyzer")
                val fn     = bridge["analyse"]
                    ?: run { finishError("Python bridge not found"); return@execute }

                val jsonStr = fn.call(apkPath, outDir.absolutePath).toString()

                // Parse result
                val json = JSONObject(jsonStr)
                val err  = json.optString("error", "")
                if (err.isNotEmpty() && err != "null") {
                    // Append any Python logs before error
                    val pyLogs = json.optString("logs", "")
                    if (pyLogs.isNotEmpty()) appendLogs(pyLogs)
                    finishError(err)
                    return@execute
                }

                val pyLogs   = json.optString("logs", "")
                if (pyLogs.isNotEmpty()) appendLogs(pyLogs)

                val gameType = json.optString("game_type", "native")

                // Save full analysis JSON to disk for patch phase
                val analysisFile = File(outDir, "cocos_analysis.json")
                analysisFile.writeText(jsonStr)

                prefs.edit().putString(KEY_GAME_TYPE, gameType).apply()

                log("Analysis complete — type: ${gameType.uppercase()}")
                finishSuccess(analysisFile.absolutePath)
                NotificationHelper.showResult(this, true,
                    "Cocos analysis done", "Game type: ${gameType.uppercase()}")

            } catch (e: Exception) {
                if (cancelFlag.get() || e is InterruptedException) finishCancelled()
                else { log("Error: ${e.message}"); finishError(e.message ?: "Unknown error") }
            } finally {
                releaseWake(); stopForeground(true); stopSelf()
            }
        }
    }

    // ── PATCH NATIVE — on-device ARM64 binary patching ────────────────────────
    private fun handlePatchNative(intent: Intent) {
        val apkPath      = intent.getStringExtra(EXTRA_APK_PATH)      ?: run { bail(); return }
        val gameName     = intent.getStringExtra(EXTRA_GAME_NAME)      ?: "game"
        val featuresJson = intent.getStringExtra(EXTRA_FEATURES_JSON)  ?: "[]"

        prefs.edit()
            .putBoolean(KEY_RUNNING, true)
            .putString(KEY_PHASE,   "extracting")
            .putString(KEY_LOGS,    "")
            .putString(KEY_STATUS,  "running")
            .putInt(KEY_PROGRESS,   -1)
            .apply()

        executor.execute {
            workerThread = Thread.currentThread()
            try {
                val safeGame = gameName.replace(" ", "_")
                log("On-device ARM64 patch — $gameName")
                updatePhase("extracting")

                val outDir = File(
                    Environment.getExternalStorageDirectory(),
                    "Taurus-Shield/output/cocos/$safeGame"
                ).also { it.mkdirs() }

                // 1. Extract libcocos2dcpp.so
                val outFile = File(outDir, "${safeGame}_libcocos2dcpp_patched.so")
                var soSize  = 0L

                ZipFile(apkPath).use { zip ->
                    val entries  = zip.entries().toList()
                    val soEntry  = entries.firstOrNull { it.name.contains("arm64-v8a/libcocos2dcpp.so") }
                        ?: entries.firstOrNull { it.name.contains("armeabi-v7a/libcocos2dcpp.so") }
                        ?: entries.firstOrNull { it.name.contains("libcocos2dcpp.so") }
                        ?: throw RuntimeException("libcocos2dcpp.so not found in APK")

                    log("Found ${soEntry.name.substringAfterLast('/')}")
                    updateProgress(0)
                    zip.getInputStream(soEntry).use { inp ->
                        FileOutputStream(outFile).use { out ->
                            val buf = ByteArray(65_536)
                            var n: Int; var wrote = 0L
                            val knownSize = soEntry.size.takeIf { it > 0 }
                            while (inp.read(buf).also { n = it } != -1) {
                                out.write(buf, 0, n); wrote += n
                                if (knownSize != null)
                                    updateProgress(((wrote * 50L) / knownSize).toInt().coerceIn(0, 50))
                            }
                        }
                    }
                }
                soSize = outFile.length()
                if (soSize == 0L) throw RuntimeException("Extracted .so is empty")
                log("Extracted ${"%.1f".format(soSize / 1_048_576.0)} MB — applying patches…")
                updatePhase("patching")

                // 2. Apply ARM64 patches
                val features = JSONArray(featuresJson)
                val count    = features.length()
                var applied  = 0; var skipped = 0

                RandomAccessFile(outFile, "rw").use { raf ->
                    for (i in 0 until count) {
                        if (cancelFlag.get()) break
                        val feat      = features.getJSONObject(i)
                        val offsetStr = feat.optString("file_offset", "")
                        val type      = feat.optString("type", "bool")
                        val value     = feat.opt("value")
                        val label     = feat.optString("name", "?")

                        val fileOff = offsetStr.removePrefix("0x").toLongOrNull(16)
                        if (fileOff == null || fileOff < 0L || fileOff >= soSize) {
                            log("  ⚠ Skip $label — offset out of range"); skipped++; continue
                        }
                        if (fileOff % 4L != 0L) {
                            log("  ⚠ Skip $label — not 4-byte aligned"); skipped++; continue
                        }

                        val patchValue: Any? = if (type == "branch_always") {
                            val buf4 = ByteArray(4)
                            raf.seek(fileOff); raf.readFully(buf4)
                            (buf4[0].toInt() and 0xFF) or
                                ((buf4[1].toInt() and 0xFF) shl 8) or
                                ((buf4[2].toInt() and 0xFF) shl 16) or
                                ((buf4[3].toInt() and 0xFF) shl 24)
                        } else value

                        val patch = buildArm64Patch(type, patchValue)
                        if (patch == null) {
                            log("  ⚠ Skip $label — unsupported type '$type'"); skipped++; continue
                        }
                        if (fileOff + patch.size > soSize) {
                            log("  ⚠ Skip $label — patch exceeds file"); skipped++; continue
                        }
                        raf.seek(fileOff); raf.write(patch)
                        applied++
                        updateProgress(50 + ((applied.toLong() * 50L) / count.toLong().coerceAtLeast(1L)).toInt().coerceIn(0, 50))
                        log("  ✓ $label @ $offsetStr")
                    }
                }

                updateProgress(100)
                log("Done — $applied patched${if (skipped > 0) ", $skipped skipped" else ""} ✓")
                log("Saved → Taurus-Shield/output/cocos/$safeGame/")
                log("Open APK in MT Manager → replace lib/arm64-v8a/libcocos2dcpp.so → sign → install")
                finishSuccess(outFile.absolutePath)
                NotificationHelper.showResult(this, true,
                    "Patched! $applied offset(s) applied",
                    "Replace libcocos2dcpp.so in APK via MT Manager")

            } catch (e: Exception) {
                if (cancelFlag.get() || e is InterruptedException) finishCancelled()
                else { log("Error: ${e.message}"); finishError(e.message ?: "Unknown error") }
            } finally {
                releaseWake(); stopForeground(true); stopSelf()
            }
        }
    }

    // ── PATCH SCRIPT — Lua/JS re-encrypt via Python ───────────────────────────
    private fun handlePatchScript(intent: Intent) {
        val apkPath     = intent.getStringExtra(EXTRA_APK_PATH)     ?: run { bail(); return }
        val gameName    = intent.getStringExtra(EXTRA_GAME_NAME)    ?: "game"
        val patchesJson = intent.getStringExtra(EXTRA_PATCHES_JSON) ?: "[]"

        prefs.edit()
            .putBoolean(KEY_RUNNING, true)
            .putString(KEY_PHASE,   "patching")
            .putString(KEY_LOGS,    "")
            .putString(KEY_STATUS,  "running")
            .putInt(KEY_PROGRESS,   -1)
            .apply()

        executor.execute {
            workerThread = Thread.currentThread()
            try {
                val safeGame = gameName.replace(" ", "_")
                log("Patching scripts — $gameName")

                val outDir = File(
                    Environment.getExternalStorageDirectory(),
                    "Taurus-Shield/output/cocos/$safeGame"
                ).also { it.mkdirs() }

                val py     = Python.getInstance()
                val bridge = py.getModule("cocos_analyzer")
                val fn     = bridge["patch_scripts"]
                    ?: run { finishError("Python bridge not found"); return@execute }

                val jsonStr  = fn.call(apkPath, outDir.absolutePath, patchesJson).toString()
                val json     = JSONObject(jsonStr)
                val pyLogs   = json.optString("logs", "")
                if (pyLogs.isNotEmpty()) appendLogs(pyLogs)

                val err = json.optString("error", "")
                if (err.isNotEmpty() && err != "null") {
                    finishError(err); return@execute
                }

                val outPath = json.optString("output_path", "")
                log("Patched APK saved — sign with MT Manager then install")
                finishSuccess(outPath)
                NotificationHelper.showResult(this, true,
                    "Scripts patched", "Sign APK with MT Manager then install")

            } catch (e: Exception) {
                if (cancelFlag.get() || e is InterruptedException) finishCancelled()
                else { log("Error: ${e.message}"); finishError(e.message ?: "Unknown error") }
            } finally {
                releaseWake(); stopForeground(true); stopSelf()
            }
        }
    }

    // ── ARM64 patch builder (same as ModEngineService) ─────────────────────────
    private fun buildArm64Patch(type: String, value: Any?): ByteArray? {
        val RET = byteArrayOf(0xC0.toByte(), 0x03, 0x5F.toByte(), 0xD6.toByte())
        fun i32le(v: Int) = byteArrayOf(
            (v and 0xFF).toByte(), ((v ushr 8) and 0xFF).toByte(),
            ((v ushr 16) and 0xFF).toByte(), ((v ushr 24) and 0xFF).toByte())
        fun movzW0(i: Int) = i32le(0x52800000 or ((i and 0xFFFF) shl 5))
        fun movkW0Hi(i: Int) = i32le(0x72A00000 or ((i and 0xFFFF) shl 5))
        val fmovS0W0 = i32le(0x1E270000)

        fun intPatch(v: Long): ByteArray {
            val lo = (v and 0xFFFFL).toInt(); val hi = ((v ushr 16) and 0xFFFFL).toInt()
            return if (hi == 0) movzW0(lo) + RET else movzW0(lo) + movkW0Hi(hi) + RET
        }

        return when (type) {
            "void"  -> RET
            "bool"  -> {
                val v = when (value) {
                    is Boolean -> if (value) 1L else 0L
                    is Number  -> value.toLong()
                    is String  -> if (value == "true" || value == "1") 1L else 0L
                    else       -> 1L
                }
                intPatch(v.coerceIn(0L, 1L))
            }
            "int", "long" -> {
                val v = when (value) {
                    is Number -> value.toLong()
                    is String -> value.toLongOrNull() ?: 1L
                    else      -> 1L
                }
                intPatch(v and 0xFFFFFFFFL)
            }
            "float" -> {
                val fv = when (value) {
                    is Number -> value.toFloat()
                    is String -> value.toFloatOrNull() ?: 1.0f
                    else      -> 1.0f
                }
                val bits = java.lang.Float.floatToRawIntBits(fv).toLong() and 0xFFFFFFFFL
                val lo = (bits and 0xFFFFL).toInt(); val hi = ((bits ushr 16) and 0xFFFFL).toInt()
                if (hi == 0) movzW0(lo) + fmovS0W0 + RET
                else movzW0(lo) + movkW0Hi(hi) + fmovS0W0 + RET
            }
            "nop" -> {
                val count = when (value) {
                    is Number -> value.toInt().coerceIn(1, 64)
                    is String -> value.toIntOrNull()?.coerceIn(1, 64) ?: 1
                    else      -> 1
                }
                val nop = i32le(0xD503201F.toInt())
                (1..count).fold(byteArrayOf()) { acc, _ -> acc + nop }
            }
            "branch_never"  -> i32le(0xD503201F.toInt())
            "branch_always" -> {
                val existing = when (value) { is Number -> value.toInt(); else -> return null }
                val unconditional = convertToUnconditionalBranch(existing) ?: return null
                i32le(unconditional)
            }
            else -> null
        }
    }

    private fun convertToUnconditionalBranch(insn: Int): Int? {
        if ((insn ushr 24) == 0x54 && (insn and 0x10) == 0) {
            val imm19 = (insn ushr 5) and 0x7FFFF
            val s = if (imm19 and 0x40000 != 0) (imm19 or -0x80000) else imm19
            return 0x14000000 or (s and 0x3FFFFFF)
        }
        val op8 = (insn ushr 24) and 0xFF
        if (op8 == 0x34 || op8 == 0x35 || op8 == 0xB4 || op8 == 0xB5) {
            val imm19 = (insn ushr 5) and 0x7FFFF
            val s = if (imm19 and 0x40000 != 0) (imm19 or -0x80000) else imm19
            return 0x14000000 or (s and 0x3FFFFFF)
        }
        if ((insn ushr 24) and 0x3F == 0x1B) {
            val imm14 = (insn ushr 5) and 0x3FFF
            val s = if (imm14 and 0x2000 != 0) (imm14 or -0x4000) else imm14
            return 0x14000000 or (s and 0x3FFFFFF)
        }
        if ((insn ushr 26) and 0x3F == 5) return insn
        return null
    }

    // ── Finish helpers ────────────────────────────────────────────────────────
    private fun finishSuccess(path: String) {
        prefs.edit().putBoolean(KEY_RUNNING, false)
            .putString(KEY_PHASE, "done")
            .putString(KEY_STATUS, "success")
            .putString(KEY_RESULT, path).apply()
    }

    private fun finishError(msg: String) {
        prefs.edit().putBoolean(KEY_RUNNING, false)
            .putString(KEY_PHASE, "error")
            .putString(KEY_STATUS, "error:$msg").apply()
    }

    private fun finishCancelled() {
        prefs.edit().putBoolean(KEY_RUNNING, false)
            .putString(KEY_PHASE, "cancelled")
            .putString(KEY_STATUS, "cancelled").apply()
    }

    private fun bail() { releaseWake(); stopForeground(true); stopSelf() }

    private fun acquireWake() {
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "taurus:cocos")
            .also { it.acquire(30 * 60_000L) }
    }

    private fun releaseWake() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
    }

    private fun log(msg: String) {
        val existing = prefs.getString(KEY_LOGS, "") ?: ""
        prefs.edit()
            .putString(KEY_LOGS, (if (existing.isEmpty()) msg else "$existing\n$msg").takeLast(8000))
            .apply()
    }

    private fun appendLogs(block: String) {
        block.split("\n").filter { it.isNotBlank() }.forEach { log(it) }
    }

    private fun updatePhase(p: String) = prefs.edit().putString(KEY_PHASE, p).apply()
    private fun updateProgress(pct: Int) = prefs.edit().putInt(KEY_PROGRESS, pct.coerceIn(-1, 100)).apply()

    @Suppress("DEPRECATION")
    private fun foregroundType() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
        releaseWake()
    }
}
