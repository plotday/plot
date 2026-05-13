import 'package:flutter/widgets.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/util/splash.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  removeSplash();
  runApp(const _FontTestApp());
}

const _kBgDarkL = 0.26;
const _kBgLightL = 0.98;

const _lightnessSteps = <double>[0.48, 0.55, 0.58, 0.62, 0.68, 0.74];
const _weights = <FontWeight>[
  FontWeight.w400,
  FontWeight.w500,
  FontWeight.w600,
];
const _letterSpacings = <double>[-0.1, 0.0, 0.1, 0.2, 0.3];

const _sampleAgenda = 'May 14 Thursday';
const _sampleDuration = '29m';
const _samplePath = 'Plot › Product Development';

Color _neutral(double l, {double alpha = 1.0}) =>
    RayOklch.fromComponents(l, 0.005, 115.0, alpha).toColor();

class _FontTestApp extends StatefulWidget {
  const _FontTestApp();

  @override
  State<_FontTestApp> createState() => _FontTestAppState();
}

class _FontTestAppState extends State<_FontTestApp> {
  Brightness _brightness = Brightness.dark;
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final isDark = _brightness == Brightness.dark;
    final bg = _neutral(isDark ? _kBgDarkL : _kBgLightL);
    final fg = _neutral(isDark ? 0.88 : 0.25);

    return WidgetsApp(
      color: bg,
      title: 'Font rendering test',
      pageRouteBuilder: <T>(settings, builder) =>
          PageRouteBuilder<T>(settings: settings, pageBuilder: (c, _, _) => builder(c)),
      home: MediaQuery(
        data: MediaQueryData.fromView(View.of(context)).copyWith(
          textScaler: TextScaler.linear(_scale),
        ),
        child: Container(
          color: bg,
          child: DefaultTextStyle(
            style: TextStyle(
              fontFamily: 'Figtree',
              color: fg,
              fontSize: 13,
              height: 1.3,
            ),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Toolbar(
                      brightness: _brightness,
                      scale: _scale,
                      onBrightness: (b) => setState(() => _brightness = b),
                      onScale: (s) => setState(() => _scale = s),
                      fg: fg,
                    ),
                    const SizedBox(height: 24),
                    _SectionHeader(
                      'Lightness × Weight grid (current dark veryMuted = L 0.48 w400)',
                      fg: fg,
                    ),
                    const SizedBox(height: 12),
                    _LightnessWeightGrid(brightness: _brightness),
                    const SizedBox(height: 32),
                    _SectionHeader('Alpha vs pre-blended at same effective color', fg: fg),
                    const SizedBox(height: 12),
                    _AlphaVsBlended(brightness: _brightness),
                    const SizedBox(height: 32),
                    _SectionHeader('Letter spacing (sm = 0.1)', fg: fg),
                    const SizedBox(height: 12),
                    _LetterSpacingRows(brightness: _brightness),
                    const SizedBox(height: 32),
                    _SectionHeader('Side-by-side at production sizes (sm 13, xs 11)', fg: fg),
                    const SizedBox(height: 12),
                    _ProductionSizes(brightness: _brightness),
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.brightness,
    required this.scale,
    required this.onBrightness,
    required this.onScale,
    required this.fg,
  });

  final Brightness brightness;
  final double scale;
  final ValueChanged<Brightness> onBrightness;
  final ValueChanged<double> onScale;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Pill(
          label: 'Dark',
          selected: brightness == Brightness.dark,
          onTap: () => onBrightness(Brightness.dark),
          fg: fg,
        ),
        const SizedBox(width: 8),
        _Pill(
          label: 'Light',
          selected: brightness == Brightness.light,
          onTap: () => onBrightness(Brightness.light),
          fg: fg,
        ),
        const SizedBox(width: 24),
        Text('scale:', style: TextStyle(color: fg)),
        const SizedBox(width: 8),
        for (final s in <double>[0.8, 1.0, 1.25, 1.5, 2.0]) ...[
          _Pill(
            label: s.toString(),
            selected: scale == s,
            onTap: () => onScale(s),
            fg: fg,
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.fg,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? fg.withValues(alpha: 0.15) : null,
          border: Border.all(color: fg.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label, style: TextStyle(color: fg, fontSize: 12)),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text, {required this.fg});
  final String text;
  final Color fg;
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      );
}

class _LightnessWeightGrid extends StatelessWidget {
  const _LightnessWeightGrid({required this.brightness});
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final headerColor = _neutral(brightness == Brightness.dark ? 0.65 : 0.45);
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        TableRow(children: [
          const SizedBox(width: 60),
          for (final l in _lightnessSteps)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'L=${l.toStringAsFixed(2)}',
                style: TextStyle(color: headerColor, fontSize: 11),
              ),
            ),
        ]),
        for (final w in _weights)
          TableRow(children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'w${w.value}',
                style: TextStyle(color: headerColor, fontSize: 11),
              ),
            ),
            for (final l in _lightnessSteps)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _sampleAgenda,
                      style: TextStyle(
                        color: _neutral(l),
                        fontSize: 13,
                        fontWeight: w,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _sampleDuration,
                      style: TextStyle(
                        color: _neutral(l),
                        fontSize: 13,
                        fontWeight: w,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _samplePath,
                      style: TextStyle(
                        color: _neutral(l),
                        fontSize: 13,
                        fontWeight: w,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
          ]),
      ],
    );
  }
}

