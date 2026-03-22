import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../widgets/app_drawer.dart';
import '../utils/session_state.dart';
import '../utils/permission_helper.dart';
import 'home_screen.dart';
import 'blutter_screen.dart';
import 'dex2c_screen.dart';
import 'dptshell_screen.dart';
import 'apktool_screen.dart';
import 'android_id_spoof_screen.dart';
import 'js_encryptor_screen.dart';
import 'ads_patch_screen.dart';
import 'anti_dialog_screen.dart';

enum _IconAnim { pulse, spin, glow }

class ToolSelectionScreen extends StatefulWidget {
  const ToolSelectionScreen({super.key});

  @override
  State<ToolSelectionScreen> createState() => _ToolSelectionScreenState();
}

class _ToolSelectionScreenState extends State<ToolSelectionScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final AnimationController _cardCtrl;
  late final Animation<double> _pulse;
  late final Animation<double> _cardFade;
  late final Animation<Offset> _cardSlide;

  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _cardCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();

    _pulse = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _cardFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _cardCtrl, curve: Curves.easeOut),
    );

    _cardSlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _cardCtrl, curve: Curves.easeOutCubic));

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await PermissionHelper.checkStartup(context);
      if (mounted) _restoreLastTool();
    });
  }

  Future<void> _restoreLastTool() async {
    final last = await SessionState.loadLastTool();
    if (!mounted) return;
    if (last == 'hbc') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const HomeScreen()));
    } else if (last == 'blutter') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const BlutterScreen()));
    } else if (last == 'dex2c') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const Dex2CScreen()));
    } else if (last == 'dptshell') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const DptShellScreen()));
    } else if (last == 'apktool') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const ApkToolScreen()));
    } else if (last == 'androididspoof') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const AndroidIdSpoofScreen()));
    } else if (last == 'jsencryptor') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const JsEncryptorScreen()));
    } else if (last == 'adspatch') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const AdsPatchScreen()));
    }
  }

  Future<void> _navigateTo(Widget screen, String toolKey) async {
    await SessionState.saveLastTool(toolKey);
    if (!mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _cardCtrl.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    final now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.exit_to_app_rounded, color: Colors.white, size: 18),
              SizedBox(width: 10),
              Text('Press back again to exit',
                  style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
          backgroundColor: const Color(0xFF1a0a30),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.all(12),
          duration: const Duration(seconds: 2),
        ),
      );
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldExit = await _onWillPop();
        if (shouldExit && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0a0a1a),
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AppBarShield(),
              const SizedBox(width: 10),
              const Text('TAURUS SHIELD'),
              const SizedBox(width: 10),
              _AppBarShield(mirrored: true),
            ],
          ),
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0d0d20), Color(0xFF1a0a30)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
        ),
        drawer: const AppDrawer(),
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 14),

              // ── Compact branded header ─────────────────────────────────
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) => Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF130820),
                        Color(0xFF0a1228),
                        Color(0xFF130820)
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: Color.lerp(
                        const Color(0xFF7c3aed).withOpacity(0.30),
                        const Color(0xFF22d3ee).withOpacity(0.25),
                        _pulse.value,
                      )!,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF7c3aed)
                            .withOpacity(0.05 + _pulse.value * 0.05),
                        blurRadius: 20,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Color.lerp(
                            const Color(0xFF7c3aed).withOpacity(0.15),
                            const Color(0xFF9d5cf6).withOpacity(0.20),
                            _pulse.value,
                          ),
                          border: Border.all(
                            color: const Color(0xFF7c3aed)
                                .withOpacity(0.3 + _pulse.value * 0.2),
                          ),
                        ),
                        child: Icon(
                          Icons.security_rounded,
                          size: 22,
                          color: Color.lerp(
                            const Color(0xFF7c3aed),
                            const Color(0xFF9d5cf6),
                            _pulse.value,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Select a Tool',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Tap a tool below to get started',
                              style: TextStyle(
                                color: const Color(0xFF6b7280)
                                    .withOpacity(0.9),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // ── Tool cards — expanded to fill remaining space ──────────
              Expanded(
                child: FadeTransition(
                  opacity: _cardFade,
                  child: SlideTransition(
                    position: _cardSlide,
                    child: Column(
                      children: [
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.memory_rounded,
                            iconColor: const Color(0xFF7c3aed),
                            glowColor: const Color(0xFF7c3aed),
                            iconAnim: _IconAnim.pulse,
                            title: 'HBC Tool',
                            subtitle: 'Hermes Bytecode DSM & ASM',
                            description:
                                'Disassemble .bundle / .hbc files into readable .hasm, '
                                'or assemble .hasm back into working Hermes bytecode.',
                            chips: const ['.bundle', '.hbc', '.hasm', '.zip'],
                            badgeLabel: 'ACTIVE',
                            badgeColor: const Color(0xFF22c55e),
                            onTap: () =>
                                _navigateTo(const HomeScreen(), 'hbc'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.flutter_dash_rounded,
                            iconColor: const Color(0xFF22d3ee),
                            glowColor: const Color(0xFF22d3ee),
                            iconAnim: _IconAnim.spin,
                            title: 'Blutter',
                            subtitle: 'Flutter App Reverse Engineering',
                            description:
                                'Analyze Flutter APKs and extract Dart symbols, '
                                'class layouts and disassembled ARM64 code from libapp.so.',
                            chips: const ['.apk', 'libapp.so'],
                            badgeLabel: 'BETA',
                            badgeColor: const Color(0xFFf59e0b),
                            onTap: () =>
                                _navigateTo(const BlutterScreen(), 'blutter'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.enhanced_encryption_rounded,
                            iconColor: const Color(0xFF10b981),
                            glowColor: const Color(0xFF10b981),
                            iconAnim: _IconAnim.glow,
                            title: 'Dex2C',
                            subtitle: 'APK Native Protection',
                            description:
                                'Convert DEX bytecode to native C/C++ code. '
                                'Protects methods against static analysis and decompilation.',
                            chips: const ['.apk', 'filter.txt'],
                            badgeLabel: 'CLOUD',
                            badgeColor: const Color(0xFF10b981),
                            iconBuilder: (color, t) => CustomPaint(
                              size: const Size(26, 26),
                              painter: _ChipPainter(color: color, t: t),
                            ),
                            onTap: () =>
                                _navigateTo(const Dex2CScreen(), 'dex2c'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.layers_rounded,
                            iconColor: const Color(0xFFf97316),
                            glowColor: const Color(0xFFf97316),
                            iconAnim: _IconAnim.pulse,
                            title: 'DPT Shell',
                            subtitle: 'DEX Hollowing Protection',
                            description:
                                'Apply shell protection to any Android APK via '
                                'DEX hollowing. Moves bytecode into a native shell layer.',
                            chips: const ['.apk', 'rules.txt?'],
                            badgeLabel: 'CLOUD',
                            badgeColor: const Color(0xFFf97316),
                            onTap: () =>
                                _navigateTo(const DptShellScreen(), 'dptshell'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.android_rounded,
                            iconColor: const Color(0xFF3b82f6),
                            glowColor: const Color(0xFF3b82f6),
                            iconAnim: _IconAnim.glow,
                            title: 'APK Tool',
                            subtitle: 'Decompile / Recompile APK',
                            description:
                                'Decompile any APK to smali + resources using apktool, '
                                'then recompile and optionally sign the rebuilt APK.',
                            chips: const ['.apk', '.zip'],
                            badgeLabel: 'CLOUD',
                            badgeColor: const Color(0xFF3b82f6),
                            onTap: () =>
                                _navigateTo(const ApkToolScreen(), 'apktool'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.fingerprint_rounded,
                            iconColor: const Color(0xFF00E5FF),
                            glowColor: const Color(0xFF00E5FF),
                            iconAnim: _IconAnim.pulse,
                            title: 'Android ID Spoofer',
                            subtitle: 'Android Identity Engine',
                            description:
                                'Generates a modified APK configured with a custom Android '
                                'identifier. Supports any standard APK format, including multi-dex.',
                            chips: const ['.apk', 'android.id', 'multi-apk'],
                            badgeLabel: 'ALPHA',
                            badgeColor: const Color(0xFF00E5FF),
                            onTap: () => _navigateTo(
                                const AndroidIdSpoofScreen(), 'androididspoof'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.javascript_rounded,
                            iconColor: const Color(0xFFF59E0B),
                            glowColor: const Color(0xFFF59E0B),
                            iconAnim: _IconAnim.glow,
                            title: 'JS Encryptor',
                            subtitle: 'On-Device JS Obfuscation',
                            description:
                                '14 methods — Arabic/Japanese/Chinese/Kanji IDs, '
                                'SubZero HTML 4-key lock, decrypt. Hardened local core · air-gapped · leaves no trace.',
                            chips: const ['.js', '.html', '.zip', 'decrypt'],
                            badgeLabel: 'ON-DEVICE',
                            badgeColor: const Color(0xFFF59E0B),
                            onTap: () => _navigateTo(
                                const JsEncryptorScreen(), 'jsencryptor'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.block_rounded,
                            iconColor: const Color(0xFFef4444),
                            glowColor: const Color(0xFFef4444),
                            iconAnim: _IconAnim.pulse,
                            title: 'Ads Patch',
                            subtitle: 'Remove Ads from APKs',
                            description:
                                'Patch smali bytecode to neutralize ad SDKs, block ad URLs '
                                'and NOP ad invoke calls. 5 levels from Basic to All.',
                            chips: const ['.apk', 'basic', 'advance', 'all'],
                            badgeLabel: 'CLOUD',
                            badgeColor: const Color(0xFFef4444),
                            onTap: () =>
                                _navigateTo(const AdsPatchScreen(), 'adspatch'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _ToolCard(
                            icon: Icons.shield_rounded,
                            iconColor: const Color(0xFF8B5CF6),
                            glowColor: const Color(0xFF8B5CF6),
                            iconAnim: _IconAnim.pulse,
                            title: 'Anti-Dialog Killer',
                            subtitle: 'Neutralize Subscription Dialogs',
                            description:
                                'Injects AntiDialogKiller into APK smali to permanently '
                                'block subscription and paywall dialogs. Integrity-verified.',
                            chips: const ['.apk', 'smali', 'inject', 'cloud'],
                            badgeLabel: 'CLOUD',
                            badgeColor: const Color(0xFF8B5CF6),
                            onTap: () =>
                                _navigateTo(const AntiDialogScreen(), 'antidialog'),
                          ),
                        ),
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              'More tools coming soon...',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.28),
                                fontSize: 12,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Tool card ──────────────────────────────────────────────────────────────────

class _ToolCard extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final Color glowColor;
  final _IconAnim iconAnim;
  final String title;
  final String subtitle;
  final String description;
  final List<String> chips;
  final String badgeLabel;
  final Color badgeColor;
  final VoidCallback onTap;
  // Optional custom icon builder; receives animation value t ∈ [0,1]
  final Widget Function(Color color, double t)? iconBuilder;

  const _ToolCard({
    required this.icon,
    required this.iconColor,
    required this.glowColor,
    required this.iconAnim,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.chips,
    required this.badgeLabel,
    required this.badgeColor,
    required this.onTap,
    this.iconBuilder,
  });

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> with TickerProviderStateMixin {
  late final AnimationController _tapCtrl;
  late final AnimationController _iconCtrl;
  late final Animation<double> _tapAnim;
  late final Animation<double> _iconAnim;

  @override
  void initState() {
    super.initState();

    // Tap / press animation
    _tapCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    _tapAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _tapCtrl, curve: Curves.easeOut),
    );

    // Idle icon animation
    switch (widget.iconAnim) {
      case _IconAnim.pulse:
        _iconCtrl = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1800),
        )..repeat(reverse: true);
        _iconAnim = Tween<double>(begin: 0.82, end: 1.0).animate(
          CurvedAnimation(parent: _iconCtrl, curve: Curves.easeInOut),
        );
        break;
      case _IconAnim.spin:
        _iconCtrl = AnimationController(
          vsync: this,
          duration: const Duration(seconds: 7),
        )..repeat();
        _iconAnim = Tween<double>(begin: 0.0, end: 1.0).animate(_iconCtrl);
        break;
      case _IconAnim.glow:
        _iconCtrl = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 850),
        )..repeat(reverse: true);
        _iconAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(parent: _iconCtrl, curve: Curves.easeInOut),
        );
        break;
    }
  }

  @override
  void dispose() {
    _tapCtrl.dispose();
    _iconCtrl.dispose();
    super.dispose();
  }

  Widget _buildAnimatedIcon() {
    switch (widget.iconAnim) {
      case _IconAnim.pulse:
        return AnimatedBuilder(
          animation: _iconAnim,
          builder: (_, __) => Transform.scale(
            scale: _iconAnim.value,
            child: Icon(widget.icon, color: widget.iconColor, size: 26),
          ),
        );
      case _IconAnim.spin:
        return AnimatedBuilder(
          animation: _iconAnim,
          builder: (_, __) => Transform.rotate(
            angle: _iconAnim.value * 2 * math.pi,
            child: Icon(widget.icon, color: widget.iconColor, size: 26),
          ),
        );
      case _IconAnim.glow:
        return AnimatedBuilder(
          animation: _iconAnim,
          builder: (_, __) {
            final t = _iconAnim.value;
            return Transform.scale(
              scale: 0.80 + 0.28 * t,
              child: Opacity(
                opacity: 0.55 + 0.45 * t,
                child: widget.iconBuilder != null
                    ? widget.iconBuilder!(widget.iconColor, t)
                    : Icon(widget.icon, color: widget.iconColor, size: 26),
              ),
            );
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _tapCtrl.forward(),
      onTapUp: (_) {
        _tapCtrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _tapCtrl.reverse(),
      child: AnimatedBuilder(
        animation: _tapAnim,
        builder: (_, child) => Transform.scale(
          scale: 1.0 - _tapAnim.value * 0.015,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF12102a),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: const Color(0xFF1e1e38),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Animated icon box
              widget.iconAnim == _IconAnim.glow
                  ? AnimatedBuilder(
                      animation: _iconAnim,
                      builder: (_, __) {
                        final t = _iconAnim.value;
                        return Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: const Color(0xFF0a0a1a),
                            border: Border.all(
                              color: Color.lerp(
                                const Color(0xFF1e1e38),
                                widget.glowColor.withOpacity(0.55),
                                t,
                              )!,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: widget.glowColor.withOpacity(0.22 * t),
                                blurRadius: 14,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Center(child: _buildAnimatedIcon()),
                        );
                      },
                    )
                  : Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: const Color(0xFF0a0a1a),
                        border: Border.all(color: const Color(0xFF1e1e38)),
                      ),
                      child: Center(child: _buildAnimatedIcon()),
                    ),
              const SizedBox(width: 14),
              // ── Text content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: widget.badgeColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                                color: widget.badgeColor.withOpacity(0.35)),
                          ),
                          child: Text(
                            widget.badgeLabel,
                            style: TextStyle(
                              color: widget.badgeColor,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: TextStyle(
                        color: widget.iconColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      widget.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF9ca3af),
                        fontSize: 11.5,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 5,
                      runSpacing: 3,
                      children: widget.chips
                          .map((c) => _Chip(label: c, color: widget.iconColor))
                          .toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward_ios_rounded,
                  color: widget.iconColor.withOpacity(0.45), size: 14),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Chip ───────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withOpacity(0.22)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.withOpacity(0.85),
          fontSize: 9.5,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── AppBar shield ──────────────────────────────────────────────────────────────

class _AppBarShield extends StatelessWidget {
  final bool mirrored;
  const _AppBarShield({this.mirrored = false});

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scaleX: mirrored ? -1 : 1,
      child: CustomPaint(
        size: const Size(18, 20),
        painter: _ShieldPainter(),
      ),
    );
  }
}

class _ShieldPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, 0)
      ..lineTo(w, h * 0.18)
      ..lineTo(w, h * 0.52)
      ..quadraticBezierTo(w, h * 0.82, w * 0.5, h)
      ..quadraticBezierTo(0, h * 0.82, 0, h * 0.52)
      ..lineTo(0, h * 0.18)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          colors: [
            const Color(0xFF9d5cf6).withOpacity(0.22),
            const Color(0xFF4f1fa0).withOpacity(0.12),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(Rect.fromLTWH(0, 0, w, h))
        ..style = PaintingStyle.fill,
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF9d5cf6).withOpacity(0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeJoin = StrokeJoin.round,
    );

    final tp = Paint()
      ..color = const Color(0xFF9d5cf6).withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(w * 0.3, h * 0.40), Offset(w * 0.7, h * 0.40), tp);
    canvas.drawLine(Offset(w * 0.5, h * 0.40), Offset(w * 0.5, h * 0.68), tp);
  }

  @override
  bool shouldRepaint(_ShieldPainter _) => false;
}

// ── Dex2C chip icon ────────────────────────────────────────────────────────────
// Advanced IC-chip SVG drawn with CustomPainter. Replaces the generic padlock.
// t is the animation value (0→1) used to pulse the core and corner nodes.

class _ChipPainter extends CustomPainter {
  final Color color;
  final double t;
  const _ChipPainter({required this.color, required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * .5;
    final cy = h * .5;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.4;

    final fill = Paint()..style = PaintingStyle.fill;

    // ── Chip body ─────────────────────────────────────────────────────────────
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * .20, h * .20, w * .60, h * .60),
      const Radius.circular(3),
    );
    canvas.drawRRect(bodyRect, fill..color = color.withOpacity(.13));
    canvas.drawRRect(bodyRect, stroke..color = color..strokeWidth = 1.4);

    // ── Pins (2 per side) ─────────────────────────────────────────────────────
    stroke.strokeWidth = 1.3;
    final pa = w * .33;
    final pb = w * .67;
    // top
    canvas.drawLine(Offset(pa, h * .06), Offset(pa, h * .20), stroke);
    canvas.drawLine(Offset(pb, h * .06), Offset(pb, h * .20), stroke);
    // bottom
    canvas.drawLine(Offset(pa, h * .80), Offset(pa, h * .94), stroke);
    canvas.drawLine(Offset(pb, h * .80), Offset(pb, h * .94), stroke);
    // left
    canvas.drawLine(Offset(w * .06, pa), Offset(w * .20, pa), stroke);
    canvas.drawLine(Offset(w * .06, pb), Offset(w * .20, pb), stroke);
    // right
    canvas.drawLine(Offset(w * .80, pa), Offset(w * .92, pa), stroke);
    canvas.drawLine(Offset(w * .80, pb), Offset(w * .92, pb), stroke);

    // ── Inner core circle (pulsing) ────────────────────────────────────────────
    final coreAlpha = .18 + .20 * t;
    canvas.drawCircle(Offset(cx, cy), w * .13,
        fill..color = color.withOpacity(coreAlpha));
    canvas.drawCircle(Offset(cx, cy), w * .13,
        stroke..color = color.withOpacity(.5 + .4 * t)..strokeWidth = 1.0);

    // ── Corner nodes with trace lines to core ─────────────────────────────────
    final nodes = [
      Offset(w * .32, h * .32),
      Offset(w * .68, h * .32),
      Offset(w * .32, h * .68),
      Offset(w * .68, h * .68),
    ];
    final traceStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7
      ..color = color.withOpacity(.25);
    final dotFill = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withOpacity(.50 + .45 * t);

    for (final n in nodes) {
      canvas.drawLine(n, Offset(cx, cy), traceStroke);
      canvas.drawCircle(n, 1.7, dotFill);
    }
  }

  @override
  bool shouldRepaint(_ChipPainter old) => old.t != t || old.color != color;
}
