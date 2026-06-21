import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/core/supabase/supabase_config.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/observability/error_reporter.dart';
import 'package:ethnocount/core/routing/route_persistence.dart';
import 'package:ethnocount/app.dart';

void main() {
  // Единая зона перехвата необработанных ошибок. Без неё (как было раньше)
  // упавшая денежная операция уходила в тишину — в проде нет способа узнать,
  // что у бухгалтера падает выдача/конвертация. Теперь все ошибки —
  // framework (FlutterError), платформенные (PlatformDispatcher) и из async
  // зон — сходятся в ErrorReporter (лог сейчас, Sentry/Crashlytics при DSN).
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      ErrorReporter.report(
        details.exception,
        details.stack,
        context: 'FlutterError',
      );
    };
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      ErrorReporter.report(error, stack, context: 'PlatformDispatcher');
      return true;
    };

    // Russian-locale month/day names for DateFormat.
    await initializeDateFormatting('ru');

    final prefs = await SharedPreferences.getInstance();
    RoutePersistence.prime(prefs);

    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );

    await initDependencies();

    runApp(const EthnoCountApp());
  }, (Object error, StackTrace stack) {
    ErrorReporter.report(error, stack, context: 'runZonedGuarded');
  });
}
