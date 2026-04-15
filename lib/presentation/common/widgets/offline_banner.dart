import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/constants/app_durations.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/network/connectivity_service.dart';

/// Offline banner that slides in when connectivity is lost.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final service = sl<ConnectivityService>();

    return StreamBuilder<bool>(
      stream: service.onConnectivityChanged,
      builder: (context, snapshot) {
        final isOnline = snapshot.data ?? true;

        return AnimatedSize(
          duration: AppDurations.normal,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: isOnline
              ? const SizedBox.shrink()
              : Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: const BoxDecoration(
                    color: AppColors.warning,
                  ),
                  child: const SafeArea(
                    bottom: false,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cloud_off_rounded, size: 16, color: Colors.black87),
                        SizedBox(width: AppSpacing.sm),
                        Text(
                          'Нет подключения к интернету',
                          style: TextStyle(
                            color: Colors.black87,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}
