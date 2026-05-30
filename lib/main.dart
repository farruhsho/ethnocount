import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/core/supabase/supabase_config.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/routing/route_persistence.dart';
import 'package:ethnocount/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
}