class _AlphaVsBlended extends StatelessWidget {
  const _AlphaVsBlended({required this.brightness});
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final isDark = brightness == Brightness.dark;
    final bgL = isDark ? _kBgDarkL : _kBgLightL;
    final headerColor = _neutral(isDark ? 0.65 : 0.45);

    final pairs = <(String, Color)>[
      ('opaque L=0.48 (current veryMuted dark)', _neutral(0.48)),
      ('opaque L=0.58', _neutral(0.58)),
      ('opaque L=0.65', _neutral(0.65)),
      (
        'white → alpha 0.30 over bg',
        const Color(0xFFFFFFFF).withValues(alpha: 0.30),
      ),
      (
        'white → alpha 0.45 over bg',
        const Color(0xFFFFFFFF).withValues(alpha: 0.45),
      ),
      (
        'white → alpha 0.60 over bg',
        const Color(0xFFFFFFFF).withValues(alpha: 0.60),
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      color: _neutral(bgL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final p in pairs)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 280,
                    child: Text(
                      p.$1,
                      style: TextStyle(color: headerColor, fontSize: 11),
                    ),
                  ),
                  Text(
                    '$_sampleAgenda  $_sampleDuration  $_samplePath',
                    style: TextStyle(
                      color: p.$2,
                      fontSize: 13,
                      letterSpacing: 0.1,
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

class _LetterSpacingRows extends StatelessWidget {
  const _LetterSpacingRows({required this.brightness});
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final isDark = brightness == Brightness.dark;
    final color = _neutral(isDark ? 0.58 : 0.48);
    final headerColor = _neutral(isDark ? 0.65 : 0.45);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final ls in _letterSpacings)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text(
                    'ls=$ls',
                    style: TextStyle(color: headerColor, fontSize: 11),
                  ),
                ),
                Text(
                  '$_sampleAgenda  $_sampleDuration  $_samplePath',
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    letterSpacing: ls,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ProductionSizes extends StatelessWidget {
  const _ProductionSizes({required this.brightness});
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final isDark = brightness == Brightness.dark;
    final headerColor = _neutral(isDark ? 0.65 : 0.45);

    Widget block(String label, Color color, FontWeight w, double size) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 260,
              child: Text(
                label,
                style: TextStyle(color: headerColor, fontSize: 11),
              ),
            ),
            Expanded(
              child: Text(
                '$_sampleAgenda      $_samplePath      $_sampleDuration',
                style: TextStyle(
                  color: color,
                  fontSize: size,
                  fontWeight: w,
                  letterSpacing: size <= 11 ? 0.2 : 0.1,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        block(
          'PRODUCTION (sm 13 w400 L=${isDark ? "0.48" : "0.58"})',
          _neutral(isDark ? 0.48 : 0.58),
          FontWeight.w400,
          13,
        ),
        block(
          'PROPOSED A (sm 13 w400 L=${isDark ? "0.60" : "0.50"})',
          _neutral(isDark ? 0.60 : 0.50),
          FontWeight.w400,
          13,
        ),
        block(
          'PROPOSED B (sm 13 w500 L=${isDark ? "0.58" : "0.52"})',
          _neutral(isDark ? 0.58 : 0.52),
          FontWeight.w500,
          13,
        ),
        block(
          'PROPOSED C (sm 13 w500 L=${isDark ? "0.62" : "0.48"})',
          _neutral(isDark ? 0.62 : 0.48),
          FontWeight.w500,
          13,
        ),
        const SizedBox(height: 16),
        block(
          'xs 11 w400 PROD (L=${isDark ? "0.48" : "0.58"})',
          _neutral(isDark ? 0.48 : 0.58),
          FontWeight.w400,
          11,
        ),
        block(
          'xs 11 w500 PROPOSED (L=${isDark ? "0.62" : "0.48"})',
          _neutral(isDark ? 0.62 : 0.48),
          FontWeight.w500,
          11,
        ),
      ],
    );
  }
}
