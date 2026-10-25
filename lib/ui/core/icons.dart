import 'package:flutter/widgets.dart';

/// The app's icons, drawn on a 24-unit grid as in the design: strokes with round ends, except the
/// few that are solid shapes.
enum CauceGlyph {
  play('M7 4.5v15l13-7.5z', filled: true),
  pause('M6 4h4v16H6zM14 4h4v16h-4z', filled: true),
  next('M4 5l10 7-10 7zM16.5 5H19v14h-2.5z', filled: true),
  prev('M20 5l-10 7 10 7zM5 5h2.5v14H5z', filled: true),
  repeat('M4 11V9a3 3 0 0 1 3-3h12m-3-3 3 3-3 3M20 13v2a3 3 0 0 1-3 3H5m3 3-3-3 3-3'),
  shuffle('M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5'),
  heart('M12 20s-7.5-4.6-7.5-10.2A4.2 4.2 0 0 1 12 7.2a4.2 4.2 0 0 1 7.5 2.6C19.5 15.4 12 20 12 20z'),
  heartFilled('M12 20.5s-8-4.8-8-10.6A4.5 4.5 0 0 1 12 7a4.5 4.5 0 0 1 8 2.9c0 5.8-8 10.6-8 10.6z', filled: true),
  download('M12 4v11m-4.5-4.5L12 15l4.5-4.5M5 20h14'),
  downloaded(
    'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1.2 4.5h2.4v6.3l2.4-2.4 1.7 1.7L12 17.4l-5.3-5.3 1.7-1.7 2.4 2.4z',
    filled: true,
  ),
  more(
    'M5 10.3a1.7 1.7 0 1 0 0 3.4 1.7 1.7 0 0 0 0-3.4zm7 0a1.7 1.7 0 1 0 0 3.4 1.7 1.7 0 0 0 0-3.4zm7 0a1.7 1.7 0 1 0 0 3.4 1.7 1.7 0 0 0 0-3.4z',
    filled: true,
  ),
  search('M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM15.5 15.5l5 5'),
  home('M4 10.5 12 4l8 6.5V20h-5.5v-6h-5v6H4z'),
  library('M5 4v16M10 4v16M14.5 4.8l5 14.6'),
  settings('M4 7h9M17 7h3M4 17h3M11 17h9M15 4.5v5M9 14.5v5'),
  airplay('M6 17H4V5h16v12h-2M7.5 21 12 15.5l4.5 5.5z'),
  lyrics('M4 5h16v11H10l-5 4v-4H4zM8 9h8M8 12.5h5'),
  queue('M4 6h13M4 11h13M4 16h7M15 14v6l5-3z'),
  volumeLow('M4 9.5h3.5L12 6v12l-4.5-3.5H4z'),
  volumeHigh('M3 9.5h3.5L11 6v12l-4.5-3.5H3zM15 9a4.5 4.5 0 0 1 0 6M17.8 6.5a8 8 0 0 1 0 11'),
  chevronLeft('M15 5l-7 7 7 7'),
  chevronRight('M9 5l7 7-7 7'),
  chevronDown('M5 9l7 7 7-7'),
  close('M6 6l12 12M18 6 6 18'),
  plus('M12 5v14M5 12h14'),
  retry('M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4v4h-4'),
  trash('M5 7h14M10 7V4.5h4V7M7 7l1 13h8l1-13'),
  album('M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 10a2 2 0 1 0 0 4 2 2 0 0 0 0-4z'),
  user('M12 4a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM4.5 20c1-3.8 4.2-5.8 7.5-5.8s6.5 2 7.5 5.8'),
  headphones('M4 18v-5a8 8 0 0 1 16 0v5M4 14h3.5v6H4zM16.5 14H20v6h-3.5z'),
  phone('M8 3h8a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM11 18h2'),
  speaker('M7 3h10v18H7zM12 7v.2M12 11a3.2 3.2 0 1 0 0 6.4 3.2 3.2 0 0 0 0-6.4z'),
  folder('M3.5 6.5h6l2 2h9v10h-17z'),
  globe('M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3.5 12h17M12 3c3.2 3.5 3.2 14.5 0 18M12 3c-3.2 3.5-3.2 14.5 0 18'),
  equalizer('M4 10v4M8 6v12M12 9v6M16 4v16M20 10v4'),
  info('M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v5.5M12 7.8v.2'),
  code('M8.5 7l-5 5 5 5M15.5 7l5 5-5 5'),
  document('M6 3h8l4 4v14H6zM14 3v4h4'),
  offline(
    'M3 3l18 18M8.5 16a5 5 0 0 1 7 0M4.5 12.5a10.5 10.5 0 0 1 4.3-2.6M19.5 12.5a10.5 10.5 0 0 0-4-2.5M2 9a15 15 0 0 1 4-2.6M22 9a15 15 0 0 0-9.5-3.4M12 19.5v.2',
  ),
  lock('M6 11h12v9H6zM8.5 11V8a3.5 3.5 0 0 1 7 0v3'),
  check('M5 12.5l4.5 4.5L19 7'),
  alert('M12 4 2.5 20h19zM12 10v4.5M12 17.3v.2'),
  external('M14 4h6v6M20 4l-9 9M18 14v6H4V6h6'),
  clock('M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7.5V12l3 2'),
  grip('M5 9h14M5 15h14'),
  palette('M12 3a9 9 0 0 0 0 18c1.5 0 2-1 1.5-2-.6-1.2.2-2.5 1.5-2.5H18a3 3 0 0 0 3-3A9 9 0 0 0 12 3z'),
  plug('M9 3v5M15 3v5M6.5 8h11v3a5.5 5.5 0 0 1-11 0zM12 16.5V21'),
  wifi('M2.5 9a14 14 0 0 1 19 0M6 12.5a9 9 0 0 1 12 0M9.3 16a4 4 0 0 1 5.4 0M12 19.3v.2'),
  quality('M4 18V6M8 18v-8M12 18V8M16 18v-5M20 18V4'),
  bolt('M13 3 5 13.5h6L10 21l8-10.5h-6z'),
  sun(
    'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4',
  ),
  cam('M4 8h3.5l1.5-2.5h6L16.5 8H20v11H4zM12 10.5a3 3 0 1 0 0 6 3 3 0 0 0 0-6z'),
  torch('M8 3h8v4l-2 3v11h-4V10L8 7z');

