import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/theme_provider.dart';
import '../utils/storage_helper.dart';
import '../utils/permission_helper.dart';

const _kAccent      = Color(0xFF00E5FF);
const _kAccentDark  = Color(0xFF006064);
const _kAccentSoft  = Color(0xFF80DEEA);
const _kSurface     = Color(0xFF0A1628);

const _kModChannel  = MethodChannel('com.taurus.shield/mod_engine');

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

class OffsetEntry {
  final String name;
  final String offset;
  final String returnType;
  final String className;
  final int interestScore;
  bool selected;
  String featureType; // bool | int | long | float
  int defaultVal;
  int maxVal;

  OffsetEntry({
    required this.name,
    required this.offset,
    required this.returnType,
    required this.className,
    required this.interestScore,
    this.selected = false,
    this.featureType = 'bool',
    this.defaultVal = 0,
    this.maxVal = 0,
  });

  Map<String, dynamic> toFeatureJson() => {
    'name':        name,
    'offset':      offset,
    'type':        featureType,
    'default_val': defaultVal,
    'max_val':     maxVal,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen widget
// ─────────────────────────────────────────────────────────────────────────────

class ModEngineScreen extends StatefulWidget {
  const ModEngineScreen({super.key});
  @override
  State<ModEngineScreen> createState() => _ModEngineScreenState();
}

class _ModEngineScreenState extends State<ModEngineScreen>
    with TickerProviderStateMixin {

  // ── State ──────────────────────────────────────────────────────────────────
  int    _step = 0;     // 0=pick game  1=dumping  2=select features  3=building  4=done

  String? _gamePath;
  String? _gameName;
  String? _dumpJsonPath;

  List<OffsetEntry> _allOffsets      = [];
  List<OffsetEntry> _filteredOffsets = [];
  final Set<int>    _selectedIdx     = {};
  String            _filterQuery     = '';
  bool              _onlyInteresting = true;

  bool   _isProcessing = false;
  String _logs         = '';
  String _phase        = '';
  String _resultPath   = '';

  StreamSubscription<String>? _logSub;
  Timer? _pollTimer;

  late final AnimationController _pulseCtrl;
  late final Animation<double>   _pulseAnim;
  final ScrollController _logCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _restoreState();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _logSub?.cancel();
    _pollTimer?.cancel();
    _logCtrl.dispose();
    super.dispose();
  }

  // ── Restore from background service state ─────────────────────────────────
  Future<void> _restoreState() async {
    try {
      final result = await _kModChannel.invokeMethod<Map>('getState');
      if (result == null) return;
      final running = result['running'] as bool? ?? false;
      final phase   = result['phase']   as String? ?? '';
      final logs    = result['logs']    as String? ?? '';
      final status  = result['result_status'] as String? ?? '';
      final respath = result['result']  as String? ?? '';

      if (running || phase == 'done' || phase == 'error') {
        setState(() {
          _isProcessing = running;
          _phase = phase;
          _logs  = logs;
          if (!running && (phase == 'done' || phase == 'error')) {
            _step = _stepFromPhase(phase, status, respath);
            _resultPath = respath;
          }
        });
        if (running) _startPolling();
      }
    } catch (_) {}
  }

  int _stepFromPhase(String phase, String status, String path) {
    if (phase == 'done' && status == 'success') {
      if (path.endsWith('.json')) return 2; // dump done → feature selection
      if (path.endsWith('.apk'))  return 4; // build done → install
    }
    return _step;
  }

  // ── Step 0: Pick APK ──────────────────────────────────────────────────────
  Future<void> _pickGame() async {
    final hasPermission = await PermissionHelper.ensureStorage(context, accent: _kAccent);
    if (!hasPermission) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path!;
    final name = result.files.first.name
        .replaceAll('.apk', '')
        .replaceAll(' ', '_');
    setState(() {
      _gamePath = path;
      _gameName = name;
    });
  }

  // ── Step 1: Dump ──────────────────────────────────────────────────────────
  Future<void> _startDump() async {
    if (_gamePath == null) return;
    setState(() { _step = 1; _isProcessing = true; _logs = ''; _phase = 'starting'; });
    try {
      await _kModChannel.invokeMethod('startDump', {'apk_path': _gamePath});
      _startPolling();
    } catch (e) {
      _appendLog('Error starting dump: $e');
      setState(() { _step = 0; _isProcessing = false; });
    }
  }

  // ── Step 2: Load dump JSON → show feature selection ───────────────────────
  Future<void> _loadDumpJson(String path) async {
    setState(() { _dumpJsonPath = path; });
    try {
      final content = File(path).readAsStringSync();
      final json    = jsonDecode(content) as Map<String, dynamic>;
      final interesting = (json['interesting_methods'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      final all = (json['all_methods'] as List? ?? [])
          .cast<Map<String, dynamic>>();

      final src = interesting.isNotEmpty ? interesting : all;

      _allOffsets = src.map((m) {
        final score = (m['interest_score'] as num?)?.toInt() ?? 0;
        return OffsetEntry(
          name:          m['method']      as String? ?? '?',
          offset:        m['offset']      as String? ?? '0x0',
          returnType:    m['return_type'] as String? ?? 'void',
          className:     m['class']       as String? ?? '',
          interestScore: score,
          featureType:   _inferType(m['return_type'] as String? ?? ''),
        );
      }).toList();

      _applyFilter();
      setState(() { _step = 2; });
    } catch (e) {
      _appendLog('Error loading dump: $e');
    }
  }

  String _inferType(String ret) {
    final r = ret.toLowerCase();
    if (r.contains('bool'))  return 'bool';
    if (r.contains('long') || r.contains('int64')) return 'long';
    if (r.contains('float') || r.contains('double')) return 'float';
    if (r.contains('int'))   return 'int';
    return 'bool';
  }

  void _applyFilter() {
    final q = _filterQuery.toLowerCase();
    setState(() {
      _filteredOffsets = _allOffsets.where((e) {
        final matchQuery = q.isEmpty ||
            e.name.toLowerCase().contains(q) ||
            e.className.toLowerCase().contains(q);
        final matchInterest = !_onlyInteresting || e.interestScore > 0;
        return matchQuery && matchInterest;
      }).toList();
    });
  }

  // ── Step 3: Build ─────────────────────────────────────────────────────────
  Future<void> _startBuild() async {
    final selected = _allOffsets.where((e) => e.selected).toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one feature to mod')),
      );
      return;
    }
    if (_gamePath == null) return;

    final featuresJson = jsonEncode(selected.map((e) => e.toFeatureJson()).toList());
    setState(() { _step = 3; _isProcessing = true; _logs = ''; _phase = 'building'; });

    try {
      await _kModChannel.invokeMethod('startBuild', {
        'apk_path':      _gamePath,
        'game_name':     _gameName ?? 'game',
        'features_json': featuresJson,
      });
      _startPolling();
    } catch (e) {
      _appendLog('Error starting build: $e');
      setState(() { _step = 2; _isProcessing = false; });
    }
  }

  // ── Polling ───────────────────────────────────────────────────────────────
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final r = await _kModChannel.invokeMethod<Map>('getState');
        if (r == null) return;
        final running = r['running'] as bool? ?? false;
        final phase   = r['phase']   as String? ?? '';
        final logs    = r['logs']    as String? ?? '';
        final status  = r['result_status'] as String? ?? '';
        final respath = r['result']  as String? ?? '';

        setState(() {
          _isProcessing = running;
          _phase = phase;
          _logs  = logs;
        });

        // Scroll logs
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logCtrl.hasClients) {
            _logCtrl.jumpTo(_logCtrl.position.maxScrollExtent);
          }
        });

        if (!running) {
          _pollTimer?.cancel();
          if (status == 'success') {
            _resultPath = respath;
            if (respath.endsWith('.json')) {
              await _loadDumpJson(respath);
            } else {
              setState(() { _step = 4; });
            }
          } else if (phase == 'error') {
            setState(() { _step = _step > 2 ? 2 : 0; });
            _showError(status.replaceFirst('error:', ''));
          }
        }
      } catch (_) {}
    });
  }

  void _appendLog(String msg) {
    setState(() { _logs = _logs.isEmpty ? msg : '$_logs\n$msg'; });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error: $msg'), backgroundColor: Colors.red[800]),
    );
  }

  // ── Install APK ───────────────────────────────────────────────────────────
  Future<void> _installApk() async {
    try {
      await _kModChannel.invokeMethod('installApk', {'path': _resultPath});
    } catch (e) {
      _showError(e.toString());
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD UI
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kSurface,
      appBar: AppBar(
        backgroundColor: _kSurface,
        foregroundColor: _kAccent,
        title: const Text('Mod Engine', style: TextStyle(color: _kAccent, fontWeight: FontWeight.bold)),
        actions: [
          if (_step > 0 && !_isProcessing)
            IconButton(
              icon: const Icon(Icons.refresh, color: _kAccentSoft),
              tooltip: 'Start over',
              onPressed: () => setState(() {
                _step = 0; _gamePath = null; _gameName = null;
                _logs = ''; _phase = ''; _resultPath = '';
                _allOffsets = []; _filteredOffsets = [];
              }),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildStepBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildStepBar() {
    const steps = ['Pick Game', 'Analyse', 'Select Features', 'Build', 'Install'];
    return Container(
      color: const Color(0xFF0D1F3C),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        children: List.generate(steps.length, (i) {
          final active = i == _step;
          final done   = i < _step;
          return Expanded(
            child: Row(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: done  ? _kAccent :
                               active? _kAccentDark :
                               const Color(0xFF1A2A4A),
                        border: Border.all(
                          color: active ? _kAccent : Colors.transparent, width: 2),
                      ),
                      child: Center(
                        child: done
                          ? const Icon(Icons.check, size: 16, color: Colors.black)
                          : Text('${i+1}',
                              style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold,
                                color: active ? _kAccent : Colors.white38)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(steps[i],
                      style: TextStyle(
                        fontSize: 9,
                        color: active ? _kAccent : (done ? _kAccentSoft : Colors.white38),
                        fontWeight: active ? FontWeight.bold : FontWeight.normal,
                      )),
                  ],
                ),
                if (i < steps.length - 1)
                  Expanded(child: Container(
                    height: 1,
                    color: i < _step ? _kAccent : Colors.white12,
                    margin: const EdgeInsets.only(bottom: 20, left: 4, right: 4),
                  )),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case 0: return _buildPickStep();
      case 1: return _buildProcessingStep('Analysing game…', 'Extracting IL2CPP symbols via GitHub Actions');
      case 2: return _buildFeatureSelectStep();
      case 3: return _buildProcessingStep('Building mod APK…', 'Compiling hooks and patching game APK via GitHub Actions');
      case 4: return _buildDoneStep();
      default: return _buildPickStep();
    }
  }

  // ── Step 0: Pick Game ─────────────────────────────────────────────────────
  Widget _buildPickStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0A2540), Color(0xFF0D3B6E)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kAccent.withOpacity(0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.memory, color: _kAccent, size: 28),
                  const SizedBox(width: 12),
                  const Text('Unity IL2CPP Mod Engine',
                    style: TextStyle(color: _kAccent, fontSize: 18, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 12),
                const Text(
                  'Dumps the game\'s C# symbols, lets you pick which functions to hook '
                  '(coins, speed, unlock checks, etc.), then builds and signs a custom '
                  'modded APK — all via GitHub Actions, no server needed.',
                  style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _chip(Icons.cloud_queue, 'GitHub Actions'),
                  _chip(Icons.code, 'Dobby Hooks'),
                  _chip(Icons.security, 'Auto-signed'),
                  _chip(Icons.gamepad, 'Any Unity Game'),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // How it works
          _sectionHeader('How It Works'),
          const SizedBox(height: 8),
          _howItWorksCard(),
          const SizedBox(height: 24),

          // APK picker
          _sectionHeader('Step 1 — Select Game APK'),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _pickGame,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1F3C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _gamePath != null ? _kAccent : Colors.white24,
                  width: _gamePath != null ? 2 : 1,
                ),
              ),
              child: _gamePath == null
                ? Column(children: [
                    Icon(Icons.android, color: _kAccent.withOpacity(0.5), size: 48),
                    const SizedBox(height: 12),
                    Text('Tap to pick a Unity game APK',
                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 15)),
                    const SizedBox(height: 4),
                    const Text('Must be a Unity IL2CPP game',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ])
                : Row(children: [
                    const Icon(Icons.check_circle, color: _kAccent, size: 28),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_gameName ?? '', style: const TextStyle(color: _kAccent, fontWeight: FontWeight.bold)),
                      Text(_gamePath!, style: const TextStyle(color: Colors.white54, fontSize: 11),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    ])),
                    TextButton(onPressed: _pickGame, child: const Text('Change', style: TextStyle(color: _kAccentSoft))),
                  ]),
            ),
          ),
          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _gamePath != null ? _startDump : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('Analyse Game', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _howItWorksCard() {
    final steps = [
      ('1', 'Upload game APK to GitHub', Icons.upload),
      ('2', 'Actions extracts libil2cpp.so + metadata', Icons.layers),
      ('3', 'Il2CppDumper maps all C# methods + offsets', Icons.list_alt),
      ('4', 'You pick which functions to hook', Icons.tune),
      ('5', 'Actions compiles C++ Dobby hook .so', Icons.build),
      ('6', 'Patches + signs the game APK', Icons.verified),
      ('7', 'You download and install the modded APK', Icons.install_mobile),
    ];
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1F3C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: steps.asMap().entries.map((e) {
          final i = e.key;
          final step = e.value;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              border: i < steps.length - 1
                ? const Border(bottom: BorderSide(color: Colors.white10)) : null,
            ),
            child: Row(children: [
              Container(width: 28, height: 28,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _kAccentDark),
                child: Center(child: Text(step.$1,
                  style: const TextStyle(color: _kAccent, fontSize: 12, fontWeight: FontWeight.bold)))),
              const SizedBox(width: 12),
              Icon(step.$3, color: _kAccentSoft, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(step.$2, style: const TextStyle(color: Colors.white70, fontSize: 13))),
            ]),
          );
        }).toList(),
      ),
    );
  }

  // ── Step 1/3: Processing ───────────────────────────────────────────────────
  Widget _buildProcessingStep(String title, String subtitle) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, __) => Opacity(
                    opacity: _pulseAnim.value,
                    child: const Icon(Icons.memory, color: _kAccent, size: 72),
                  ),
                ),
                const SizedBox(height: 20),
                Text(title, style: const TextStyle(color: _kAccent, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                const SizedBox(height: 12),
                if (_phase.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: _kAccentDark.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(_phase.toUpperCase(),
                      style: const TextStyle(color: _kAccent, fontSize: 11, letterSpacing: 1.2)),
                  ),
              ],
            ),
          ),
        ),
        if (_logs.isNotEmpty)
          Container(
            height: 200,
            color: Colors.black,
            child: SingleChildScrollView(
              controller: _logCtrl,
              padding: const EdgeInsets.all(12),
              child: Text(_logs,
                style: const TextStyle(color: Color(0xFF00FF88), fontSize: 11,
                  fontFamily: 'monospace', height: 1.4)),
            ),
          ),
      ],
    );
  }

  // ── Step 2: Feature selection ─────────────────────────────────────────────
  Widget _buildFeatureSelectStep() {
    final selected = _allOffsets.where((e) => e.selected).length;
    return Column(
      children: [
        // Toolbar
        Container(
          color: const Color(0xFF0D1F3C),
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            TextField(
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search methods…',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: _kAccentSoft),
                filled: true, fillColor: const Color(0xFF0A1628),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onChanged: (v) { _filterQuery = v; _applyFilter(); },
            ),
            const SizedBox(height: 8),
            Row(children: [
              Switch(
                value: _onlyInteresting,
                activeColor: _kAccent,
                onChanged: (v) { _onlyInteresting = v; _applyFilter(); },
              ),
              const Text('High-interest methods only', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const Spacer(),
              Text('${_filteredOffsets.length} shown',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ]),
          ]),
        ),

        // List
        Expanded(
          child: _filteredOffsets.isEmpty
            ? const Center(child: Text('No methods found.\nTry disabling the filter.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white38)))
            : ListView.builder(
                itemCount: _filteredOffsets.length,
                itemBuilder: (_, i) => _buildOffsetTile(_filteredOffsets[i]),
              ),
        ),

        // Bottom bar
        Container(
          padding: const EdgeInsets.all(16),
          color: const Color(0xFF0D1F3C),
          child: Row(children: [
            Text('$selected selected',
              style: TextStyle(color: selected > 0 ? _kAccent : Colors.white38,
                fontWeight: FontWeight.bold, fontSize: 16)),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: selected > 0 ? _startBuild : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.build),
              label: const Text('Build Mod APK', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _buildOffsetTile(OffsetEntry entry) {
    final color = entry.interestScore >= 8 ? Colors.orange
                : entry.interestScore >= 4 ? _kAccentSoft
                : Colors.white54;
    return InkWell(
      onTap: () {
        setState(() => entry.selected = !entry.selected);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10)),
        ),
        child: Row(children: [
          Checkbox(
            value: entry.selected,
            activeColor: _kAccent,
            onChanged: (v) => setState(() => entry.selected = v ?? false),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${entry.className}.${entry.name}',
                style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('${entry.returnType} · ${entry.offset}',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
          ),
          if (entry.interestScore > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: entry.interestScore >= 8 ? Colors.orange.withOpacity(0.2)
                     : _kAccentDark,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('⭐ ${entry.interestScore}',
                style: TextStyle(color: color, fontSize: 10)),
            ),
        ]),
      ),
    );
  }

  // ── Step 4: Done ──────────────────────────────────────────────────────────
  Widget _buildDoneStep() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: _kAccent, size: 80),
            const SizedBox(height: 20),
            const Text('Modded APK Ready!',
              style: TextStyle(color: _kAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(_resultPath,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            const Text(
              'The modded APK has been downloaded to your device. '
              'Install it to play with your selected mods active.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 32),
            SizedBox(width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _installApk,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent, foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.install_mobile),
                label: const Text('Install Now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => setState(() {
                _step = 0; _gamePath = null; _gameName = null;
                _logs = ''; _phase = ''; _resultPath = '';
                _allOffsets = []; _filteredOffsets = [];
              }),
              child: const Text('Mod Another Game', style: TextStyle(color: _kAccentSoft)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  Widget _sectionHeader(String text) => Text(text,
    style: const TextStyle(color: _kAccentSoft, fontSize: 14,
      fontWeight: FontWeight.bold, letterSpacing: 0.5));

  Widget _chip(IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: _kAccentDark.withOpacity(0.6),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _kAccent.withOpacity(0.3)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: _kAccent, size: 13),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: _kAccentSoft, fontSize: 11)),
    ]),
  );
}
