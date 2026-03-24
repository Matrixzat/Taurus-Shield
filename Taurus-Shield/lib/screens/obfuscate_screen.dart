import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/hbc_channel.dart';
import '../utils/storage_helper.dart';
import '../utils/permission_helper.dart';

const _kStorageChannel = MethodChannel('com.taurus.shield/storage');

const _kAccent      = Color(0xFFe11d48);
const _kAccentLight = Color(0xFFfb7185);
const _kGold        = Color(0xFFf59e0b);

class ObfuscateScreen extends StatefulWidget {
  const ObfuscateScreen({super.key});

  @override
  State<ObfuscateScreen> createState() => _ObfuscateScreenState();
}

class _ObfuscateScreenState extends State<ObfuscateScreen>
    with TickerProviderStateMixin {
  String? _selectedFilePath;
  String? _selectedFileName;
  bool    _isProcessing     = false;
  bool    _logVisible       = false;
  String  _logs             = '';
  String? _outputDir;
  int     _downloadProgress = -1;
  bool    _autoScroll       = true;
  String? _apkStatus;
  bool    _apkValid         = false;
  StreamSubscription<String>? _streamSub;
  final Stopwatch _stopwatch = Stopwatch();
  Timer?  _tickTimer;
  String  _elapsed          = '00:00';
  Timer?  _pollTimer;

  final ScrollController _logScrollCtrl  = ScrollController();
  final ScrollController _pageScrollCtrl = ScrollController();
  final GlobalKey        _logPanelKey    = GlobalKey();

  late final AnimationController _pulseCtrl;
  late final AnimationController _orbitCtrl;
  late final AnimationController _logCtrl;
  late final Animation<double>   _pulseAnim;
  late final Animation<double>   _logFade;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _orbitCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 6000),
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
      final state     = await HbcChannel.obfuscateCloudState();
      final running   = state['running'] == true;
      final status    = (state['status'] as String?) ?? '';
      final logs      = (state['logs'] as String?) ?? '';
      final filePath  = (state['filePath'] as String?) ?? '';
      final outputDir = (state['outputDir'] as String?) ?? '';

      if (running && mounted) {
        setState(() {
          _isProcessing     = true;
          _logVisible       = true;
          _logs             = logs;
          _selectedFilePath = filePath.isNotEmpty ? filePath : _selectedFilePath;
          _selectedFileName = filePath.isNotEmpty
              ? filePath.split('/').last : _selectedFileName;
        });
        _logCtrl.forward(from: 0);
        if (!_stopwatch.isRunning) _startTimer();
        _startPollingCloudState();
      } else if (status == 'success' && mounted) {
        setState(() {
          _isProcessing     = false;
          _logVisible       = true;
          _logs             = logs;
          _outputDir        = outputDir.isNotEmpty ? outputDir : null;
          _selectedFilePath = filePath.isNotEmpty ? filePath : _selectedFilePath;
          _selectedFileName = filePath.isNotEmpty
              ? filePath.split('/').last : _selectedFileName;
        });
        _logCtrl.forward(from: 0);
        _showSnack('Obfuscation complete',
            icon: Icons.check_circle_rounded, color: const Color(0xFF22c55e));
      } else if (status == 'cancelled' && mounted) {
        setState(() {
          _isProcessing = false;
          _logVisible   = true;
          _logs         = logs;
        });
        _logCtrl.forward(from: 0);
        _showSnack('Obfuscation cancelled',
            icon: Icons.cancel_outlined, color: const Color(0xFFf59e0b));
      } else if (status == 'error' && logs.isNotEmpty && mounted) {
        final error = (state['error'] as String?) ?? 'Obfuscation failed';
        setState(() {
          _isProcessing = false;
          _logVisible   = true;
          _logs         = logs;
        });
        _logCtrl.forward(from: 0);
        _showSnack(error,
            icon: Icons.error_rounded, color: const Color(0xFFef4444));
      }
    } catch (_) {}
  }

  void _startPollingCloudState() {
    _pollTimer?.cancel();
    _streamSub?.cancel();

    _streamSub = HbcChannel.logStream.listen((line) {
      if (!mounted) return;
      if (line.startsWith('DOWNLOAD_PROGRESS:')) {
        final pct = int.tryParse(line.split(':').last) ?? -1;
        setState(() => _downloadProgress = pct);
        return;
      }
      if (line == '__TAURUS_DONE__') {
        _pollTimer?.cancel();
        _checkCloudState();
        return;
      }
      setState(() {
        _logs += (_logs.isEmpty ? '' : '\n') + line;
      });
      if (_autoScroll) _scrollLogToBottom();
    }, onDone: () {}, onError: (_) {});

    var consecutiveErrors = 0;
    const maxErrors = 6;

    _pollTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      if (!mounted) { _pollTimer?.cancel(); return; }
      try {
        final state     = await HbcChannel.obfuscateCloudState();
        consecutiveErrors = 0;
        final running   = state['running'] == true;
        final logs      = (state['logs'] as String?) ?? '';
        final status    = (state['status'] as String?) ?? '';
        final outputDir = (state['outputDir'] as String?) ?? '';

        if (logs != _logs && mounted) {
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
              if (cancelled) {
                _logs += '\nCancelled by user.\n';
              } else {
                _logs += '\n${success ? "Completed" : "Failed"} in $totalTime\n';
              }
            });
            if (cancelled) {
              _showSnack('Obfuscation cancelled',
                  icon: Icons.cancel_outlined, color: const Color(0xFFf59e0b));
            } else {
              _showSnack(
                success ? 'Obfuscation complete — $totalTime'
                        : 'Obfuscation failed',
                icon:  success ? Icons.check_circle_rounded : Icons.error_rounded,
                color: success ? const Color(0xFF22c55e) : const Color(0xFFef4444),
              );
            }
          }
        }
      } catch (_) {
        consecutiveErrors++;
        if (consecutiveErrors >= maxErrors && mounted) {
          _pollTimer?.cancel();
          _streamSub?.cancel();
          _stopTimer();
          setState(() {
            _isProcessing     = false;
            _downloadProgress = -1;
            _logs += '\nLost connection to obfuscation service after $maxErrors attempts.\n';
          });
          _showSnack('Connection lost — check service status',
              icon: Icons.error_rounded, color: const Color(0xFFef4444));
        }
      }
    });
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
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _startTimer() {
    _stopwatch.reset();
    _stopwatch.start();
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed = _formatDuration(_stopwatch.elapsed));
    });
  }

  String _stopTimer() {
    _stopwatch.stop();
    _tickTimer?.cancel();
    _tickTimer = null;
    final result = _formatDuration(_stopwatch.elapsed);
    setState(() => _elapsed = result);
    return result;
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    if (file.path == null) return;

    final sizeMb = File(file.path!).lengthSync() / 1048576.0;
    if (sizeMb > 100) {
      setState(() {
        _selectedFilePath = file.path;
        _selectedFileName = file.name;
        _apkStatus        = 'File too large (${sizeMb.toStringAsFixed(1)} MB) — 100 MB limit';
        _apkValid         = false;
        _logs             = '';
        _logVisible       = false;
        _outputDir        = null;
        _downloadProgress = -1;
        _isProcessing     = false;
        _stopwatch.reset();
        _tickTimer?.cancel();
        _elapsed = '00:00';
      });
      _showSnack('File too large — 100 MB limit',
          icon: Icons.warning_rounded, color: const Color(0xFFf59e0b));
      return;
    }

    setState(() {
      _selectedFilePath = file.path;
      _selectedFileName = file.name;
      _apkStatus        = 'APK ready — ${sizeMb.toStringAsFixed(1)} MB';
      _apkValid         = true;
      _logs             = '';
      _logVisible       = false;
      _outputDir        = null;
      _downloadProgress = -1;
      _isProcessing     = false;
      _stopwatch.reset();
      _tickTimer?.cancel();
      _elapsed = '00:00';
    });
  }

  Future<void> _runObfuscation() async {
    if (_selectedFilePath == null) {
      _showSnack('Pick an APK file first',
          icon: Icons.folder_open_rounded, color: const Color(0xFFf59e0b));
      return;
    }

    if (!_apkValid) {
      _showSnack(_apkStatus ?? 'Invalid APK file',
          icon: Icons.warning_rounded, color: const Color(0xFFf59e0b));
      return;
    }

    final hasPermission = await PermissionHelper.ensureStorage(
      context, accent: _kAccent,
    );
    if (!hasPermission) {
      _showSnack('Storage permission is required',
          icon: Icons.lock_rounded, color: const Color(0xFFef4444));
      return;
    }

    final outputDir = await StorageHelper.buildOutputDir(prefix: 'obfuscate');

    setState(() {
      _isProcessing     = true;
      _logs             = '';
      _logVisible       = true;
      _downloadProgress = -1;
    });
    _logCtrl.forward(from: 0);
    _scrollToLogPanel();
    _startTimer();

    try {
      final result = await HbcChannel.obfuscateAnalyze(
        filePath:  _selectedFilePath!,
        fileName:  _selectedFileName ?? _selectedFilePath!.split('/').last,
        outputDir: outputDir,
      );

      if (result['started'] == true) {
        await Future.delayed(const Duration(seconds: 1));
        _startPollingCloudState();
      } else {
        _stopTimer();
        final errMsg = (result['error'] as String?) ?? 'Failed to start obfuscation';
        if (mounted) {
          setState(() { _isProcessing = false; });
          _showSnack(errMsg,
              icon: Icons.error_rounded, color: const Color(0xFFef4444));
        }
      }
    } catch (e) {
      _stopTimer();
      if (mounted) {
        setState(() {
          _isProcessing     = false;
          _downloadProgress = -1;
          _logs += '\nError: $e\n';
        });
        _showSnack('Error: $e',
            icon: Icons.error_rounded, color: const Color(0xFFef4444));
      }
    }
  }

  void _scrollToLogPanel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _logPanelKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 480),
        curve: Curves.easeInOut,
        alignment: 0.0,
      );
    });
  }

  void _showSnack(String msg, {required IconData icon, required Color color}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(icon, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(msg,
                style: const TextStyle(color: Colors.white, fontSize: 13))),
      ]),
      backgroundColor: color.withOpacity(0.9),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _onBackPressed() async {
    final leave = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF12102a),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: _kAccent, width: 1),
        ),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _kAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.translate_rounded, color: _kAccent, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Leave Obfuscator?',
                style: TextStyle(
                    color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ]),
        content: Text(
          _isProcessing
              ? 'Obfuscation is running in the background.\nYou can return later to see results.'
              : 'Are you sure you want to go back?',
          style: const TextStyle(
              color: Color(0xFFa0a0b8), fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay',
                style: TextStyle(color: Color(0xFF6b7280))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_isProcessing ? 'Leave (keeps running)' : 'Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBackPressed();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0a0a1a),
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ObfAppBarIcon(animation: _pulseAnim),
              const SizedBox(width: 10),
              const Text('APK OBFUSCATOR'),
              const SizedBox(width: 10),
              _ObfAppBarIcon(animation: _pulseAnim, mirrored: true),
            ],
          ),
          iconTheme: const IconThemeData(color: Colors.white),
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0d0d20), Color(0xFF200a0a)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: _kAccent.withOpacity(0.25)),
          ),
        ),
        body: SingleChildScrollView(
          controller: _pageScrollCtrl,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              _buildInfoCards(),
              const SizedBox(height: 16),
              _buildFileSelector(),
              if (_selectedFileName != null) ...[
                const SizedBox(height: 12),
                _buildApkInfo(),
              ],
              const SizedBox(height: 14),
              _buildActionRow(),
              if (_downloadProgress >= 0) ...[
                const SizedBox(height: 12),
                _buildProgressBar(),
              ],
              if (_logVisible) ...[
                const SizedBox(height: 16),
                _buildLogPanel(),
              ],
              if (_outputDir != null && !_isProcessing) ...[
                const SizedBox(height: 14),
                _buildOutputDir(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseAnim, _orbitCtrl]),
      builder: (_, __) {
        final pulse = _pulseAnim.value;
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.2,
              colors: [
                _kAccent.withOpacity(0.06 + 0.04 * pulse),
                const Color(0xFF0a0a1a),
              ],
            ),
            border: Border.all(color: _kAccent.withOpacity(0.10 + 0.08 * pulse)),
          ),
          child: Column(children: [
            SizedBox(
              width: 64,
              height: 64,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Transform.rotate(
                    angle: _orbitCtrl.value * math.pi * 2,
                    child: CustomPaint(
                      size: const Size(64, 64),
                      painter: _OrbitPainter(
                          color: _kAccent, opacity: 0.25 + 0.25 * pulse),
                    ),
                  ),
                  Transform.rotate(
                    angle: -_orbitCtrl.value * math.pi * 2 * 0.5,
                    child: CustomPaint(
                      size: const Size(42, 42),
                      painter: _OrbitPainter(
                          color: _kGold, opacity: 0.2 + 0.2 * pulse, dashes: 4),
                    ),
                  ),
                  Icon(Icons.translate_rounded,
                      color: _kAccent.withOpacity(0.7 + 0.3 * pulse),
                      size: 26),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _HeaderChip('汉字 Rename'),
                const SizedBox(width: 8),
                _HeaderChip('String Encrypt'),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '中文混淆 · Chinese Obfuscation Engine',
              style: TextStyle(
                color: _kAccent.withOpacity(0.5 + 0.3 * pulse),
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _buildInfoCards() {
    return Row(
      children: [
        Expanded(child: _InfoCard(
          icon: Icons.abc_rounded,
          color: _kAccent,
          title: '汉字 Rename',
          subtitle: 'Classes, methods & fields renamed to random Chinese characters',
        )),
        const SizedBox(width: 10),
        Expanded(child: _InfoCard(
          icon: Icons.lock_rounded,
          color: _kGold,
          title: 'String Encrypt',
          subtitle: 'String literals transformed into unreadable cipher sequences',
        )),
      ],
    );
  }

  Widget _buildFileSelector() {
    final hasFile = _selectedFileName != null;
    return GestureDetector(
      onTap: _isProcessing ? null : _pickFile,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: const Color(0xFF111122),
          border: Border.all(
            color: hasFile
                ? _kAccent.withOpacity(0.30)
                : const Color(0xFF1e1e3a),
          ),
        ),
        child: Row(children: [
          Icon(
            hasFile ? Icons.android_rounded : Icons.upload_file_rounded,
            color: hasFile
                ? (_apkValid ? _kAccent : const Color(0xFFef4444))
                : const Color(0xFF4b5563),
            size: 28,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasFile ? _selectedFileName! : 'Select APK file',
                  style: TextStyle(
                    color: hasFile ? Colors.white : const Color(0xFF6b7280),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (hasFile && _apkStatus != null)
                  Text(_apkStatus!,
                      style: TextStyle(
                          color: _apkValid
                              ? const Color(0xFF22c55e)
                              : const Color(0xFFef4444),
                          fontSize: 11))
                else if (!hasFile)
                  const Text('APK file to obfuscate (max 100 MB)',
                      style: TextStyle(color: Color(0xFF4b5563), fontSize: 11)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _kAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _kAccent.withOpacity(0.25)),
            ),
            child: Text(
              hasFile ? 'Change' : 'Browse',
              style: const TextStyle(
                  color: _kAccent, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildApkInfo() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0f0f22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1e1e3a)),
      ),
      child: Row(children: [
        Icon(Icons.info_outline_rounded,
            color: _kAccent.withOpacity(0.6), size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _selectedFilePath ?? '',
            style: const TextStyle(color: Color(0xFF6b7280), fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
    );
  }

  Widget _buildActionRow() {
    return Row(children: [
      Expanded(
        child: GestureDetector(
          onTap: (_isProcessing || !_apkValid) ? null : _runObfuscation,
          child: AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, __) => Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(
                  colors: (_isProcessing || !_apkValid)
                      ? [const Color(0xFF2a1020), const Color(0xFF1a0a1a)]
                      : [
                          Color.lerp(_kAccent, const Color(0xFF9f1239),
                              _pulseAnim.value)!,
                          _kAccent,
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: (_isProcessing || !_apkValid)
                    ? []
                    : [
                        BoxShadow(
                          color: _kAccent
                              .withOpacity(0.25 + 0.15 * _pulseAnim.value),
                          blurRadius: 16,
                          spreadRadius: 1,
                        ),
                      ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isProcessing)
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                  else
                    const Icon(Icons.translate_rounded,
                        color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    _isProcessing
                        ? 'Obfuscating... $_elapsed'
                        : 'Obfuscate APK',
                    style: TextStyle(
                      color: (_isProcessing || !_apkValid)
                          ? const Color(0xFF4b5563)
                          : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (_isProcessing) ...[
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () async {
            await HbcChannel.obfuscateCancel();
            setState(() {
              _isProcessing     = false;
              _downloadProgress = -1;
              _logs += '\nCancelling...\n';
            });
            _stopTimer();
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF2a1010),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFef4444).withOpacity(0.35)),
            ),
            child: const Icon(Icons.stop_rounded,
                color: Color(0xFFef4444), size: 22),
          ),
        ),
      ],
    ]);
  }

  Widget _buildProgressBar() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Upload progress',
            style: TextStyle(
                color: _kAccent.withOpacity(0.7), fontSize: 11)),
        Text('$_downloadProgress%',
            style: const TextStyle(color: Colors.white, fontSize: 11)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: _downloadProgress / 100,
          backgroundColor: const Color(0xFF1e1e3a),
          valueColor: AlwaysStoppedAnimation<Color>(_kAccent),
          minHeight: 6,
        ),
      ),
    ]);
  }

  Widget _buildLogPanel() {
    return FadeTransition(
      opacity: _logFade,
      child: Container(
        key: _logPanelKey,
        decoration: BoxDecoration(
          color: const Color(0xFF080814),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kAccent.withOpacity(0.18)),
        ),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border:
                  Border(bottom: BorderSide(color: _kAccent.withOpacity(0.15))),
            ),
            child: Row(children: [
              Icon(Icons.terminal_rounded,
                  color: _kAccent.withOpacity(0.7), size: 16),
              const SizedBox(width: 8),
              const Text('Obfuscation Log',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_isProcessing)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: _kAccent.withOpacity(0.6)),
                  ),
                ),
              GestureDetector(
                onTap: () => setState(() => _autoScroll = !_autoScroll),
                child: Icon(
                  _autoScroll
                      ? Icons.lock_outline_rounded
                      : Icons.lock_open_rounded,
                  color: _autoScroll
                      ? _kAccent.withOpacity(0.7)
                      : const Color(0xFF4b5563),
                  size: 16,
                ),
              ),
              const SizedBox(width: 8),
              // Copy button
              GestureDetector(
                onTap: () {
                  if (_logs.isEmpty) {
                    _showSnack('No logs to copy yet',
                        icon: Icons.info_rounded,
                        color: const Color(0xFF6b7280));
                    return;
                  }
                  Clipboard.setData(ClipboardData(text: _logs));
                  _showSnack('Logs copied',
                      icon: Icons.copy_rounded,
                      color: const Color(0xFF22d3ee));
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22d3ee).withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: const Color(0xFF22d3ee).withOpacity(0.35)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy_rounded,
                          color: Color(0xFF22d3ee), size: 13),
                      SizedBox(width: 4),
                      Text('Copy',
                          style: TextStyle(
                              color: Color(0xFF22d3ee),
                              fontSize: 10,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Delete / clear button
              GestureDetector(
                onTap: () {
                  if (_logs.isEmpty) return;
                  _stopwatch.reset();
                  _tickTimer?.cancel();
                  _tickTimer = null;
                  _pollTimer?.cancel();
                  setState(() {
                    _logs             = '';
                    _outputDir        = null;
                    _logVisible       = false;
                    _isProcessing     = false;
                    _downloadProgress = -1;
                    _elapsed          = '00:00';
                  });
                  _logCtrl.reverse();
                  try { HbcChannel.obfuscateClearState(); } catch (_) {}
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFef4444).withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: const Color(0xFFef4444).withOpacity(0.35)),
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    color: Color(0xFFf87171),
                    size: 14,
                  ),
                ),
              ),
            ]),
          ),
          SizedBox(
            height: 220,
            child: ListView(
              controller: _logScrollCtrl,
              padding: const EdgeInsets.all(12),
              children: [
                SelectableText(
                  _logs.isEmpty ? 'Waiting for output...' : _logs,
                  style: TextStyle(
                    color: _logs.isEmpty
                        ? const Color(0xFF4b5563)
                        : const Color(0xFFa0f0a0),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildOutputDir() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0a1a0a),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF22c55e).withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.check_circle_rounded,
              color: Color(0xFF22c55e), size: 18),
          SizedBox(width: 8),
          Text('Obfuscation Complete',
              style: TextStyle(
                  color: Color(0xFF22c55e),
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        Text(_outputDir ?? '',
            style: const TextStyle(
                color: Color(0xFF4b5563), fontSize: 11),
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () async {
            final dir = _outputDir;
            if (dir != null) {
              try {
                await _kStorageChannel.invokeMethod('openFolder', {'path': dir});
              } catch (_) {}
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF22c55e).withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: const Color(0xFF22c55e).withOpacity(0.3)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_open_rounded,
                    color: Color(0xFF22c55e), size: 16),
                SizedBox(width: 6),
                Text('Open Output Folder',
                    style: TextStyle(
                        color: Color(0xFF22c55e),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _HeaderChip extends StatelessWidget {
  final String label;
  const _HeaderChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _kAccent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _kAccent.withOpacity(0.25)),
      ),
      child: Text(label,
          style: const TextStyle(
              color: _kAccentLight, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   title;
  final String   subtitle;
  const _InfoCard(
      {required this.icon,
      required this.color,
      required this.title,
      required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0f0f22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 8),
        Text(title,
            style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(subtitle,
            style: const TextStyle(
                color: Color(0xFF6b7280), fontSize: 10, height: 1.4)),
      ]),
    );
  }
}

class _ObfAppBarIcon extends StatelessWidget {
  final Animation<double> animation;
  final bool mirrored;
  const _ObfAppBarIcon({required this.animation, this.mirrored = false});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, __) {
        final t = animation.value;
        return Transform.scale(
          scaleX: mirrored ? -1 : 1,
          child: SizedBox(
            width: 22,
            height: 22,
            child: CustomPaint(
              painter: _DragonPainter(t: t),
            ),
          ),
        );
      },
    );
  }
}

class _DragonPainter extends CustomPainter {
  final double t;
  const _DragonPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color.lerp(_kAccent, _kGold, t)!
      ..style = PaintingStyle.fill;

    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = size.width * 0.4;

    final path = Path();
    for (int i = 0; i < 8; i++) {
      final angle = (i / 8) * math.pi * 2 - math.pi / 2;
      final ir    = i % 2 == 0 ? r : r * 0.45;
      final x     = cx + math.cos(angle) * ir;
      final y     = cy + math.sin(angle) * ir;
      if (i == 0) path.moveTo(x, y);
      else path.lineTo(x, y);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_DragonPainter old) => old.t != t;
}

class _OrbitPainter extends CustomPainter {
  final Color  color;
  final double opacity;
  final int    dashes;
  const _OrbitPainter(
      {required this.color, required this.opacity, this.dashes = 3});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color  = color.withOpacity(opacity)
      ..style  = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = size.width * 0.45;

    for (int i = 0; i < dashes; i++) {
      final startAngle = (i / dashes) * math.pi * 2;
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        startAngle,
        math.pi / (dashes * 1.2),
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.opacity != opacity || old.color != color;
}
