import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/hbc_channel.dart';
import '../utils/storage_helper.dart';
import '../utils/permission_helper.dart';

const _kAkAccent      = Color(0xFF8B5CF6);
const _kAkAccentLight = Color(0xFFC4B5FD);

class AntiDialogScreen extends StatefulWidget {
  const AntiDialogScreen({super.key});
  @override
  State<AntiDialogScreen> createState() => _AntiDialogScreenState();
}

class _AntiDialogScreenState extends State<AntiDialogScreen>
    with TickerProviderStateMixin {
  String? _selectedFilePath;
  String? _selectedFileName;
  bool    _isProcessing     = false;
  bool    _logVisible       = false;
  String  _logs             = '';
  String? _outputDir;
  int     _downloadProgress = -1;
  bool    _autoScroll       = true;
  String? _fileStatus;
  bool    _fileValid        = false;
  bool    _signApk          = true;
  String  _mainActivity     = '';
  StreamSubscription<String>? _streamSub;
  final Stopwatch _stopwatch  = Stopwatch();
  Timer?  _tickTimer;
  String  _elapsed           = '00:00';
  Timer?  _pollTimer;
  final ScrollController _logScrollCtrl  = ScrollController();
  final ScrollController _pageScrollCtrl = ScrollController();
  final TextEditingController _activityCtrl = TextEditingController();

  late final AnimationController _pulseCtrl;
  late final AnimationController _orbitCtrl;
  late final AnimationController _logCtrl;
  late final Animation<double>   _pulseAnim;
  late final Animation<double>   _logFade;

  static const _accent      = _kAkAccent;
  static const _accentLight = _kAkAccentLight;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _orbitCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 5000),
    )..repeat();

    _logCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 400),
    );

    _pulseAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _logFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logCtrl, curve: Curves.easeOut),
    );

    _checkCloudState();
  }

  Future<void> _checkCloudState() async {
    try {
      final state     = await HbcChannel.antiKillerCloudState();
      final running   = state['running'] == true;
      final status    = (state['status'] as String?) ?? '';
      final logs      = (state['logs']   as String?) ?? '';
      final filePath  = (state['filePath']  as String?) ?? '';
      final outputDir = (state['outputDir'] as String?) ?? '';
      final mainAct   = (state['mainActivity'] as String?) ?? '';

      if (running && mounted) {
        setState(() {
          _isProcessing     = true;
          _logVisible       = true;
          _logs             = logs;
          _selectedFilePath = filePath.isNotEmpty ? filePath : _selectedFilePath;
          _selectedFileName = filePath.isNotEmpty ? filePath.split('/').last : _selectedFileName;
          if (mainAct.isNotEmpty) {
            _mainActivity = mainAct;
            _activityCtrl.text = mainAct;
          }
        });
        _logCtrl.forward(from: 0);
        if (!_stopwatch.isRunning) _startTimer();
        _startPolling();
      } else if (status == 'success' && mounted) {
        setState(() {
          _isProcessing = false;
          _logVisible   = true;
          _logs         = logs;
          _outputDir    = outputDir.isNotEmpty ? outputDir : null;
          _selectedFilePath = filePath.isNotEmpty ? filePath : _selectedFilePath;
          _selectedFileName = filePath.isNotEmpty ? filePath.split('/').last : _selectedFileName;
        });
        _logCtrl.forward(from: 0);
        _showSnack('Patch complete', icon: Icons.check_circle_rounded, color: const Color(0xFF22c55e));
      } else if (status == 'cancelled' && mounted) {
        setState(() { _isProcessing = false; _logVisible = true; _logs = logs; });
        _logCtrl.forward(from: 0);
        _showSnack('Operation cancelled', icon: Icons.cancel_outlined, color: const Color(0xFFf59e0b));
      } else if (status == 'error' && logs.isNotEmpty && mounted) {
        final error = (state['error'] as String?) ?? 'Operation failed';
        setState(() { _isProcessing = false; _logVisible = true; _logs = logs; });
        _logCtrl.forward(from: 0);
        _showSnack(error, icon: Icons.error_rounded, color: _accent);
      }
    } catch (_) {}
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _streamSub?.cancel();

    _streamSub = HbcChannel.logStream.listen((line) {
      if (!mounted) return;
      if (line.startsWith('DOWNLOAD_PROGRESS:')) {
        final pct = int.tryParse(line.substring('DOWNLOAD_PROGRESS:'.length)) ?? -1;
        setState(() { _downloadProgress = pct; });
        return;
      }
      if (line == '__TAURUS_DONE__') {
        _pollTimer?.cancel();
        _checkCloudState();
        return;
      }
      setState(() { _logs += '$line\n'; });
      if (_autoScroll) _scrollLogToBottom();
    });

    int consecutiveErrors = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      try {
        final state     = await HbcChannel.antiKillerCloudState();
        final running   = state['running'] == true;
        final status    = (state['status'] as String?) ?? '';
        final logs      = (state['logs']   as String?) ?? '';
        final outputDir = (state['outputDir'] as String?) ?? '';
        consecutiveErrors = 0;

        if (logs.isNotEmpty && mounted) {
          setState(() { _logs = logs; });
          if (_autoScroll) _scrollLogToBottom();
        }

        if (!running) {
          _pollTimer?.cancel();
          _streamSub?.cancel();
          final success   = status == 'success';
          final cancelled = status == 'cancelled';
          final totalTime = _stopTimer();

          if (mounted) {
            setState(() {
              _isProcessing     = false;
              _logs             = logs;
              _outputDir        = outputDir.isNotEmpty ? outputDir : null;
              _downloadProgress = -1;
              _logs += '\n${cancelled ? "Cancelled" : success ? "Completed" : "Failed"} in $totalTime\n';
            });
            _showSnack(
              cancelled ? 'Operation cancelled' : success ? 'Patch complete — $totalTime' : 'Operation failed',
              icon: success && !cancelled ? Icons.check_circle_rounded : (cancelled ? Icons.cancel_outlined : Icons.error_rounded),
              color: success && !cancelled ? const Color(0xFF22c55e) : (cancelled ? const Color(0xFFf59e0b) : _accent),
            );
          }
          return;
        }
      } catch (_) {
        consecutiveErrors++;
        if (consecutiveErrors >= 5 && mounted) {
          _pollTimer?.cancel();
          _streamSub?.cancel();
          _stopTimer();
          setState(() { _isProcessing = false; _downloadProgress = -1; });
          _showSnack('Connection lost', icon: Icons.error_rounded, color: _accent);
        }
      }
    });
  }

  void _startTimer() {
    _stopwatch.reset(); _stopwatch.start(); _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final e = _stopwatch.elapsed;
      setState(() {
        _elapsed = '${e.inMinutes.toString().padLeft(2, '0')}:'
            '${(e.inSeconds % 60).toString().padLeft(2, '0')}';
      });
    });
  }

  String _stopTimer() {
    _tickTimer?.cancel(); _stopwatch.stop();
    final e = _stopwatch.elapsed;
    final t = e.inSeconds < 60 ? '${e.inSeconds}s' : '${e.inMinutes}m ${e.inSeconds % 60}s';
    setState(() { _elapsed = '00:00'; });
    return t;
  }

  void _scrollLogToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollCtrl.hasClients) {
        _logScrollCtrl.animateTo(
          _logScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnack(String msg, {required IconData icon, required Color color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(msg, style: const TextStyle(color: Colors.white))),
      ]),
      backgroundColor: const Color(0xFF0d0820),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withOpacity(0.4)),
      ),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ));
  }

  Future<void> _pickFile() async {
    final hasPermission = await PermissionHelper.ensureStorage(context, accent: _accent);
    if (!hasPermission) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.first;
    final path   = picked.path;
    if (path == null) return;

    final file   = File(path);
    final sizeMb = file.lengthSync() / 1048576.0;

    if (sizeMb > 300) {
      setState(() {
        _selectedFilePath = path;
        _selectedFileName = picked.name;
        _fileStatus  = 'File too large (${sizeMb.toStringAsFixed(1)} MB) — 300 MB limit';
        _fileValid   = false;
      });
      return;
    }

    setState(() {
      _selectedFilePath = path;
      _selectedFileName = picked.name;
      _fileStatus       = 'APK ready — ${sizeMb.toStringAsFixed(1)} MB';
      _fileValid        = true;
    });
  }

  Future<void> _runOperation() async {
    if (!_fileValid || _selectedFilePath == null) return;

    final hasPermission = await PermissionHelper.ensureStorage(context, accent: _accent);
    if (!hasPermission) return;

    final outputDir = await StorageHelper.buildOutputDir(prefix: 'anti-killer');

    setState(() {
      _isProcessing     = true;
      _logVisible       = true;
      _logs             = '';
      _outputDir        = null;
      _downloadProgress = -1;
    });
    _logCtrl.forward(from: 0);
    _startTimer();

    try {
      final result = await HbcChannel.antiKillerAnalyze(
        filePath:     _selectedFilePath!,
        fileName:     _selectedFileName ?? _selectedFilePath!.split('/').last,
        outputDir:    outputDir,
        mainActivity: _mainActivity.trim(),
        signApk:      _signApk,
      );

      if (result['started'] != true) {
        final msg = (result['error'] as String?) ?? 'Could not start operation';
        setState(() { _isProcessing = false; });
        _stopTimer();
        _showSnack(msg, icon: Icons.error_rounded, color: _accent);
        return;
      }

      _startPolling();
    } catch (e) {
      setState(() { _isProcessing = false; });
      _stopTimer();
      _showSnack('Failed to start: $e', icon: Icons.error_rounded, color: _accent);
    }
  }

  Future<void> _cancelOperation() async {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _streamSub?.cancel();
    await HbcChannel.antiKillerCancel();
    if (!mounted) return;
    setState(() { _isProcessing = false; });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Operation cancelled'),
        backgroundColor: Color(0xFF1a0a2e),
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _streamSub?.cancel();
    _tickTimer?.cancel();
    _pulseCtrl.dispose();
    _orbitCtrl.dispose();
    _logCtrl.dispose();
    _logScrollCtrl.dispose();
    _pageScrollCtrl.dispose();
    _activityCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => true,
      child: Scaffold(
        backgroundColor: const Color(0xFF0a0a1a),
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: SingleChildScrollView(
                  controller: _pageScrollCtrl,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 12),
                      _buildHeader(),
                      const SizedBox(height: 18),
                      _buildFileSelector(),
                      const SizedBox(height: 12),
                      _buildActivityInput(),
                      const SizedBox(height: 10),
                      _buildOptions(),
                      const SizedBox(height: 14),
                      _buildActionRow(),
                      if (_logVisible) ...[
                        const SizedBox(height: 16),
                        _buildLogPanel(),
                      ],
                      if (_outputDir != null && !_isProcessing) ...[
                        const SizedBox(height: 16),
                        _buildOutputCard(),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          const Expanded(
            child: Text('Anti-Dialog Killer',
                style: TextStyle(color: Colors.white, fontSize: 18,
                    fontWeight: FontWeight.w800, letterSpacing: 0.5)),
          ),
          if (_isProcessing)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _accent.withOpacity(0.4)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 10, height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: _accent),
                ),
                const SizedBox(width: 6),
                Text(_elapsed,
                    style: TextStyle(color: _accent, fontSize: 11, fontFamily: 'monospace')),
              ]),
            ),
          if (!_isProcessing && _outputDir != null)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent.withOpacity(0.15),
                foregroundColor: _accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                side: BorderSide(color: _accent.withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                elevation: 0,
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Leave'),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseAnim, _orbitCtrl]),
      builder: (_, __) {
        final pulse = _pulseAnim.value;
        final orbit = _orbitCtrl.value;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              colors: [Color(0xFF100820), Color(0xFF120a1e), Color(0xFF100820)],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: Color.lerp(
                _accent.withOpacity(0.25), _accentLight.withOpacity(0.20), pulse)!),
            boxShadow: [
              BoxShadow(color: _accent.withOpacity(0.05 + pulse * 0.06),
                  blurRadius: 24, spreadRadius: 2),
            ],
          ),
          child: Row(children: [
            SizedBox(
              width: 80, height: 80,
              child: Stack(alignment: Alignment.center, children: [
                Transform.rotate(
                  angle: orbit * 2 * math.pi,
                  child: CustomPaint(
                    size: const Size(74, 74),
                    painter: _AkOrbitPainter(color: _accent, opacity: 0.4 + pulse * 0.25),
                  ),
                ),
                Transform.scale(
                  scale: 1.0 + pulse * 0.04,
                  child: Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(colors: [
                        Color.lerp(const Color(0xFF2a1060), const Color(0xFF3a1870), pulse)!,
                        const Color(0xFF100820),
                      ], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      boxShadow: [BoxShadow(
                        color: _accent.withOpacity(0.3 + pulse * 0.2),
                        blurRadius: 16, spreadRadius: 1,
                      )],
                    ),
                    child: Icon(Icons.shield_rounded, color: _accent, size: 28),
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Anti-Dialog Killer',
                    style: TextStyle(
                      color: Color.lerp(_accent, _accentLight, pulse),
                      fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 0.5,
                    )),
                const SizedBox(height: 4),
                Text('Injects AntiDialogKiller to neutralize\nsubscription dialogs in APKs.',
                    style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 11.5)),
              ]),
            ),
          ]),
        );
      },
    );
  }

  Widget _buildFileSelector() {
    final hasFile = _selectedFileName != null;
    return GestureDetector(
      onTap: _isProcessing ? null : _pickFile,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF111120),
          border: Border.all(
            color: hasFile && _fileValid
                ? _accent.withOpacity(0.5)
                : hasFile && !_fileValid
                    ? const Color(0xFFf59e0b).withOpacity(0.5)
                    : const Color(0xFF1e1e38),
          ),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: hasFile && _fileValid
                  ? _accent.withOpacity(0.12)
                  : const Color(0xFF1a1a2e),
              border: Border.all(color: hasFile && _fileValid
                  ? _accent.withOpacity(0.4) : const Color(0xFF2a2a4a)),
            ),
            child: Icon(
              hasFile ? Icons.android_rounded : Icons.upload_file_rounded,
              color: hasFile && _fileValid ? _accent : const Color(0xFF4a4a6a),
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              hasFile ? _selectedFileName! : 'Tap to select APK',
              style: TextStyle(
                color: hasFile ? Colors.white : const Color(0xFF6b7280),
                fontSize: 13, fontWeight: FontWeight.w600,
              ),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            ),
            if (_fileStatus != null) ...[
              const SizedBox(height: 2),
              Text(_fileStatus!,
                  style: TextStyle(
                    color: _fileValid
                        ? _accent.withOpacity(0.8)
                        : const Color(0xFFf59e0b),
                    fontSize: 10.5,
                  )),
            ],
          ])),
          if (_isProcessing)
            Icon(Icons.lock_rounded, color: const Color(0xFF4a4a6a), size: 18)
          else
            Icon(Icons.chevron_right_rounded,
                color: hasFile ? _accent.withOpacity(0.6) : const Color(0xFF4a4a6a), size: 20),
        ]),
      ),
    );
  }

  Widget _buildActivityInput() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xFF111120),
        border: Border.all(color: const Color(0xFF1e1e38)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Row(children: [
            Icon(Icons.memory_rounded, color: _accent.withOpacity(0.7), size: 15),
            const SizedBox(width: 8),
            Text('Main Activity',
                style: TextStyle(color: Colors.white.withOpacity(0.7),
                    fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: _accent.withOpacity(0.1),
              ),
              child: Text('optional',
                  style: TextStyle(color: _accent.withOpacity(0.7), fontSize: 9,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: TextField(
            controller: _activityCtrl,
            enabled: !_isProcessing,
            onChanged: (v) => setState(() => _mainActivity = v),
            style: const TextStyle(color: Colors.white, fontSize: 12.5, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'e.g. com.example.app.MainActivity',
              hintStyle: TextStyle(color: const Color(0xFF4a4a6a), fontSize: 11.5),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              filled: true,
              fillColor: const Color(0xFF0d0d20),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: _accent.withOpacity(0.2)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: _accent.withOpacity(0.6), width: 1.5),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF1a1a30)),
              ),
              suffixIcon: _mainActivity.isNotEmpty && !_isProcessing
                  ? GestureDetector(
                      onTap: () {
                        _activityCtrl.clear();
                        setState(() => _mainActivity = '');
                      },
                      child: Icon(Icons.close_rounded,
                          color: const Color(0xFF4a4a6a), size: 16),
                    )
                  : null,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Text(
            'Leave blank to auto-detect from AndroidManifest',
            style: TextStyle(color: const Color(0xFF4a4a6a), fontSize: 10),
          ),
        ),
      ]),
    );
  }

  Widget _buildOptions() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF111120),
        border: Border.all(color: const Color(0xFF1e1e38)),
      ),
      child: Row(children: [
        Icon(Icons.verified_user_rounded,
            color: _signApk ? const Color(0xFF22c55e) : const Color(0xFF4a4a6a), size: 18),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Sign APK', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          Text('Debug-sign the patched APK for direct install',
              style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 10.5)),
        ])),
        Switch(
          value: _signApk,
          onChanged: _isProcessing ? null : (v) => setState(() => _signApk = v),
          activeColor: const Color(0xFF22c55e),
          activeTrackColor: const Color(0xFF22c55e).withOpacity(0.3),
          inactiveTrackColor: const Color(0xFF1e1e38),
          inactiveThumbColor: const Color(0xFF4a4a6a),
        ),
      ]),
    );
  }

  Widget _buildActionRow() {
    if (_isProcessing) {
      return Row(children: [
        Expanded(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1a0a2e).withOpacity(0.6),
              foregroundColor: _accentLight,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              side: BorderSide(color: _accent.withOpacity(0.4)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              elevation: 0,
            ),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
            onPressed: _cancelOperation,
          ),
        ),
      ]);
    }

    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: _fileValid ? _accent.withOpacity(0.15) : const Color(0xFF111120),
        foregroundColor: _fileValid ? _accent : const Color(0xFF4a4a6a),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: _fileValid ? _accent.withOpacity(0.5) : const Color(0xFF1e1e38)),
        padding: const EdgeInsets.symmetric(vertical: 14),
        elevation: 0,
      ),
      icon: const Icon(Icons.shield_rounded, size: 18),
      label: const Text('Start Anti-Dialog Killer',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      onPressed: _fileValid ? _runOperation : null,
    );
  }

  Widget _buildLogPanel() {
    return FadeTransition(
      opacity: _logFade,
      child: Container(
        height: 240,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF080810),
          border: Border.all(color: _accent.withOpacity(0.2)),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(children: [
              Icon(Icons.terminal_rounded, color: _accent.withOpacity(0.7), size: 14),
              const SizedBox(width: 6),
              Text('Live Log', style: TextStyle(
                  color: _accent.withOpacity(0.7), fontSize: 11, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_downloadProgress >= 0) ...[
                SizedBox(
                  width: 80,
                  child: LinearProgressIndicator(
                    value: _downloadProgress / 100.0,
                    backgroundColor: const Color(0xFF1a1a2e),
                    valueColor: AlwaysStoppedAnimation<Color>(_accent),
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text('$_downloadProgress%',
                    style: TextStyle(color: _accent, fontSize: 10)),
                const SizedBox(width: 4),
              ],
              GestureDetector(
                onTap: () => setState(() => _autoScroll = !_autoScroll),
                child: Icon(
                  _autoScroll ? Icons.vertical_align_bottom_rounded : Icons.pause_rounded,
                  color: _autoScroll ? _accent.withOpacity(0.6) : const Color(0xFF4a4a6a),
                  size: 16,
                ),
              ),
            ]),
          ),
          const Divider(height: 1, color: Color(0xFF1e1e38)),
          Expanded(
            child: ListView.builder(
              controller: _logScrollCtrl,
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              itemCount: _logs.split('\n').where((l) => l.isNotEmpty).length,
              itemBuilder: (_, i) {
                final lines = _logs.split('\n').where((l) => l.isNotEmpty).toList();
                if (i >= lines.length) return const SizedBox.shrink();
                return Text(
                  lines[i],
                  style: const TextStyle(
                    color: Color(0xFFd1d5db),
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildOutputCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xFF0a0a1a),
        border: Border.all(color: const Color(0xFF22c55e).withOpacity(0.4)),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: const Color(0xFF22c55e).withOpacity(0.12),
            border: Border.all(color: const Color(0xFF22c55e).withOpacity(0.4)),
          ),
          child: const Icon(Icons.check_circle_outline_rounded,
              color: Color(0xFF22c55e), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Patched APK saved',
              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          Text(_outputDir ?? '',
              style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 10.5),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ])),
        IconButton(
          icon: const Icon(Icons.folder_open_rounded, color: Color(0xFF22c55e), size: 20),
          onPressed: () async {
            if (_outputDir != null) {
              await const MethodChannel('com.taurus.shield/storage')
                  .invokeMethod('openFolder', {'path': _outputDir});
            }
          },
        ),
      ]),
    );
  }
}

class _AkOrbitPainter extends CustomPainter {
  final Color color;
  final double opacity;
  const _AkOrbitPainter({required this.color, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(size.width / 2, size.height / 2),
          width: size.width, height: size.height),
      0, math.pi * 1.6, false, paint,
    );
    canvas.drawArc(
      Rect.fromCenter(center: Offset(size.width / 2, size.height / 2),
          width: size.width * 0.55, height: size.height * 0.55),
      math.pi * 0.8, math.pi * 1.6, false, paint,
    );
  }

  @override
  bool shouldRepaint(_AkOrbitPainter old) => old.opacity != opacity;
}
