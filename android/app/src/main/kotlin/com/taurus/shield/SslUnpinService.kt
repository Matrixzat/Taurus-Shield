package com.taurus.shield

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import java.io.BufferedOutputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.Adler32
import java.util.zip.CRC32
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import org.jf.dexlib2.Opcode
import org.jf.dexlib2.Opcodes
import org.jf.dexlib2.dexbacked.DexBackedDexFile
import org.jf.dexlib2.dexbacked.DexBackedMethodImplementation
import org.jf.dexlib2.dexbacked.instruction.DexBackedInstruction
import org.jf.dexlib2.iface.Method
import org.jf.dexlib2.iface.instruction.ReferenceInstruction
import org.jf.dexlib2.iface.reference.FieldReference
import org.jf.dexlib2.iface.reference.MethodReference
import org.jf.dexlib2.iface.reference.TypeReference
import org.jf.dexlib2.iface.value.ArrayEncodedValue
import org.jf.dexlib2.iface.value.TypeEncodedValue
import com.reandroid.apk.ApkModule
import com.reandroid.archive.ByteInputSource
import com.reandroid.arsc.value.ValueType

class SslUnpinService : Service() {

    companion object {
        const val PREFS           = "ssl_unpin_svc"
        const val KEY_RUNNING     = "running"
        const val KEY_PHASE       = "phase"
        const val KEY_LOGS        = "logs"
        const val KEY_STATUS      = "result_status"
        const val KEY_OUTPUT_DIR  = "output_dir"
        const val KEY_OUTPUT_PATH = "output_path"
        const val KEY_ERROR       = "error"
        const val KEY_FILE_NAME   = "file_name"
        const val KEY_FILE_PATH   = "file_path"
        const val KEY_STEP        = "current_step"
        const val KEY_SIGN_APK    = "sign_apk"

        fun isRunning(context: Context): Boolean =
            context.getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_RUNNING, false)

        fun getState(context: Context): Map<String, Any?> {
            val p = context.getSharedPreferences(PREFS, MODE_PRIVATE)
            return mapOf(
                "running"     to p.getBoolean(KEY_RUNNING, false),
                "phase"       to (p.getString(KEY_PHASE, "") ?: ""),
                "logs"        to (p.getString(KEY_LOGS, "") ?: ""),
                "status"      to (p.getString(KEY_STATUS, "") ?: ""),
                "outputDir"   to (p.getString(KEY_OUTPUT_DIR, "") ?: ""),
                "outputPath"  to (p.getString(KEY_OUTPUT_PATH, "") ?: ""),
                "error"       to (p.getString(KEY_ERROR, "") ?: ""),
                "fileName"    to (p.getString(KEY_FILE_NAME, "") ?: ""),
                "filePath"    to (p.getString(KEY_FILE_PATH, "") ?: ""),
                "currentStep" to (p.getString(KEY_STEP, "") ?: ""),
            )
        }

        fun clearState(context: Context) {
            context.getSharedPreferences(PREFS, MODE_PRIVATE).edit().clear().apply()
        }

        private val cancelFlag  = AtomicBoolean(false)
        private var workerThread: Thread? = null

        fun cancel(context: Context) {
            cancelFlag.set(true)
            workerThread?.interrupt()
            context.stopService(Intent(context, SslUnpinService::class.java))
        }

        // ── DEX target methods ─────────────────────────────────────────────────
        // void methods → patched to return-void (opcode 0x0E)
        private val VOID_TARGETS = mapOf(
            // OkHttp3 certificate pinning
            "okhttp3/CertificatePinner"                       to setOf("check", "check\$okhttp", "check\$default"),
            "okhttp3/internal/connection/RealConnection"      to setOf("connectTls"),
            "okhttp3/internal/connection/ConnectPlan"         to setOf("connectTls"),
            "okhttp3/internal/tls/CertificateChainCleaner"   to setOf("clean"),
            // OkHttp2 / AOSP variants
            "com/android/okhttp/CertificatePinner"            to setOf("check"),
            "com/squareup/okhttp/CertificatePinner"           to setOf("check"),
            "com/android/okhttp/internal/http/OkHeaders"      to setOf("requiresCleanup"),
            // TrustKit
            "com/datatheorem/android/trustkit/pinning/PinningTrustManager"       to setOf("checkServerTrusted"),
            "com/datatheorem/android/trustkit/pinning/OkHttp3Helper"             to setOf("check"),
            "com/datatheorem/android/trustkit/reporting/BackgroundReporter"      to setOf("pinValidationFailed"),
            // Appcelerator / Titanium
            "org/appcelerator/titanium/util/TiPlatformHelper" to setOf("pinCertificate"),
            // Conscrypt / Android internal
            "com/android/org/conscrypt/CertPinManager"        to setOf("isChainValid"),
            "com/android/org/conscrypt/TrustManagerImpl"      to setOf("checkServerTrusted", "checkTrusted"),
            "sun/security/ssl/X509TrustManagerImpl"           to setOf("checkServerTrusted", "checkClientTrusted"),
            // Volley
            "com/android/volley/toolbox/HurlStack"            to setOf("createConnection"),
            // Firebase / Google Play Services
            "com/google/android/gms/common/security/ProviderInstallerImpl" to setOf("insertProvider"),
        )

        // boolean methods → patched to return true (const/4 v0, 1 + return v0)
        private val BOOL_TARGETS = mapOf(
            // OkHttp hostname verifiers
            "okhttp3/internal/tls/OkHostnameVerifier"             to setOf("verify", "verifyHostname"),
            "okhttp3/OkHostnameVerifier"                          to setOf("verify"),
            "com/android/okhttp/internal/tls/OkHostnameVerifier"  to setOf("verify"),
            // Standard SSL hostname verifiers
            "javax/net/ssl/HttpsURLConnection\$DefaultHostnameVerifier" to setOf("verify"),
            "org/apache/http/conn/ssl/BrowserCompatHostnameVerifier"    to setOf("verify"),
            "org/apache/http/conn/ssl/AllowAllHostnameVerifier"         to setOf("verify"),
            "org/apache/http/conn/ssl/StrictHostnameVerifier"           to setOf("verify"),
        )
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var prefs: SharedPreferences
    private val logBuf = StringBuilder()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return bail()

        val filePath  = intent.getStringExtra("filePath")  ?: return bail()
        val outputDir = intent.getStringExtra("outputDir") ?: return bail()
        val fileName  = intent.getStringExtra("fileName")  ?: filePath.substringAfterLast('/')
        val signApk   = intent.getBooleanExtra("signApk", false)

