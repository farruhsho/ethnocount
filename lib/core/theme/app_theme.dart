import 'package:ethnocount/core/theme/dark_theme.dart';
import 'package:ethnocount/core/theme/light_theme.dart';

export 'dark_theme.dart';
export 'light_theme.dart';
export 'glassmorphism.dart';

/// Central theme configuration.
class AppTheme {
  AppTheme._();

  static final dark = DarkTheme.theme;
  static final light = LightTheme.theme;
}
