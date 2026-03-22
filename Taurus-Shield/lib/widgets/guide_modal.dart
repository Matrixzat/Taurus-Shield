import 'package:flutter/material.dart';

void showGuideModal(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _GuideSheet(),
  );
}

// ── Outer sheet — HBC Tool | Blutter | Dex2C ──────────────────────────────────

class _GuideSheet extends StatefulWidget {
  const _GuideSheet();
  @override
  State<_GuideSheet> createState() => _GuideSheetState();
}

class _GuideSheetState extends State<_GuideSheet>
    with SingleTickerProviderStateMixin {
  late TabController _outerTab;

  @override
  void initState() {
    super.initState();
    _outerTab = TabController(length: 8, vsync: this);
    _outerTab.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _outerTab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: const BoxDecoration(
        color: Color(0xFF0d0d20),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: Color(0xFF7c3aed), width: 1.5),
        ),
      ),
      child: Column(
        children: [
          // ── Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF4b3a6e),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // ── Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7c3aed).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: const Color(0xFF7c3aed).withOpacity(0.4)),
                  ),
                  child: const Icon(Icons.menu_book_rounded,
                      color: Color(0xFF9d5cf6), size: 20),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'HOW TO USE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      'Step-by-step guide',
                      style: TextStyle(
                          color: Color(0xFF6b7280), fontSize: 11),
                    ),
                  ],
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1e1e3a),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: Color(0xFF6b7280), size: 18),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ── Outer tool tabs (wrapped, 2 rows)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: AnimatedBuilder(
              animation: _outerTab,
              builder: (_, __) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _GuideTab(index: 0, label: 'HBC Tool',   icon: Icons.terminal_rounded,                  color: const Color(0xFF7c3aed), controller: _outerTab),
                      _GuideTab(index: 1, label: 'Spoofer',    icon: Icons.perm_device_information_rounded,   color: const Color(0xFF0891b2), controller: _outerTab),
                      _GuideTab(index: 2, label: 'Blutter',    icon: Icons.biotech_rounded,                   color: const Color(0xFF0e7490), controller: _outerTab),
                      _GuideTab(index: 3, label: 'Dex2C',      icon: Icons.enhanced_encryption_rounded,       color: const Color(0xFF059669), controller: _outerTab),
                      _GuideTab(index: 4, label: 'DPT Shell',  icon: Icons.security_rounded,                  color: const Color(0xFFea580c), controller: _outerTab),
                      _GuideTab(index: 5, label: 'APK Tool',   icon: Icons.android_rounded,                   color: const Color(0xFF1d4ed8), controller: _outerTab),
                      _GuideTab(index: 6, label: 'Ads Patch',  icon: Icons.block_rounded,                     color: const Color(0xFFef4444), controller: _outerTab),
                      _GuideTab(index: 7, label: 'Anti-Dialog', icon: Icons.shield_rounded,                   color: const Color(0xFF8B5CF6), controller: _outerTab),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Color(0xFF1e1e3a), height: 1, thickness: 1),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          // ── Content
          Expanded(
            child: TabBarView(
              controller: _outerTab,
              children: const [
                _HbcTabContent(),
                _SpoofGuide(),
                _BlutterGuide(),
                _Dex2CGuide(),
                _DptShellGuide(),
                _ApkToolGuide(),
                _AdsPatchGuide(),
                _AntiKillerGuide(),
              ],
            ),
          ),
          SizedBox(height: bottom + 8),
        ],
      ),
    );
  }
}

// ── HBC Tool tab — contains inner Disassemble / Assemble tabs ──────────────────

class _HbcTabContent extends StatefulWidget {
  const _HbcTabContent();
  @override
  State<_HbcTabContent> createState() => _HbcTabContentState();
}

class _HbcTabContentState extends State<_HbcTabContent>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0a0a18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1e1e3a)),
            ),
            child: TabBar(
              controller: _tab,
              indicator: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7c3aed), Color(0xFF4f1fa0)],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: Colors.white,
              unselectedLabelColor: const Color(0xFF6b7280),
              labelStyle: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 13),
              unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w500, fontSize: 13),
              tabs: const [
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.code_rounded, size: 15),
                      SizedBox(width: 6),
                      Text('Disassemble'),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.build_rounded, size: 15),
                      SizedBox(width: 6),
                      Text('Assemble'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _StepList(steps: _dsmSteps),
              _StepList(steps: _asmSteps),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Blutter guide tab ──────────────────────────────────────────────────────────

class _BlutterGuide extends StatelessWidget {
  const _BlutterGuide();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: _blutterSteps.length + 1,
      separatorBuilder: (_, i) => i < _blutterSteps.length - 1
          ? _StepConnector(color: const Color(0xFF22d3ee))
          : const SizedBox(height: 20),
      itemBuilder: (_, i) {
        if (i < _blutterSteps.length) {
          return _StepCard(step: _blutterSteps[i], index: i);
        }
        return _BlutterOutputNote();
      },
    );
  }
}

