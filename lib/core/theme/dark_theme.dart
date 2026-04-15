import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_typography.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';

/// Dark theme configuration for EthnoCount.
class DarkTheme {
  DarkTheme._();

  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.darkBg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          onPrimary: AppColors.darkBg,
          secondary: AppColors.secondary,
          onSecondary: Colors.white,
          surface: AppColors.darkSurface,
          onSurface: AppColors.darkTextPrimary,
          error: AppColors.error,
          onError: Colors.white,
          outline: AppColors.darkBorder,
        ),
        textTheme: TextTheme(
          displayLarge: AppTypography.displayLarge.copyWith(color: AppColors.darkTextPrimary),
          displayMedium: AppTypography.displayMedium.copyWith(color: AppColors.darkTextPrimary),
          displaySmall: AppTypography.displaySmall.copyWith(color: AppColors.darkTextPrimary),
          headlineLarge: AppTypography.headlineLarge.copyWith(color: AppColors.darkTextPrimary),
          headlineMedium: AppTypography.headlineMedium.copyWith(color: AppColors.darkTextPrimary),
          headlineSmall: AppTypography.headlineSmall.copyWith(color: AppColors.darkTextPrimary),
          titleLarge: AppTypography.titleLarge.copyWith(color: AppColors.darkTextPrimary),
          titleMedium: AppTypography.titleMedium.copyWith(color: AppColors.darkTextPrimary),
          titleSmall: AppTypography.titleSmall.copyWith(color: AppColors.darkTextSecondary),
          bodyLarge: AppTypography.bodyLarge.copyWith(color: AppColors.darkTextPrimary),
          bodyMedium: AppTypography.bodyMedium.copyWith(color: AppColors.darkTextSecondary),
          bodySmall: AppTypography.bodySmall.copyWith(color: AppColors.darkTextTertiary),
          labelLarge: AppTypography.labelLarge.copyWith(color: AppColors.darkTextPrimary),
          labelMedium: AppTypography.labelMedium.copyWith(color: AppColors.darkTextSecondary),
          labelSmall: AppTypography.labelSmall.copyWith(color: AppColors.darkTextTertiary),
        ),
        cardTheme: CardThemeData(
          color: AppColors.darkCard,
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
            side: const BorderSide(color: AppColors.darkBorder, width: 1),
          ),
          margin: EdgeInsets.zero,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: AppColors.darkBg,
          foregroundColor: AppColors.darkTextPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: AppTypography.headlineSmall.copyWith(
            color: AppColors.darkTextPrimary,
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppColors.darkSurface,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.darkTextTertiary,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: AppColors.darkSurface,
          selectedIconTheme: IconThemeData(color: AppColors.primary),
          unselectedIconTheme: IconThemeData(color: AppColors.darkTextTertiary),
          indicatorColor: AppColors.primarySurface,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.darkCard,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            borderSide: const BorderSide(color: AppColors.darkBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            borderSide: const BorderSide(color: AppColors.darkBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            borderSide: const BorderSide(color: AppColors.error),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.formFieldGap,
          ),
          hintStyle: AppTypography.bodyMedium.copyWith(
            color: AppColors.darkTextTertiary,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.darkBg,
            elevation: 0,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xxl,
              vertical: AppSpacing.md,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
            textStyle: AppTypography.labelLarge.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.darkBorder),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xxl,
              vertical: AppSpacing.md,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.darkDivider,
          thickness: 1,
          space: 0,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: AppColors.darkCard,
          selectedColor: AppColors.primarySurface,
          side: const BorderSide(color: AppColors.darkBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
          ),
          labelStyle: AppTypography.labelMedium.copyWith(
            color: AppColors.darkTextSecondary,
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.darkSurface,
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: AppColors.darkCard,
          contentTextStyle: AppTypography.bodyMedium.copyWith(
            color: AppColors.darkTextPrimary,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          behavior: SnackBarBehavior.floating,
        ),
        dataTableTheme: DataTableThemeData(
          headingRowHeight: 48,
          dataRowMinHeight: 56,
          dataRowMaxHeight: 72,
          headingRowColor: WidgetStateProperty.all(AppColors.darkSurface),
          headingTextStyle: AppTypography.labelMedium.copyWith(
            color: AppColors.darkTextSecondary,
            fontWeight: FontWeight.w600,
          ),
          dataTextStyle: AppTypography.bodyMedium.copyWith(
            color: AppColors.darkTextPrimary,
          ),
        ),
        listTileTheme: const ListTileThemeData(
          contentPadding: EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.xs,
          ),
          minVerticalPadding: 14,
        ),
        focusColor: AppColors.primarySurface,
        hoverColor: AppColors.primary.withValues(alpha: 0.08),
        splashColor: AppColors.primary.withValues(alpha: 0.12),
        highlightColor: AppColors.primary.withValues(alpha: 0.08),
      );
}
