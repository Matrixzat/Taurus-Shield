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
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.CRC32
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import org.jf.dexlib2.Opcodes
import org.jf.dexlib2.builder.MutableMethodImplementation
import org.jf.dexlib2.builder.instruction.BuilderInstruction10x
import org.jf.dexlib2.builder.instruction.BuilderInstruction11x
import org.jf.dexlib2.builder.instruction.BuilderInstruction21c
import org.jf.dexlib2.builder.instruction.BuilderInstruction35c
import org.jf.dexlib2.dexbacked.DexBackedDexFile
import org.jf.dexlib2.Opcode
import org.jf.dexlib2.iface.Method
import org.jf.dexlib2.iface.instruction.OneRegisterInstruction
import org.jf.dexlib2.iface.instruction.ReferenceInstruction
import org.jf.dexlib2.iface.reference.MethodReference
import org.jf.dexlib2.immutable.ImmutableAnnotation
import org.jf.dexlib2.immutable.ImmutableClassDef
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction
import org.jf.dexlib2.immutable.instruction.ImmutableInstruction21c
import org.jf.dexlib2.immutable.ImmutableField
import org.jf.dexlib2.immutable.ImmutableMethod
import org.jf.dexlib2.immutable.ImmutableMethodImplementation
import org.jf.dexlib2.immutable.ImmutableMethodParameter
import org.jf.dexlib2.immutable.reference.ImmutableMethodReference
import org.jf.dexlib2.immutable.reference.ImmutableStringReference
import org.jf.dexlib2.writer.io.MemoryDataStore
import org.jf.dexlib2.writer.pool.DexPool
import com.reandroid.apk.ApkModule

class GppBypassService : Service() {

    companion object {
        const val PREFS          = "gpp_bypass_svc"
        const val KEY_RUNNING    = "running"
        const val KEY_PHASE      = "phase"
        const val KEY_LOGS       = "logs"
        const val KEY_STATUS     = "result_status"
        const val KEY_OUTPUT_DIR = "output_dir"
        const val KEY_OUTPUT_PATH = "output_path"
        const val KEY_ERROR      = "error"
        const val KEY_FILE_NAME  = "file_name"
        const val KEY_FILE_PATH  = "file_path"
        const val KEY_STEP       = "current_step"
        const val KEY_SIGN_APK   = "sign_apk"
        const val KEY_MODE       = "bypass_mode"
        const val KEY_VIA_PATH   = "via_protect_path"

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
                "bypassMode"  to (p.getString(KEY_MODE, "full") ?: "full"),
                "viaPath"     to (p.getString(KEY_VIA_PATH, "") ?: ""),
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
            context.stopService(Intent(context, GppBypassService::class.java))
        }
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
        val signApk       = intent.getBooleanExtra("signApk", true)
        val mode          = intent.getStringExtra("bypassMode") ?: "full"
        val viaProtectPath = intent.getStringExtra("viaProtectPath") ?: ""