class _BlutterOutputNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0a161e),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFF22d3ee).withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF22d3ee).withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.folder_open_rounded,
                color: Color(0xFF22d3ee), size: 18),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Where to find your output',
                  style: TextStyle(
                    color: Color(0xFF22d3ee),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Open any file manager and navigate to:',
                  style: TextStyle(
                      color: Color(0xFF6b7280), fontSize: 11.5),
                ),
                SizedBox(height: 6),
                Text(
                  'Internal Storage → Taurus-Shield → output → blutter',
                  style: TextStyle(
                    color: Color(0xFF67e8f9),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Dex2C guide tab ────────────────────────────────────────────────────────────

class _Dex2CGuide extends StatelessWidget {
  const _Dex2CGuide();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: _dex2cSteps.length + 1,
      separatorBuilder: (_, i) => i < _dex2cSteps.length - 1
          ? _StepConnector(color: const Color(0xFF10b981))
          : const SizedBox(height: 20),
      itemBuilder: (_, i) {
        if (i < _dex2cSteps.length) {
          return _StepCard(step: _dex2cSteps[i], index: i);
        }
        return _Dex2COutputNote();
      },
    );
  }
}

class _Dex2COutputNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF091a12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFF10b981).withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF10b981).withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.folder_open_rounded,
                color: Color(0xFF10b981), size: 18),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Where to find your protected APK',
                  style: TextStyle(
                    color: Color(0xFF10b981),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Open any file manager and navigate to:',
                  style: TextStyle(
                      color: Color(0xFF6b7280), fontSize: 11.5),
                ),
                SizedBox(height: 6),
                Text(
                  'Internal Storage → Taurus-Shield → output → dex2c',
                  style: TextStyle(
                    color: Color(0xFF34d399),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared widgets ─────────────────────────────────────────────────────────────

class _StepList extends StatelessWidget {
  final List<_Step> steps;
  const _StepList({required this.steps});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: steps.length + 1,
      separatorBuilder: (_, i) => i < steps.length - 1
          ? _StepConnector(color: const Color(0xFF7c3aed))
          : const SizedBox(height: 20),
      itemBuilder: (_, i) {
        if (i < steps.length) return _StepCard(step: steps[i], index: i);
        return _OutputNote();
      },
    );
  }
}

