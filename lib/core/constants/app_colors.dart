import 'package:flutter/material.dart';

/// Premium fintech color palette using HSL-derived values.
/// Dark-first design with subtle accent colors.
class AppColors {
  AppColors._();

  // ─── Brand Primary (Teal / Cyan accent) ───
  static const Color primary = Color(0xFF00D1A0);
  static const Color primaryLight = Color(0xFF33DDBA);
  static const Color primaryDark = Color(0xFF00A67E);
  static const Color primarySurface = Color(0x1A00D1A0); // 10% opacity

  // ─── Secondary (Electric Blue) ───
  static const Color secondary = Color(0xFF4C7CF5);
  static const Color secondaryLight = Color(0xFF7DA0FF);
  static const Color secondaryDark = Color(0xFF2A5BD8);

  // ─── Semantic ───
  static const Color success = Color(0xFF00C48C);
  static const Color warning = Color(0xFFFFAA2B);
  static const Color error = Color(0xFFFF4757);
  static const Color info = Color(0xFF3B82F6);

  // ─── Income / Expense ───
  static const Color income = Color(0xFF00C48C);
  static const Color expense = Color(0xFFFF4757);
  static const Color transfer = Color(0xFF4C7CF5);

  // ─── Dark Theme ───
  static const Color darkBg = Color(0xFF0A0E17);
  static const Color darkSurface = Color(0xFF121829);
  static const Color darkCard = Color(0xFF1A2138);
  static const Color darkCardHover = Color(0xFF212A45);
  static const Color darkBorder = Color(0xFF2A3352);
  static const Color darkDivider = Color(0xFF1E2740);

  static const Color darkTextPrimary = Color(0xFFF1F3F8);
  static const Color darkTextSecondary = Color(0xFF8B95B0);
  /// Softer than before for WCAG-friendly contrast on darkCard/darkSurface.
  static const Color darkTextTertiary = Color(0xFF7A85A0);
  static const Color darkTextDisabled = Color(0xFF3D465E);

  // ─── Light Theme ───
  static const Color lightBg = Color(0xFFF5F7FA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightCardHover = Color(0xFFF0F2F5);
  static const Color lightBorder = Color(0xFFE2E6EF);
  static const Color lightDivider = Color(0xFFEDF0F5);

  static const Color lightTextPrimary = Color(0xFF0F1729);
  static const Color lightTextSecondary = Color(0xFF5A6480);
  static const Color lightTextTertiary = Color(0xFF8B95B0);
  static const Color lightTextDisabled = Color(0xFFBCC4D6);

  // ─── Glassmorphism ───
  static const Color glassWhite = Color(0x1AFFFFFF);
  static const Color glassBorder = Color(0x33FFFFFF);
  static const Color glassDark = Color(0x1A000000);
  static const Color glassDarkBorder = Color(0x33000000);

  // ─── Chart Colors ───
  static const List<Color> chartPalette = [
    Color(0xFF00D1A0),
    Color(0xFF4C7CF5),
    Color(0xFFFFAA2B),
    Color(0xFFFF4757),
    Color(0xFF9B59B6),
    Color(0xFFF39C12),
    Color(0xFF1ABC9C),
    Color(0xFFE74C3C),
  ];

  // ─── Gradients ───
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF00D1A0), Color(0xFF00A3FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient darkCardGradient = LinearGradient(
    colors: [Color(0xFF1A2138), Color(0xFF121829)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient incomeGradient = LinearGradient(
    colors: [Color(0xFF00C48C), Color(0xFF00D1A0)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient expenseGradient = LinearGradient(
    colors: [Color(0xFFFF4757), Color(0xFFFF6B7A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