        prefs = getSharedPreferences(PREFS, MODE_PRIVATE)

        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "TaurusShield:SslUnpin"
        ).apply { acquire(60 * 60 * 1000L) }

        val notification = NotificationHelper.buildProcessingNotif(this, "SSL Unpinner", fileName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NotificationHelper.NOTIF_PROCESSING, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NotificationHelper.NOTIF_PROCESSING, notification)
        }

        prefs.edit()
            .putBoolean(KEY_RUNNING, true)
            .putString(KEY_PHASE, "patching")
            .putString(KEY_LOGS, "")
            .putString(KEY_STATUS, "")
            .putString(KEY_OUTPUT_DIR, outputDir)
            .putString(KEY_OUTPUT_PATH, "")
            .putString(KEY_ERROR, "")
            .putString(KEY_FILE_NAME, fileName)
            .putString(KEY_FILE_PATH, filePath)
            .putString(KEY_STEP, "Initializing SSL Unpinner...")
            .putBoolean(KEY_SIGN_APK, signApk)
            .apply()

        cancelFlag.set(false)
        logBuf.clear()
        LogBridge.clear()

        executor.execute {
            workerThread = Thread.currentThread()
            runSslUnpin(filePath, fileName, outputDir, signApk)
        }
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
        NotificationHelper.showProcessing(this, "SSL Unpinner", step)
    }

    private fun finish(success: Boolean, outputPath: String, outputDir: String, error: String) {
        LogBridge.done()
        prefs.edit()
            .putBoolean(KEY_RUNNING, false)
            .putString(KEY_STATUS, if (success) "success" else "error")
            .putString(KEY_OUTPUT_PATH, outputPath)
            .putString(KEY_OUTPUT_DIR, outputDir)
            .putString(KEY_ERROR, error)
            .putString(KEY_PHASE, "done")
            .apply()
        NotificationHelper.showResult(
            this, success,
            "SSL Unpinner",
            if (success) "SSL pinning removed. APK ready."
            else "SSL unpin failed: $error"
        )
        releaseWake()
        stopForeground(true)
        stopSelf()
    }

    private fun releaseWake() {
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Throwable) {}
    }

    // ── Main worker ─────────────────────────────────────────────────────────────

    private fun runSslUnpin(
        filePath: String,
        fileName: String,
        outputDir: String,
        signApk: Boolean,
    ) {
        try {
            val inputExt  = File(filePath).extension.lowercase()
            val isBundled = inputExt in setOf("apks", "xapk", "apkm")

            val baseApkPath: String = if (isBundled) {
                updateStep("Extracting base APK from bundle...")
                val tempBase = File(outputDir, "ssl_base_extracted.apk")
                ZipFile(File(filePath)).use { zf ->
                    val entry = zf.entries().asSequence()
                        .firstOrNull { it.name.equals("base.apk", ignoreCase = true) }
                        ?: run { finish(false, "", outputDir, "No base.apk in bundle"); return }
                    zf.getInputStream(entry).use { inp -> tempBase.outputStream().use { inp.copyTo(it) } }
                }
                log("base.apk extracted: ${tempBase.length() / 1024} KB")
                tempBase.absolutePath
            } else {
                filePath
            }

            updateStep("Preparing APK...")
            val cleanApk = sanitizeApk(baseApkPath)
            log("APK ready: ${File(cleanApk).length() / 1024} KB")

            if (cancelFlag.get()) return handleCancel(outputDir)

            updateStep("Scanning certificate logic...")
            val patchedApk = patchDexInApk(cleanApk, outputDir)
            log("Certificate scan complete")

            if (cancelFlag.get()) return handleCancel(outputDir)

            updateStep("Applying trust override...")
            val nscApk = injectNscInApk(patchedApk)
            log("Trust override applied")

            if (cancelFlag.get()) return handleCancel(outputDir)

            updateStep("Aligning APK...")
            val alignedApk = try { fixApkAlignment(nscApk) } catch (e: Throwable) {
                log("Warning: alignment failed (${e.message}), using unaligned"); nscApk
            }

            val outName = File(fileName).nameWithoutExtension + "_ssl_unpin.apk"
            val outFile = File(outputDir, outName)

            if (signApk) {
                updateStep("Signing APK with Taurus key...")
                try {
                    val tempSigned = File(outputDir, "temp_signed_${outName}")
                    signApkWithKeystore(File(alignedApk), tempSigned)
                    // Re-align after signing: signing re-compresses all entries with DEFLATE
                    // which breaks the Android 11+ requirement that resources.arsc be STORED
                    // and 4-byte aligned. Run alignment again on the signed output.
                    updateStep("Aligning signed APK...")
                    val finalAligned = try {
                        fixApkAlignment(tempSigned.absolutePath)
                    } catch (e: Throwable) {
                        log("Warning: post-sign alignment failed (${e.message})")
                        tempSigned.absolutePath
                    }
                    File(finalAligned).renameTo(outFile)
                    if (finalAligned != tempSigned.absolutePath) tempSigned.delete()
                    log("Signed with Taurus key — ready to install.")
                } catch (e: Throwable) {
                    log("Warning: signing failed (${e.message}) — output is unsigned.")
                    File(alignedApk).copyTo(outFile, overwrite = true)
                }
            } else {
                File(alignedApk).copyTo(outFile, overwrite = true)
                log("Output is unsigned — sign manually before installing.")
            }

            updateStep("Done!")
            log("Output: ${outFile.absolutePath}")
            finish(true, outFile.absolutePath, outputDir, "")

        } catch (e: Throwable) {
            if (cancelFlag.get() || e is InterruptedException) {
                handleCancel(outputDir)
            } else {
                try { log("Fatal: ${e.message}") } catch (_: Throwable) {}
                finish(false, "", outputDir, e.message ?: "Unknown error")
            }
            releaseWake()
            stopForeground(true)
            stopSelf()
        }
    }

    private fun handleCancel(outputDir: String) {
        cancelFlag.set(false)
        LogBridge.push("Cancelled by user.")
        LogBridge.done()
        prefs.edit()
            .putBoolean(KEY_RUNNING, false)
            .putString(KEY_STATUS, "cancelled")
            .putString(KEY_ERROR, "Cancelled")
            .putString(KEY_PHASE, "done")
            .apply()
        NotificationHelper.cancelProcessing(this)
        releaseWake()
        stopForeground(true)
        stopSelf()
    }

    // ── APK sanitize (strip META-INF, copy fresh) ────────────────────────────

    private fun sanitizeApk(srcPath: String): String {
        val src = File(srcPath)
        val dst = File(src.parent, "ssl_clean_${src.name}")
        dst.parentFile?.mkdirs()
        ZipFile(src).use { zf ->
            ZipOutputStream(BufferedFileOutputStream(dst)).use { zout ->
                zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                for (entry in zf.entries()) {
                    if (entry.name.startsWith("META-INF/")) continue
                    writeZipEntry(zout, entry, zf.getInputStream(entry).readBytes())
                }
            }
        }
        return dst.absolutePath
    }

    // ── DEX patching ──────────────────────────────────────────────────────────

    private fun patchDexInApk(apkPath: String, outputDir: String): String {
        val src = File(apkPath)
        val dst = File(src.parent, "ssl_dex_${src.name}")
        var totalPatched = 0

        ZipFile(src).use { zf ->
            ZipOutputStream(BufferedFileOutputStream(dst)).use { zout ->
                zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                for (entry in zf.entries()) {
                    val raw = zf.getInputStream(entry).readBytes()
                    val name = entry.name

                    val patched = if (name.matches(Regex("classes\\d*\\.dex"))) {
                        val (patchedDex, count) = patchSingleDex(raw, name)
                        if (count > 0) log("  $name → $count method(s) patched")
                        totalPatched += count
                        patchedDex
                    } else raw

                    writeZipEntry(zout, entry, patched)
                }
            }
        }
        log("Overrides applied: $totalPatched")
        return dst.absolutePath
    }

    /**
     * Unified DEX patcher — uses dexlib2 to resolve every class and method correctly
     * (no hand-rolled ULEB128 accumulator, no direct/virtual split bug), then patches
     * bytes directly via DexBackedMethodImplementation.codeOffset.
     *
     * One pass covers ALL of:
     *   • Name-based targets  (VOID_TARGETS / BOOL_TARGETS)
     *   • Obfuscated OkHttp pinner   (isObfuscatedSslCertPinner)
     *   • X509TrustManager checks    (isTrustManagerCheckMethod)
     *   • HostnameVerifier.verify    (isHostnameVerifierMethod)
     */
    private fun patchSingleDex(dex: ByteArray, label: String): Pair<ByteArray, Int> {
        if (dex.size < 112) return dex to 0
        if (String(dex, 0, 4) != "dex\n") return dex to 0

        return try {
            val dexFile = DexBackedDexFile.fromInputStream(
                Opcodes.getDefault(),
                java.io.BufferedInputStream(ByteArrayInputStream(dex))
            )
            val data = dex.copyOf()
            var patchCount = 0

            fun i32(off: Int) =
                (data[off].toInt() and 0xFF) or
                ((data[off + 1].toInt() and 0xFF) shl 8) or
                ((data[off + 2].toInt() and 0xFF) shl 16) or
                ((data[off + 3].toInt() and 0xFF) shl 24)

            for (classDef in dexFile.classes) {
                val className = try {
                    classDef.type.let {
                        if (it.startsWith("L") && it.endsWith(";")) it.drop(1).dropLast(1) else it
                    }
                } catch (_: Throwable) { continue }

                val voidNames = VOID_TARGETS[className]
                val boolNames = BOOL_TARGETS[className]

                for (method in classDef.methods) {
                    // Determine patch type — void wins over bool if both match
                    val patchAsVoid = try {
                        (voidNames != null && method.name in voidNames)
                            || isObfuscatedSslCertPinner(method)
                            || isTrustManagerCheckMethod(method)
                    } catch (_: Throwable) { false }
                    val patchAsBool = !patchAsVoid && try {
                        (boolNames != null && method.name in boolNames)
                            || isHostnameVerifierMethod(method)
                    } catch (_: Throwable) { false }

                    if (!patchAsVoid && !patchAsBool) continue

                    // Get the byte offset of the first instruction from dexlib2.
                    //
                    // PRIMARY: DexBackedInstruction.instructionStart is a public field —
                    //   no reflection tricks, no setAccessible, works in all builds.
                    // FALLBACK: reflect on DexBackedMethodImplementation.codeOffset and
                    //   add the 16-byte code_item header to reach the instruction stream.
                    //
                    // The old approach used only the fallback, which silently fails when
                    // ProGuard or a version mismatch makes the private field inaccessible.
                    val impl = method.implementation as? DexBackedMethodImplementation ?: continue
                    val insnsOff: Int = run {
                        // Primary: use the public instructionStart field
                        try {
                            (impl.instructions.firstOrNull() as? DexBackedInstruction)
                                ?.instructionStart ?: -1
                        } catch (_: Throwable) {
                            // Fallback: codeOffset reflection + 16
                            try {
                                val f = DexBackedMethodImplementation::class.java
                                            .getDeclaredField("codeOffset")
                                f.isAccessible = true
                                f.getInt(impl) + 16
                            } catch (_: Throwable) { -1 }
                        }
                    }
                    if (insnsOff < 16 || insnsOff + 2 > data.size) continue

                    // code_item layout (DEX spec):
                    //   +0  ushort registers_size
                    //   +2  ushort ins_size
                    //   +4  ushort outs_size
                    //   +6  ushort tries_size
                    //   +8  uint   debug_info_off
                    //   +12 uint   insns_size   ← in 16-bit code units
                    //   +16 ushort insns[]      ← first instruction here (= insnsOff)
                    val codeOff   = insnsOff - 16
                    val insnsSize = i32(codeOff + 12)

                    if (insnsSize < 1) continue

                    // ── Rewrite the full code_item header + opcode ──────────────
                    // Root cause of "viewer shows original code":
                    // Patching only the first opcode bytes leaves insns_size pointing
                    // to the full original instruction count, so DEX viewers and the
                    // runtime verifier see the whole old method body (with our tiny
                    // stub at offset 0 as invisible dead code).
                    //
                    // Fix: also update the code_item header so it declares the correct
                    // (minimal) method body.  Layout of code_item (little-endian):
                    //   codeOff+0  ushort  registers_size  ← keep (includes params)
                    //   codeOff+2  ushort  ins_size        ← keep (param word count)
                    //   codeOff+4  ushort  outs_size       → 0  (no outgoing calls)
                    //   codeOff+6  ushort  tries_size      → 0  (no try blocks)
                    //   codeOff+8  uint    debug_info_off  → 0  (discard debug info)
                    //   codeOff+12 uint    insns_size      → 1 (void) or 2 (bool)
                    //   codeOff+16 ushort[]  insns         ← patch opcode here

                    fun writeU16(off: Int, v: Int) {
                        data[off]     = (v and 0xFF).toByte()
                        data[off + 1] = ((v shr 8) and 0xFF).toByte()
                    }
                    fun writeU32(off: Int, v: Int) {
                        data[off]     = (v         and 0xFF).toByte()
                        data[off + 1] = ((v shr  8) and 0xFF).toByte()
                        data[off + 2] = ((v shr 16) and 0xFF).toByte()
                        data[off + 3] = ((v shr 24) and 0xFF).toByte()
                    }

                    // ── Zero-fill the original instruction area beyond our stub ──
                    //
                    // WHY THIS IS REQUIRED:
                    // After we shrink insns_size (e.g. from 200 code units → 1),
                    // the DEX verifier reads our code_item, sees insns_size=1 (2 bytes),
                    // and considers the code_item "done" at insnsOff+2.  The next
                    // code_item must start at a 4-byte-aligned offset, so the verifier
                    // expects the intervening bytes to all be 0x00.  But bytes
                    // insnsOff+2 .. insnsOff+originalInsnsSize*2 are still the original
                    // method's bytecode — non-zero — which produces:
                    //   "Non-zero padding N before section of type 0x2001 (CODE_ITEM)"
                    // and a ClassNotFoundException at app startup.
                    //
                    // Fix: zero out every byte of the original instruction area that
                    // follows our tiny stub.  This turns leftover bytecode into valid
                    // zero padding, satisfying the DEX verifier on all API levels.
                    val origInsnBytes = insnsSize * 2            // bytes used by original insns
                    val zeroFrom: Int                            // first byte to clear
                    val zeroTo: Int = minOf(                     // last byte to clear (exclusive)
                        insnsOff + origInsnBytes,
                        data.size
                    )

                    if (patchAsVoid) {
                        val alreadyDone = data[insnsOff] == 0x0E.toByte() && insnsSize == 1
                        // code_item header
                        writeU16(codeOff + 4, 0)   // outs_size  = 0
                        writeU16(codeOff + 6, 0)   // tries_size = 0
                        writeU32(codeOff + 8, 0)   // debug_info_off = 0
                        writeU32(codeOff + 12, 1)  // insns_size = 1 code unit
                        // opcode: return-void
                        data[insnsOff]     = 0x0E.toByte()
                        data[insnsOff + 1] = 0x00.toByte()
                        // zero the rest of the original instruction area
                        zeroFrom = insnsOff + 2
                        if (zeroFrom < zeroTo) data.fill(0, zeroFrom, zeroTo)
                        if (!alreadyDone) patchCount++
                        log("    Patched $className.${method.name}() → return-void${if (alreadyDone) " (re-confirmed)" else ""}")
                    } else {
                        if (insnsOff + 4 > data.size) continue
                        val alreadyDone = data[insnsOff] == 0x12.toByte() &&
                                          data[insnsOff + 1] == 0x10.toByte() && insnsSize == 2
                        // Ensure registers_size >= 1 so v0 is valid
                        val regsSz = (data[codeOff].toInt() and 0xFF) or
                                     ((data[codeOff + 1].toInt() and 0xFF) shl 8)
                        if (regsSz == 0) writeU16(codeOff, 1)
                        // code_item header
                        writeU16(codeOff + 4, 0)   // outs_size  = 0
                        writeU16(codeOff + 6, 0)   // tries_size = 0
                        writeU32(codeOff + 8, 0)   // debug_info_off = 0
                        writeU32(codeOff + 12, 2)  // insns_size = 2 code units
                        // opcodes: const/4 v0, #1  then  return v0
                        data[insnsOff]     = 0x12.toByte() // const/4 v0, #1
                        data[insnsOff + 1] = 0x10.toByte()
                        data[insnsOff + 2] = 0x0F.toByte() // return v0
                        data[insnsOff + 3] = 0x00.toByte()
                        // zero the rest of the original instruction area
                        zeroFrom = insnsOff + 4
                        if (zeroFrom < zeroTo) data.fill(0, zeroFrom, zeroTo)
                        if (!alreadyDone) patchCount++
                        log("    Patched $className.${method.name}() → return true${if (alreadyDone) " (re-confirmed)" else ""}")
                    }
                }
            }

            // ── Repair pass: clamp outs_size ≤ registers_size for every code_item ──
            //
            // The original APK may contain code_items where outs_size > registers_size
            // (a pre-existing compiler/toolchain artefact).  The device's ART runtime
            // accepted them using its OAT cache from first install.  Our patch changes
            // the DEX SHA-1, invalidating the OAT cache and forcing a full DEX
            // re-verification — which rejects these code_items even though we never
            // touched them.
            //
            // Uses dexlib2 (same library used by the SSL patch loop above) to iterate
            // every class and method — no manual ULEB128 parsing, no missed code_items.
            // DexBackedMethodImplementation.codeOffset gives us the exact byte offset of
            // each code_item header.  From there: +0 = registers_size, +4 = outs_size.
            // Clamping outs down to regs is safe: outs_size is only a stack-frame hint;
            // ART dispatches invoke arguments from the actual instruction, not this field.
            var outsRepaired = 0
            run {
                fun u16r(off: Int) =
                    (data[off].toInt() and 0xFF) or ((data[off + 1].toInt() and 0xFF) shl 8)
                try {
                    val repairDex = DexBackedDexFile.fromInputStream(
                        Opcodes.getDefault(), ByteArrayInputStream(data)
                    )
                    val coField = DexBackedMethodImplementation::class.java
                        .getDeclaredField("codeOffset").also { it.isAccessible = true }

                    for (cls in repairDex.classes) {
                        for (method in (cls.directMethods + cls.virtualMethods)) {
                            val impl = method.implementation
                                as? DexBackedMethodImplementation ?: continue
                            val co = try { coField.getInt(impl) } catch (_: Throwable) { continue }
                            if (co == 0 || co + 6 > data.size) continue
                            val regs = u16r(co)
                            val outs = u16r(co + 4)
                            if (outs > regs) {
                                data[co + 4] = (regs and 0xFF).toByte()
                                data[co + 5] = ((regs shr 8) and 0xFF).toByte()
                                outsRepaired++
                            }
                        }
                    }
                    if (outsRepaired > 0)
                        log("  Repaired $outsRepaired code_item(s) with outs > regs (pre-existing)")
                } catch (e: Throwable) {
                    log("  outs-repair scan failed: ${e.message?.take(120)}")
                }
            }

            // Only skip the DEX entirely when BOTH SSL patches and outs repairs are zero.
            // Previously this returned original `dex` even when outs repairs were applied,
            // silently discarding fixes on DEX files that contain no SSL methods
            // (e.g. classes2.dex, classes3.dex).
            if (patchCount == 0 && outsRepaired == 0) return dex to 0

            // DEX spec: SHA-1 covers bytes 32..end; Adler-32 covers bytes 12..end
            // (which includes the SHA-1 field at bytes 12-31).
            // MUST update SHA-1 first so Adler-32 is computed over the final SHA-1 value.

            // Step 1: SHA-1 signature (bytes 12-31, covers bytes 32..end)
            val sha1 = MessageDigest.getInstance("SHA-1").digest(data.copyOfRange(32, data.size))
            sha1.forEachIndexed { i, b -> data[12 + i] = b }

            // Step 2: Adler-32 checksum (bytes 8-11, covers bytes 12..end incl. new SHA-1)
            val adler = Adler32()
            adler.update(data, 12, data.size - 12)
            val checksum = adler.value
            data[8]  = (checksum         and 0xFF).toByte()
            data[9]  = ((checksum shr  8) and 0xFF).toByte()
            data[10] = ((checksum shr 16) and 0xFF).toByte()
            data[11] = ((checksum shr 24) and 0xFF).toByte()

            data to patchCount
        } catch (e: Throwable) {
            log("  [$label] dex patch error: ${e.message?.take(120)}")
            dex to 0
        }
    }

    /**
     * Returns true if [method] structurally matches an OkHttp CertificatePinner
     * check() / check$okhttp() — or any obfuscated equivalent — that validates
     * peer certificates.
     *
     * Implements the Smali regex guide criteria exactly:
     *
     *   1. Void return, any name, public (access not restricted — catches any visibility)
     *   2. Exactly 2 params: Ljava/lang/String; + any single object type (L...)
     *      Handles both List<Certificate> (OkHttp 3/4) and older array variants.
     *   3. PRIMARY anchor (guide check-cast rule):
     *      Body contains a CHECK_CAST instruction targeting Ljava/security/cert/X509Certificate;
     *   4. FALLBACK anchor (broader):
     *      Body contains ANY reference (TypeRef / MethodRef / FieldRef) to X509Certificate
     *      — catches unusual D8/R8 transformations where check-cast is merged away
     *   5. Body OR @Throws annotation references Ljavax/net/ssl/SSLPeerUnverifiedException;
     *      — TypeReference (new-instance), MethodReference (<init> call),
     *        or Ldalvik/annotation/Throws; annotation element
     *
     * Both anchor 3 and anchor 4 are tested; either is sufficient (OR logic) so
     * neither obfuscated nor optimized builds are missed.
     */
    private fun isObfuscatedSslCertPinner(method: Method): Boolean {
        if (method.returnType != "V") return false

        val params = method.parameterTypes.toList()
        if (params.size != 2) return false
        if (params[0].toString() != "Ljava/lang/String;") return false
        // Second param must be an object type (L...) or array of objects ([L...)
        val p1 = params[1].toString()
        if (!p1.startsWith("L") && !p1.startsWith("[L")) return false

        var hasCastToX509 = false   // guide primary: check-cast specifically
        var hasX509Ref    = false   // fallback: any reference to X509Cert
        var hasSslEx      = false   // SSLPeerUnverifiedException anywhere

        // ── Check @Throws annotation ─────────────────────────────────────────
        for (ann in method.annotations) {
            if (ann.type == "Ldalvik/annotation/Throws;") {
                for (elem in ann.elements) {
                    val v = elem.value
                    if (v is ArrayEncodedValue) {
                        for (item in v.value) {
                            if (item is TypeEncodedValue &&
                                item.value == "Ljavax/net/ssl/SSLPeerUnverifiedException;") {
                                hasSslEx = true
                            }
                        }
                    }
                }
            }
        }

        // ── Scan instructions ────────────────────────────────────────────────
        val impl = method.implementation ?: return false
        for (instr in impl.instructions) {
            if (instr !is ReferenceInstruction) continue

            // Guide primary: check-cast opcode → X509Certificate (anchor #3)
            if (!hasCastToX509 && instr.opcode == Opcode.CHECK_CAST) {
                val ref = instr.reference
                if (ref is TypeReference &&
                    ref.type == "Ljava/security/cert/X509Certificate;") {
                    hasCastToX509 = true
                }
            }

            when (val ref = instr.reference) {
                is TypeReference -> when (ref.type) {
                    "Ljava/security/cert/X509Certificate;"       -> hasX509Ref = true
                    "Ljavax/net/ssl/SSLPeerUnverifiedException;" -> hasSslEx   = true
                }
                is MethodReference -> when (ref.definingClass) {
                    "Ljava/security/cert/X509Certificate;"       -> hasX509Ref = true
                    "Ljavax/net/ssl/SSLPeerUnverifiedException;" -> hasSslEx   = true
                }
                is FieldReference -> when (ref.definingClass) {
                    "Ljava/security/cert/X509Certificate;"       -> hasX509Ref = true
                    "Ljavax/net/ssl/SSLPeerUnverifiedException;" -> hasSslEx   = true
                }
                else -> {}
            }

            // Short-circuit as soon as both conditions are satisfied
            if ((hasCastToX509 || hasX509Ref) && hasSslEx) return true
        }

        // ── Scan exception handler types in try blocks ───────────────────────
        // SSLPeerUnverifiedException (and occasionally X509Certificate) can appear
        // ONLY as a catch-handler type in the DEX encoded_catch_handler_list — they
        // are NOT emitted as instruction-level ReferenceInstructions in that case.
        // Smali disassembly renders catch types as text, so the smali regex finds
        // them; but impl.instructions only covers the instruction stream and misses
        // the try-block section entirely. We scan impl.tryBlocks here to cover that gap.
        if (!(hasCastToX509 || hasX509Ref) || !hasSslEx) {
            for (tryBlock in impl.tryBlocks) {
                for (handler in tryBlock.exceptionHandlers) {
                    when (handler.exceptionType) {
                        "Ljava/security/cert/X509Certificate;"       -> hasX509Ref = true
                        "Ljavax/net/ssl/SSLPeerUnverifiedException;" -> hasSslEx   = true
                    }
                    if ((hasCastToX509 || hasX509Ref) && hasSslEx) return true
                }
            }
        }

        return (hasCastToX509 || hasX509Ref) && hasSslEx
    }

    /**
     * Returns true if [method] is a standard X509TrustManager certificate check:
     *   checkServerTrusted([Ljava/security/cert/X509Certificate;, Ljava/lang/String;)V
     *   checkClientTrusted([Ljava/security/cert/X509Certificate;, Ljava/lang/String;)V
     *
     * These throw CertificateException (not SSLPeerUnverifiedException), so they are
     * completely invisible to isObfuscatedSslCertPinner. Method NAME alone is enough
     * because these names are mandated by the X509TrustManager interface contract.
     */
    private fun isTrustManagerCheckMethod(method: Method): Boolean {
        if (method.returnType != "V") return false
        val name = method.name
        if (name != "checkServerTrusted" && name != "checkClientTrusted") return false
        val params = method.parameterTypes.toList()
        if (params.size < 2) return false
        val p0 = params[0].toString()
        // Accept both array ([L...) and single-cert (L...) signatures — some wrappers use single cert
        if (!p0.startsWith("[Ljava/security/cert/X509Certificate") &&
            !p0.startsWith("Ljava/security/cert/X509Certificate")) return false
        if (params[1].toString() != "Ljava/lang/String;") return false
        return true
    }

    /**
     * Returns true if [method] matches the standard javax.net.ssl.HostnameVerifier contract:
     *   verify(Ljava/lang/String;, Ljavax/net/ssl/SSLSession;)Z
     *
     * These are not caught by isObfuscatedSslCertPinner (different return type and params).
     * We patch them to return true, bypassing all hostname checks.
     */
    private fun isHostnameVerifierMethod(method: Method): Boolean {
        if (method.returnType != "Z") return false   // Z = boolean in DEX
        if (method.name != "verify") return false
        val params = method.parameterTypes.toList()
        if (params.size != 2) return false
        if (params[0].toString() != "Ljava/lang/String;") return false
        if (params[1].toString() != "Ljavax/net/ssl/SSLSession;") return false
        return true
    }

    // ── NSC XML injection ─────────────────────────────────────────────────────

    private fun injectNscInApk(apkPath: String): String {
        val src = File(apkPath)
        val dst = File(src.parent, "ssl_nsc_${src.name}")
        var nscReplaced = 0
        var manifestBytes: ByteArray? = null

        val permissiveNsc = buildPermissiveNscBinary()

        // ── Phase 1: replace ANY res/xml/*.xml that looks like an NSC ─────────
        ZipFile(src).use { zf ->
            ZipOutputStream(BufferedFileOutputStream(dst)).use { zout ->
                zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                for (entry in zf.entries()) {
                    val raw = zf.getInputStream(entry).readBytes()
                    val name = entry.name

                    if (name == "AndroidManifest.xml") manifestBytes = raw

                    val out = if (name.startsWith("res/xml/") && name.endsWith(".xml")) {
                        if (looksLikeNsc(raw)) {
                            nscReplaced++
                            log("  Updating trust settings: $name")
                            permissiveNsc
                        } else raw
                    } else raw

                    writeZipEntry(zout, entry, out)
                }
            }
        }

        if (nscReplaced > 0) {
            log("  Updated $nscReplaced trust configuration(s).")
            return dst.absolutePath
        }

        // ── Phase 2: manifest has NSC reference but file not found by Phase 1 ─
        // Scan manifest binary for android:networkSecurityConfig (attr 0x01010527).
        val manifestHasNscRef = manifestBytes?.let { hasNscManifestAttr(it) } ?: false
        if (manifestHasNscRef) {
            log("  Expanding trust override to all security configs...")
            val src2 = dst
            val dst2 = File(src2.parent, "ssl_nsc2_${src.name}")
            ZipFile(src2).use { zf ->
                ZipOutputStream(BufferedFileOutputStream(dst2)).use { zout ->
                    zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                    for (entry in zf.entries()) {
                        val raw = zf.getInputStream(entry).readBytes()
                        val name = entry.name
                        val out = if (name.startsWith("res/xml/") && name.endsWith(".xml")
                            && isBinaryXml(raw)) {
                            nscReplaced++
                            log("  Overriding trust settings: $name")
                            permissiveNsc
                        } else raw
                        writeZipEntry(zout, entry, out)
                    }
                }
            }
            src2.delete()
            dst2.renameTo(dst)
            if (nscReplaced > 0) {
                log("  Applied trust override to $nscReplaced configuration(s).")
                return dst.absolutePath
            }
        }

        // ── Phase 3: no NSC anywhere — inject one via ARSCLib ────────────────
        // Uses ARSCLib (the ARSC equivalent of dexlib2) to:
        //  1. Add a new xml/network_security_config entry to resources.arsc
        //  2. Wire android:networkSecurityConfig in <application>
        //  3. Embed the permissive NSC binary XML into the APK
        log("  No existing trust config — injecting via resource table...")
        val injected = injectNscViaArscLib(dst, buildPermissiveNscBinary())
        if (injected) {
            log("  Trust configuration wired via resource table.")
        } else {
            log("  DEX-level bypass active (resource table injection skipped).")
        }
        return dst.absolutePath
    }

    /**
     * Uses ARSCLib (the structured ARSC library, analogous to dexlib2 for DEX) to:
     *  1. Open the APK and parse resources.arsc via TableBlock
     *  2. Add a new "xml/network_security_config" entry → gets a stable resource ID
     *  3. Patch the binary AndroidManifest's <application> element to reference it
     *  4. Embed the permissive binary NSC XML at res/xml/network_security_config.xml
     *  5. Write the modified APK back (fixApkAlignment runs after this, handling alignment)
     */
    private fun injectNscViaArscLib(apkFile: File, nscXmlBytes: ByteArray): Boolean {
        return try {
            val apkModule = ApkModule.loadApkFile(apkFile)

            // ── 1. Find the main application package (usually 0x7F) ──────────
            val tableBlock = apkModule.tableBlock
                ?: return false.also { log("  ARSCLib: no resource table in APK") }
            val pkg = tableBlock.pickOne(0x7F)
                ?: tableBlock.iterator().asSequence().firstOrNull()
                ?: return false.also { log("  ARSCLib: no package found in resource table") }

            // ── 2. Add/find the xml/network_security_config entry ────────────
            val nscPath = "res/xml/network_security_config.xml"
            val entry = pkg.getOrCreate("", "xml", "network_security_config")
            entry.setValueAsString(nscPath)
            val nscResId = entry.resourceId
            log("  ARSCLib: registered network_security_config as 0x${nscResId.toString(16)}")

            // ── 3. Wire android:networkSecurityConfig in <application> ───────
            val manifest = apkModule.androidManifest
            val appElem = manifest.applicationElement
            val nscAttr = appElem.getOrCreateAndroidAttribute("networkSecurityConfig", 0x01010527)
            nscAttr.setValueType(ValueType.REFERENCE)
            nscAttr.setData(nscResId)

            // ── 4. Embed permissive NSC binary XML ───────────────────────────
            apkModule.zipEntryMap.remove(nscPath)
            apkModule.add(ByteInputSource(nscXmlBytes, nscPath))

            // ── 5. Write back ─────────────────────────────────────────────────
            val tmp = File(apkFile.parent, "arsclib_nsc_${apkFile.name}")
            apkModule.writeApk(tmp)
            apkFile.delete()
            tmp.renameTo(apkFile)
            true
        } catch (e: Throwable) {
            log("  ARSCLib NSC injection failed: ${e.javaClass.simpleName}: ${e.message?.take(100)}")
            false
        }
    }

    /**
     * Returns true if this binary XML is a network-security-config file.
     * Matches ANY NSC regardless of whether it contains pin-set or domain-config —
     * the permissive replacement always wins.
     *
     * Handles both UTF-8 string pools (modern AAPT2) and UTF-16LE (legacy AAPT).
     */
    private fun looksLikeNsc(xml: ByteArray): Boolean {
        if (xml.size < 12) return false
        val type = (xml[0].toInt() and 0xFF) or ((xml[1].toInt() and 0xFF) shl 8)
        if (type != 0x0003) return false  // not binary XML
        val content = try { String(xml, Charsets.ISO_8859_1) } catch (_: Throwable) { return false }
        // UTF-8 string pools store "network-security-config" literally
        if (content.contains("network-security-config")) return true
        // UTF-16LE string pools store it with null bytes between chars — check for "n\0e\0t\0w\0o\0r\0k\0"
        val utf16marker = "n\u0000e\u0000t\u0000w\u0000o\u0000r\u0000k\u0000"
        return content.contains(utf16marker)
    }

    /** True if the bytes look like any binary Android XML (magic word 0x0003). */
    private fun isBinaryXml(bytes: ByteArray): Boolean {
        if (bytes.size < 4) return false
        val type = (bytes[0].toInt() and 0xFF) or ((bytes[1].toInt() and 0xFF) shl 8)
        return type == 0x0003
    }

    /**
     * Scans the binary AndroidManifest for the presence of the
     * android:networkSecurityConfig attribute (resource ID 0x01010527).
     * Returns true if that attribute is referenced anywhere in the manifest.
     */
    private fun hasNscManifestAttr(manifest: ByteArray): Boolean {
        // Attribute resource ID 0x01010527 stored as little-endian 4 bytes:
        val needle = byteArrayOf(0x27.toByte(), 0x05.toByte(), 0x01.toByte(), 0x01.toByte())
        outer@ for (i in 0 until manifest.size - 3) {
            for (j in needle.indices) {
                if (manifest[i + j] != needle[j]) continue@outer
            }
            return true
        }
        return false
    }

    /**
     * Attempts to add android:networkSecurityConfig="@xml/network_security_config"
     * to the <application> START_ELEMENT in a binary AndroidManifest.
     *
     * Strategy: find the <application> chunk (type 0x0102), locate its attrCount
     * field, increment it, and append a new 20-byte attribute block.
     * The resource reference value uses the most common XML type mapping
     * (package 0x7F, type 0x04, entry 0x0000 → 0x7F040000).
     */
    private fun patchManifestAddNsc(manifest: ByteArray, resId: Int): ByteArray? {
        return try {
            patchManifestAddNscImpl(manifest, resId)
        } catch (e: Throwable) {
            log("  Warning: manifest NSC attr patch failed (${e.message})")
            null
        }
    }

    private fun patchManifestAddNscImpl(data: ByteArray, resId: Int): ByteArray {
        if (data.size < 8) return data
        val intAt   = { p: Int -> (data[p].toInt() and 0xFF) or
                                  ((data[p+1].toInt() and 0xFF) shl 8) or
                                  ((data[p+2].toInt() and 0xFF) shl 16) or
                                  ((data[p+3].toInt() and 0xFF) shl 24) }
        val shortAt = { p: Int -> (data[p].toInt() and 0xFF) or ((data[p+1].toInt() and 0xFF) shl 8) }
        fun putI(arr: ByteArray, off: Int, v: Int) {
            arr[off]   = (v and 0xFF).toByte(); arr[off+1] = ((v shr 8) and 0xFF).toByte()
            arr[off+2] = ((v shr 16) and 0xFF).toByte(); arr[off+3] = ((v shr 24) and 0xFF).toByte()
        }

        if (shortAt(0) != 0x0003) return data   // not binary XML

        // ── Read string pool ─────────────────────────────────────────────────
        val spStart      = shortAt(2)           // file header size (= sp offset, usually 8)
        val spChunkSize  = intAt(spStart + 4)
        val spHeaderSize = shortAt(spStart + 2)
        val stringCount  = intAt(spStart + 8)
        val isUtf8       = (intAt(spStart + 16) and 0x100) != 0
        val stringsStart = intAt(spStart + 20)
        val offsetsBase  = spStart + spHeaderSize
        val strDataBase  = spStart + stringsStart

        val allStrings = (0 until stringCount).map { i ->
            val absPos = strDataBase + intAt(offsetsBase + i * 4)
            try { if (isUtf8) readBinXmlUtf8(data, absPos) else readBinXmlUtf16(data, absPos) }
            catch (_: Throwable) { "" }
        }

        val applicationIdx = allStrings.indexOf("application")
        if (applicationIdx < 0) return data

        val androidNsIdx   = allStrings.indexOf("http://schemas.android.com/apk/res/android")

        // Add "networkSecurityConfig" to string pool if absent.
        // The name field in a binary XML attribute is a STRING POOL INDEX —
        // the corresponding resource ID goes in the resource map chunk (0x0180).
        // We surgically extend the ORIGINAL pool bytes (preserving all string data
        // byte-for-byte) rather than rebuilding from scratch, to avoid any
        // encoding round-trip issues.
        val nscAttrName    = "networkSecurityConfig"
        val existingNscIdx = allStrings.indexOf(nscAttrName)
        val nscNameIdx: Int
        val newSpBytes: ByteArray
        if (existingNscIdx >= 0) {
            nscNameIdx = existingNscIdx
            newSpBytes = data.copyOfRange(spStart, spStart + spChunkSize)
        } else {
            nscNameIdx = stringCount   // appended at end of string pool

            // Encode the new string entry in the same format as the rest of the pool
            val nscEncoded = ByteArrayOutputStream()
            if (isUtf8) {
                val nscUtf8 = nscAttrName.toByteArray(Charsets.UTF_8)
                // Android compact format for lengths < 128 = same as ULEB128 single byte
                nscEncoded.write(nscAttrName.length); nscEncoded.write(nscUtf8.size)
                nscEncoded.write(nscUtf8); nscEncoded.write(0)
            } else {
                val nscUtf16 = nscAttrName.toByteArray(Charsets.UTF_16LE)
                nscEncoded.write(nscAttrName.length and 0xFF)
                nscEncoded.write((nscAttrName.length shr 8) and 0xFF)
                nscEncoded.write(nscUtf16); nscEncoded.write(0); nscEncoded.write(0)
            }
            val nscEntryBytes = nscEncoded.toByteArray()

            // Find the unpadded string data end: lastString offset + its encoded size
            val lastOff = intAt(offsetsBase + (stringCount - 1) * 4)
            val lastStr = allStrings[stringCount - 1]
            val lastEncoded = if (isUtf8) {
                val u8 = lastStr.toByteArray(Charsets.UTF_8)
                // u16len(1) + u8len(1) + u8bytes + null(1)
                val sizeU16 = if (lastStr.length < 128) 1 else 2
                val sizeU8  = if (u8.size < 128) 1 else 2
                sizeU16 + sizeU8 + u8.size + 1
            } else {
                val u16 = lastStr.toByteArray(Charsets.UTF_16LE)
                // len(2) + utf16bytes + null(2)
                val sizeLen = if (lastStr.length < 0x8000) 2 else 4
                sizeLen + u16.size + 2
            }
            val strDataUnpadded = lastOff + lastEncoded  // unpadded string data size

            // New string's offset entry = strDataUnpadded (right after existing data)
            val newOffEntry = byteArrayOf(
                (strDataUnpadded and 0xFF).toByte(),
                ((strDataUnpadded shr 8) and 0xFF).toByte(),
                ((strDataUnpadded shr 16) and 0xFF).toByte(),
                ((strDataUnpadded shr 24) and 0xFF).toByte()
            )

            // New pool layout:
            //   [updated header: 28 bytes]
            //   [original N offsets]
            //   [new offset entry: 4 bytes]
            //   [original string data (strDataUnpadded bytes, no old padding)]
            //   [new string entry]
            //   [new 4-byte alignment padding]
            val newStrDataSize = strDataUnpadded + nscEntryBytes.size
            val newPad = (4 - (newStrDataSize % 4)) % 4
            val newStringsStart = 28 + (stringCount + 1) * 4  // old_stringsStart + 4
            val newChunkSize    = newStringsStart + newStrDataSize + newPad

            val sp = ByteArrayOutputStream(newChunkSize)
            // Header
            writeShort(sp, 0x0001); writeShort(sp, 28)
            writeInt(sp, newChunkSize)
            writeInt(sp, stringCount + 1); writeInt(sp, intAt(spStart + 12))  // styleCount unchanged
            writeInt(sp, if (isUtf8) 0x100 else 0)
            writeInt(sp, newStringsStart); writeInt(sp, intAt(spStart + 24))  // stylesStart unchanged
            // Original N offsets (unchanged — still valid relative to new stringsStart)
            sp.write(data, offsetsBase, stringCount * 4)
            // New offset entry
            sp.write(newOffEntry)
            // Original string data (unpadded — preserve EXACTLY as original bytes)
            sp.write(data, strDataBase, strDataUnpadded)
            // New string
            sp.write(nscEntryBytes)
            // New padding
            repeat(newPad) { sp.write(0) }

            newSpBytes = sp.toByteArray()
        }
        val spSizeDiff = newSpBytes.size - spChunkSize

        // ── Resource map chunk (0x0180) — maps sp index → android attr resource ID ──
        val rmStart     = spStart + spChunkSize
        val hasRm       = rmStart + 8 <= data.size && shortAt(rmStart) == 0x0180
        val rmChunkSize = if (hasRm) intAt(rmStart + 4) else 0
        val rmCount     = if (hasRm) (rmChunkSize - 8) / 4 else 0

        val newRmCount     = maxOf(rmCount, nscNameIdx + 1)
        val newRmChunkSize = 8 + newRmCount * 4
        val newRm = java.io.ByteArrayOutputStream()
        writeShort(newRm, 0x0180); writeShort(newRm, 8)
        writeInt(newRm, newRmChunkSize)
        for (i in 0 until newRmCount) {
            val existing = if (hasRm && i < rmCount) intAt(rmStart + 8 + i * 4) else 0
            writeInt(newRm, if (i == nscNameIdx) 0x01010527 else existing)
        }
        val newRmBytes = newRm.toByteArray()
        val rmSizeDiff = newRmBytes.size - (if (hasRm) rmChunkSize else 0)

        // ── Find <application> START_ELEMENT ─────────────────────────────────
        val chunksStart = if (hasRm) rmStart + rmChunkSize else rmStart
        var appChunkStart = -1
        var pos = chunksStart
        while (pos + 8 < data.size) {
            val cType = shortAt(pos); val cSize = intAt(pos + 4)
            if (cSize <= 0 || pos + cSize > data.size) break
            if (cType == 0x0102 && intAt(pos + 20) == applicationIdx) { appChunkStart = pos; break }
            pos += cSize
        }
        if (appChunkStart < 0) return data

        // ── Build new 20-byte attribute ───────────────────────────────────────
        // ns  = string pool index of android namespace URI
        // name = string pool index of "networkSecurityConfig"  ← CORRECT (not the resource ID)
        // resource map entry at [nscNameIdx] = 0x01010527      ← resource ID lives here
        val newAttr = ByteArray(20)
        putI(newAttr,  0, androidNsIdx)   // ns  = android namespace string pool index
        putI(newAttr,  4, nscNameIdx)     // name = sp index of "networkSecurityConfig"
        putI(newAttr,  8, -1)             // rawValue = none
        newAttr[12] = 0x08; newAttr[13] = 0x00  // typedValue.size = 8
        newAttr[14] = 0x00                // res0
        newAttr[15] = 0x01                // dataType = TYPE_REFERENCE
        putI(newAttr, 16, resId)          // data = @xml/network_security_config resource ID

        // ── Reconstruct file ──────────────────────────────────────────────────
        val oldAppSize  = intAt(appChunkStart + 4)
        val newAppSize  = oldAppSize + 20
        val totalDiff   = spSizeDiff + rmSizeDiff + 20
        val newFileSize = intAt(4) + totalDiff

        val out = java.io.ByteArrayOutputStream(data.size + totalDiff)

        // File header: update size
        out.write(data, 0, 4)   // type + headerSize (unchanged)
        out.write(byteArrayOf(
            (newFileSize and 0xFF).toByte(), ((newFileSize shr 8) and 0xFF).toByte(),
            ((newFileSize shr 16) and 0xFF).toByte(), ((newFileSize shr 24) and 0xFF).toByte()
        ))

        out.write(newSpBytes)    // extended string pool
        out.write(newRmBytes)    // extended resource map

        // chunks between resource map and <application>
        out.write(data, chunksStart, appChunkStart - chunksStart)

        // patched <application> chunk: update chunkSize + attrCount
        val appChunk = data.copyOfRange(appChunkStart, appChunkStart + oldAppSize)
        appChunk[4] = (newAppSize and 0xFF).toByte()
        appChunk[5] = ((newAppSize shr 8) and 0xFF).toByte()
        appChunk[6] = ((newAppSize shr 16) and 0xFF).toByte()
        appChunk[7] = ((newAppSize shr 24) and 0xFF).toByte()
        val oldCount = (appChunk[28].toInt() and 0xFF) or ((appChunk[29].toInt() and 0xFF) shl 8)
        appChunk[28] = ((oldCount + 1) and 0xFF).toByte()
        appChunk[29] = (((oldCount + 1) shr 8) and 0xFF).toByte()
        out.write(appChunk)
        out.write(newAttr)

        // rest of file
        out.write(data, appChunkStart + oldAppSize, data.size - (appChunkStart + oldAppSize))
        return out.toByteArray()
    }

    // ── resources.arsc patcher ────────────────────────────────────────────────

    /**
     * Parses resources.arsc, finds the "xml" resource type, and appends a new
     * entry for "network_security_config" → "res/xml/network_security_config.xml".
     * Returns (patchedArscBytes, newResourceId) or null if the arsc cannot be parsed.
     *
     * Format: TABLE(12) → GlobalStringPool → PACKAGE(288) → TypeStringPool →
     *         KeyStringPool → [TYPE_SPEC chunks] → [TYPE chunks]
     */
    private fun patchArscAddNsc(arsc: ByteArray): Pair<ByteArray, Int>? {
        return try { patchArscImpl(arsc) } catch (e: Throwable) {
            log("  ARSC patch skipped: ${e.message}")
            null
        }
    }

    private fun patchArscImpl(arsc: ByteArray): Pair<ByteArray, Int>? {
        fun i32(o: Int) = (arsc[o].toInt() and 0xFF) or
                          ((arsc[o+1].toInt() and 0xFF) shl 8) or
                          ((arsc[o+2].toInt() and 0xFF) shl 16) or
                          ((arsc[o+3].toInt() and 0xFF) shl 24)
        fun i16(o: Int) = (arsc[o].toInt() and 0xFF) or ((arsc[o+1].toInt() and 0xFF) shl 8)
        fun i8(o: Int)  = arsc[o].toInt() and 0xFF

        // TABLE header
        if (i16(0) != 0x0002) return null
        val tableHdrSize = i16(2)

        // Global string pool immediately after table header
        val gspOff = tableHdrSize
        if (i16(gspOff) != 0x0001) return null
        val gspHdrSize     = i16(gspOff + 2)
        val gspChunkSize   = i32(gspOff + 4)
        val gspStrCount    = i32(gspOff + 8)
        val gspFlags       = i32(gspOff + 16)
        val gspStrStart    = i32(gspOff + 20)
        val gspIsUtf8      = (gspFlags and 0x100) != 0
        val gspOffBase     = gspOff + gspHdrSize
        val gspStrBase     = gspOff + gspStrStart

        val nscPath = "res/xml/network_security_config.xml"
        var globalIdx = gspStrCount   // default: append at end
        for (i in 0 until gspStrCount) {
            val s = readArscString(arsc, gspStrBase + i32(gspOffBase + i * 4), gspIsUtf8)
            if (s == nscPath) { globalIdx = i; break }
        }
        val newGspBytes = if (globalIdx == gspStrCount) {
            extendArscStringPool(arsc.copyOfRange(gspOff, gspOff + gspChunkSize), nscPath)
                ?: return null
        } else arsc.copyOfRange(gspOff, gspOff + gspChunkSize)

        // Package chunk
        val pkgOff = gspOff + gspChunkSize
        if (i16(pkgOff) != 0x0200) return null
        val pkgHdrSize   = i16(pkgOff + 2)   // 288
        val pkgChunkSize = i32(pkgOff + 4)
        val pkgId        = i8(pkgOff + 8)    // package ID (low byte, usually 0x7F)
        // Layout: [0..1]=type [2..3]=hdrSize [4..7]=chunkSize [8..11]=id [12..267]=name(256)
        // [268..271]=typeStrings [272..275]=lastPublicType [276..279]=keyStrings
        val typeStrRelOff = i32(pkgOff + 268)
        val keyStrRelOff  = i32(pkgOff + 276)

        // Type string pool
        val typeSpOff      = pkgOff + typeStrRelOff
        val typeSpHdrSize  = i16(typeSpOff + 2)
        val typeSpChunk    = i32(typeSpOff + 4)
        val typeSpCount    = i32(typeSpOff + 8)
        val typeSpFlags    = i32(typeSpOff + 16)
        val typeSpStrStart = i32(typeSpOff + 20)
        val typeSpIsUtf8   = (typeSpFlags and 0x100) != 0
        val typeOffBase    = typeSpOff + typeSpHdrSize
        val typeStrBase    = typeSpOff + typeSpStrStart

        var xmlTypeId = -1
        for (i in 0 until typeSpCount) {
            val s = readArscString(arsc, typeStrBase + i32(typeOffBase + i * 4), typeSpIsUtf8)
            if (s == "xml") { xmlTypeId = i + 1; break }   // 1-based type ID
        }
        if (xmlTypeId < 0) return null

        // Key string pool
        val keySpOff      = pkgOff + keyStrRelOff
        val keySpHdrSize  = i16(keySpOff + 2)
        val keySpChunk    = i32(keySpOff + 4)
        val keySpCount    = i32(keySpOff + 8)
        val keySpFlags    = i32(keySpOff + 16)
        val keySpStrStart = i32(keySpOff + 20)
        val keySpIsUtf8   = (keySpFlags and 0x100) != 0
        val keyOffBase    = keySpOff + keySpHdrSize
        val keyStrBase    = keySpOff + keySpStrStart

        val nscKey = "network_security_config"
        var keyIdx = keySpCount
        for (i in 0 until keySpCount) {
            val s = readArscString(arsc, keyStrBase + i32(keyOffBase + i * 4), keySpIsUtf8)
            if (s == nscKey) { keyIdx = i; break }
        }
        val newKeySpBytes = if (keyIdx == keySpCount) {
            extendArscStringPool(arsc.copyOfRange(keySpOff, keySpOff + keySpChunk), nscKey)
                ?: return null
        } else arsc.copyOfRange(keySpOff, keySpOff + keySpChunk)

        // Scan TYPE_SPEC and TYPE chunks after key string pool
        var xmlEntryCount = -1
        val patchedChunks = ByteArrayOutputStream()
        var pos = keySpOff + keySpChunk
        val pkgEnd = pkgOff + pkgChunkSize

        while (pos < pkgEnd) {
            val cType = i16(pos)
            val cSize = i32(pos + 4)
            val cId   = i8(pos + 8)
            if (cSize <= 0 || pos + cSize > arsc.size) break

            when {
                cType == 0x0202 && cId == xmlTypeId -> {
                    // TYPE_SPEC: add one spec entry (4 bytes) for the new resource
                    val entryCount    = i32(pos + 12)
                    xmlEntryCount     = entryCount
                    val newCount      = entryCount + 1
                    val newChunkSize  = cSize + 4
                    val s = ByteArrayOutputStream()
                    writeShort(s, 0x0202); writeShort(s, 8)
                    writeInt(s, newChunkSize)
                    s.write(xmlTypeId); s.write(0); writeShort(s, 0)
                    writeInt(s, newCount)
                    s.write(arsc, pos + 16, entryCount * 4)   // existing flags
                    writeInt(s, 0)                             // new entry: no flags
                    patchedChunks.write(s.toByteArray())
                }
                cType == 0x0201 && cId == xmlTypeId -> {
                    // TYPE: add entry offset + ResTable_entry + Res_value
                    val typeHdrSize   = i16(pos + 2)          // typically 52
                    val entryCount    = i32(pos + 12)
                    val entriesStart  = i32(pos + 16)         // relative to chunk start
                    val newEntryCount = entryCount + 1
                    val newEntriesStart = entriesStart + 4
                    val newChunkSize  = cSize + 4 + 16        // extra offset + entry + value
                    val existDataSize = cSize - entriesStart

                    val t = ByteArrayOutputStream()
                    writeShort(t, 0x0201); writeShort(t, typeHdrSize)
                    writeInt(t, newChunkSize)
                    t.write(xmlTypeId); t.write(0); writeShort(t, 0)
                    writeInt(t, newEntryCount)
                    writeInt(t, newEntriesStart)
                    t.write(arsc, pos + 20, typeHdrSize - 20)   // config bytes
                    t.write(arsc, pos + typeHdrSize, entryCount * 4)  // existing offsets
                    writeInt(t, existDataSize)                  // offset to new entry
                    t.write(arsc, pos + entriesStart, existDataSize)  // existing entries
                    // ResTable_entry: size=8, flags=0, key=keyIdx
                    writeShort(t, 8); writeShort(t, 0); writeInt(t, keyIdx)
                    // Res_value: size=8, res0=0, dataType=TYPE_STRING(0x03), data=globalIdx
                    writeShort(t, 8); t.write(0); t.write(0x03); writeInt(t, globalIdx)
                    patchedChunks.write(t.toByteArray())
                }
                else -> patchedChunks.write(arsc, pos, cSize)
            }
            pos += cSize
        }
        if (xmlEntryCount < 0) return null

        // Assemble: TABLE header | new global pool | pkg header | typeStr | new keyStr | chunks
        // Compute newPkgSize from actual assembled parts — handles any number of TYPE/TYPE_SPEC chunks
        val patchedChunksBytes = patchedChunks.toByteArray()
        val newPkgSize = pkgHdrSize + typeSpChunk + newKeySpBytes.size + patchedChunksBytes.size
        val result        = ByteArrayOutputStream()
        result.write(arsc, 0, tableHdrSize)          // TABLE header (size patched below)
        result.write(newGspBytes)                    // global string pool (surgically extended)
        val pkgHdr = arsc.copyOfRange(pkgOff, pkgOff + pkgHdrSize)
        pkgHdr[4] = (newPkgSize and 0xFF).toByte()
        pkgHdr[5] = ((newPkgSize shr 8) and 0xFF).toByte()
        pkgHdr[6] = ((newPkgSize shr 16) and 0xFF).toByte()
        pkgHdr[7] = ((newPkgSize shr 24) and 0xFF).toByte()
        result.write(pkgHdr)                         // package header (size updated)
        result.write(arsc, typeSpOff, typeSpChunk)   // type string pool (unchanged)
        result.write(newKeySpBytes)                  // key string pool (surgically extended)
        result.write(patchedChunksBytes)             // patched TYPE_SPEC + TYPE chunks

        val out = result.toByteArray()
        // Patch TABLE chunkSize
        out[4] = (out.size and 0xFF).toByte()
        out[5] = ((out.size shr 8) and 0xFF).toByte()
        out[6] = ((out.size shr 16) and 0xFF).toByte()
        out[7] = ((out.size shr 24) and 0xFF).toByte()

        val resId = (pkgId shl 24) or (xmlTypeId shl 16) or xmlEntryCount
        return Pair(out, resId)
    }

    /** Reads a ULEB128-length-prefixed UTF-8 string or length-prefixed UTF-16LE string. */
    private fun readArscString(data: ByteArray, absPos: Int, utf8: Boolean): String {
        if (absPos < 0 || absPos >= data.size) return ""
        return if (utf8) {
            var p = absPos
            var b = data[p++].toInt() and 0xFF
            if (b and 0x80 != 0) { b = data[p++].toInt() and 0xFF }  // skip high ULEB byte
            b = data[p++].toInt() and 0xFF
            var utf8len = b and 0x7F
            if (b and 0x80 != 0) { b = data[p++].toInt() and 0xFF; utf8len = utf8len or ((b and 0x7F) shl 7) }
            if (p + utf8len > data.size) return ""
            String(data, p, utf8len, Charsets.UTF_8)
        } else {
            val len = (data[absPos].toInt() and 0xFF) or ((data[absPos + 1].toInt() and 0xFF) shl 8)
            if (absPos + 2 + len * 2 > data.size) return ""
            String(data, absPos + 2, len * 2, Charsets.UTF_16LE)
        }
    }

    /** Builds a STRING_POOL chunk (type 0x0001) from the given string list. */
    private fun buildArscStringPool(strings: List<String>, utf8: Boolean): ByteArray {
        val dataBuf = ByteArrayOutputStream()
        val offsets = IntArray(strings.size)
        for ((i, s) in strings.withIndex()) {
            offsets[i] = dataBuf.size()
            if (utf8) {
                val bytes = s.toByteArray(Charsets.UTF_8)
                writeUleb128(dataBuf, s.length)
                writeUleb128(dataBuf, bytes.size)
                dataBuf.write(bytes)
                dataBuf.write(0)
            } else {
                val bytes = s.toByteArray(Charsets.UTF_16LE)
                dataBuf.write(s.length and 0xFF); dataBuf.write((s.length shr 8) and 0xFF)
                dataBuf.write(bytes)
                dataBuf.write(0); dataBuf.write(0)
            }
        }
        val strData   = dataBuf.toByteArray()
        val pad       = (4 - (strData.size % 4)) % 4
        val hdrSize   = 28
        val offSize   = strings.size * 4
        val chunkSize = hdrSize + offSize + strData.size + pad
        val pool      = ByteArrayOutputStream(chunkSize)
        writeShort(pool, 0x0001); writeShort(pool, hdrSize)
        writeInt(pool, chunkSize)
        writeInt(pool, strings.size); writeInt(pool, 0)
        writeInt(pool, if (utf8) 0x100 else 0)
        writeInt(pool, hdrSize + offSize); writeInt(pool, 0)
        for (off in offsets) writeInt(pool, off)
        pool.write(strData)
        repeat(pad) { pool.write(0) }
        return pool.toByteArray()
    }

    /**
     * Surgically extends an ARSC string pool chunk by appending ONE new string.
     * Preserves ALL original bytes exactly — only adds:
     *   - one 4-byte offset entry in the offset table
     *   - the encoded new string bytes + null terminator
     *   - updated alignment padding
     * Header fields updated: stringCount, stringsStart, stylesStart (if set), chunkSize.
     * Style data and style offsets are preserved verbatim.
     * Returns new pool bytes, or null if the pool is malformed.
     */
    private fun extendArscStringPool(poolBytes: ByteArray, newStr: String): ByteArray? {
        if (poolBytes.size < 28) return null
        fun i32(o: Int) = (poolBytes[o].toInt() and 0xFF) or
                          ((poolBytes[o+1].toInt() and 0xFF) shl 8) or
                          ((poolBytes[o+2].toInt() and 0xFF) shl 16) or
                          ((poolBytes[o+3].toInt() and 0xFF) shl 24)
        fun i16(o: Int) = (poolBytes[o].toInt() and 0xFF) or ((poolBytes[o+1].toInt() and 0xFF) shl 8)

        val hdrSize      = i16(2)
        val chunkSize    = i32(4)
        val strCount     = i32(8)
        val styleCount   = i32(12)
        val flags        = i32(16)
        val stringsStart = i32(20)
        val stylesStart  = i32(24)
        val isUtf8       = (flags and 0x100) != 0
        if (hdrSize < 28 || chunkSize > poolBytes.size || stringsStart > chunkSize) return null

        val strOffBase   = hdrSize                    // string offsets start here
        val styleOffBase = hdrSize + strCount * 4     // style offsets follow string offsets

        // Find where the new string will go: right after the last existing string's null byte
        var newOffset = 0
        if (strCount > 0) {
            val lastOff = i32(strOffBase + (strCount - 1) * 4)
            var p = stringsStart + lastOff
            if (p >= chunkSize) return null
            if (isUtf8) {
                // Skip utf16_len ULEB128 (1 or 2 bytes)
                if ((poolBytes[p].toInt() and 0x80) != 0) p++
                p++
                // Read utf8_len ULEB128 to know how many data bytes to skip
                var utf8len = 0; var shift = 0
                while (p < chunkSize) {
                    val b = poolBytes[p++].toInt() and 0xFF
                    utf8len = utf8len or ((b and 0x7F) shl shift); shift += 7
                    if (b and 0x80 == 0) break
                }
                p += utf8len + 1  // skip string bytes + null terminator
            } else {
                val len = (poolBytes[p].toInt() and 0xFF) or ((poolBytes[p+1].toInt() and 0xFF) shl 8)
                p += 2 + len * 2 + 2  // 2-byte length + UTF-16LE chars + 2-byte null
            }
            newOffset = p - stringsStart
        }

        // Encode the new string using the pool's encoding
        val newStrBuf = ByteArrayOutputStream()
        if (isUtf8) {
            val utf8Bytes = newStr.toByteArray(Charsets.UTF_8)
            writeUleb128(newStrBuf, newStr.length)
            writeUleb128(newStrBuf, utf8Bytes.size)
            newStrBuf.write(utf8Bytes)
            newStrBuf.write(0)
        } else {
            val utf16Bytes = newStr.toByteArray(Charsets.UTF_16LE)
            newStrBuf.write(newStr.length and 0xFF); newStrBuf.write((newStr.length shr 8) and 0xFF)
            newStrBuf.write(utf16Bytes)
            newStrBuf.write(0); newStrBuf.write(0)
        }
        val newStrEncoded = newStrBuf.toByteArray()

        // Style data (preserve verbatim)
        val styleDataSize = if (stylesStart > 0 && stylesStart < chunkSize) chunkSize - stylesStart else 0

        // New layout:
        // [hdr hdrSize] [strOffsets (strCount+1)*4] [styleOffsets styleCount*4]
        // [original string data unpadded] [new string] [padding] [style data]
        val newStringsStart  = hdrSize + (strCount + 1) * 4 + styleCount * 4
        val newStrDataSize   = newOffset + newStrEncoded.size
        val newPad           = (4 - (newStrDataSize % 4)) % 4
        val newStylesStart   = if (stylesStart > 0) newStringsStart + newStrDataSize + newPad else 0
        val newChunkSize     = newStringsStart + newStrDataSize + newPad + styleDataSize

        val out = ByteArrayOutputStream(newChunkSize)
        fun putI16(v: Int) { out.write(v and 0xFF); out.write((v shr 8) and 0xFF) }
        fun putI32(v: Int) {
            out.write(v and 0xFF); out.write((v shr 8) and 0xFF)
            out.write((v shr 16) and 0xFF); out.write((v shr 24) and 0xFF)
        }

        // Header
        putI16(0x0001); putI16(hdrSize)
        putI32(newChunkSize)
        putI32(strCount + 1); putI32(styleCount)   // styleCount preserved
        putI32(flags)
        putI32(newStringsStart); putI32(newStylesStart)
        // Any extra header bytes beyond the standard 28 (rare but preserve them)
        if (hdrSize > 28) out.write(poolBytes, 28, hdrSize - 28)

        // String offsets (original N, all valid relative to new stringsStart)
        out.write(poolBytes, strOffBase, strCount * 4)
        // New string offset
        putI32(newOffset)
        // Style offsets (unchanged)
        if (styleCount > 0) out.write(poolBytes, styleOffBase, styleCount * 4)

        // Original string data (up to newOffset = right after last string's null)
        out.write(poolBytes, stringsStart, newOffset)
        // New string
        out.write(newStrEncoded)
        // Alignment padding
        repeat(newPad) { out.write(0) }
        // Style data (preserved verbatim)
        if (styleDataSize > 0) out.write(poolBytes, stylesStart, styleDataSize)

        return out.toByteArray()
    }

    /**
     * Builds a binary Android XML equivalent to:
     * <network-security-config>
     *   <base-config cleartextTrafficPermitted="true">
     *     <trust-anchors>
     *       <certificates src="system"/>
     *       <certificates src="user" overridePins="true"/>
     *     </trust-anchors>
     *   </base-config>
     *   <debug-overrides>
     *     <trust-anchors>
     *       <certificates src="system"/>
     *       <certificates src="user" overridePins="true"/>
     *     </trust-anchors>
     *   </debug-overrides>
     * </network-security-config>
     *
     * overridePins="true" makes user CA certs override any pin-set in the original config.
     * debug-overrides ensures the bypass also applies in debug builds.
     */
    private fun buildPermissiveNscBinary(): ByteArray {
        val strings = listOf(
            "",                                            // 0
            "http://schemas.android.com/apk/res/android", // 1 (android ns URI)
            "network-security-config",                    // 2
            "base-config",                                 // 3
            "cleartextTrafficPermitted",                   // 4
            "trust-anchors",                               // 5
            "certificates",                                // 6
            "src",                                         // 7
            "true",                                        // 8
            "system",                                      // 9
            "user",                                        // 10
            "overridePins",                                // 11
            "debug-overrides"                              // 12
        )

        // Build UTF-8 encoded string pool data
        val strOffsets = IntArray(strings.size)
        val strDataBuf = ByteArrayOutputStream()
        for ((i, s) in strings.withIndex()) {
            strOffsets[i] = strDataBuf.size()
            val utf8 = s.toByteArray(Charsets.UTF_8)
            val utf16len = s.length
            val utf8len = utf8.size
            writeUleb128(strDataBuf, utf16len)
            writeUleb128(strDataBuf, utf8len)
            strDataBuf.write(utf8)
            strDataBuf.write(0) // null terminator
        }
        val strData = strDataBuf.toByteArray()

        // String pool chunk (28-byte header).
        // ALL chunk sizes in AXML must be multiples of 4 — pad strData if needed.
        val strDataPad = (4 - (strData.size % 4)) % 4
        val spHeaderSize = 28
        val spOffsetTableSize = strings.size * 4
        val spChunkSize = spHeaderSize + spOffsetTableSize + strData.size + strDataPad

        val spBuf = ByteArrayOutputStream()
        writeShort(spBuf, 0x0001)                        // type = STRING_POOL
        writeShort(spBuf, spHeaderSize)
        writeInt(spBuf, spChunkSize)
        writeInt(spBuf, strings.size)                    // string_count
        writeInt(spBuf, 0)                               // style_count
        writeInt(spBuf, 0x100)                           // flags: UTF-8
        writeInt(spBuf, spHeaderSize + spOffsetTableSize) // strings_start
        writeInt(spBuf, 0)                               // styles_start
        for (off in strOffsets) writeInt(spBuf, off)
        spBuf.write(strData)
        repeat(strDataPad) { spBuf.write(0) }            // align to 4 bytes
        val spBytes = spBuf.toByteArray()

        // ── Reusable trust-anchors block builder ──────────────────────────────
        // NSC attributes (src, overridePins, cleartextTrafficPermitted) are plain
        // unnamespaced attributes — NOT android: prefixed.  The NSC parser calls
        // getAttributeValue(null, "src") with null namespace; any ns != -1 means
        // the attribute is invisible to the parser → "missing src attribute" crash.
        // Fix: ns = -1 (no namespace) for every NSC element attribute.
        //
        // <certificates overridePins="true" src="user"/>
        //   attr0: ns=-1(none), name=11(overridePins), rawVal=8("true"), type=3(string), data=8
        //   attr1: ns=-1(none), name=7(src),           rawVal=10("user"), type=3(string), data=10
        val certsUserWithPinOverride = listOf(
            intArrayOf(-1, 11, 8,  3, 8),  // overridePins="true"
            intArrayOf(-1, 7,  10, 3, 10)  // src="user"
        )

        fun ByteArrayOutputStream.writeTrustAnchors() {
            // <trust-anchors>
            writeStartElem(this, 5, emptyList())
            // <certificates src="system"/>
            writeStartElem(this, 6, listOf(intArrayOf(-1, 7, 9, 3, 9)))
            writeEndElem(this, 6)
            // <certificates overridePins="true" src="user"/>
            writeStartElem(this, 6, certsUserWithPinOverride)
            writeEndElem(this, 6)
            // </trust-anchors>
            writeEndElem(this, 5)
        }

        // Build XML body chunks
        val xmlBuf = ByteArrayOutputStream()

        // <network-security-config>
        writeStartElem(xmlBuf, 2, emptyList())

        // <base-config cleartextTrafficPermitted="true">
        // cleartextTrafficPermitted is also a plain NSC attribute (ns=-1), type=0x12(bool), data=-1(true)
        writeStartElem(xmlBuf, 3, listOf(intArrayOf(-1, 4, 8, 0x12, -1)))
        xmlBuf.writeTrustAnchors()
        writeEndElem(xmlBuf, 3)  // </base-config>

        // <debug-overrides>  (no attributes — debug-overrides has none)
        writeStartElem(xmlBuf, 12, emptyList())
        xmlBuf.writeTrustAnchors()
        writeEndElem(xmlBuf, 12)  // </debug-overrides>

        // </network-security-config>
        writeEndElem(xmlBuf, 2)

        val xmlBody = xmlBuf.toByteArray()

        // File: header(8) + stringPool + xmlBody
        val fileSize = 8 + spBytes.size + xmlBody.size
        val out = ByteArrayOutputStream(fileSize)
        writeShort(out, 0x0003)  // file type = XML
        writeShort(out, 8)       // file header size = 8
        writeInt(out, fileSize)
        out.write(spBytes)
        out.write(xmlBody)
        return out.toByteArray()
    }

    // ── Binary XML helpers ────────────────────────────────────────────────────

    private fun writeNsChunk(buf: ByteArrayOutputStream, type: Int, prefix: Int, uri: Int) {
        writeShort(buf, type)
        writeShort(buf, 0x10)   // headerSize = 16
        writeInt(buf, 24)       // chunkSize
        writeInt(buf, 1)        // line
        writeInt(buf, -1)       // comment
        writeInt(buf, prefix)
        writeInt(buf, uri)
    }

    private fun writeStartElem(buf: ByteArrayOutputStream, name: Int, attrs: List<IntArray>) {
        val attrCount = attrs.size
        val chunkSize = 36 + attrCount * 20
        writeShort(buf, 0x0102) // START_ELEMENT
        writeShort(buf, 0x10)   // headerSize = 16
        writeInt(buf, chunkSize)
        writeInt(buf, 1)        // line
        writeInt(buf, -1)       // comment
        writeInt(buf, -1)       // ns = none
        writeInt(buf, name)
        writeShort(buf, 0x14)   // attrStart = 20
        writeShort(buf, 0x14)   // attrSize = 20
        writeShort(buf, attrCount)
        writeShort(buf, -1)     // idAttributeIndex
        writeShort(buf, -1)     // classAttributeIndex
        writeShort(buf, -1)     // styleAttributeIndex
        for (a in attrs) {
            writeInt(buf, a[0]) // ns
            writeInt(buf, a[1]) // name
            writeInt(buf, a[2]) // rawValue
            writeShort(buf, 8)  // typedValue.size = 8
            buf.write(0)        // typedValue.res0
            buf.write(a[3])     // typedValue.dataType
            writeInt(buf, a[4]) // typedValue.data
        }
    }

    private fun writeEndElem(buf: ByteArrayOutputStream, name: Int) {
        writeShort(buf, 0x0103) // END_ELEMENT
        writeShort(buf, 0x10)
        writeInt(buf, 24)
        writeInt(buf, 1)
        writeInt(buf, -1)
        writeInt(buf, -1)  // ns = none
        writeInt(buf, name)
    }

    private fun writeUleb128(buf: ByteArrayOutputStream, value: Int) {
        var v = value
        do {
            var b = v and 0x7F
            v = v ushr 7
            if (v != 0) b = b or 0x80
            buf.write(b)
        } while (v != 0)
    }

    private fun writeShort(buf: ByteArrayOutputStream, v: Int) {
        buf.write(v and 0xFF); buf.write((v shr 8) and 0xFF)
    }

    private fun writeInt(buf: ByteArrayOutputStream, v: Int) {
        buf.write(v and 0xFF); buf.write((v shr 8) and 0xFF)
        buf.write((v shr 16) and 0xFF); buf.write((v shr 24) and 0xFF)
    }

    // ── V1 JAR signing with Taurus keystore ──────────────────────────────────

    private fun signApkWithKeystore(src: File, dst: File) {
        val password = "Matrix@2026".toCharArray()
        val alias    = "matrix_hbc_key"

        val ksBytes = assets.open("matrix_hbc.keystore").readBytes()
        val ks = listOf("PKCS12", "JKS", "BKS").firstNotNullOf { type ->
            runCatching {
                KeyStore.getInstance(type).also { it.load(ksBytes.inputStream(), password) }
            }.getOrNull()
        }
        val privateKey = ks.getKey(alias, password) as PrivateKey
        val cert       = ks.getCertificate(alias) as X509Certificate

        val manifestStr  = buildManifest(src)
        val manifestBytes = manifestStr.toByteArray(Charsets.UTF_8)

        val sfStr   = buildSfFile(manifestStr)
        val sfBytes = sfStr.toByteArray(Charsets.UTF_8)

        val sig = Signature.getInstance("SHA256withRSA")
        sig.initSign(privateKey)
        sig.update(sfBytes)
        val sigBytes = sig.sign()

        val pkcs7 = buildPkcs7Der(cert, sigBytes)

        ZipFile(src).use { zf ->
            ZipOutputStream(BufferedOutputStream(dst.outputStream())).use { zout ->
                zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                for (entry in zf.entries()) {
                    if (entry.name.startsWith("META-INF/")) continue
                    writeZipEntry(zout, entry, zf.getInputStream(entry).readBytes())
                }
                fun addMeta(name: String, data: ByteArray) {
                    zout.putNextEntry(ZipEntry(name).apply { method = ZipEntry.DEFLATED })
                    zout.write(data)
                    zout.closeEntry()
                }
                addMeta("META-INF/MANIFEST.MF", manifestBytes)
                addMeta("META-INF/CERT.SF",     sfBytes)
                addMeta("META-INF/CERT.RSA",    pkcs7)
            }
        }
    }

    private fun buildSfFile(manifest: String): String {
        val md = MessageDigest.getInstance("SHA-256")
        val manifestBytes = manifest.toByteArray(Charsets.UTF_8)
        val sb = StringBuilder()
        sb.append("Signature-Version: 1.0\r\n")
        sb.append("Created-By: TaurusShield\r\n")
        sb.append("SHA-256-Digest-Manifest: ${b64enc(md.digest(manifestBytes))}\r\n")
        sb.append("\r\n")
        manifest.split("\r\n\r\n").drop(1).forEach { section ->
            if (section.isBlank()) return@forEach
            val sectionBytes = (section + "\r\n\r\n").toByteArray(Charsets.UTF_8)
            val name = section.lines().first().removePrefix("Name: ").trim()
            sb.append("Name: $name\r\n")
            sb.append("SHA-256-Digest: ${b64enc(md.digest(sectionBytes))}\r\n")
            sb.append("\r\n")
        }
        return sb.toString()
    }

    private fun b64enc(bytes: ByteArray): String =
        android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

    private fun buildPkcs7Der(cert: X509Certificate, sigBytes: ByteArray): ByteArray {
        val oidSha256        = byteArrayOf(0x60.toByte(), 0x86.toByte(), 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01)
        val oidSha256WithRsa = byteArrayOf(0x2A, 0x86.toByte(), 0x48, 0x86.toByte(), 0xF7.toByte(), 0x0D, 0x01, 0x01, 0x0B)
        val oidSignedData    = byteArrayOf(0x2A, 0x86.toByte(), 0x48, 0x86.toByte(), 0xF7.toByte(), 0x0D, 0x01, 0x07, 0x02)
        val oidData          = byteArrayOf(0x2A, 0x86.toByte(), 0x48, 0x86.toByte(), 0xF7.toByte(), 0x0D, 0x01, 0x07, 0x01)

        fun derLen(n: Int): ByteArray = when {
            n < 0x80  -> byteArrayOf(n.toByte())
            n < 0x100 -> byteArrayOf(0x81.toByte(), n.toByte())
            else      -> byteArrayOf(0x82.toByte(), (n shr 8).toByte(), (n and 0xFF).toByte())
        }
        fun tlv(tag: Int, data: ByteArray) = byteArrayOf(tag.toByte()) + derLen(data.size) + data
        fun seq(data: ByteArray)   = tlv(0x30, data)
        fun set(data: ByteArray)   = tlv(0x31, data)
        fun oid(b: ByteArray)      = tlv(0x06, b)
        fun octet(b: ByteArray)    = tlv(0x04, b)
        fun ctx0(data: ByteArray)  = tlv(0xA0, data)
        fun nullDer()              = byteArrayOf(0x05, 0x00)
        fun int1(v: Int): ByteArray {
            val b = byteArrayOf(v.toByte())
            return tlv(0x02, if (v.and(0x80) != 0) byteArrayOf(0x00) + b else b)
        }
        fun bigint(n: java.math.BigInteger) = tlv(0x02, n.toByteArray())

        val sha256AlgId    = seq(oid(oidSha256) + nullDer())
        val sha256RsaAlgId = seq(oid(oidSha256WithRsa) + nullDer())
        val contentInfo    = seq(oid(oidData))
        val certsCtx       = ctx0(cert.encoded)
        val issuerAndSerial = seq(cert.issuerX500Principal.encoded + bigint(cert.serialNumber))
        val signerInfo = seq(
            int1(1) +
            issuerAndSerial +
            sha256AlgId +
            sha256RsaAlgId +
            octet(sigBytes)
        )
        val signedData = seq(
            int1(1) +
            set(sha256AlgId) +
            contentInfo +
            certsCtx +
            set(signerInfo)
        )
        return seq(oid(oidSignedData) + ctx0(signedData))
    }

    private fun buildManifest(apkFile: File): String {
        val sb = StringBuilder()
        sb.append("Manifest-Version: 1.0\r\n")
        sb.append("Created-By: TaurusShield SSL Unpinner\r\n\r\n")
        val md = MessageDigest.getInstance("SHA-256")
        ZipFile(apkFile).use { zf ->
            for (entry in zf.entries().asSequence().sortedBy { it.name }) {
                if (entry.name.startsWith("META-INF/")) continue
                val bytes = zf.getInputStream(entry).readBytes()
                val digest = md.digest(bytes)
                val b64 = android.util.Base64.encodeToString(digest, android.util.Base64.NO_WRAP)
                sb.append("Name: ${entry.name}\r\n")
                sb.append("SHA-256-Digest: $b64\r\n\r\n")
            }
        }
        return sb.toString()
    }

    // ── APK ZIP alignment (resources.arsc at 4-byte boundary) ────────────────

    private fun fixApkAlignment(apkPath: String): String {
        val src = File(apkPath)
        val dst = File(src.parent, "ssl_aligned_${src.name}")
        ZipFile(src).use { zf ->
            FileOutputStream(dst).use { fos ->
                val buf = ByteArrayOutputStream()
                ZipOutputStream(buf).also { /* just used to enumerate */ }

                // We need raw ZIP output to control local file header offsets for alignment.
                // Build aligned ZIP manually.
                val entries = zf.entries().asSequence().sortedWith(
                    compareBy({ if (it.name == "resources.arsc") 0 else 1 }, { it.name })
                ).toList()

                val rawOut = CountingOutputStream(fos)
                val cdir = mutableListOf<ByteArray>()

                for (entry in entries) {
                    val data = zf.getInputStream(entry).readBytes()
                    val nameBytes = entry.name.toByteArray(Charsets.UTF_8)
                    val extraBytes = ByteArray(0)

                    val isStored = !entry.name.endsWith(".dex") &&
                        (entry.name == "resources.arsc" || !entry.name.endsWith(".xml") ||
                         entry.name.startsWith("res/"))

                    // Align stored entries to 4-byte boundary
                    val localHeaderSize = 30 + nameBytes.size + extraBytes.size
                    val currentPos = rawOut.count
                    val dataStart = currentPos + localHeaderSize

                    var paddingSize = 0
                    if (isStored) {
                        paddingSize = ((4 - (dataStart % 4)) % 4).toInt()
                    }

                    val actualExtra = ByteArray(extraBytes.size + paddingSize)
                    extraBytes.copyInto(actualExtra)

                    val (finalData, method, crc, compressedSize) = if (isStored) {
                        val crc32 = CRC32().also { it.update(data) }.value
                        listOf(data, ZipEntry.STORED, crc32, data.size.toLong())
                    } else {
                        val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, true)
                        deflater.setInput(data)
                        deflater.finish()
                        val out2 = ByteArrayOutputStream()
                        val tmp = ByteArray(8192)
                        while (!deflater.finished()) {
                            val n = deflater.deflate(tmp)
                            out2.write(tmp, 0, n)
                        }
                        deflater.end()
                        val compressed = out2.toByteArray()
                        val crc32 = CRC32().also { it.update(data) }.value
                        listOf(compressed, ZipEntry.DEFLATED, crc32, compressed.size.toLong())
                    }

                    @Suppress("UNCHECKED_CAST")
                    val fd = finalData as ByteArray
                    val meth = method as Int
                    val crcVal = crc as Long
                    val compSize = compressedSize as Long
                    val uncompSize = data.size.toLong()

                    val localOff = rawOut.count

                    // Local file header
                    writeRaw(rawOut, byteArrayOf(0x50, 0x4B, 0x03, 0x04))      // signature
                    writeRawShort(rawOut, 20)                                    // version needed
                    writeRawShort(rawOut, 0)                                     // flags
                    writeRawShort(rawOut, meth)                                  // compression
                    writeRawShort(rawOut, 0); writeRawShort(rawOut, 0)           // mod time/date
                    writeRawInt(rawOut, crcVal.toInt())                          // crc-32
                    writeRawInt(rawOut, compSize.toInt())                        // compressed size
                    writeRawInt(rawOut, uncompSize.toInt())                      // uncompressed size
                    writeRawShort(rawOut, nameBytes.size)                        // name length
                    writeRawShort(rawOut, actualExtra.size)                      // extra length
                    rawOut.write(nameBytes)
                    rawOut.write(actualExtra)
                    rawOut.write(fd)

                    // Central directory entry
                    val cdBuf = ByteArrayOutputStream()
                    writeRaw(cdBuf, byteArrayOf(0x50, 0x4B, 0x01, 0x02))
                    writeRawShort(cdBuf, 20); writeRawShort(cdBuf, 20)
                    writeRawShort(cdBuf, 0); writeRawShort(cdBuf, meth)
                    writeRawShort(cdBuf, 0); writeRawShort(cdBuf, 0)
                    writeRawInt(cdBuf, crcVal.toInt())
                    writeRawInt(cdBuf, compSize.toInt())
                    writeRawInt(cdBuf, uncompSize.toInt())
                    writeRawShort(cdBuf, nameBytes.size)
                    writeRawShort(cdBuf, 0); writeRawShort(cdBuf, 0)
                    writeRawShort(cdBuf, 0); writeRawShort(cdBuf, 0)
                    writeRawInt(cdBuf, 0)
                    writeRawInt(cdBuf, localOff.toInt())
                    cdBuf.write(nameBytes)
                    cdir.add(cdBuf.toByteArray())
                }

                val cdOffset = rawOut.count
                for (cd in cdir) rawOut.write(cd)
                val cdSize = rawOut.count - cdOffset

                // End of central directory
                writeRaw(rawOut, byteArrayOf(0x50, 0x4B, 0x05, 0x06))
                writeRawShort(rawOut, 0); writeRawShort(rawOut, 0)
                writeRawShort(rawOut, cdir.size); writeRawShort(rawOut, cdir.size)
                writeRawInt(rawOut, cdSize.toInt())
                writeRawInt(rawOut, cdOffset.toInt())
                writeRawShort(rawOut, 0)
            }
        }
        return dst.absolutePath
    }

    // ── Binary XML string readers ─────────────────────────────────────────────

    private fun readBinXmlUtf8(data: ByteArray, pos: Int): String {
        var p = pos
        var u16 = data[p].toInt() and 0xFF; p++
        if (u16 and 0x80 != 0) { u16 = ((u16 and 0x7F) shl 8) or (data[p].toInt() and 0xFF); p++ }
        var u8 = data[p].toInt() and 0xFF; p++
        if (u8 and 0x80 != 0) { u8 = ((u8 and 0x7F) shl 8) or (data[p].toInt() and 0xFF); p++ }
        return String(data, p, u8, Charsets.UTF_8)
    }

    private fun readBinXmlUtf16(data: ByteArray, pos: Int): String {
        var p = pos
        var len = (data[p].toInt() and 0xFF) or ((data[p+1].toInt() and 0xFF) shl 8); p += 2
        if (len and 0x8000 != 0) {
            len = ((len and 0x7FFF) shl 16) or ((data[p].toInt() and 0xFF) or ((data[p+1].toInt() and 0xFF) shl 8)); p += 2
        }
        return String(data, p, len * 2, Charsets.UTF_16LE)
    }

    // ── ZIP write helpers ─────────────────────────────────────────────────────

    private fun writeZipEntry(zout: ZipOutputStream, orig: ZipEntry, data: ByteArray) {
        val ne = ZipEntry(orig.name).apply { method = ZipEntry.DEFLATED }
        zout.putNextEntry(ne)
        zout.write(data)
        zout.closeEntry()
    }

    private fun writeRaw(out: java.io.OutputStream, b: ByteArray) = out.write(b)
    private fun writeRawShort(out: java.io.OutputStream, v: Int) {
        out.write(v and 0xFF); out.write((v shr 8) and 0xFF)
    }
    private fun writeRawInt(out: java.io.OutputStream, v: Int) {
        out.write(v and 0xFF); out.write((v shr 8) and 0xFF)
        out.write((v shr 16) and 0xFF); out.write((v shr 24) and 0xFF)
    }

    private inner class BufferedFileOutputStream(f: File) :
        java.io.BufferedOutputStream(FileOutputStream(f))

    private inner class CountingOutputStream(private val delegate: java.io.OutputStream) :
        java.io.OutputStream() {
        var count: Long = 0
        override fun write(b: Int) { delegate.write(b); count++ }
        override fun write(b: ByteArray, off: Int, len: Int) { delegate.write(b, off, len); count += len }
    }

    override fun onDestroy() {
        releaseWake()
        executor.shutdownNow()
        super.onDestroy()
    }
}