class _StepConnector extends StatelessWidget {
  final Color color;
  const _StepConnector({required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 22),
      child: Container(
        width: 2,
        height: 18,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              color.withOpacity(0.5),
              color.withOpacity(0.15),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final _Step step;
  final int index;
  const _StepCard({required this.step, required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0f0f22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: step.color.withOpacity(0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: step.color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: step.color.withOpacity(0.5)),
            ),
            child: Center(
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  color: step.color,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(step.icon, color: step.color, size: 15),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        step.title,
                        style: TextStyle(
                          color: step.color,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  step.body,
                  style: const TextStyle(
                    color: Color(0xFFa0aec0),
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                if (step.tag != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: step.color.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: step.color.withOpacity(0.3)),
                    ),
                    child: Text(
                      step.tag!,
                      style: TextStyle(
                        color: step.color,
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OutputNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0a160a),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFF22c55e).withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF22c55e).withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.folder_open_rounded,
                color: Color(0xFF22c55e), size: 18),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Where to find your output',
                  style: TextStyle(
                    color: Color(0xFF22c55e),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Open any file manager app and navigate to:',
                  style: TextStyle(
                      color: Color(0xFF6b7280), fontSize: 11.5),
                ),
                SizedBox(height: 6),
                Text(
                  'Internal Storage → Taurus-Shield → output',
                  style: TextStyle(
                    color: Color(0xFF4ade80),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Step data model ────────────────────────────────────────────────────────────

class _Step {
  final IconData icon;
  final String title;
  final String body;
  final Color color;
  final String? tag;
  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
    this.tag,
  });
}

const Color _purple  = Color(0xFF9d5cf6);
const Color _cyan    = Color(0xFF22d3ee);
const Color _amber   = Color(0xFFfbbf24);
const Color _green   = Color(0xFF4ade80);
const Color _teal    = Color(0xFF2dd4bf);
const Color _sky     = Color(0xFF38bdf8);
const Color _rose    = Color(0xFFfb7185);
const Color _emerald = Color(0xFF10b981);
const Color _lime    = Color(0xFF86efac);

// ── HBC Tool — Disassemble steps ───────────────────────────────────────────────

const List<_Step> _dsmSteps = [
  _Step(
    icon: Icons.touch_app_rounded,
    title: 'Open the file picker',
    body: 'Tap the file select area in the centre of the home screen.',
    color: _purple,
  ),
  _Step(
    icon: Icons.insert_drive_file_rounded,
    title: 'Pick your bytecode file',
    body: 'Choose a .bundle or .hbc file. You can also select a .zip that contains a .bundle or .hbc inside — it will be extracted automatically.',
    color: _cyan,
    tag: 'Accepted: .bundle  .hbc  .zip (containing bundle)',
  ),
  _Step(
    icon: Icons.auto_awesome_rounded,
    title: 'Mode auto-detects as DSM',
    body: 'The pill badge below the file name will show "DSM". If it shows something else, the file may not be a valid Hermes bytecode.',
    color: _amber,
  ),
  _Step(
    icon: Icons.play_arrow_rounded,
    title: 'Tap "Disassemble (DSM)"',
    body: 'Press the large purple button. A progress log appears showing each step of the disassembly.',
    color: _purple,
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Done — check your output',
    body: 'A confirmation toast appears when finished. Your .hasm files are saved to the output folder shown below.',
    color: _green,
  ),
];

// ── HBC Tool — Assemble steps ──────────────────────────────────────────────────

const List<_Step> _asmSteps = [
  _Step(
    icon: Icons.touch_app_rounded,
    title: 'Open the file picker',
    body: 'Tap the file select area in the centre of the home screen.',
    color: _purple,
  ),
  _Step(
    icon: Icons.folder_zip_rounded,
    title: 'Pick your hasm file or zip',
    body: 'Choose a .hasm file directly, or a .zip folder that contains .hasm + metadata.json inside. The folder inside the zip can have any name.',
    color: _cyan,
    tag: 'Accepted: .hasm  .zip (containing .hasm + metadata.json)',
  ),
  _Step(
    icon: Icons.auto_awesome_rounded,
    title: 'Mode auto-detects as ASM',
    body: 'The pill badge will show "ASM". If you picked a zip, it is scanned internally to confirm it contains hasm assembly files.',
    color: _amber,
  ),
  _Step(
    icon: Icons.play_arrow_rounded,
    title: 'Tap "Assemble (ASM)"',
    body: 'Press the large purple button. The assembler reads the hasm files and rebuilds the Hermes bytecode.',
    color: _purple,
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Done — check your output',
    body: 'A confirmation toast appears when finished. Your rebuilt .hbc file is saved to the output folder shown below.',
    color: _green,
  ),
];

// ── Blutter — step-by-step guide ──────────────────────────────────────────────

const List<_Step> _blutterSteps = [
  _Step(
    icon: Icons.folder_zip_rounded,
    title: 'Get the arm64-v8a folder',
    body: 'Rename your target Flutter APK to .zip and extract it. Inside you will find a lib/arm64-v8a/ folder. That folder contains the two files you need.',
    color: _amber,
    tag: 'lib/arm64-v8a/  →  libapp.so  +  libflutter.so',
  ),
  _Step(
    icon: Icons.archive_rounded,
    title: 'Create a ZIP archive',
    body: 'Select both libapp.so and libflutter.so (or the entire arm64-v8a folder) and compress them into a single .zip file. Name it anything you like — e.g. arm64-v8a.zip.',
    color: _sky,
    tag: 'Required inside ZIP: libapp.so  +  libflutter.so',
  ),
  _Step(
    icon: Icons.touch_app_rounded,
    title: 'Open Blutter from the tool picker',
    body: 'From the main screen tap "Blutter — Flutter RE" to open the Blutter analyser.',
    color: _cyan,
  ),
  _Step(
    icon: Icons.upload_file_rounded,
    title: 'Select your ZIP file',
    body: 'Tap the file selector area and pick the arm64-v8a.zip you just created. Only .zip files are accepted here.',
    color: _teal,
    tag: 'Accepted: .zip  (must contain libapp.so)',
  ),
  _Step(
    icon: Icons.manage_search_rounded,
    title: 'Dart version auto-detected',
    body: 'The app reads libflutter.so inside the ZIP to find the Dart VM version. This works even on fully stripped release builds where libapp.so has no version string.',
    color: _cyan,
  ),
  _Step(
    icon: Icons.tag_rounded,
    title: 'Version not found? Use "Set Ver"',
    body: 'If auto-detection still fails (very rare), tap the "Set Ver" button next to Analyse. Enter the Dart version in X.Y.Z format — you can find it in the Flutter build logs or pubspec.lock of the original project.',
    color: _rose,
    tag: 'Example: 3.4.0  or  3.10.6',
  ),
  _Step(
    icon: Icons.play_arrow_rounded,
    title: 'Tap "Analyse (Blutter)"',
    body: 'Press the cyan button. If this is the first time for this Dart version, the matching blutter engine (~30–50 MB) is downloaded automatically. Internet is required for this step only.',
    color: _cyan,
  ),
  _Step(
    icon: Icons.terminal_rounded,
    title: 'Watch the live log',
    body: 'The output console streams blutter\'s progress in real time. Use the auto-scroll toggle to follow the log or scroll freely. Copy the full log with the copy button.',
    color: _teal,
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Analysis complete',
    body: 'A toast confirms success. Your Dart symbols, class dumps, and disassembly are saved to the output folder shown below. Re-running with the same Dart version is instant — no re-download needed.',
    color: _green,
  ),
];

const Color _orange  = Color(0xFFf97316);
const Color _orangeL = Color(0xFFfb923c);

// ── DPT Shell ─────────────────────────────────────────────────────────────────

class _DptShellGuide extends StatelessWidget {
  const _DptShellGuide();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: _dptShellSteps.length + 1,
      separatorBuilder: (_, i) => i < _dptShellSteps.length - 1
          ? _StepConnector(color: _orange)
          : const SizedBox(height: 20),
      itemBuilder: (_, i) {
        if (i < _dptShellSteps.length) {
          return _StepCard(step: _dptShellSteps[i], index: i);
        }
        return _DptShellOutputNote();
      },
    );
  }
}

class _DptShellOutputNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1a0e00),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _orange.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _orange.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.folder_open_rounded,
                color: _orange, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Where to find your protected APK',
                  style: TextStyle(
                    color: _orange,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Open any file manager and navigate to:',
                  style: TextStyle(
                      color: Color(0xFF6b7280), fontSize: 11.5),
                ),
                const SizedBox(height: 6),
                Text(
                  'Internal Storage → Taurus-Shield → output → dptshell',
                  style: TextStyle(
                    color: _orangeL,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const List<_Step> _dptShellSteps = [
  _Step(
    icon: Icons.info_outline_rounded,
    title: 'What is DPT Shell?',
    body: 'DPT Shell applies DEX hollowing protection to your APK. It extracts each '
        'DEX class\'s bytecode and wraps it inside a native shell layer (.so), '
        'preventing static decompilation and analysis of your code.\n\n'
        'The original DEX files are replaced with hollowed stubs; the real logic '
        'only runs through the native shell at runtime.',
    color: _orange,
    tag: 'Technique: DEX Hollowing',
  ),
  _Step(
    icon: Icons.touch_app_rounded,
    title: 'Open DPT Shell from the tool picker',
    body: 'From the main screen tap "DPT Shell — DEX Hollowing Protection" to open the protection screen.',
    color: _orange,
  ),
  _Step(
    icon: Icons.android_rounded,
    title: 'Select your APK file',
    body: 'Tap the file selector and pick your .apk file directly. '
        'No ZIP packaging is needed — just select the APK and the app handles the rest. '
        'Files up to 100 MB are supported.',
    color: _orangeL,
    tag: 'Accepted: .apk  (Max 100 MB)',
  ),
  _Step(
    icon: Icons.toggle_on_rounded,
    title: 'Choose signing option',
    body: 'Toggle "Sign APK" on to have the protected APK automatically signed with a debug keystore — useful for testing. '
        'Turn it off if you want to sign with your own release key after downloading.',
    color: _orange,
  ),
  _Step(
    icon: Icons.cloud_upload_rounded,
    title: 'Tap "Protect (DPT Shell)"',
    body: 'Press the orange button. Your APK is packaged and uploaded to the cloud, '
        'then a GitHub Actions job runs the DPT-Shell engine automatically. '
        'An active internet connection is required.',
    color: _orange,
  ),
  _Step(
    icon: Icons.terminal_rounded,
    title: 'Watch live cloud progress',
    body: 'The log panel streams real-time updates — packaging, upload, extract, install Java, '
        'download DPT Shell, apply DEX hollowing, sign. '
        'The timer shows elapsed time. DPT Shell typically takes 3–10 minutes.',
    color: _orangeL,
    tag: 'Avg: 3–10 min',
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Done — protected APK downloaded',
    body: 'A success toast confirms completion. Your shell-protected APK is automatically '
        'downloaded from the cloud and saved to the output folder on your device. '
        'Install it directly to test the protection.',
    color: _green,
  ),
];

// ── Dex2C — step-by-step guide ─────────────────────────────────────────────────

const List<_Step> _dex2cSteps = [
  _Step(
    icon: Icons.edit_note_rounded,
    title: 'Write your filter.txt',
    body: 'Each line is a regex rule in the format  class/path;method_name.\n\n'
        'WHITELIST (protect): lines without ! — matched methods get compiled to native .so.\n'
        'BLACKLIST (exclude): prefix a line with ! — those methods are left as-is.\n\n'
        'To protect the ENTIRE APK just put a single line:  .*\n\n'
        'To target specific classes/methods use the class path and method name separated by a semicolon:\n\n'
        '  .*                                → protect every method in the whole APK\n'
        '  com/example/app/Utils;.*          → protect all methods in Utils\n'
        '  com/example/app/Utils;encrypt\\(.*  → protect only the encrypt method\n'
        '  com/example/secure/.*;.*           → protect every class under a package\n'
        '  .*;onCreate\\(.*                   → protect onCreate in every class\n'
        '  !.*;onCreate\\(.*                  → exclude onCreate everywhere\n'
        '  !com/example/app/MainActivity;.*  → exclude all of MainActivity',
    color: _lime,
    tag: 'Tip: a single line  .*  protects the whole APK  |  ! = exclude',
  ),
  _Step(
    icon: Icons.folder_zip_rounded,
    title: 'Pack your ZIP',
    body: 'Create a ZIP file containing exactly one .apk and the filter.txt you just made. Both files must be at the root of the ZIP — not inside a sub-folder.',
    color: _emerald,
    tag: 'Required inside ZIP: app.apk  +  filter.txt',
  ),
  _Step(
    icon: Icons.touch_app_rounded,
    title: 'Open Dex2C from the tool picker',
    body: 'From the main screen tap "Dex2C — APK Native Protection" to open the protection screen.',
    color: _emerald,
  ),
  _Step(
    icon: Icons.upload_file_rounded,
    title: 'Select your ZIP file',
    body: 'Tap the file selector and choose your prepared ZIP. The app checks it contains exactly one .apk and one filter.txt before letting you proceed.',
    color: _teal,
    tag: 'Accepted: .zip  (must contain .apk + filter.txt)',
  ),
  _Step(
    icon: Icons.toggle_on_rounded,
    title: 'Choose signing option',
    body: 'Toggle "Sign APK" on to have the protected APK automatically signed with a debug keystore — useful for testing. Turn it off if you want to sign it with your own release key later.',
    color: _lime,
  ),
  _Step(
    icon: Icons.cloud_upload_rounded,
    title: 'Tap "Start Cloud Protection"',
    body: 'Press the green button. Your ZIP is uploaded to the cloud and a GitHub Actions job starts automatically. An active internet connection is required for this step.',
    color: _emerald,
  ),
  _Step(
    icon: Icons.terminal_rounded,
    title: 'Watch live cloud progress',
    body: 'The log panel streams real-time updates from the GitHub Actions job — upload, compile, convert DEX to C, sign. The timer shows elapsed time. This may take 5–20 minutes depending on APK size.',
    color: _teal,
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Done — protected APK downloaded',
    body: 'A success toast confirms completion. Your protected APK is automatically downloaded from the cloud and saved to the output folder. Install it directly on your device.',
    color: _green,
  ),
];

// ── APK Tool ───────────────────────────────────────────────────────────────────

const Color _blue  = Color(0xFF3b82f6);
const Color _blueL = Color(0xFF60a5fa);

class _ApkToolGuide extends StatefulWidget {
  const _ApkToolGuide();
  @override
  State<_ApkToolGuide> createState() => _ApkToolGuideState();
}

class _ApkToolGuideState extends State<_ApkToolGuide>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0a0a18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF1e1e3a)),
          ),
          child: TabBar(
            controller: _tab,
            indicator: BoxDecoration(
              gradient: LinearGradient(
                colors: [_blue, const Color(0xFF1d4ed8)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            labelColor: Colors.white,
            unselectedLabelColor: const Color(0xFF6b7280),
            labelStyle: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 12),
            unselectedLabelStyle: const TextStyle(
                fontWeight: FontWeight.w500, fontSize: 12),
            tabs: const [
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_downward_rounded, size: 14),
                    SizedBox(width: 5),
                    Text('Decompile'),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_upward_rounded, size: 14),
                    SizedBox(width: 5),
                    Text('Recompile'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      Expanded(
        child: TabBarView(
          controller: _tab,
          children: [
            _ApkToolStepList(steps: _apkDecompileSteps),
            _ApkToolStepList(steps: _apkRecompileSteps),
          ],
        ),
      ),
    ]);
  }
}

