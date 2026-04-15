import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_typography.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';

/// Light theme configuration for EthnoCount.
class LightTheme {
  LightTheme._();

  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.lightBg,
        colorScheme: const ColorScheme.light(
          primary: AppColors.primary,
          onPrimary: Colors.white,
          secondary: AppColors.secondary,
          onSecondary: Colors.white,
          surface: AppColors.lightSurface,
          onSurface: AppColors.lightTextPrimary,
          error: AppColors.error,
          onError: Colors.white,
          outline: AppColors.lightBorder,
        ),
        textTheme: TextTheme(
          displayLarge: AppTypography.displayLarge.copyWith(color: AppColors.lightTextPrimary),
          displayMedium: AppTypography.displayMedium.copyWith(color: AppColors.lightTextPrimary),
          displaySmall: AppTypography.displaySmall.copyWith(color: AppColors.lightTextPrimary),
          headlineLarge: AppTypography.headlineLarge.copyWith(color: AppColors.lightTextPrimary),
          headlineMedium: AppTypography.headlineMedium.copyWith(color: AppColors.lightTextPrimary),
          headlineSmall: AppTypography.headlineSmall.copyWith(color: AppColors.lightTextPrimary),
          titleLarge: AppTypography.titleLarge.copyWith(color: AppColors.lightTextPrimary),
          titleMedium: AppTypography.titleMedium.copyWith(color: AppColors.lightTextPrimary),
          titleSmall: AppTypography.titleSmall.copyWith(color: AppColors.lightTextSecondary),
          bodyLarge: AppTypography.bodyLarge.copyWith(color: AppColors.lightTextPrimary),
          bodyMedium: AppTypography.bodyMedium.copyWith(color: AppColors.lightTextSecondary),
          bodySmall: AppTypography.bodySmall.copyWith(color: AppColors.lightTextTertiary),
          labelLarge: AppTypography.labelLarge.copyWith(color: AppColors.lightTextPrimary),
          labelMedium: AppTypography.labelMedium.copyWith(color: AppColors.lightTextSecondary),
          labelSmall: AppTypography.labelSmall.copyWith(color: AppColors.lightTextTertiary),
        ),
        cardTheme: CardThemeData(
          color: AppColors.lightCard,
          elevation: 2,
          shadowColor: AppColors.primary.withValues(alpha: 0.05),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
            side: const BorderSide(color: AppColors.lightBorder, width: 1),
          ),
          margin: EdgeInsets.zero,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: AppColors.lightBg,
          foregroundColor: AppColors.lightTextPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: AppTypography.headlineSmall.copyWith(
            color: AppColors.lightTextPrimary,
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppColors.lightSurface,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.lightTextTertiary,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: AppColors.lightSurface,
          selectedIconTheme: IconThemeData(color: AppColors.primary),
          unselectedIconTheme: IconThemeData(color: AppColors.lightTextTertiary),
          indicatorColor: AppColors.primarySurface,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.lightSurface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            borderSide: const BorderSide(color: AppColors.lightBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            borderSide: const BorderSide(color: AppColors.lightBorder),
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
            color: AppColors.lightTextTertiary,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
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
            side: const BorderSide(color: AppColors.lightBorder),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xxl,
              vertical: AppSpacing.md,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.lightDivider,
          thickness: 1,
          space: 0,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: AppColors.lightSurface,
          selectedColor: AppColors.primarySurface,
          side: const BorderSide(color: AppColors.lightBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
          ),
          labelStyle: AppTypography.labelMedium.copyWith(
            color: AppColors.lightTextSecondary,
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.lightSurface,
          elevation: 8,
          shadowColor: AppColors.primary.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: AppColors.lightTextPrimary,
          contentTextStyle: AppTypography.bodyMedium.copyWith(
            color: AppColors.lightSurface,
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
          headingRowColor: WidgetStateProperty.all(AppColors.lightSurface),
          headingTextStyle: AppTypography.labelMedium.copyWith(
            color: AppColors.lightTextSecondary,
            fontWeight: FontWeight.w600,
          ),
          dataTextStyle: AppTypography.bodyMedium.copyWith(
            color: AppColors.lightTextPrimary,
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
        hoverColor: AppColors.primary.withValues(alpha: 0.06),
        splashColor: AppColors.primary.withValues(alpha: 0.10),
        highlightColor: AppColors.primary.withValues(alpha: 0.06),
      );
}
