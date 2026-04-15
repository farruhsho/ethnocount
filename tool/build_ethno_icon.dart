// Regenerates assets/icons/ethno_icon.png when the file is missing or corrupt.
// For a pixel-perfect logo, export 1024×1024 PNG from assets/icons/ethno.svg and replace.
import 'dart:io';

import 'package:image/image.dart';

void main() {
  const w = 1024;
  const h = 1024;
  final img = Image(width: w, height: h);
  fill(img, color: ColorRgb8(250, 248, 246));
  // Brand mark: dark on cream (#0D0808 from ethno.svg, background like adaptive_icon_background)
  fillCircle(
    img,
    x: w ~/ 2,
    y: h ~/ 2,
    radius: 300,
    color: ColorRgb8(13, 8, 8),
  );
  fillCircle(
    img,
    x: w ~/ 2,
    y: h ~/ 2,
    radius: 185,
    color: ColorRgb8(250, 248, 246),
  );
  File('assets/icons/ethno_icon.png').writeAsBytesSync(encodePng(img));
  // ignore: avoid_print
  print('Wrote assets/icons/ethno_icon.png (placeholder ring — replace from SVG for exact logo).');
}