class _ApkToolStepList extends StatelessWidget {
  final List<_Step> steps;
  const _ApkToolStepList({required this.steps});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: steps.length + 1,
      separatorBuilder: (_, i) => i < steps.length - 1
          ? _StepConnector(color: _blue)
          : const SizedBox(height: 20),
      itemBuilder: (_, i) {
        if (i < steps.length) return _StepCard(step: steps[i], index: i);
        return _ApkToolOutputNote();
      },
    );
  }
}

class _ApkToolOutputNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0a1020),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _blue.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _blue.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.folder_open_rounded, color: _blue, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Where to find your output',
                  style: TextStyle(
                    color: _blue,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Open any file manager and navigate to:',
                  style: TextStyle(
                      color: Color(0xFF6b7280), fontSize: 11.5),
                ),
                const SizedBox(height: 6),
                Text(
                  'Internal Storage → Taurus-Shield → output → apktool',
                  style: TextStyle(
                    color: _blueL,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── APK Tool — Decompile steps ─────────────────────────────────────────────────

const List<_Step> _apkDecompileSteps = [
  _Step(
    icon: Icons.touch_app_rounded,
    title: 'Open APK Tool from the tool picker',
    body: 'From the main screen tap "APK Tool — Decompile / Recompile APK" to open the tool.',
    color: _blue,
  ),
  _Step(
    icon: Icons.upload_file_rounded,
    title: 'Select your APK file',
    body: 'Tap the file selector and pick any .apk file. The app auto-detects DECOMPILE mode. Files up to 100 MB are accepted.',
    color: _blueL,
    tag: 'Accepted: .apk  (any Android APK)',
  ),
  _Step(
    icon: Icons.auto_awesome_rounded,
    title: 'Mode auto-detects as DECOMPILE',
    body: 'The blue DECOMPILE badge appears below the file name. No sign toggle is shown — decompile does not produce an installable APK.',
    color: _blue,
  ),
  _Step(
    icon: Icons.cloud_upload_rounded,
    title: 'Tap "Decompile (APK Tool)"',
    body: 'Press the blue button. Your APK is uploaded to the cloud and a GitHub Actions job runs apktool d automatically. An active internet connection is required.',
    color: _blue,
  ),
  _Step(
    icon: Icons.terminal_rounded,
    title: 'Watch live cloud progress',
    body: 'The log panel streams real-time updates — upload, install Java, run apktool, package output. The timer shows elapsed time. Decompile typically takes 1–3 minutes.',
    color: _blueL,
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Done — decompiled project downloaded',
    body: 'A success toast confirms completion. Your decompiled project (smali/, res/, AndroidManifest.xml, apktool.yml, etc.) is saved as a ZIP in the output folder.',
    color: _green,
  ),
];

// ── Android ID Spoofer guide ───────────────────────────────────────────────────

const Color _spCyan    = Color(0xFF00E5FF);
const Color _spCyanDim = Color(0xFF0891b2);

class _SpoofGuide extends StatelessWidget {
  const _SpoofGuide();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: _spoofSteps.length + 2,
      separatorBuilder: (_, i) => i < _spoofSteps.length - 1
          ? _StepConnector(color: _spCyan)
          : const SizedBox(height: 20),
      itemBuilder: (_, i) {
        if (i < _spoofSteps.length) return _StepCard(step: _spoofSteps[i], index: i);
        if (i == _spoofSteps.length) return _SpoofOutputNote();
        return _SpoofBenefitsCard();
      },
    );
  }
}

