import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/core/supabase/supabase_config.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/routing/route_persistence.dart';
import 'package:ethnocount/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Decode SVG before first frame so splash logo does not "pop in".
  try {
    const ethnoSvgLoader = SvgAssetLoader('assets/icons/ethno.svg');
    await ethnoSvgLoader.loadBytes(null);
  } catch (_) {
    // Asset / decode failure should not block startup.
  }

  final prefs = await SharedPreferences.getInstance();
  RoutePersistence.prime(prefs);

  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );

  await initDependencies();

  runApp(const EthnoCountApp());
}
