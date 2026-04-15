import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';

/// Convenience extensions on BuildContext.
extension ContextX on BuildContext {
  // ─── Theme shortcuts ───
  ThemeData get theme => Theme.of(this);
  TextTheme get textTheme => Theme.of(this).textTheme;
  ColorScheme get colorScheme => Theme.of(this).colorScheme;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  // ─── Media query ───
  Size get screenSize => MediaQuery.sizeOf(this);
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;
  EdgeInsets get padding => MediaQuery.paddingOf(this);
  EdgeInsets get viewInsets => MediaQuery.viewInsetsOf(this);

  // ─── Responsive helpers ───
  bool get isMobile => screenWidth < AppSpacing.breakpointMobile;
  bool get isTablet =>
      screenWidth >= AppSpacing.breakpointMobile &&
      screenWidth < AppSpacing.breakpointDesktop;
  bool get isDesktop => screenWidth >= AppSpacing.breakpointDesktop;
  bool get isWidescreen => screenWidth >= AppSpacing.breakpointWidescreen;

  // ─── Navigation ───
  void pop<T>([T? result]) => Navigator.of(this).pop(result);

  // ─── Snackbar ───
  void showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(this).hideCurrentSnackBar();
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? colorScheme.error : null,
      ),
    );
  }

  void showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(this).hideCurrentSnackBar();
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: colorScheme.primary,
      ),
    );
  }
}