class _SpoofOutputNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF051a20),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _spCyan.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _spCyan.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.folder_open_rounded, color: _spCyan, size: 18),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Where to find your spoofed APK',
                  style: TextStyle(
                    color: _spCyan,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Open any file manager and navigate to:',
                  style: TextStyle(color: Color(0xFF6b7280), fontSize: 11.5),
                ),
                SizedBox(height: 6),
                Text(
                  'Internal Storage → Taurus-Shield → output → spoofer',
                  style: TextStyle(
                    color: Color(0xFF67e8f9),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SpoofBenefitsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const benefits = [
      (Icons.fingerprint_rounded,       'Unique Device Identity',    'Each spoofed APK reports a different Android ID, making your device appear as a completely new unique unit to the app.'),
      (Icons.block_rounded,             'Bypass Ban Detection',      'Spoof past hardware-level bans and account restrictions tied to your Android ID — apps see a fresh device, not a flagged one.'),
      (Icons.privacy_tip_rounded,       'Privacy Protection',        'Prevent apps from tracking you across sessions using your hardware ID. Reclaim control over what identity you expose.'),
      (Icons.recycling_rounded,         'Unlimited Fresh Starts',    'Spin up as many spoofed identities as you need. No root required — the patch is embedded directly inside the APK.'),
      (Icons.verified_user_rounded,     'Signed & Ready to Install', 'Toggle signing on to get a debug-signed APK you can sideload immediately, or leave it unsigned to sign with your own key.'),
      (Icons.cloud_done_rounded,        'Cloud-Powered — No Root',   'All patching happens on a GitHub Actions runner in the cloud. No root, no Xposed, no special permissions needed on your device.'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _spCyan.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _spCyan.withOpacity(0.3)),
              ),
              child: const Icon(Icons.auto_awesome_rounded, color: _spCyan, size: 16),
            ),
            const SizedBox(width: 10),
            const Text(
              'Why Use Android ID Spoofer?',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 14,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...benefits.map((b) => _BenefitRow(icon: b.$1, title: b.$2, body: b.$3)),
      ],
    );
  }
}