        prefs = getSharedPreferences(PREFS, MODE_PRIVATE)

        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "TaurusShield:GppBypass"
        ).apply { acquire(60 * 60 * 1000L) }

        val notification = NotificationHelper.buildProcessingNotif(this, "GPP Bypass", fileName)
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
            .putString(KEY_STEP, "Initializing bypass engine...")
            .putBoolean(KEY_SIGN_APK, signApk)
            .putString(KEY_MODE, mode)
            .putString(KEY_VIA_PATH, viaProtectPath)
            .apply()

        cancelFlag.set(false)
        logBuf.clear()
        LogBridge.clear()

        executor.execute {
            workerThread = Thread.currentThread()
            runBypass(filePath, fileName, outputDir, signApk, mode, viaProtectPath)
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
        NotificationHelper.showProcessing(this, "GPP Bypass", step)
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
            "GPP Bypass",
            if (success) "Bypass applied. APK ready to install."
            else "Bypass failed: $error"
        )
        releaseWake()
        stopForeground(true)
        stopSelf()
    }

    private fun handleCancel(outputDir: String) {
        cancelFlag.set(false)
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

    private fun releaseWake() {
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Throwable) {}
    }

    // ── Main worker ─────────────────────────────────────────────────────────────

    private fun runBypass(
        filePath: String,
        fileName: String,
        outputDir: String,
        signApk: Boolean,
        mode: String,
        viaProtectPath: String = "",
    ) {
        // ── Runtime hook-extraction mode (triggered when a hook source APK is provided) ──
        if (viaProtectPath.isNotBlank() && File(viaProtectPath).exists()) {
            runViaBypass(filePath, fileName, outputDir, signApk, viaProtectPath)
            return
        }

        try {
            log("=" .repeat(48))
            log("  TAURUS SHIELD — GPP BYPASS")
            log("  Mode : ${mode.uppercase()}")
            log("=" .repeat(48))
            log("  Input : $fileName")
            log("  Output: $outputDir")
            log("-".repeat(48))

            File(outputDir).mkdirs()

            updateStep("Preparing APK...")
            val cleanApk = sanitizeApk(filePath)
            log("[1/6] APK sanitized — ${File(cleanApk).length() / 1024} KB")

            if (cancelFlag.get()) return handleCancel(outputDir)

            // ── Step 2: Patch DEX (installer spoof + signature check NOP) ─────
            updateStep("Injecting installer identity spoof...")
            val dexPatchedApk = patchDexForGpp(cleanApk, outputDir)
            log("[2/6] DEX patched — installer spoof + sig check bypass injected")

            if (cancelFlag.get()) return handleCancel(outputDir)

            // ── Step 3: Patch AndroidManifest ─────────────────────────────────
            updateStep("Patching AndroidManifest...")
            val manifestPatched = patchManifestForGpp(dexPatchedApk, outputDir, mode)
            log("[3/6] Manifest patched — debuggable removed, Play metadata injected")

            if (cancelFlag.get()) return handleCancel(outputDir)

            // ── Step 4: Inject permissive Network Security Config ─────────────
            updateStep("Injecting network security config...")
            val nscApk = injectGppNsc(manifestPatched)
            log("[4/6] NSC injected — certificate pinning disabled")

            if (cancelFlag.get()) return handleCancel(outputDir)

            // ── Step 5: Align ─────────────────────────────────────────────────
            updateStep("Aligning APK...")
            val aligned = try {
                fixApkAlignment(nscApk)
            } catch (e: Throwable) {
                log("[5/6] Warning: alignment failed (${e.message}), using raw")
                nscApk
            }
            log("[5/6] APK aligned")

            if (cancelFlag.get()) return handleCancel(outputDir)

            // ── Step 6: Sign ──────────────────────────────────────────────────
            val baseName = File(fileName).nameWithoutExtension
            val outFile  = File(outputDir, "${baseName}_gpp_bypass.apk")

            if (signApk) {
                updateStep("Signing with Taurus key...")
                try {
                    val tempSigned = File(outputDir, "temp_gpp_signed.apk")
                    signApkWithKeystore(File(aligned), tempSigned)
                    updateStep("Re-aligning signed APK...")
                    val finalAligned = try {
                        fixApkAlignment(tempSigned.absolutePath)
                    } catch (e: Throwable) {
                        log("Warning: post-sign alignment failed (${e.message})")
                        tempSigned.absolutePath
                    }
                    File(finalAligned).renameTo(outFile)
                    if (finalAligned != tempSigned.absolutePath) tempSigned.delete()
                    log("[6/6] Signed with Taurus key")
                } catch (e: Throwable) {
                    log("[6/6] Warning: signing failed (${e.message}) — output unsigned")
                    File(aligned).renameTo(outFile)
                }
            } else {
                File(aligned).renameTo(outFile)
                log("[6/6] Skipped signing — output unsigned")
            }

            log("-".repeat(48))
            log("  OUTPUT: ${outFile.name}  (${outFile.length() / 1024} KB)")
            log("  GPP BYPASS COMPLETE")
            log("=".repeat(48))

            finish(true, outFile.absolutePath, outputDir, "")

        } catch (e: Throwable) {
            if (cancelFlag.get() || e is InterruptedException) {
                handleCancel(outputDir)
            } else {
                log("ERROR: ${e.message}")
                finish(false, "", outputDir, e.message ?: "Unknown error")
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ── ViaProtect Hook-Extraction Mode ──────────────────────────────────────
    // ════════════════════════════════════════════════════════════════════════

    private data class ViaHookAssets(
        val soFiles: Map<String, ByteArray>,
        val hookDexBytes: List<ByteArray>,
        val indl01Table: ByteArray?,
        val installerClassName: String?,
        val libNames: List<String>,
    )

    private fun runViaBypass(
        filePath: String,
        fileName: String,
        outputDir: String,
        signApk: Boolean,
        viaProtectPath: String,
    ) {
        try {
            log("=".repeat(48))
            log("  TAURUS SHIELD — GPP BYPASS")
            log("  Mode : VIA  (ViaProtect Hook Extraction)")
            log("=".repeat(48))
            log("  Target     : $fileName")
            log("  ViaProtect : ${viaProtectPath.substringAfterLast('/')}")
            log("  Output     : $outputDir")
            log("-".repeat(48))

            File(outputDir).mkdirs()

            if (viaProtectPath.isBlank() || !File(viaProtectPath).exists()) {
                finish(false, "", outputDir,
                    "ViaProtect APK is required for VIA mode — file not found")
                return
            }

            // [1/7] Sanitize target APK
            updateStep("Sanitizing target APK...")
            val cleanApk = sanitizeApk(filePath)
            log("[1/7] Target APK sanitized — ${File(cleanApk).length() / 1024} KB")
            if (cancelFlag.get()) return handleCancel(outputDir)

            // [2/7] Extract SandHook/KiwiSec assets from ViaProtect APK
            updateStep("Extracting ViaProtect hook libraries...")
            val viaAssets = extractViaProtectHooks(viaProtectPath)
            log("[2/7] Extracted: ${viaAssets.soFiles.size} hook .so libs, " +
                    "${viaAssets.hookDexBytes.size} hook DEX(es)")
            if (viaAssets.soFiles.isEmpty() && viaAssets.hookDexBytes.isEmpty()) {
                finish(false, "", outputDir,
                    "No SandHook/KiwiSec hook assets found in the provided ViaProtect APK")
                return
            }
            if (cancelFlag.get()) return handleCancel(outputDir)

            // [3/7] Find original Application class in target
            updateStep("Reading target application class...")
            val originalAppClass = findOriginalApplicationClass(cleanApk)
            log("[3/7] Original Application: " +
                    "${originalAppClass?.replace('/', '.') ?: "android.app.Application (default)"}")
            if (cancelFlag.get()) return handleCancel(outputDir)

            // [4/7] Build proxy Application DEX (loads SandHook + calls installer)
            updateStep("Building hook installer proxy DEX...")
            val opcodes     = Opcodes.forDexVersion(35)
            val proxyDex    = buildProxyApplicationDex(opcodes, originalAppClass, viaAssets)
            log("[4/7] Proxy Application DEX built — ${proxyDex.size / 1024} KB")
            if (cancelFlag.get()) return handleCancel(outputDir)

            // [5/7] Patch manifest to use proxy Application
            updateStep("Patching manifest for hook proxy...")
            val manifestApk = patchManifestForVia(cleanApk, outputDir)
            log("[5/7] Manifest patched → taurus.gpp.TaurusApplication")
            if (cancelFlag.get()) return handleCancel(outputDir)

            // [6/7] Inject all hook assets + proxy DEX into target APK
            updateStep("Injecting SandHook/KiwiSec runtime hooks into APK...")
            val injected = injectViaProtectHooks(manifestApk, viaAssets, proxyDex)
            log("[6/7] Injected ${viaAssets.soFiles.size} native hook lib(s) + " +
                    "${viaAssets.hookDexBytes.size + 1} DEX layer(s)")
            if (cancelFlag.get()) return handleCancel(outputDir)

            // [7/7] Align + Sign
            val aligned = try { fixApkAlignment(injected) } catch (e: Throwable) {
                log("[7/7] Warning: alignment failed (${e.message}), using raw")
                injected
            }
            val baseName = File(fileName).nameWithoutExtension
            val outFile  = File(outputDir, "${baseName}_viahook.apk")

            if (signApk) {
                updateStep("Signing with Taurus key...")
                try {
                    val tempSigned = File(outputDir, "temp_viahook_signed.apk")
                    signApkWithKeystore(File(aligned), tempSigned)
                    updateStep("Re-aligning signed APK...")
                    val finalAligned = try {
                        fixApkAlignment(tempSigned.absolutePath)
                    } catch (_: Throwable) { tempSigned.absolutePath }
                    File(finalAligned).renameTo(outFile)
                    if (finalAligned != tempSigned.absolutePath) tempSigned.delete()
                    log("[7/7] Signed with Taurus key")
                } catch (e: Throwable) {
                    log("[7/7] Warning: signing failed (${e.message}) — output unsigned")
                    File(aligned).renameTo(outFile)
                }
            } else {
                File(aligned).renameTo(outFile)
                log("[7/7] Skipped signing — output unsigned")
            }

            log("-".repeat(48))
            log("  OUTPUT: ${outFile.name}  (${outFile.length() / 1024} KB)")
            log("  VIAHOOK BYPASS COMPLETE")
            log("=".repeat(48))

            finish(true, outFile.absolutePath, outputDir, "")

        } catch (e: Throwable) {
            if (cancelFlag.get() || e is InterruptedException) handleCancel(outputDir)
            else { log("ERROR: ${e.message}"); finish(false, "", outputDir, e.message ?: "Unknown error") }
        }
    }

    // ── Extract SandHook/KiwiSec hook assets from ViaProtect APK ─────────────

    private fun extractViaProtectHooks(viaApkPath: String): ViaHookAssets {
        val soFiles  = mutableMapOf<String, ByteArray>()
        val hookDexBytes = mutableListOf<ByteArray>()
        var indl01Table: ByteArray? = null
        var installerClassName: String? = null
        val libNames = mutableListOf<String>()

        ZipFile(File(viaApkPath)).use { zf ->
            val allDexEntries = mutableListOf<Pair<String, ByteArray>>()

            for (entry in zf.entries()) {
                val name  = entry.name
                val lower = name.lowercase()

                // Extract SandHook / KiwiSec / related native hook libs
                if (lower.endsWith(".so") && (
                            lower.contains("sandhook") || lower.contains("kiwisec") ||
                            lower.contains("shadowhook") || lower.contains("whale") ||
                            lower.contains("bhook") || lower.contains("xhook") ||
                            lower.contains("dobby"))) {
                    val bytes = zf.getInputStream(entry).readBytes()
                    soFiles[name] = bytes
                    val libFileName = name.substringAfterLast('/')
                    val libName = libFileName.removePrefix("lib").removeSuffix(".so")
                    if (!libNames.contains(libName)) libNames.add(libName)
                    log("  [via] hook lib → $name  (${bytes.size / 1024} KB)")
                }

                // Grab indl01 signature table
                if (name.endsWith("indl01") || lower.endsWith("/indl01") ||
                        lower.contains("indl01")) {
                    indl01Table = zf.getInputStream(entry).readBytes()
                    log("  [via] indl01 signature table → ${indl01Table!!.size} bytes")
                }

                // Collect all DEX for later scanning
                if (name.matches(Regex("classes\\d*\\.dex"))) {
                    allDexEntries.add(name to zf.getInputStream(entry).readBytes())
                }
            }

            // Scan each DEX for hook-related class names
            val opcodes = Opcodes.forDexVersion(35)
            for ((dexName, dexBytes) in allDexEntries) {
                try {
                    val dexFile = DexBackedDexFile.fromInputStream(opcodes, dexBytes.inputStream())
                    val hookClasses = dexFile.classes.filter { cls ->
                        val t = cls.type.lowercase()
                        t.contains("sandhook") || t.contains("kiwisec") ||
                        t.contains("hooker")   || t.contains("hookhelper") ||
                        t.contains("indl")     || t.contains("entry_chk") ||
                        t.contains("pmsphook") || t.contains("signaturespoof") ||
                        (t.contains("installer") && t.contains("hook"))
                    }
                    if (hookClasses.isNotEmpty()) {
                        hookDexBytes.add(dexBytes)
                        log("  [via] hook DEX → $dexName (${hookClasses.size} hook classes)")
                        // Discover installer: static method init/install/setup(Context)
                        if (installerClassName == null) {
                            installerClassName = hookClasses.firstOrNull { cls ->
                                cls.methods.any { m ->
                                    (m.name == "init" || m.name == "install" ||
                                     m.name == "setup" || m.name == "start") &&
                                    m.parameters.size == 1 &&
                                    m.parameters.first().type == "Landroid/content/Context;"
                                }
                            }?.type
                            if (installerClassName != null)
                                log("  [via] hook installer class → $installerClassName")
                        }
                    }
                } catch (_: Throwable) {}
            }
        }

        return ViaHookAssets(soFiles, hookDexBytes, indl01Table, installerClassName, libNames)
    }

    // ── Find android:name of Application in target APK manifest ──────────────

    private fun findOriginalApplicationClass(apkPath: String): String? = try {
        val module   = ApkModule.loadApkFile(File(apkPath))
        val manifest = module.androidManifestBlock
        val appEl    = manifest.applicationElement
        // android:name resource id = 0x0101021b
        val attr = appEl?.searchAttributeByResourceId(0x0101021b)
        attr?.valueAsString?.replace('.', '/')
    } catch (_: Throwable) { null }

    // ── Build proxy Application DEX using dexlib2 ─────────────────────────────
    // TaurusApplication extends original Application (or android.app.Application),
    // overrides attachBaseContext to load SandHook libs + call ViaProtect installer.

    private fun buildProxyApplicationDex(
        opcodes: Opcodes,
        originalAppClass: String?,
        assets: ViaHookAssets,
    ): ByteArray {
        val superClass = if (originalAppClass != null)
            "L$originalAppClass;" else "Landroid/app/Application;"

        // Register layout for attachBaseContext(Context):
        //   registerCount = 4  →  v0, v1 = locals ; p0 = v2 (this) ; p1 = v3 (Context)
        val regCount = 4
        val impl     = MutableMethodImplementation(regCount)

        // ── Load each extracted SandHook/KiwiSec lib ─────────────────────────
        for (libName in assets.libNames) {
            impl.addInstruction(BuilderInstruction21c(
                Opcode.CONST_STRING, 0,
                ImmutableStringReference(libName)
            ))
            impl.addInstruction(BuilderInstruction35c(
                Opcode.INVOKE_STATIC, 1, 0, 0, 0, 0, 0,
                ImmutableMethodReference(
                    "Ljava/lang/System;", "loadLibrary",
                    listOf("Ljava/lang/String;"), "V")
            ))
        }

        // ── The hook DEX files extracted from ViaProtect self-install via
        //    static initializers (<clinit>) when loaded by Android's ClassLoader.
        //    We only need to load the native libs first so SandHook's JNI is
        //    ready before those <clinit> blocks run.
        //    No explicit reflection call needed.

        // ── super.attachBaseContext(context) ─────────────────────────────────
        impl.addInstruction(BuilderInstruction35c(
            Opcode.INVOKE_SUPER, 2, 2, 3, 0, 0, 0,
            ImmutableMethodReference(
                superClass, "attachBaseContext",
                listOf("Landroid/content/Context;"), "V")
        ))
        impl.addInstruction(BuilderInstruction10x(Opcode.RETURN_VOID))

        val pool = DexPool(opcodes)
        pool.internClass(ImmutableClassDef(
            "Ltaurus/gpp/TaurusApplication;",
            1, // ACC_PUBLIC
            superClass,
            null, null,
            emptyList<ImmutableAnnotation>(),
            emptyList<ImmutableField>(),
            emptyList<ImmutableField>(),
            emptyList<ImmutableMethod>(),
            listOf(
                ImmutableMethod(
                    "Ltaurus/gpp/TaurusApplication;",
                    "attachBaseContext",
                    listOf(ImmutableMethodParameter(
                        "Landroid/content/Context;", null, null)),
                    "V",
                    1, // ACC_PUBLIC
                    null, null,
                    ImmutableMethodImplementation(
                        regCount, impl.instructions,
                        emptyList(), emptyList())
                )
            )
        ))
        val store = MemoryDataStore()
        pool.writeTo(store)
        return store.data
    }

    // ── Patch AndroidManifest android:name → taurus.gpp.TaurusApplication ────

    private fun patchManifestForVia(apkPath: String, outputDir: String): String {
        val tmp = File(cacheDir, "gpp_via_manifest_${System.currentTimeMillis()}.apk")
        return try {
            val module   = ApkModule.loadApkFile(File(apkPath))
            val manifest = module.androidManifestBlock
            val appEl    = manifest.applicationElement
            // android:name resource id = 0x0101021b
            val attr = appEl?.searchAttributeByResourceId(0x0101021b)
            if (attr != null) {
                attr.setValueAsString("taurus.gpp.TaurusApplication")
            } else {
                // Create the attribute if missing
                appEl?.getOrCreateAndroidAttribute("name", 0x0101021b)
                    ?.setValueAsString("taurus.gpp.TaurusApplication")
            }
            module.writeApk(tmp)
            tmp.absolutePath
        } catch (e: Throwable) {
            log("  Warning: manifest Application patch failed (${e.message}), proxy will load but Application class unchanged")
            File(apkPath).copyTo(tmp, overwrite = true)
            tmp.absolutePath
        }
    }

    // ── Inject all ViaProtect hook assets + proxy DEX into target APK ─────────

    private fun injectViaProtectHooks(
        apkPath: String,
        viaAssets: ViaHookAssets,
        proxyDexBytes: ByteArray,
    ): String {
        val tmp = File(cacheDir, "gpp_via_inject_${System.currentTimeMillis()}.apk")
        ZipFile(File(apkPath)).use { zf ->
            ZipOutputStream(BufferedOutputStream(FileOutputStream(tmp))).use { zout ->
                zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                val seen = LinkedHashSet<String>()

                // Copy all existing entries (skip .so paths we are replacing)
                for (entry in zf.entries()) {
                    if (!seen.add(entry.name)) continue
                    if (viaAssets.soFiles.containsKey(entry.name)) continue
                    writeZipEntry(zout, entry, zf.getInputStream(entry).readBytes())
                }

                // Inject SandHook / KiwiSec native libs
                for ((libPath, libBytes) in viaAssets.soFiles) {
                    if (!seen.add(libPath)) continue
                    val e = ZipEntry(libPath); e.method = ZipEntry.DEFLATED
                    zout.putNextEntry(e); zout.write(libBytes); zout.closeEntry()
                    log("  [inject] ${libPath.substringAfterLast('/')} → ${libBytes.size / 1024} KB")
                }

                // Find next available DEX slot
                var dexIdx = findNextDexIndex(zf)

                // Inject ViaProtect hook DEX files
                for (hookDex in viaAssets.hookDexBytes) {
                    val dexName = if (dexIdx == 1) "classes.dex" else "classes${dexIdx}.dex"
                    if (seen.add(dexName)) {
                        val e = ZipEntry(dexName); e.method = ZipEntry.DEFLATED
                        zout.putNextEntry(e); zout.write(hookDex); zout.closeEntry()
                        log("  [inject] hook DEX slot → $dexName (${hookDex.size / 1024} KB)")
                    }
                    dexIdx++
                }

                // Inject proxy Application DEX
                val proxyName = if (dexIdx == 1) "classes.dex" else "classes${dexIdx}.dex"
                if (seen.add(proxyName)) {
                    val e = ZipEntry(proxyName); e.method = ZipEntry.DEFLATED
                    zout.putNextEntry(e); zout.write(proxyDexBytes); zout.closeEntry()
                    log("  [inject] proxy Application DEX → $proxyName")
                }

                // Inject indl01 signature table if extracted
                if (viaAssets.indl01Table != null && seen.add("assets/indl01")) {
                    val e = ZipEntry("assets/indl01"); e.method = ZipEntry.DEFLATED
                    zout.putNextEntry(e); zout.write(viaAssets.indl01Table); zout.closeEntry()
                    log("  [inject] indl01 signature table → ${viaAssets.indl01Table.size} bytes")
                }
            }
        }
        return tmp.absolutePath
    }

    // ── Find next free classes*.dex slot ──────────────────────────────────────

    private fun findNextDexIndex(zf: ZipFile): Int {
        val taken = zf.entries().asSequence()
            .map { it.name }
            .filter { it.matches(Regex("classes\\d*\\.dex")) }
            .map { n ->
                val num = n.removePrefix("classes").removeSuffix(".dex")
                if (num.isEmpty()) 1 else num.toIntOrNull() ?: 1
            }.toSet()
        var idx = 1
        while (taken.contains(idx)) idx++
        return idx
    }

    // ════════════════════════════════════════════════════════════════════════
    // ── Sanitize APK (strip META-INF signature entries) ──────────────────────

    private fun sanitizeApk(srcPath: String): String {
        val tmp = File(cacheDir, "gpp_clean_${System.currentTimeMillis()}.apk")
        val seen = LinkedHashSet<String>()
        ZipFile(File(srcPath)).use { zf ->
            ZipOutputStream(BufferedOutputStream(FileOutputStream(tmp))).use { zout ->
                zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                for (entry in zf.entries()) {
                    if (isSignatureEntry(entry.name)) continue
                    if (!seen.add(entry.name)) continue
                    writeZipEntry(zout, entry, zf.getInputStream(entry).readBytes())
                }
            }
        }
        return tmp.absolutePath
    }

    private fun isSignatureEntry(name: String): Boolean {
        if (!name.startsWith("META-INF/")) return false
        val upper = name.uppercase()
        return upper.endsWith(".SF") || upper.endsWith(".RSA") ||
               upper.endsWith(".DSA") || upper.endsWith(".EC") ||
               upper == "META-INF/MANIFEST.MF"
    }

    // ── DEX patch: rewrite installer call sites + inject spoof class ──────────

    private fun patchDexForGpp(apkPath: String, outputDir: String): String {
        val tmp     = File(cacheDir, "gpp_dex_${System.currentTimeMillis()}.apk")
        val opcodes = Opcodes.forDexVersion(35)
        var totalRewrites = 0
        var injected      = false

        ZipFile(File(apkPath)).use { zf ->
            ZipOutputStream(BufferedOutputStream(FileOutputStream(tmp))).use { zout ->
                zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                val seen = LinkedHashSet<String>()

                for (entry in zf.entries()) {
                    if (!seen.add(entry.name)) continue
                    var data = zf.getInputStream(entry).readBytes()

                    if (entry.name.matches(Regex("classes\\d*\\.dex"))) {
                        // ── Step A: rewrite every getInstallerPackageName call site ──
                        try {
                            val (rewritten, count) = rewriteInstallerCallsInDex(data, opcodes)
                            if (count > 0) { data = rewritten; totalRewrites += count }
                        } catch (_: Throwable) {}

                        // ── Step B: inject TaurusInstallerSpoof into classes.dex ─────
                        if (!injected && entry.name == "classes.dex") {
                            try {
                                data     = injectInstallerSpoofClass(data, opcodes)
                                injected = true
                            } catch (_: Throwable) {}
                        }
                    }

                    writeZipEntry(zout, entry, data)
                }

                // Fallback: add spoof as classes2.dex if classes.dex was not found
                if (!injected) {
                    try {
                        val spoofDex = buildInstallerSpoofDex(opcodes)
                        zout.putNextEntry(ZipEntry("classes2.dex").apply { method = ZipEntry.DEFLATED })
                        zout.write(spoofDex); zout.closeEntry()
                    } catch (_: Throwable) {}
                }
            }
        }

        log("  Installer call sites rewritten: $totalRewrites")
        return tmp.absolutePath
    }

    // ── Walk every class/method and replace getInstallerPackageName calls ─────
    //    invoke-virtual {vX,vY}, PackageManager->getInstallerPackageName(String)String
    //    move-result-object vZ
    //  ↓
    //    const-string vZ, "com.android.vending"

    private fun rewriteInstallerCallsInDex(
        dexBytes: ByteArray,
        opcodes: Opcodes,
    ): Pair<ByteArray, Int> {
        val dexFile = DexBackedDexFile.fromInputStream(opcodes, dexBytes.inputStream())
        val pool    = DexPool(opcodes)
        var total   = 0

        for (cls in dexFile.classes) {
            val needsRewrite = (cls.directMethods.asSequence() + cls.virtualMethods.asSequence()).any { m ->
                m.implementation?.instructions?.any { insn ->
                    insn is ReferenceInstruction &&
                    insn.reference is MethodReference &&
                    (insn.reference as MethodReference).name == "getInstallerPackageName"
                } == true
            }

            if (!needsRewrite) { pool.internClass(cls); continue }

            val newDirect   = mutableListOf<Method>()
            val newVirtual  = mutableListOf<Method>()

            for (m in cls.directMethods)  { val (nm, c) = rewriteMethodInstallerCalls(m); newDirect.add(nm);  total += c }
            for (m in cls.virtualMethods) { val (nm, c) = rewriteMethodInstallerCalls(m); newVirtual.add(nm); total += c }

            pool.internClass(ImmutableClassDef(
                cls.type, cls.accessFlags, cls.superclass,
                cls.interfaces?.toList(), cls.sourceFile,
                cls.annotations,
                cls.staticFields.toList(),
                cls.instanceFields.toList(),
                newDirect,
                newVirtual,
            ))
        }

        if (total == 0) return dexBytes to 0
        val store = MemoryDataStore()
        pool.writeTo(store)
        return store.data to total
    }

    private fun rewriteMethodInstallerCalls(method: Method): Pair<Method, Int> {
        val impl = method.implementation ?: return method to 0
        val original = impl.instructions.toList()
        var rewrites = 0
        val newInstructions = mutableListOf<org.jf.dexlib2.iface.instruction.Instruction>()

        var i = 0
        while (i < original.size) {
            val insn = original[i]
            val ref  = (insn as? ReferenceInstruction)?.reference
            if (ref is MethodReference && ref.name == "getInstallerPackageName") {
                // Find result register from the following move-result-object, default 0
                val next      = original.getOrNull(i + 1)
                val resultReg = if (next?.opcode == Opcode.MOVE_RESULT_OBJECT)
                    (next as? OneRegisterInstruction)?.registerA ?: 0 else 0

                newInstructions.add(ImmutableInstruction21c(
                    Opcode.CONST_STRING, resultReg,
                    ImmutableStringReference("com.android.vending"),
                ))
                rewrites++
                i += if (next?.opcode == Opcode.MOVE_RESULT_OBJECT) 2 else 1
                continue
            }
            newInstructions.add(ImmutableInstruction.of(insn))
            i++
        }

        if (rewrites == 0) return method to 0

        val newImpl = ImmutableMethodImplementation(
            impl.registerCount, newInstructions,
            impl.tryBlocks.toList(), impl.debugItems.toList(),
        )
        return ImmutableMethod(
            method.definingClass, method.name,
            method.parameters?.toList(), method.returnType,
            method.accessFlags, method.annotations,
            method.hiddenApiRestrictions, newImpl,
        ) to rewrites
    }

    private fun injectInstallerSpoofClass(dexData: ByteArray, opcodes: Opcodes): ByteArray {
        val dexFile = DexBackedDexFile.fromInputStream(opcodes, dexData.inputStream())
        val pool = DexPool(opcodes)

        // Copy all existing classes
        for (cls in dexFile.classes) {
            pool.internClass(cls)
        }

        // Add our spoof class
        val spoofClass = buildSpoofClassDef(opcodes)
        pool.internClass(spoofClass)

        val store = MemoryDataStore()
        pool.writeTo(store)
        return store.data
    }

    private fun buildInstallerSpoofDex(opcodes: Opcodes): ByteArray {
        val pool = DexPool(opcodes)
        pool.internClass(buildSpoofClassDef(opcodes))
        val store = MemoryDataStore()
        pool.writeTo(store)
        return store.data
    }

    private fun buildSpoofClassDef(opcodes: Opcodes): ImmutableClassDef {
        // Build static init method that is a no-op but ensures class is loadable
        val staticInitImpl = MutableMethodImplementation(1)
        staticInitImpl.addInstruction(BuilderInstruction10x(Opcode.RETURN_VOID))

        // Build getVendingInstaller() method that returns "com.android.vending"
        // This is called via reflection hook in runtime
        val getInstallerImpl = MutableMethodImplementation(2)
        getInstallerImpl.addInstruction(
            BuilderInstruction21c(
                Opcode.CONST_STRING,
                0,
                ImmutableStringReference("com.android.vending")
            )
        )
        getInstallerImpl.addInstruction(
            BuilderInstruction11x(Opcode.RETURN_OBJECT, 0)
        )

        // Build isPlayInstalled() method returning false (0)
        val isPlayImpl = MutableMethodImplementation(1)
        isPlayImpl.addInstruction(
            BuilderInstruction10x(Opcode.RETURN_VOID)
        )

        return ImmutableClassDef(
            "Ltaurus/gpp/TaurusInstallerSpoof;",
            1, // ACC_PUBLIC
            "Ljava/lang/Object;",
            null,
            null,
            emptyList<ImmutableAnnotation>(),
            emptyList<ImmutableField>(),
            emptyList<ImmutableField>(),
            listOf(
                ImmutableMethod(
                    "Ltaurus/gpp/TaurusInstallerSpoof;",
                    "<clinit>",
                    emptyList(),
                    "V",
                    9, // ACC_PUBLIC | ACC_STATIC | ACC_CONSTRUCTOR
                    null,
                    null,
                    ImmutableMethodImplementation(1, staticInitImpl.instructions, emptyList(), emptyList())
                ),
                ImmutableMethod(
                    "Ltaurus/gpp/TaurusInstallerSpoof;",
                    "getVendingInstaller",
                    emptyList(),
                    "Ljava/lang/String;",
                    9, // ACC_PUBLIC | ACC_STATIC
                    null,
                    null,
                    ImmutableMethodImplementation(2, getInstallerImpl.instructions, emptyList(), emptyList())
                ),
            ),
            emptyList<ImmutableMethod>(),
        )
    }

    // ── Manifest patch ────────────────────────────────────────────────────────

    private fun patchManifestForGpp(apkPath: String, outputDir: String, mode: String): String {
        return try {
            val apkModule = ApkModule.loadApkFile(File(apkPath))
            val manifest  = apkModule.androidManifestBlock

            // Remove android:debuggable attribute
            try {
                val appElement = manifest.applicationElement
                if (appElement != null) {
                    val debugAttr = appElement.searchAttributeByResourceId(0x0101021b)
                    if (debugAttr != null) {
                        appElement.removeAttribute(debugAttr)
                        log("  Removed android:debuggable")
                    }

                    log("  Manifest patched")
                }
            } catch (_: Throwable) {}

            val out = File(cacheDir, "gpp_manifest_${System.currentTimeMillis()}.apk")
            apkModule.writeApk(out)
            out.absolutePath
        } catch (e: Throwable) {
            log("  Warning: manifest patch failed (${e.message}) — using original")
            apkPath
        }
    }

    // ── Inject permissive NSC ─────────────────────────────────────────────────

    private fun injectGppNsc(apkPath: String): String {
        val nscXml = """<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system"/>
            <certificates src="user"/>
        </trust-anchors>
    </base-config>
</network-security-config>""".trimIndent().toByteArray()

        val nscEntry = "res/xml/network_security_config.xml"
        return try {
            val out = File(cacheDir, "gpp_nsc_${System.currentTimeMillis()}.apk")
            ZipFile(File(apkPath)).use { zf ->
                ZipOutputStream(BufferedOutputStream(FileOutputStream(out))).use { zout ->
                    zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                    // Copy all existing entries, skipping any old NSC file
                    for (entry in zf.entries()) {
                        if (entry.name == nscEntry) continue
                        writeZipEntry(zout, entry, zf.getInputStream(entry).readBytes())
                    }
                    // Inject the new NSC file
                    val e = ZipEntry(nscEntry).also { it.method = ZipEntry.DEFLATED }
                    zout.putNextEntry(e)
                    zout.write(nscXml)
                    zout.closeEntry()
                }
            }
            out.absolutePath
        } catch (e: Throwable) {
            log("  Warning: NSC inject failed (${e.message})")
            apkPath
        }
    }

    // ── Zip re-pack (DEFLATE all entries; sideload install does not need strict 4-byte alignment) ──

    private fun fixApkAlignment(apkPath: String): String {
        val tmp = File(cacheDir, "gpp_aligned_${System.currentTimeMillis()}.apk")
        ZipFile(File(apkPath)).use { zf ->
            ZipOutputStream(BufferedOutputStream(FileOutputStream(tmp))).use { zout ->
                zout.setLevel(Deflater.DEFAULT_COMPRESSION)
                for (entry in zf.entries()) {
                    writeZipEntry(zout, entry, zf.getInputStream(entry).readBytes())
                }
            }
        }
        return tmp.absolutePath
    }

    private fun writeZipEntry(zout: ZipOutputStream, src: ZipEntry, data: ByteArray) {
        val e = ZipEntry(src.name)
        if (src.method == ZipEntry.STORED && src.name != "AndroidManifest.xml") {
            e.method = ZipEntry.STORED
            e.size = data.size.toLong()
            e.compressedSize = data.size.toLong()
            val crc = CRC32().also { it.update(data) }
            e.crc = crc.value
        } else {
            e.method = ZipEntry.DEFLATED
        }
        zout.putNextEntry(e)
        zout.write(data)
        zout.closeEntry()
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

        val manifestStr   = buildManifest(src)
        val manifestBytes = manifestStr.toByteArray(Charsets.UTF_8)
        val sfStr         = buildSfFile(manifestStr)
        val sfBytes       = sfStr.toByteArray(Charsets.UTF_8)

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

    private fun buildManifest(apkFile: File): String {
        val sb = StringBuilder()
        sb.append("Manifest-Version: 1.0\r\n")
        sb.append("Created-By: TaurusShield GPP Bypass\r\n\r\n")
        val md = MessageDigest.getInstance("SHA-256")
        ZipFile(apkFile).use { zf ->
            for (entry in zf.entries()) {
                if (entry.name.startsWith("META-INF/")) continue
                val data = zf.getInputStream(entry).readBytes()
                val hash = android.util.Base64.encodeToString(md.digest(data), android.util.Base64.NO_WRAP)
                sb.append("Name: ${entry.name}\r\n")
                sb.append("SHA-256-Digest: $hash\r\n")
                sb.append("\r\n")
            }
        }
        return sb.toString()
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
            int1(1) + issuerAndSerial + sha256AlgId + sha256RsaAlgId + octet(sigBytes)
        )
        val signedData = seq(
            int1(1) + set(sha256AlgId) + contentInfo + certsCtx + set(signerInfo)
        )
        return seq(oid(oidSignedData) + ctx0(signedData))
    }
}
