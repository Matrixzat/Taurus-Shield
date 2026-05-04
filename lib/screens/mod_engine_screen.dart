import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/theme_provider.dart';
import '../utils/storage_helper.dart';
import '../utils/permission_helper.dart';
import '../widgets/guide_modal.dart';

// Il2CppDumper + Mod — deep violet terminal theme
const _kAccent      = Color(0xFF8B5CF6);   // electric violet
const _kAccentDark  = Color(0xFF2D1B69);   // deep violet
const _kAccentSoft  = Color(0xFFA78BFA);   // soft lavender
const _kSurface     = Color(0xFF080812);   // near-black with purple tint
const _kSurface2    = Color(0xFF0F0B1E);   // card / section bg
const _kBorder      = Color(0xFF3D2A7A);   // subtle border

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
  bool    selected;
  String  featureType;   // bool | int | long | float | void | nop | branch_always | branch_never
  dynamic customValue;   // null = use smart default

  OffsetEntry({
    required this.name,
    required this.offset,
    required this.returnType,
    required this.className,
    required this.interestScore,
    this.selected    = false,
    this.featureType = 'bool',
    this.customValue,
  });

  // Smart default per type — overridden by customValue when set
  dynamic get resolvedValue {
    if (customValue != null) return customValue;
    switch (featureType) {
      case 'float':          return 1.0;
      case 'long':           return 999999;
      case 'bool':           return 1;       // ARM64: 1=true, 0=false
      case 'void':           return 0;
      case 'nop':            return 1;       // number of NOPs to write
      case 'branch_always':  return 0;       // Kotlin reads existing insn
      case 'branch_never':   return 0;       // Kotlin writes NOP
      default:               return 999999;  // int
    }
  }

  // ── Safety analysis — can this method be patched without crashing? ──────────
  bool get isSafe {
    final rt = returnType.trim().toLowerCase();
    final n  = name.toLowerCase();
    // Unsafe: event subscriptions, constructors, async state machines
    if (n.startsWith('add_on') || n.startsWith('remove_on')) return false;
    if (n == '.ctor' || n.contains('movenext') || n.contains('d__')) return false;
    // Unsafe: lifecycle callbacks
    if (RegExp(r'^on(game|manager|ready|load|boot|bootstrap)', caseSensitive: false).hasMatch(n)) return false;
    // Unsafe: returns complex/reference types
    if (RegExp(r'list|dictionary|task|ienumer|action|func|\[\]|queue|stack|class|object\b')
        .hasMatch(rt)) return false;
    // Unsafe: custom class returns (not primitive)
    final base = rt.split(' ').last;
    return ['bool','int','float','void','long','double','uint','short','string'].contains(base);
  }

  String get safetyLabel {
    if (isSafe) return 'Safe';
    final n = name.toLowerCase();
    if (n.startsWith('add_on') || n.startsWith('remove_on')) return 'Event handler';
    if (name == '.ctor') return 'Constructor';
    if (returnType.contains('List') || returnType.contains('[]')) return 'Returns array';
    if (returnType.contains('Dictionary')) return 'Returns map';
    if (returnType.contains('Task')) return 'Async';
    return 'Complex return';
  }

  Map<String, dynamic> toFeatureJson() => {
    'method':      name,
    'class':       className,
    'file_offset': offset,
    'type':        featureType,
    'value':       resolvedValue,
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

  String? _gamePath;     // slim zip — used for dump only
  String? _gameName;
  String? _dumpJsonPath;
  String? _buildApkPath; // original game APK — used for build only
  String? _buildApkName;

  List<OffsetEntry> _interestingOffsets = []; // scored/interesting methods only
  List<OffsetEntry> _fullOffsets        = []; // all 3 000+ methods
  List<OffsetEntry> _allOffsets         = []; // active source (one of the two above)
  List<OffsetEntry> _filteredOffsets    = [];
  final Set<int>    _selectedIdx        = {};
  String            _filterQuery        = '';
  bool              _onlyInteresting    = true;
  String?           _expectedPackage;         // guards APK picker

  bool   _isProcessing = false;
  String _logs         = '';
  String _phase        = '';
  String _resultPath   = '';
  String _dumpCsPath      = '';
  String _dumpHPath       = '';
  String _scriptJsonPath  = '';
  String _stringLitPath   = '';
  String _idaPyPath       = '';
  String _idaStructPath   = '';
  String _ghidraPyPath    = '';
  int    _progress        = -1;

  StreamSubscription<String>? _logSub;
  Timer? _pollTimer;
  Timer? _filterDebounce;

  // Value editor controllers — keyed by offset hex string
  final Map<String, TextEditingController> _valCtrl = {};

  TextEditingController _ctrlFor(OffsetEntry e) {
    return _valCtrl.putIfAbsent(e.offset, () {
      final init = switch (e.featureType) {
        'float'         => '1.0',
        'bool'          => '1',
        'void'          => '',
        'nop'           => '1',
        'branch_always' => '',
        'branch_never'  => '',
        _               => '999999',
      };
      return TextEditingController(text: init);
    });
  }

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
    _filterDebounce?.cancel();
    _logCtrl.dispose();
    for (final c in _valCtrl.values) c.dispose();
    super.dispose();
  }

  // ── Restore from background service state ─────────────────────────────────
  Future<void> _restoreState() async {
    try {
      final result = await _kModChannel.invokeMethod<Map>('getState');
      if (result == null) return;
      final running   = result['running'] as bool? ?? false;
      final phase     = result['phase']   as String? ?? '';
      final logs      = result['logs']    as String? ?? '';
      final status    = result['result_status'] as String? ?? '';
      final respath   = result['result']  as String? ?? '';
      final dumpCsPath     = result['dump_cs_path']       as String? ?? '';
      final dumpHPath      = result['dump_h_path']         as String? ?? '';
      final scriptJsonPath = result['script_json_path']    as String? ?? '';
      final stringLitPath  = result['stringliteral_path']  as String? ?? '';
      final idaPyPath      = result['ida_py_path']         as String? ?? '';
      final idaStructPath  = result['ida_struct_path']     as String? ?? '';
      final ghidraPyPath   = result['ghidra_py_path']      as String? ?? '';

      if (running) {
        setState(() { _isProcessing = true; _phase = phase; _logs = logs; });
        _startPolling();
        return;
      }

      if (status == 'success' && respath.isNotEmpty) {
        // Validate file still exists on disk (may be gone after reinstall / clear)
        final fileExists = File(respath).existsSync();
        if (!fileExists) {
          // Stale state — wipe and start fresh
          await _kModChannel.invokeMethod('clearState').catchError((_) {});
          return;
        }
        setState(() {
          _logs = logs;
          _resultPath     = respath;
          _dumpCsPath     = dumpCsPath;
          _dumpHPath      = dumpHPath;
          _scriptJsonPath = scriptJsonPath;
          _stringLitPath  = stringLitPath;
          _idaPyPath      = idaPyPath;
          _idaStructPath  = idaStructPath;
          _ghidraPyPath   = ghidraPyPath;
        });
        if (respath.endsWith('.json')) {
          await _loadDumpJson(respath); // populates _allOffsets and sets _step = 2
        } else if (respath.endsWith('.apk')) {
          setState(() { _step = 4; });
        }
        return;
      }

      if (phase == 'error') {
        setState(() { _phase = phase; _logs = logs; });
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

  // ── Step 0: Pick IL2CPP zip ───────────────────────────────────────────────
  Future<void> _pickGame() async {
    final hasPermission = await PermissionHelper.ensureStorage(context, accent: _kAccent);
    if (!hasPermission) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path!;
    final name = result.files.first.name
        .replaceAll('.zip', '')
        .replaceAll(' ', '_');
    setState(() {
      _gamePath = path;
      _gameName = name;
    });
  }

  // ── Step 0b: Pick original APK for build ─────────────────────────────────
  Future<void> _pickBuildApk() async {
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

    // ── Package name safety check ─────────────────────────────────────────
    // Read the APK's actual package name and warn if it doesn't match the
    // game that was dumped. Prevents accidentally patching the wrong app.
    try {
      final apkPackage = await _kModChannel.invokeMethod<String>('getApkPackage', {'path': path});
      if (apkPackage != null && _expectedPackage != null &&
          apkPackage != _expectedPackage) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _kSurface2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0xFFf87171), width: 1.5),
            ),
            title: const Row(children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFf87171), size: 22),
              SizedBox(width: 8),
              Text('Wrong APK', style: TextStyle(color: Color(0xFFf87171), fontSize: 16)),
            ]),
            content: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('This APK does not match the game you dumped.',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 12),
                _pkgRow('Dumped game', _expectedPackage!, Colors.greenAccent),
                const SizedBox(height: 6),
                _pkgRow('Selected APK', apkPackage, const Color(0xFFf87171)),
                const SizedBox(height: 14),
                const Text(
                  'Patching the wrong app will corrupt it and cause a crash on launch.',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFFf87171)),
                child: const Text('Patch Anyway (risky)'),
              ),
            ],
          ),
        );
        if (proceed != true) return; // user cancelled
      }
    } catch (_) {
      // getApkPackage failed — silently allow (older Android versions)
    }

    setState(() {
      _buildApkPath = path;
      _buildApkName = name;
    });
  }

  Widget _pkgRow(String label, String pkg, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
      const SizedBox(height: 2),
      Text(pkg,
        style: TextStyle(
          color: color, fontSize: 11.5,
          fontFamily: 'monospace', fontWeight: FontWeight.bold),
      ),
    ],
  );

  // ── Step 0c: Pick existing dump.json (skip analysis) ─────────────────────
  Future<void> _pickExistingDump() async {
    final hasPermission = await PermissionHelper.ensureStorage(context, accent: _kAccent);
    if (!hasPermission) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Pick offsets.json (or legacy dump.json)',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path!;
    // Validate it looks like a Taurus dump before loading
    try {
      final raw = File(path).readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (!decoded.containsKey('all_methods') && !decoded.containsKey('interesting_methods')) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That doesn\'t look like a Taurus offsets.json — missing method keys.'),
          backgroundColor: Color(0xFFef4444),
        ));
        return;
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not read that file — make sure it\'s a valid JSON dump.'),
        backgroundColor: Color(0xFFef4444),
      ));
      return;
    }
    await _loadDumpJson(path); // sets _step = 2 automatically
  }

  // ── Step 1: Dump ──────────────────────────────────────────────────────────
  Future<void> _startDump() async {
    if (_gamePath == null) return;
    setState(() { _step = 1; _isProcessing = true; _logs = ''; _phase = 'starting'; });
    try {
      await _kModChannel.invokeMethod('startDump', {'zip_path': _gamePath});
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

      // Capture expected package name so the APK picker can validate it
      _expectedPackage = json['package_name'] as String?;

      OffsetEntry _toEntry(Map<String, dynamic> m) {
        final score = (m['interest_score'] as num?)?.toInt() ?? 0;
        return OffsetEntry(
          name:          m['method']      as String? ?? '?',
          offset:        m['offset']      as String? ?? '0x0',
          returnType:    m['return_type'] as String? ?? 'void',
          className:     m['class']       as String? ?? '',
          interestScore: score,
          featureType:   _inferType(m['return_type'] as String? ?? ''),
        );
      }

      _interestingOffsets = interesting.map(_toEntry).toList();
      // full list = interesting + all (dedup by offset)
      final seenOffsets = <String>{};
      final combined = <OffsetEntry>[];
      for (final e in _interestingOffsets) {
        seenOffsets.add(e.offset);
        combined.add(e);
      }
      for (final m in all) {
        final offset = m['offset'] as String? ?? '';
        if (!seenOffsets.contains(offset)) {
          combined.add(_toEntry(m));
          seenOffsets.add(offset);
        }
      }
      _fullOffsets = combined;

      // Start in high-interest mode
      _onlyInteresting = true;
      _allOffsets = _interestingOffsets;
      _applyFilter();
      setState(() { _step = 2; });
    } catch (e) {
      _appendLog('Error loading dump: $e');
    }
  }

  String _inferType(String ret) {
    final r = ret.trim().toLowerCase();
    // Void — early-return patch (RET), no value needed
    if (r == 'void' || r == 'system.void' || r.isEmpty) return 'void';
    if (r.contains('bool')) return 'bool';
    // Signed 64-bit
    if (r.contains('int64') || r == 'long' || r.contains('uint64')) return 'long';
    // Float / double both fit in float patch
    if (r.contains('float') || r.contains('double') || r.contains('single')) return 'float';
    // Unsigned / signed 32-bit and smaller integers
    if (r.contains('uint32') || r.contains('uint16') || r.contains('uint8')  ||
        r.contains('uint')   || r.contains('int32')  || r.contains('int16')  ||
        r.contains('int8')   || r.contains('int')    || r.contains('short')  ||
        r.contains('byte')   || r.contains('sbyte')  || r.contains('char')) return 'int';
    // String / enum / object — can't trivially patch a return value; use void (RET)
    if (r.contains('string') || r.contains('enum') || r.contains('object')) return 'void';
    // Unknown complex type — default void is safer than a wrong value
    return 'void';
  }

  // ── Smart patch guidance engine ───────────────────────────────────────────
  // Analyses method name + return type + class name and returns a recommendation
  // covering every patch type: bool, int, long, float, void, NOP, branch patches.
  static ({IconData icon, Color color, String category, String tip, String why})
      _patchGuidance(OffsetEntry entry) {
    final n  = entry.name.toLowerCase();
    final rt = entry.returnType.trim().toLowerCase();
    final cn = entry.className.toLowerCase();

    // ── Ad / monetisation ──────────────────────────────────────────────────
    if (n.contains('ad') || n.contains('admob') || n.contains('banner') ||
        n.contains('interstitial') || n.contains('rewarded') ||
        n.contains('showad') || cn.contains('admob') || cn.contains('admanager')) {
      return (icon: Icons.block_rounded, color: const Color(0xFF818CF8),
        category: 'Ad method',
        tip: 'void  →  early return  |  bool → false',
        why: 'Void skips the entire ad call. If it returns bool ("should show ad?") flip to false.');
    }

    // ── Condition / unlock / gate checks ──────────────────────────────────
    if (n.startsWith('is_') || n.startsWith('has_') || n.startsWith('can_') ||
        n.startsWith('should_') || n.startsWith('check') ||
        n.contains('unlock') || n.contains('premium') || n.contains('purchase') ||
        n.contains('own') || n.contains('active') || n.contains('ready') ||
        n.contains('enable') || n.contains('available') || n.contains('eligible') ||
        (rt == 'bool' && (n.contains('lock') || n.contains('gate') || n.contains('allow')))) {
      return (icon: Icons.toggle_on_rounded, color: const Color(0xFF60A5FA),
        category: 'Condition / gate check',
        tip: 'bool → true  to always pass  |  false  to always block',
        why: 'This bool guards a feature or payment wall. true = gate always open, false = always closed.');
    }

    // ── Currency / score / resource ───────────────────────────────────────
    if (n.contains('coin') || n.contains('gold') || n.contains('gem') ||
        n.contains('cash') || n.contains('credit') || n.contains('score') ||
        n.contains('point') || n.contains('star') || n.contains('key') ||
        n.contains('diamond') || n.contains('currency') || n.contains('token') ||
        n.contains('resource') || n.contains('ticket') || n.contains('shard')) {
      final t = (rt.contains('int64') || rt == 'long') ? 'long' : 'int';
      return (icon: Icons.monetization_on_rounded, color: const Color(0xFFFBBF24),
        category: 'Currency / score getter',
        tip: '$t → 999999  (or any amount you want)',
        why: 'Game reads this as your balance or score — fixed return gives you unlimited resources.');
    }

    // ── Health / lives / energy ───────────────────────────────────────────
    if (n.contains('health') || n.contains('hp') || n.contains('live') ||
        n.contains('life') || n.contains('heart') || n.contains('energy') ||
        n.contains('shield') || n.contains('armor') || n.contains('mana') ||
        n.contains('stamina') || n.contains('revive')) {
      return (icon: Icons.favorite_rounded, color: const Color(0xFFef4444),
        category: 'Health / lives',
        tip: 'int → 999999  |  bool "isAlive" → true',
        why: 'Large int return = max HP/lives. For invincibility checks, flip bool to always true.');
    }

    // ── Speed / movement / physics ────────────────────────────────────────
    if (n.contains('speed') || n.contains('velocity') || n.contains('jump') ||
        n.contains('gravity') || n.contains('accel') || n.contains('dash') ||
        n.contains('movespeed') || (n.contains('move') && rt.contains('float'))) {
      return (icon: Icons.speed_rounded, color: const Color(0xFFf97316),
        category: 'Speed / movement',
        tip: 'float → 2.0–5.0  (start low — high values clip through geometry)',
        why: 'Multiplier or base rate. 2.0 = double speed. 0.3 = slow-mo. Gravity: 0.5 = low gravity.');
    }

    // ── Timer / cooldown ──────────────────────────────────────────────────
    if (n.contains('timer') || n.contains('cooldown') || n.contains('wait') ||
        n.contains('delay') || n.contains('duration') || n.contains('countdown') ||
        n.contains('interval') || n.contains('timeout') || n.contains('regen')) {
      return (icon: Icons.timer_off_rounded, color: const Color(0xFF818CF8),
        category: 'Timer / cooldown',
        tip: 'float → 0.0  |  NOP the increment instruction',
        why: '0.0 expires the timer instantly. NOP removes the countdown tick — freezes it at current value.');
    }

    // ── Enumeration return ────────────────────────────────────────────────
    if (rt.contains('enum') || rt.contains('state') || rt.contains('type') ||
        rt.contains('mode') || rt.contains('status') || rt.contains('phase')) {
      if (!rt.contains('list') && !rt.contains('dict') && !rt.contains('task') &&
          !rt.contains('bool') && !rt.contains('int') && !rt.contains('float')) {
        return (icon: Icons.format_list_numbered_rounded, color: const Color(0xFF34D399),
          category: 'Enumeration return',
          tip: 'int → 0  (first enum value)  |  1  (second)  |  etc.',
          why: 'Enum values are just ints internally. 0 = first state, 1 = second. Check the dump for the enum definition.');
      }
    }

    // ── Branch / condition instruction (advanced) ─────────────────────────
    if (n.startsWith('on_') || n.contains('trigger') || n.contains('fire') ||
        n.contains('dispatch') || (rt == 'bool' && n.contains('check'))) {
      return (icon: Icons.device_hub_rounded, color: const Color(0xFFA78BFA),
        category: 'Event / trigger',
        tip: 'void  (early return)  |  B never  to kill the trigger',
        why: 'Early void return prevents the event body from executing. B never kills a specific branch inside.');
    }

    // ── Void method ────────────────────────────────────────────────────────
    if (rt == 'void' || rt.isEmpty || rt == 'system.void') {
      return (icon: Icons.not_interested_rounded, color: const Color(0x99FFFFFF),
        category: 'Void method',
        tip: 'void  →  early RET skips body  |  NOP  kills one instruction',
        why: 'Nothing is returned. Early return prevents the method body running. NOP a specific instruction inside it instead.');
    }

    // ── Generic float getter ───────────────────────────────────────────────
    if (rt.contains('float') || rt.contains('double') || rt.contains('single')) {
      return (icon: Icons.numbers_rounded, color: const Color(0xFFFBBF24),
        category: 'Float value',
        tip: 'float → your target  (e.g. 1.0, 2.5, 0.0)',
        why: 'Decimal value the game uses as a rate, multiplier, or coordinate. Pick a value that makes sense for the method name.');
    }

    // ── Generic bool getter ────────────────────────────────────────────────
    if (rt == 'bool') {
      return (icon: Icons.toggle_on_rounded, color: const Color(0xFF60A5FA),
        category: 'Bool return',
        tip: 'bool → true  or  false  based on what you want to enable/disable',
        why: 'Controls a yes/no flag. Read the method name to decide which direction benefits you.');
    }

    // ── Generic int / long ────────────────────────────────────────────────
    if (rt.contains('int') || rt.contains('long') || rt.contains('uint') ||
        rt.contains('short') || rt.contains('byte')) {
      final t = (rt.contains('int64') || rt == 'long') ? 'long' : 'int';
      return (icon: Icons.numbers_rounded, color: const Color(0xFFFBBF24),
        category: 'Integer return',
        tip: '$t → 999999  |  0  to zero it out',
        why: 'Fixed numeric return. Set to 999999 for stat/resource maxing, or 0 to nullify it.');
    }

    // ── Complex / unsafe fallback ──────────────────────────────────────────
    return (icon: Icons.construction_rounded, color: const Color(0xFFf97316),
      category: 'Complex / advanced',
      tip: 'NOP  specific instruction  |  B never / B always  on branch',
      why: 'Cannot safely replace the return value — use a disassembler (Radare2/Ghidra) to find a NOP or branch target inside this method.');
  }

  // Debounced entry point — use this from UI text fields
  void _scheduleFilter() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 180), _applyFilter);
  }

  void _applyFilter() {
    final q = _filterQuery.toLowerCase().trim();
    // When searching, always search across ALL methods regardless of toggle
    final src = (q.isNotEmpty && _fullOffsets.isNotEmpty) ? _fullOffsets : _allOffsets;
    final result = q.isEmpty
        ? src
        : src.where((e) =>
            e.name.toLowerCase().contains(q) ||
            e.className.toLowerCase().contains(q) ||
            e.offset.toLowerCase().contains(q) ||
            e.returnType.toLowerCase().contains(q)).toList();
    setState(() { _filteredOffsets = result; });
  }

  // ── Step 3: Patch libil2cpp.so on-device ─────────────────────────────────
  Future<void> _startPatch() async {
    final selected = _fullOffsets.where((e) => e.selected).toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one method to patch')),
      );
      return;
    }
    if (_buildApkPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick the original game APK first')),
      );
      return;
    }

    final featuresJson = jsonEncode(selected.map((e) => e.toFeatureJson()).toList());
    setState(() { _step = 3; _isProcessing = true; _logs = ''; _phase = 'extracting'; });

    try {
      await _kModChannel.invokeMethod('startPatch', {
        'apk_path':      _buildApkPath,
        'game_name':     _buildApkName ?? _gameName ?? 'game',
        'features_json': featuresJson,
      });
      _startPolling();
    } catch (e) {
      _appendLog('Error starting patch: $e');
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
        final status     = r['result_status'] as String? ?? '';
        final respath    = r['result']  as String? ?? '';
        final dumpCsPath     = r['dump_cs_path']       as String? ?? '';
        final dumpHPath      = r['dump_h_path']         as String? ?? '';
        final scriptJsonPath = r['script_json_path']    as String? ?? '';
        final stringLitPath  = r['stringliteral_path']  as String? ?? '';
        final idaPyPath      = r['ida_py_path']         as String? ?? '';
        final idaStructPath  = r['ida_struct_path']     as String? ?? '';
        final ghidraPyPath   = r['ghidra_py_path']      as String? ?? '';
        final pct            = r['progress'] as int? ?? -1;

        setState(() {
          _isProcessing = running;
          _phase = phase;
          _logs  = logs;
          _progress = pct;
          if (dumpCsPath.isNotEmpty)     _dumpCsPath     = dumpCsPath;
          if (dumpHPath.isNotEmpty)      _dumpHPath      = dumpHPath;
          if (scriptJsonPath.isNotEmpty) _scriptJsonPath = scriptJsonPath;
          if (stringLitPath.isNotEmpty)  _stringLitPath  = stringLitPath;
          if (idaPyPath.isNotEmpty)      _idaPyPath      = idaPyPath;
          if (idaStructPath.isNotEmpty)  _idaStructPath  = idaStructPath;
          if (ghidraPyPath.isNotEmpty)   _ghidraPyPath   = ghidraPyPath;
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

  Future<void> _cancelJob() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D1F3C),
        title: const Text('Cancel job?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will stop the on-device patch immediately. Any progress will be lost.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep running', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel job', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _kModChannel.invokeMethod('modEngine_cancel');
      _pollTimer?.cancel();
      setState(() {
        _isProcessing = false;
        _phase = 'cancelled';
        _step  = _step > 2 ? 2 : 0;
      });
      _appendLog('Job cancelled.');
    } catch (e) {
      _appendLog('Cancel error: $e');
    }
  }

  void _appendLog(String msg) {
    setState(() { _logs = _logs.isEmpty ? msg : '$_logs\n$msg'; });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error: $msg'), backgroundColor: Colors.red[800]),
    );
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
        title: Row(children: [
          const Icon(Icons.terminal_rounded, color: _kAccent, size: 20),
          const SizedBox(width: 8),
          const Text('Il2CppDumper', style: TextStyle(color: _kAccent, fontWeight: FontWeight.bold, fontSize: 17)),
          const Text(' + Mod', style: TextStyle(color: _kAccentSoft, fontWeight: FontWeight.w400, fontSize: 14)),
        ]),
        actions: [
          if (_isProcessing)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
              tooltip: 'Cancel',
              onPressed: _cancelJob,
            ),
          if (_step > 0 && !_isProcessing)
            IconButton(
              icon: const Icon(Icons.refresh, color: _kAccentSoft),
              tooltip: 'Start over',
              onPressed: () => setState(() {
                _step = 0; _gamePath = null; _gameName = null;
                _logs = ''; _phase = ''; _resultPath = '';
                _dumpCsPath = ''; _dumpHPath = ''; _scriptJsonPath = ''; _stringLitPath = '';
                _idaPyPath = ''; _idaStructPath = ''; _ghidraPyPath = '';
                _allOffsets = []; _filteredOffsets = [];
              }),
            ),
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, color: _kAccentSoft),
            tooltip: 'How to use',
            onPressed: () => showGuideModal(context, initialIndex: 9, singleTool: true),
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
    const steps = ['Pick Game', 'Analyse', 'Select Features', 'Patch', 'Done'];
    return Container(
      color: _kSurface2,
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
                               const Color(0xFF1A1030),
                        border: Border.all(
                          color: active ? _kAccent : Colors.transparent, width: 2),
                      ),
                      child: Center(
                        child: done
                          ? const Icon(Icons.check, size: 16, color: Colors.white)
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
      case 1: return _buildProcessingStep('Analysing game…', 'Extracting IL2CPP symbols via Taurus cloud engine');
      case 2: return _buildFeatureSelectStep();
      case 3: return _buildProcessingStep('Patching libil2cpp.so…', 'Extracting binary from APK and writing ARM64 instructions on-device');
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
              gradient: LinearGradient(
                colors: [
                  _kAccentDark.withOpacity(0.85),
                  const Color(0xFF1A0A3C),
                ],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kAccent.withOpacity(0.4)),
              boxShadow: [
                BoxShadow(
                  color: _kAccent.withOpacity(0.15),
                  blurRadius: 24, spreadRadius: 0, offset: const Offset(0, 4)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _kAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _kAccent.withOpacity(0.4)),
                    ),
                    child: const Icon(Icons.terminal_rounded, color: _kAccent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Il2CppDumper + Mod',
                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                    Text('Unity IL2CPP · Static Binary Patch',
                      style: TextStyle(color: _kAccentSoft.withOpacity(0.7), fontSize: 11)),
                  ]),
                ]),
                const SizedBox(height: 12),
                const Text(
                  'Dumps the full C# method map from the game binary, lets you '
                  'search & configure which functions to patch — coins, speed, '
                  'unlocks, revive — then writes ARM64 instructions directly into '
                  'libil2cpp.so on your device. No root. No Frida. No cloud APK build.',
                  style: TextStyle(color: Colors.white60, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 14),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _chip(Icons.memory,         'On-Device Patch'),
                  _chip(Icons.terminal,       'Il2CppDumper'),
                  _chip(Icons.shield_outlined,'No Root Needed'),
                  _chip(Icons.sports_esports, 'Any Unity Game'),
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

          // ZIP picker
          _sectionHeader('Step 1 — Select IL2CPP Zip'),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _pickGame,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _kSurface2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _gamePath != null ? _kAccent : _kBorder,
                  width: _gamePath != null ? 2 : 1,
                ),
              ),
              child: _gamePath == null
                ? Column(children: [
                    Icon(Icons.folder_zip_outlined, color: _kAccent.withOpacity(0.5), size: 48),
                    const SizedBox(height: 12),
                    Text('Tap to pick the IL2CPP zip',
                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 15)),
                    const SizedBox(height: 4),
                    const Text('Zip must contain libil2cpp.so + global-metadata.dat',
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
          const SizedBox(height: 20),

          // ── OR divider ──────────────────────────────────────────────────
          Row(children: [
            Expanded(child: Divider(color: Colors.white12, thickness: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text('OR', style: TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            Expanded(child: Divider(color: Colors.white12, thickness: 1)),
          ]),
          const SizedBox(height: 20),

          // ── Already have dump.json? ──────────────────────────────────────
          GestureDetector(
            onTap: _pickExistingDump,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _kSurface2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF4ADE80).withOpacity(0.35)),
              ),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4ADE80).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF4ADE80).withOpacity(0.3)),
                  ),
                  child: const Icon(Icons.file_open_rounded, color: Color(0xFF4ADE80), size: 22),
                ),
                const SizedBox(width: 14),
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Already have an offsets.json?',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                  SizedBox(height: 3),
                  Text('Pick your saved offsets.json (or legacy dump.json) to skip analysis and go straight to patching',
                    style: TextStyle(color: Colors.white54, fontSize: 11.5, height: 1.4)),
                ])),
                const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _howItWorksCard() {
    final steps = [
      ('1', 'Pick zip with libil2cpp.so + global-metadata.dat', Icons.folder_zip_outlined),
      ('2', 'Zip sent for IL2CPP analysis — not the full APK', Icons.upload),
      ('3', 'Il2CppDumper maps all C# methods + file offsets', Icons.list_alt),
      ('4', 'You pick which functions to patch', Icons.tune),
      ('5', 'App writes ARM64 instructions at each offset on-device', Icons.memory),
      ('6', 'Patched libil2cpp.so auto-saved to Taurus-Shield/output/', Icons.save_alt),
      ('7', 'Replace libil2cpp.so in APK via MT Manager, sign and install', Icons.swap_horiz),
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

  // ── Log sanitiser — never expose internal URLs / tokens / workflow details ─
  static final _kSensitivePatterns = [
    RegExp(r'github\.com', caseSensitive: false),
    RegExp(r'api\.github', caseSensitive: false),
    RegExp(r'uploads\.github', caseSensitive: false),
    RegExp(r'workers\.dev', caseSensitive: false),
    RegExp(r'cloudflare', caseSensitive: false),
    RegExp(r'Authorization', caseSensitive: false),
    RegExp(r'token\s*[:=]', caseSensitive: false),
    RegExp(r'Bearer\s', caseSensitive: false),
    RegExp(r'GITHUB_', caseSensitive: false),
    RegExp(r'asset_id\s*[:=]', caseSensitive: false),
    RegExp(r'run_id\s*[:=]', caseSensitive: false),
    RegExp(r'release_id', caseSensitive: false),
    RegExp(r'curl\s+-', caseSensitive: false),
    RegExp(r'https?://(?!taurus)', caseSensitive: false),
  ];

  String _sanitiseLogs(String raw) {
    return raw.split('\n').where((line) {
      return !_kSensitivePatterns.any((p) => p.hasMatch(line));
    }).join('\n');
  }

  // ── Step 1/3: Processing ───────────────────────────────────────────────────
  Widget _buildProcessingStep(String title, String subtitle) {
    final cleanLogs = _sanitiseLogs(_logs);
    return Column(
      children: [
        // ── Compact header (no Expanded — log panel gets the space) ──────────
        Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _pulseAnim,
                builder: (_, __) => Opacity(
                  opacity: _pulseAnim.value,
                  child: const Icon(Icons.memory, color: _kAccent, size: 56),
                ),
              ),
              const SizedBox(height: 14),
              Text(title,
                style: const TextStyle(color: _kAccent, fontSize: 19, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 10),
              if (_phase.isNotEmpty) ...[
                if ((_phase == 'uploading' || _phase == 'downloading') && _progress >= 0) ...[
                  const SizedBox(height: 4),
                  SizedBox(
                    width: 220,
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text(
                          _phase == 'uploading' ? 'UPLOADING' : 'DOWNLOADING',
                          style: const TextStyle(color: _kAccent, fontSize: 11, letterSpacing: 1.2),
                        ),
                        Text('$_progress%',
                          style: const TextStyle(
                            color: _kAccentSoft, fontSize: 13,
                            fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                      ]),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _progress / 100.0,
                          backgroundColor: _kAccentDark,
                          valueColor: const AlwaysStoppedAnimation<Color>(_kAccent),
                          minHeight: 6,
                        ),
                      ),
                    ]),
                  ),
                ] else
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
            ],
          ),
        ),

        // ── Log panel — takes all remaining space ────────────────────────────
        Expanded(
          child: Container(
            width: double.infinity,
            color: Colors.black,
            child: cleanLogs.isEmpty
              ? const Center(
                  child: Text('Waiting for engine…',
                    style: TextStyle(color: Colors.white24, fontSize: 12,
                      fontFamily: 'monospace')),
                )
              : SingleChildScrollView(
                  controller: _logCtrl,
                  padding: const EdgeInsets.all(12),
                  child: Text(cleanLogs,
                    style: const TextStyle(color: Color(0xFF00FF88), fontSize: 11,
                      fontFamily: 'monospace', height: 1.4)),
                ),
          ),
        ),
      ],
    );
  }

  // ── Select helpers ────────────────────────────────────────────────────────
  void _selectAll() {
    setState(() { for (final e in _filteredOffsets) e.selected = true; });
  }

  void _selectNone() {
    // Clear across the full list so nothing stays ticked when switching views
    setState(() { for (final e in _fullOffsets) e.selected = false; });
  }

  /// Selects only safe-to-patch methods in the current visible list.
  void _selectSafe() {
    setState(() {
      for (final e in _filteredOffsets) {
        if (e.isSafe) e.selected = true;
      }
    });
  }

  // ── Review selected — bottom sheet ────────────────────────────────────────
  void _showReviewSheet() {
    final picks = _fullOffsets.where((e) => e.selected).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kSurface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final current = picks.where((e) => e.selected).toList();
          return DraggableScrollableSheet(
            initialChildSize: 0.65,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            expand: false,
            builder: (_, scroll) => Column(children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2)),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(children: [
                  const Icon(Icons.checklist_rounded, color: _kAccentSoft, size: 18),
                  const SizedBox(width: 8),
                  Text('${current.length} patches queued',
                    style: const TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      setSheet(() {
                        for (final e in picks) e.selected = false;
                      });
                      setState(() {});
                    },
                    child: const Text('Clear all',
                      style: TextStyle(color: Color(0xFFf87171), fontSize: 12)),
                  ),
                ]),
              ),
              const Divider(color: Colors.white10, height: 1),
              // List of selected methods
              Expanded(
                child: current.isEmpty
                  ? const Center(
                      child: Text('Nothing selected',
                        style: TextStyle(color: Colors.white38)))
                  : ListView.builder(
                      controller: scroll,
                      itemCount: current.length,
                      itemBuilder: (_, i) {
                        final e = current[i];
                        final isVoid = e.featureType == 'void' ||
                            e.featureType == 'branch_always' ||
                            e.featureType == 'branch_never';
                        final valStr = e.featureType == 'void'
                            ? 'no-op'
                            : e.featureType == 'branch_always'
                                ? 'force branch'
                                : e.featureType == 'branch_never'
                                    ? 'kill branch'
                                    : e.featureType == 'nop'
                                        ? '${e.resolvedValue ?? 1}× NOP'
                                        : e.featureType == 'bool'
                                            ? (e.resolvedValue == 1 ? 'true' : 'false')
                                            : '${e.resolvedValue}';
                        final typeColor = e.featureType == 'bool'
                            ? const Color(0xFF60A5FA)
                            : e.featureType == 'void'
                                ? const Color(0x61FFFFFF)
                                : e.featureType.startsWith('branch')
                                    ? const Color(0xFFA78BFA)
                                    : e.featureType == 'nop'
                                        ? const Color(0xFF34D399)
                                        : const Color(0xFFFBBF24);
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Colors.white10))),
                          child: Row(children: [
                            Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${e.className}.${e.name}',
                                  style: const TextStyle(
                                    color: Colors.white, fontSize: 12,
                                    fontWeight: FontWeight.w600),
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 3),
                                Row(children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: typeColor.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4)),
                                    child: Text(e.featureType,
                                      style: TextStyle(
                                        color: typeColor, fontSize: 9.5,
                                        fontFamily: 'monospace')),
                                  ),
                                  const SizedBox(width: 6),
                                  Text('→  $valStr',
                                    style: TextStyle(
                                      color: isVoid ? Colors.white38 : _kAccentSoft,
                                      fontSize: 11, fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 6),
                                  Text(e.offset,
                                    style: const TextStyle(
                                      color: Colors.white24, fontSize: 9.5,
                                      fontFamily: 'monospace')),
                                ]),
                              ],
                            )),
                            // Unselect button
                            GestureDetector(
                              onTap: () {
                                setSheet(() { e.selected = false; });
                                setState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF7F1D1D).withOpacity(0.4),
                                  shape: BoxShape.circle),
                                child: const Icon(Icons.close,
                                  color: Color(0xFFf87171), size: 14),
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
              ),
              // Build button inside sheet
              Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                color: _kSurface2,
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: (_buildApkPath != null && current.isNotEmpty)
                        ? () { Navigator.pop(ctx); _startPatch(); }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.memory),
                    label: Text(
                      _buildApkPath == null
                          ? 'Pick APK first'
                          : 'Patch ${current.length} methods → libil2cpp.so',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  // ── Step 2: Feature selection ─────────────────────────────────────────────
  Widget _buildFeatureSelectStep() {
    final selected      = _fullOffsets.where((e) => e.selected).length;
    final allVisible    = _filteredOffsets.isNotEmpty &&
                          _filteredOffsets.every((e) => e.selected);
    return Column(
      children: [
        // Toolbar
        Container(
          color: _kSurface2,
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            TextField(
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: _filterQuery.isEmpty
                    ? (_onlyInteresting
                        ? '${_interestingOffsets.length} suggestions — search all ${_fullOffsets.length} methods…'
                        : 'All ${_fullOffsets.length} methods — type to filter…')
                    : 'Searching ${_fullOffsets.length} methods…',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                prefixIcon: const Icon(Icons.search, color: _kAccentSoft),
                filled: true, fillColor: _kSurface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _kAccent, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                suffixIcon: _filterQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                        onPressed: () {
                          setState(() { _filterQuery = ''; });
                          _applyFilter();
                        },
                      )
                    : null,
              ),
              onChanged: (v) { _filterQuery = v; _scheduleFilter(); },
            ),
            const SizedBox(height: 8),
            // ── Row 1: toggle + count ────────────────────────────────────
            Row(children: [
              Switch(
                value: _onlyInteresting,
                activeColor: _filterQuery.isNotEmpty ? Colors.white24 : _kAccent,
                onChanged: _filterQuery.isNotEmpty
                    ? null
                    : (v) {
                        _onlyInteresting = v;
                        _allOffsets = v ? _interestingOffsets : _fullOffsets;
                        _applyFilter();
                      },
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Suggestions only',
                      style: TextStyle(
                        color: _filterQuery.isNotEmpty ? Colors.white24 : Colors.white70,
                        fontSize: 12, fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _onlyInteresting
                          ? 'Off = show all ${_fullOffsets.length} methods'
                          : 'Showing all ${_fullOffsets.length} methods',
                      style: TextStyle(
                        color: _filterQuery.isNotEmpty ? Colors.white12 : Colors.white38,
                        fontSize: 9.5,
                      ),
                    ),
                  ],
                ),
              ),
              // Count badge — right aligned
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (_filterQuery.isNotEmpty ? _kAccent : Colors.white).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_filteredOffsets.length} shown',
                  style: TextStyle(
                    color: _filterQuery.isNotEmpty ? _kAccent : Colors.white38,
                    fontSize: 10.5, fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            // ── Row 2: Smart Select | Deselect ───────────────────────────
            Row(children: [
              // Smart Select
              Expanded(
                child: GestureDetector(
                  onTap: _selectSafe,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF14532D).withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF4ADE80).withOpacity(0.6)),
                    ),
                    child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.verified_rounded, color: Color(0xFF4ADE80), size: 13),
                      SizedBox(width: 5),
                      Text('Smart Select',
                        style: TextStyle(color: Color(0xFF4ADE80),
                            fontSize: 11, fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Deselect All / Select All
              Expanded(
                child: GestureDetector(
                  onTap: allVisible ? _selectNone : _selectAll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: allVisible ? _kAccent.withOpacity(0.15) : _kAccentDark,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: allVisible ? _kAccent : _kAccentSoft.withOpacity(0.5)),
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(allVisible ? Icons.deselect : Icons.select_all,
                        color: allVisible ? _kAccent : _kAccentSoft, size: 13),
                      const SizedBox(width: 5),
                      Text(allVisible ? 'Deselect All' : 'Select All',
                        style: TextStyle(
                          color: allVisible ? _kAccent : _kAccentSoft,
                          fontSize: 11, fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
              ),
            ]),
          ]),
        ),

        // ── Dump files card ──────────────────────────────────────────────────
        Builder(builder: (ctx) {
          final files = <Map<String, String>>[
            if (_resultPath.isNotEmpty)     {'label': 'offsets.json',         'desc': 'Offsets — auto-loaded for patching',     'path': _resultPath},
            if (_dumpCsPath.isNotEmpty)     {'label': 'dump.cs',              'desc': 'C# classes · methods · fields',           'path': _dumpCsPath},
            if (_scriptJsonPath.isNotEmpty) {'label': 'script.json',          'desc': 'Raw RVA table for IDA / Ghidra scripts', 'path': _scriptJsonPath},
            if (_dumpHPath.isNotEmpty)      {'label': 'il2cpp.h',             'desc': 'C structure header for IDA Pro',          'path': _dumpHPath},
            if (_stringLitPath.isNotEmpty)  {'label': 'stringliteral.json',   'desc': 'All game string literals',                'path': _stringLitPath},
            if (_idaPyPath.isNotEmpty)      {'label': 'ida.py',               'desc': 'IDA Pro auto-label script',               'path': _idaPyPath},
            if (_idaStructPath.isNotEmpty)  {'label': 'ida_with_struct.py',   'desc': 'IDA Pro script + il2cpp.h structs',       'path': _idaStructPath},
            if (_ghidraPyPath.isNotEmpty)   {'label': 'ghidra.py',            'desc': 'Ghidra auto-label script',                'path': _ghidraPyPath},
          ];
          if (files.isEmpty) return const SizedBox.shrink();
          return Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            decoration: BoxDecoration(
              color: _kAccent.withOpacity(0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kAccent.withOpacity(0.25)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.folder_zip_outlined, color: _kAccent, size: 13),
                const SizedBox(width: 5),
                Text('${files.length} dump files saved  ·  Internal Storage/Taurus-Shield/output/mod-engine/',
                  style: const TextStyle(color: _kAccentSoft, fontSize: 9.5),
                  overflow: TextOverflow.ellipsis),
              ]),
              const SizedBox(height: 6),
              ...files.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(children: [
                  const Icon(Icons.insert_drive_file_outlined, color: _kAccentSoft, size: 13),
                  const SizedBox(width: 6),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(f['label']!,
                      style: const TextStyle(color: Colors.white, fontSize: 11,
                          fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                    Text(f['desc']!,
                      style: const TextStyle(color: Colors.white38, fontSize: 9.5)),
                  ])),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: f['path']!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${f['label']} path copied')));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: _kAccent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: _kAccent.withOpacity(0.35)),
                      ),
                      child: const Text('Copy',
                        style: TextStyle(color: _kAccent, fontSize: 9.5, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ]),
              )),
            ]),
          );
        }),

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

        // APK picker for build
        GestureDetector(
          onTap: _pickBuildApk,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0a0a18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _buildApkPath != null
                    ? const Color(0xFF4ADE80).withOpacity(0.6)
                    : const Color(0xFFef4444).withOpacity(0.4),
                width: 1.5,
              ),
            ),
            child: Row(children: [
              Icon(
                _buildApkPath != null ? Icons.android : Icons.upload_file_rounded,
                color: _buildApkPath != null ? const Color(0xFF4ADE80) : const Color(0xFFf97316),
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  _buildApkPath != null
                      ? 'APK ready — ${_buildApkName ?? ''}'
                      : 'Pick the original game APK',
                  style: TextStyle(
                    color: _buildApkPath != null ? const Color(0xFF4ADE80) : Colors.white70,
                    fontSize: 12, fontWeight: FontWeight.w600,
                  ),
                ),
                if (_buildApkPath == null) ...[
                  const SizedBox(height: 2),
                  const Text('libil2cpp.so will be extracted from it on-device',
                    style: TextStyle(color: Colors.white38, fontSize: 10.5)),
                ],
              ])),
              Text(
                _buildApkPath != null ? 'Change' : 'Pick APK',
                style: TextStyle(
                  color: _buildApkPath != null ? Colors.white38 : _kAccentSoft,
                  fontSize: 11, fontWeight: FontWeight.w600,
                ),
              ),
            ]),
          ),
        ),

        // Bottom bar
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          color: _kSurface2,
          child: Row(children: [
            // Tappable selected count — opens review sheet
            GestureDetector(
              onTap: selected > 0 ? _showReviewSheet : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: selected > 0 ? _kAccentDark : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected > 0 ? _kAccent : Colors.white12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.checklist_rounded,
                    color: selected > 0 ? _kAccentSoft : Colors.white24, size: 15),
                  const SizedBox(width: 6),
                  Text(
                    selected > 0 ? '$selected selected' : 'None selected',
                    style: TextStyle(
                      color: selected > 0 ? _kAccent : Colors.white38,
                      fontWeight: FontWeight.bold, fontSize: 14)),
                  if (selected > 0) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.expand_less, color: _kAccentSoft, size: 14),
                  ],
                ]),
              ),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: (selected > 0 && _buildApkPath != null) ? _startPatch : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.memory),
              label: const Text('Patch libil2cpp.so', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _buildOffsetTile(OffsetEntry entry) {
    final nameColor = entry.interestScore >= 8 ? Colors.orange
                    : entry.interestScore >= 4 ? _kAccentSoft
                    : Colors.white54;
    final isVoid    = entry.featureType == 'void';
    final isBool    = entry.featureType == 'bool';
    final isFloat   = entry.featureType == 'float';
    final isNop     = entry.featureType == 'nop';
    final isNoValue = isVoid ||
                      entry.featureType == 'branch_always' ||
                      entry.featureType == 'branch_never';

    final safeColor   = entry.isSafe ? const Color(0xFF4ADE80) : const Color(0xFFf87171);
    final safeBgColor = entry.isSafe
        ? const Color(0xFF14532D).withOpacity(0.5)
        : const Color(0xFF7F1D1D).withOpacity(0.4);

    return Container(
      decoration: BoxDecoration(
        color: entry.selected ? _kAccentDark.withOpacity(0.5) : Colors.transparent,
        border: const Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ────────────────────────────────────────────────────
          InkWell(
            onTap: () => setState(() => entry.selected = !entry.selected),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
              child: Row(children: [
                Checkbox(
                  value: entry.selected,
                  activeColor: _kAccent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => setState(() => entry.selected = v ?? false),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      '${entry.className}.${entry.name}',
                      style: TextStyle(
                        color: nameColor, fontSize: 12.5, fontWeight: FontWeight.bold),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      // Safety badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: safeBgColor,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: safeColor.withOpacity(0.4)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            entry.isSafe
                                ? Icons.verified_rounded
                                : Icons.warning_amber_rounded,
                            color: safeColor, size: 9),
                          const SizedBox(width: 3),
                          Text(entry.safetyLabel,
                            style: TextStyle(
                              color: safeColor, fontSize: 8.5,
                              fontWeight: FontWeight.bold)),
                        ]),
                      ),
                      const SizedBox(width: 6),
                      // Type badge — colour per patch type
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: _kSurface, borderRadius: BorderRadius.circular(4)),
                        child: Text(
                          switch (entry.featureType) {
                            'branch_always' => 'B always',
                            'branch_never'  => 'B never',
                            'nop'           => 'NOP',
                            _               => entry.featureType,
                          },
                          style: TextStyle(
                            color: switch (entry.featureType) {
                              'bool'          => const Color(0xFF60A5FA),
                              'int' || 'long' => const Color(0xFFFBBF24),
                              'float'         => const Color(0xFFFBBF24),
                              'void'          => const Color(0x61FFFFFF),
                              'nop'           => const Color(0xFF34D399),
                              'branch_always' ||
                              'branch_never'  => const Color(0xFFA78BFA),
                              _               => _kAccentSoft,
                            },
                            fontSize: 9.5, fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(entry.offset,
                        style: const TextStyle(color: Colors.white38, fontSize: 10.5,
                          fontFamily: 'monospace')),
                    ]),
                    const SizedBox(height: 4),
                    // ── Smart guidance hint (always visible) ──────────────
                    Builder(builder: (_) {
                      final g = _patchGuidance(entry);
                      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(g.icon, color: g.color, size: 10),
                        const SizedBox(width: 4),
                        Expanded(child: Text(
                          '${g.category}  ·  ${g.tip}',
                          style: TextStyle(
                            color: g.color.withOpacity(0.85),
                            fontSize: 9.5, height: 1.3),
                          maxLines: entry.selected ? 3 : 1,
                          overflow: TextOverflow.ellipsis,
                        )),
                      ]);
                    }),
                  ]),
                ),
                if (entry.interestScore > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: entry.interestScore >= 8
                          ? Colors.orange.withOpacity(0.18) : _kAccentDark,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('⭐ ${entry.interestScore}',
                      style: TextStyle(color: nameColor, fontSize: 9.5)),
                  ),
              ]),
            ),
          ),

          // ── When selected: why explanation + patch type picker + value editor
          if (entry.selected) ...[
            // Why explanation
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 2, 12, 6),
              child: Builder(builder: (_) {
                final g = _patchGuidance(entry);
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: g.color.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: g.color.withOpacity(0.2)),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline_rounded, color: g.color, size: 12),
                    const SizedBox(width: 6),
                    Expanded(child: Text(g.why,
                      style: TextStyle(color: g.color.withOpacity(0.9),
                        fontSize: 10.5, height: 1.5))),
                  ]),
                );
              }),
            ),
            // Type selector row
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 12, 4),
              child: _patchTypeSelector(entry),
            ),
            // Value editor — hidden for void / branch_always / branch_never
            if (!isNoValue)
              Padding(
                padding: const EdgeInsets.fromLTRB(52, 0, 12, 10),
                child: isBool
                  // Bool — true / false chips
                  ? Row(children: [
                      const Text('Return value:',
                        style: TextStyle(color: Colors.white54, fontSize: 11)),
                      const SizedBox(width: 10),
                      _boolChip(entry, 1, 'true  (enable)'),
                      const SizedBox(width: 6),
                      _boolChip(entry, 0, 'false (disable)'),
                    ])
                  // int / long / float / nop — text input
                  : Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _ctrlFor(entry),
                          keyboardType: isFloat
                              ? const TextInputType.numberWithOptions(decimal: true)
                              : TextInputType.number,
                          style: const TextStyle(
                            color: _kAccent, fontSize: 13, fontFamily: 'monospace'),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            hintText: isFloat
                                ? 'e.g. 2.5'
                                : isNop
                                    ? 'NOPs to write (default 1)'
                                    : 'e.g. 999999',
                            hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF0A1628),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: _kAccentDark),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: _kAccent),
                            ),
                            prefixIcon: const Icon(Icons.edit, color: _kAccentSoft, size: 14),
                            prefixIconConstraints:
                                const BoxConstraints(minWidth: 32, minHeight: 32),
                            suffixText: isFloat ? 'float' : isNop ? 'count' : entry.featureType,
                            suffixStyle: const TextStyle(color: Colors.white24, fontSize: 10),
                          ),
                          onChanged: (v) {
                            setState(() {
                              if (isFloat) {
                                entry.customValue = double.tryParse(v);
                              } else {
                                entry.customValue = int.tryParse(v);
                              }
                            });
                          },
                        ),
                      ),
                    ]),
              ),
          ],
        ],
      ),
    );
  }

  // ── Patch type selector — compact scrollable chip row ────────────────────
  Widget _patchTypeSelector(OffsetEntry entry) {
    const types = [
      ('bool',          'bool',     Color(0xFF60A5FA)),
      ('int',           'int',      Color(0xFFFBBF24)),
      ('float',         'float',    Color(0xFFFBBF24)),
      ('void',          'void',     Color(0x61FFFFFF)),
      ('nop',           'NOP',      Color(0xFF34D399)),
      ('branch_always', 'B always', Color(0xFFA78BFA)),
      ('branch_never',  'B never',  Color(0xFFA78BFA)),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          const Text('Type:',
            style: TextStyle(color: Colors.white38, fontSize: 10)),
          const SizedBox(width: 6),
          ...types.map((t) {
            final active = entry.featureType == t.$1;
            return GestureDetector(
              onTap: () => setState(() {
                entry.featureType = t.$1;
                entry.customValue = null;
                _valCtrl.remove(entry.offset);
              }),
              child: Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: active ? t.$3.withOpacity(0.18) : const Color(0xFF0A1628),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: active ? t.$3 : Colors.white12, width: 1),
                ),
                child: Text(t.$2,
                  style: TextStyle(
                    color: active ? t.$3 : Colors.white38,
                    fontSize: 10, fontFamily: 'monospace',
                    fontWeight: active ? FontWeight.bold : FontWeight.normal)),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _boolChip(OffsetEntry entry, int val, String label) {
    final active = (entry.customValue ?? entry.resolvedValue) == val;
    return GestureDetector(
      onTap: () => setState(() => entry.customValue = val),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? _kAccent.withOpacity(0.2) : const Color(0xFF0A1628),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? _kAccent : Colors.white24, width: 1),
        ),
        child: Text(label,
          style: TextStyle(
            color: active ? _kAccent : Colors.white38,
            fontSize: 11, fontWeight: active ? FontWeight.bold : FontWeight.normal)),
      ),
    );
  }

  // ── Step 4: Done ──────────────────────────────────────────────────────────
  Widget _buildDoneStep() {
    final fileName = _resultPath.split('/').last;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          const Icon(Icons.memory, color: _kAccent, size: 72),
          const SizedBox(height: 16),
          const Text('libil2cpp.so Patched!',
            style: TextStyle(color: _kAccent, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(fileName,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kAccentSoft, fontSize: 12, fontFamily: 'monospace'),
            maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          const Text('Internal Storage/Taurus-Shield/output/mod-engine/',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 24),

          // Step-by-step instructions
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _kSurface2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kAccent.withOpacity(0.25)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Next steps', style: TextStyle(
                color: _kAccentSoft, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              _doneStep('1', Icons.folder_open, 'Open your original game APK in MT Manager'),
              _doneStep('2', Icons.folder, 'Navigate to  lib › arm64-v8a'),
              _doneStep('3', Icons.swap_horiz, 'Long-press libil2cpp.so → Replace with the patched file above'),
              _doneStep('4', Icons.build_circle_outlined, 'Sign the APK (MT Manager → Sign)'),
              _doneStep('5', Icons.install_mobile, 'Install the signed APK over the original game'),
            ]),
          ),
          const SizedBox(height: 20),

          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                // Share the .so file path via clipboard
                Clipboard.setData(ClipboardData(text: _resultPath));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('File path copied to clipboard')));
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _kAccentDark,
                foregroundColor: _kAccent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: _kAccent, width: 1)),
              ),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy File Path', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => setState(() {
              _step = 2; _resultPath = ''; _phase = ''; _logs = '';
            }),
            child: const Text('← Back to Feature Select', style: TextStyle(color: _kAccentSoft)),
          ),
          TextButton(
            onPressed: () => setState(() {
              _step = 0; _gamePath = null; _gameName = null;
              _buildApkPath = null; _buildApkName = null;
              _logs = ''; _phase = ''; _resultPath = '';
              _dumpCsPath = ''; _dumpHPath = ''; _scriptJsonPath = ''; _stringLitPath = '';
              _idaPyPath = ''; _idaStructPath = ''; _ghidraPyPath = '';
              _allOffsets = []; _filteredOffsets = [];
            }),
            child: const Text('Patch Another Game', style: TextStyle(color: Colors.white38)),
          ),
        ],
      ),
    );
  }

  Widget _doneStep(String num, IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 22, height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _kAccent.withOpacity(0.15),
          border: Border.all(color: _kAccent.withOpacity(0.5))),
        child: Center(child: Text(num,
          style: const TextStyle(color: _kAccent, fontSize: 10, fontWeight: FontWeight.bold))),
      ),
      const SizedBox(width: 10),
      Icon(icon, color: _kAccentSoft, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(text,
        style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.4))),
    ]),
  );

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