class _BenefitRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _BenefitRow({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF08141e),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _spCyan.withOpacity(0.15)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: _spCyan.withOpacity(0.1),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(icon, color: _spCyan, size: 15),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: _spCyan,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: const TextStyle(
                      color: Color(0xFF9ca3af),
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const List<_Step> _spoofSteps = [
  _Step(
    icon: Icons.touch_app_rounded,
    title: 'Open Android ID Spoofer',
    body: 'From the main screen tap "Android ID Spoofer" to open the tool. You will see the ID input, file selector, and sign toggle.',
    color: _spCyan,
  ),
  _Step(
    icon: Icons.tag_rounded,
    title: 'Enter or generate your Android ID',
    body: 'Type any 16-character hex string into the ID field, or tap the dice icon to auto-generate a random valid ID. The field validates your input and shows an error if the format is wrong.',
    color: _spCyanDim,
    tag: 'Must be exactly 16 hex characters  (0-9, a-f)',
  ),
  _Step(
    icon: Icons.upload_file_rounded,
    title: 'Select your APK file',
    body: 'Tap the file selector and pick the .apk you want to patch. The app shows the file name and size. Any standard Android APK is accepted.',
    color: _spCyan,
    tag: 'Accepted: .apk  (any Android APK)',
  ),
  _Step(
    icon: Icons.toggle_on_rounded,
    title: 'Choose signing option',
    body: 'Toggle "Sign APK" on to have the spoofed APK automatically signed with a debug key — you can sideload it immediately after. Turn it off if you want to sign it yourself with a release key.',
    color: _spCyanDim,
  ),
  _Step(
    icon: Icons.cloud_upload_rounded,
    title: 'Tap "Patch APK"',
    body: 'Press the button to start. Your APK is uploaded directly to the cloud. A GitHub Actions job then decompiles it with apktool, patches the smali bytecode with your Android ID, rebuilds and optionally signs it.',
    color: _spCyan,
  ),
  _Step(
    icon: Icons.terminal_rounded,
    title: 'Watch live cloud progress',
    body: 'The log panel streams real-time updates — upload, decompile, patch, rebuild, sign. The timer shows elapsed time. Patching typically takes 3–10 minutes depending on APK size.',
    color: _spCyanDim,
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Done — spoofed APK downloaded',
    body: 'A success toast confirms completion. Your patched APK is automatically downloaded and saved. The filename ends in _spoofed.apk. Sideload it to your device and the app will read your custom Android ID.',
    color: _green,
  ),
];

// ── APK Tool — Recompile steps ─────────────────────────────────────────────────

const List<_Step> _apkRecompileSteps = [
  _Step(
    icon: Icons.edit_note_rounded,
    title: 'Start from a decompiled project',
    body: 'Use the Decompile tab first to get an apktool project, or use any existing apktool output directory. Edit the smali files or resources as needed.',
    color: _blueL,
    tag: 'Project must contain: apktool.yml',
  ),
  _Step(
    icon: Icons.folder_zip_rounded,
    title: 'Pack your project into a ZIP',
    body: 'Select the decompiled project folder (containing apktool.yml, smali/, res/, AndroidManifest.xml) and compress it into a single .zip file.',
    color: _blue,
    tag: 'Required inside ZIP: apktool.yml  (at root level)',
  ),
  _Step(
    icon: Icons.touch_app_rounded,
    title: 'Open APK Tool from the tool picker',
    body: 'From the main screen tap "APK Tool — Decompile / Recompile APK".',
    color: _blue,
  ),
  _Step(
    icon: Icons.upload_file_rounded,
    title: 'Select your project ZIP',
    body: 'Tap the file selector and pick your ZIP. The app scans it for apktool.yml and auto-detects RECOMPILE mode. Files up to 100 MB are accepted.',
    color: _blueL,
    tag: 'Accepted: .zip  (must contain apktool.yml)',
  ),
  _Step(
    icon: Icons.toggle_on_rounded,
    title: 'Choose signing option (optional)',
    body: 'Toggle "Sign APK" on to have the rebuilt APK automatically signed with a debug keystore — useful for installing to a test device. Leave off if you have your own signing setup.',
    color: _blue,
  ),
  _Step(
    icon: Icons.cloud_upload_rounded,
    title: 'Tap "Recompile (APK Tool)"',
    body: 'Press the blue button. Your ZIP is uploaded to the cloud and a GitHub Actions job runs apktool b to rebuild the APK. An active internet connection is required.',
    color: _blue,
  ),
  _Step(
    icon: Icons.terminal_rounded,
    title: 'Watch live cloud progress',
    body: 'The log panel streams real-time updates — upload, install Java, run apktool build, optionally sign. Recompile typically takes 1–4 minutes.',
    color: _blueL,
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Done — rebuilt APK downloaded',
    body: 'A success toast confirms completion. Your rebuilt APK (out.apk) is saved to the output folder. Install it directly on your device to test your changes.',
    color: _green,
  ),
];

// ── Ads Patch guide ────────────────────────────────────────────────────────────

const _red = Color(0xFFef4444);

class _AdsPatchGuide extends StatelessWidget {
  const _AdsPatchGuide();

  @override
  Widget build(BuildContext context) {
    return _SimpleStepList(steps: _adsPatchSteps, accent: _red);
  }
}

class _SimpleStepList extends StatelessWidget {
  final List<_Step> steps;
  final Color accent;
  const _SimpleStepList({required this.steps, required this.accent});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _red.withOpacity(0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _red.withOpacity(0.25)),
          ),
          child: Row(children: [
            Icon(Icons.block_rounded, color: _red, size: 16),
            const SizedBox(width: 8),
            const Expanded(child: Text(
              'Removes ad SDKs from Android APKs by patching smali bytecode. '
              'Choose a patch level — higher levels are more aggressive.',
              style: TextStyle(color: Color(0xFFd1d5db), fontSize: 11, height: 1.5),
            )),
          ]),
        ),
        const SizedBox(height: 14),
        ...steps.map((s) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: s.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: s.color.withOpacity(0.35)),
              ),
              child: Icon(s.icon, color: s.color, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.title, style: const TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(s.body, style: const TextStyle(
                  color: Color(0xFF9ca3af), fontSize: 11, height: 1.5)),
            ])),
          ]),
        )),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0a0a18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2a1020)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Patch Levels', style: TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            ...[
              ['Basic',   'Neutralizes loadAd / renderAd methods only'],
              ['Low',     '+ Comments out GMS ad invoke calls'],
              ['Mid',     '+ Blocks ad network URLs and AdMob pub IDs'],
              ['Advance', '+ NOPs full ad SDK invoke calls (recommended)'],
              ['All',     'Combines every technique above'],
            ].map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(children: [
                Container(width: 6, height: 6,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _red.withOpacity(0.7))),
                const SizedBox(width: 8),
                Text('${e[0]}: ', style: TextStyle(
                    color: _red, fontSize: 10.5, fontWeight: FontWeight.w700)),
                Expanded(child: Text(e[1], style: const TextStyle(
                    color: Color(0xFF9ca3af), fontSize: 10.5))),
              ]),
            )),
          ]),
        ),
        const SizedBox(height: 12),
        const _CloudNote(),
      ],
    );
  }
}

