import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:auto_updater/auto_updater.dart';
import 'package:ethnocount/core/constants/app_update_config.dart' show appcastUrl;

/// Проверяет обновления на desktop (Windows, macOS). На web и мобильных — не активен.
class DesktopUpdateWrapper extends StatefulWidget {
  const DesktopUpdateWrapper({super.key, required this.child});
  final Widget child;

  @override
  State<DesktopUpdateWrapper> createState() => _DesktopUpdateWrapperState();
}

class _DesktopUpdateWrapperState extends State<DesktopUpdateWrapper> {
  static bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      _initUpdater();
    }
  }

  Future<void> _initUpdater() async {
    try {
      await autoUpdater.setFeedURL(appcastUrl);
      await autoUpdater.checkForUpdates();
      await autoUpdater.setScheduledCheckInterval(3600);
    } catch (_) {
      // Игнорируем: appcast может быть ещё не настроен
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
