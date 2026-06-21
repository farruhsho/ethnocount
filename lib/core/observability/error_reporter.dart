import 'package:flutter/foundation.dart';

/// Централизованный приём необработанных ошибок приложения.
///
/// Раньше `main()` не имел ни `runZonedGuarded`, ни `FlutterError.onError` —
/// любой краш денежной операции уходил в тишину (нет мониторинга прода).
/// Теперь все необработанные ошибки сходятся сюда.
///
/// Сейчас [report] пишет структурный лог (виден в проде через нативные логи
/// / `flutter logs`). Контур готов к подключению Sentry/Crashlytics: добавьте
/// `sentry_flutter`, вызовите `Sentry.captureException(...)` в [report], а DSN
/// прокидывайте через `--dart-define=SENTRY_DSN=...` (см. [isRemoteEnabled]).
class ErrorReporter {
  ErrorReporter._();

  static const String _sentryDsn =
      String.fromEnvironment('SENTRY_DSN', defaultValue: '');

  /// true, если задан DSN — можно слать ошибки во внешний мониторинг.
  static bool get isRemoteEnabled => _sentryDsn.isNotEmpty;

  /// Принять необработанную ошибку. [context] — источник (FlutterError,
  /// PlatformDispatcher, runZonedGuarded и т.п.) для удобной фильтрации.
  static void report(Object error, StackTrace? stack, {String? context}) {
    final tag = context == null ? 'ERROR' : 'ERROR · $context';
    debugPrint('[$tag] $error');
    if (stack != null) {
      debugPrint(stack.toString());
    }
    // TODO(observability): при isRemoteEnabled — Sentry.captureException(
    //   error, stackTrace: stack); требует пакета sentry_flutter и init в main.
  }
}