const _adsPatchSteps = [
  _Step(
    icon: Icons.upload_file_rounded,
    title: 'Select your APK',
    body: 'Tap the file picker and choose an APK. The file is uploaded directly to the processing cluster over a secure connection.',
    color: _red,
  ),
  _Step(
    icon: Icons.tune_rounded,
    title: 'Choose patch level',
    body: 'Select Basic for a quick light patch, or Advance / All for maximum ad removal. Higher levels are more effective but may rarely affect app stability.',
    color: Color(0xFFf97316),
  ),
  _Step(
    icon: Icons.verified_user_rounded,
    title: 'Enable signing (optional)',
    body: 'Toggle Sign APK on to debug-sign the patched APK automatically. This lets you install it directly on your device without a separate signing step.',
    color: Color(0xFF22c55e),
  ),
  _Step(
    icon: Icons.cloud_upload_rounded,
    title: 'Start patch',
    body: 'Tap Start Ads Patch. The APK is decompiled, patched using the cloud engine, rebuilt, and optionally signed. Typical time: 2–5 minutes.',
    color: Color(0xFF3b82f6),
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Download patched APK',
    body: 'The finished APK (out.apk) is saved to Internal Storage → Taurus-Shield → output. Tap the folder icon to open it directly.',
    color: Color(0xFF22c55e),
  ),
];

// ── Anti-Dialog Killer guide ───────────────────────────────────────────────────

const _akPurple    = Color(0xFF8B5CF6);
const _akPurpleDim = Color(0xFF6D28D9);