  const CauceGlyph(this.data, {this.filled = false});

  /// SVG path data on the 24-unit grid.
  final String data;

  /// Painted as a solid shape rather than a stroke.
  final bool filled;
}

/// One of the app's icons at [size], stroked [weight] units thick on the 24-unit grid.
class CauceIcon extends StatelessWidget {
  const CauceIcon(this.glyph, {super.key, this.size = 24, this.color, this.weight = 1.8});

  final CauceGlyph glyph;
  final double size;

  /// Defaults to the ambient icon colour.
  final Color? color;
  final double weight;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _GlyphPainter(glyph, color, weight)),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color, this.weight);

  final CauceGlyph glyph;
  final Color color;
  final double weight;

  static final _paths = <CauceGlyph, Path>{};

  @override
  void paint(Canvas canvas, Size size) {
    final path = _paths.putIfAbsent(glyph, () => parseSvgPath(glyph.data)..fillType = PathFillType.evenOdd);
    canvas.scale(size.width / 24);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true
        ..style = glyph.filled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = weight
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color || old.weight != weight;
}

final _token = RegExp(r'[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?');

/// A [Path] from SVG path data, covering the commands the icon set uses: M L H V C S A Z, each
/// absolute or relative, with implicit repeats.
Path parseSvgPath(String data) {
  final path = Path();
  final tokens = _token.allMatches(data).map((match) => match[0]!).toList();
  var index = 0;
  var command = 'M';
  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  // The second control point of the last curve, which a smooth curve mirrors.
  double? controlX, controlY;
  bool isCommand(String token) => RegExp(r'^[A-Za-z]$').hasMatch(token);
  double next() => double.parse(tokens[index++]);

  while (index < tokens.length) {
    if (isCommand(tokens[index])) command = tokens[index++];
    final relative = command == command.toLowerCase();
    final dx = relative ? x : 0.0, dy = relative ? y : 0.0;
    var curve = false;
    switch (command.toUpperCase()) {
      case 'M':
        x = dx + next();
        y = dy + next();
        path.moveTo(x, y);
        startX = x;
        startY = y;
        // Pairs after a move are lines.
        command = relative ? 'l' : 'L';
      case 'L':
        x = dx + next();
        y = dy + next();
        path.lineTo(x, y);
      case 'H':
        x = dx + next();
        path.lineTo(x, y);
      case 'V':
        y = dy + next();
        path.lineTo(x, y);
      case 'C':
        final x1 = dx + next(), y1 = dy + next();
        controlX = dx + next();
        controlY = dy + next();
        x = dx + next();
        y = dy + next();
        path.cubicTo(x1, y1, controlX, controlY, x, y);
        curve = true;
      case 'S':
        final x1 = controlX == null ? x : 2 * x - controlX;
        final y1 = controlY == null ? y : 2 * y - controlY;
        controlX = dx + next();
        controlY = dy + next();
        x = dx + next();
        y = dy + next();
        path.cubicTo(x1, y1, controlX, controlY, x, y);
        curve = true;
      case 'A':
        final rx = next(), ry = next(), rotation = next();
        final large = next() != 0, sweep = next() != 0;
        x = dx + next();
        y = dy + next();
        path.arcToPoint(
          Offset(x, y),
          radius: Radius.elliptical(rx, ry),
          rotation: rotation,
          largeArc: large,
          clockwise: sweep,
        );
      case 'Z':
        path.close();
        x = startX;
        y = startY;
      default:
        throw FormatException('Unsupported path command $command', data);
    }
    if (!curve) controlX = controlY = null;
  }
  return path;
}