class _AntiKillerGuide extends StatelessWidget {
  const _AntiKillerGuide();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _akPurple.withOpacity(0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _akPurple.withOpacity(0.25)),
          ),
          child: Row(children: [
            Icon(Icons.shield_rounded, color: _akPurple, size: 16),
            const SizedBox(width: 8),
            const Expanded(child: Text(
              'Injects AntiDialogKiller into your APK to permanently neutralize '
              'subscription and paywall dialogs using smali hook injection.',
              style: TextStyle(color: Color(0xFFd1d5db), fontSize: 11, height: 1.5),
            )),
          ]),
        ),
        const SizedBox(height: 14),
        ..._antiKillerSteps.map((s) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: s.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: s.color.withOpacity(0.35)),
              ),
              child: Icon(s.icon, color: s.color, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.title, style: const TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              if (s.tag != null) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: s.color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: s.color.withOpacity(0.3)),
                  ),
                  child: Text(s.tag!, style: TextStyle(
                      color: s.color, fontSize: 9.5, fontWeight: FontWeight.w600,
                      fontFamily: 'monospace')),
                ),
              ],
              Text(s.body, style: const TextStyle(
                  color: Color(0xFF9ca3af), fontSize: 11, height: 1.5)),
            ])),
          ]),
        )),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0a0a18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF1e1040)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('How it works', style: TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            ...[
              ['Hook injection', 'Inserts invoke-static call to AntiDialogKiller.check(Context) into onCreate of MainActivity and Application class'],
              ['DEX injection',  'Adds the AntiDialogKiller DEX smali into your APK as a new DEX file'],
              ['Integrity seal', 'Computes manifest hash + DEX count, AES-encrypts both, writes ak_mh.dat and ak_dc.dat'],
              ['Double-sign',    'APK is signed twice: once before hash injection, once after — ensuring all files are covered'],
            ].map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _akPurple.withOpacity(0.7))),
                const SizedBox(width: 8),
                Text('${e[0]}: ', style: TextStyle(
                    color: _akPurple, fontSize: 10.5, fontWeight: FontWeight.w700)),
                Expanded(child: Text(e[1], style: const TextStyle(
                    color: Color(0xFF9ca3af), fontSize: 10.5, height: 1.4))),
              ]),
            )),
          ]),
        ),
        const SizedBox(height: 12),
        const _CloudNote(),
      ],
    );
  }
}

const _antiKillerSteps = [
  _Step(
    icon: Icons.upload_file_rounded,
    title: 'Select your APK',
    body: 'Tap the file picker and choose any Android APK. It will be uploaded securely to the cloud for processing.',
    color: _akPurple,
  ),
  _Step(
    icon: Icons.memory_rounded,
    title: 'Enter Main Activity (optional)',
    body: 'Type the fully-qualified main activity class name (e.g. com.example.app.MainActivity). If left blank, the engine auto-detects it from AndroidManifest.xml.',
    color: _akPurpleDim,
    tag: 'e.g. com.example.app.MainActivity',
  ),
  _Step(
    icon: Icons.verified_user_rounded,
    title: 'Enable signing (optional)',
    body: 'Toggle Sign APK on to debug-sign the patched APK. This lets you sideload it immediately. Turn off if you plan to sign with your own release key.',
    color: Color(0xFF22c55e),
  ),
  _Step(
    icon: Icons.cloud_upload_rounded,
    title: 'Start Anti-Dialog Killer',
    body: 'Tap the button. The APK is uploaded, decompiled, hooked with AntiDialogKiller, rebuilt, integrity-sealed, and signed. Typical time: 3–8 minutes.',
    color: Color(0xFF3b82f6),
  ),
  _Step(
    icon: Icons.check_circle_rounded,
    title: 'Download patched APK',
    body: 'The finished APK (out.apk) is saved to Internal Storage → Taurus-Shield → output. Tap the folder icon to open it directly.',
    color: Color(0xFF22c55e),
  ),
];

// ── Shared helper widgets ──────────────────────────────────────────────────────

class _GuideTab extends StatelessWidget {
  final int             index;
  final String          label;
  final IconData        icon;
  final Color           color;
  final TabController   controller;
  const _GuideTab({required this.index, required this.label, required this.icon, required this.color, required this.controller});

  @override
  Widget build(BuildContext context) {
    final selected = controller.index == index;
    return GestureDetector(
      onTap: () => controller.animateTo(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.15) : const Color(0xFF0a0a18),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color.withOpacity(0.65) : const Color(0xFF1e1e3a),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: selected ? color : const Color(0xFF6b7280)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Colors.white : const Color(0xFF6b7280),
            ),
          ),
        ]),
      ),
    );
  }
}

class _OutFile extends StatelessWidget {
  final String name;
  final String desc;
  final Color  color;
  const _OutFile({required this.name, required this.desc, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(Icons.insert_drive_file_rounded, color: color, size: 14),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700)),
        Text(desc, style: const TextStyle(color: Color(0xFF6b7280), fontSize: 10)),
      ])),
    ]);
  }
}

class _CloudNote extends StatelessWidget {
  const _CloudNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0a0a18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2a1040)),
      ),
      child: const Row(children: [
        Icon(Icons.cloud_done_rounded, color: Color(0xFF6b7280), size: 18),
        SizedBox(width: 10),
        Expanded(child: Text(
          'This tool runs on a remote cloud worker (GitHub Actions). '
          'An active internet connection is required. Results are saved to '
          'Internal Storage → Taurus-Shield → output.',
          style: TextStyle(color: Color(0xFF6b7280), fontSize: 11, height: 1.5),
        )),
      ]),
    );
  }
}
