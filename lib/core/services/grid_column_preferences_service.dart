import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists column visibility per grid so settings survive page reopen.
class GridColumnPreferencesService {
  static const _prefix = 'grid_hidden_';

  Future<List<String>> loadHiddenFields(String gridId) async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('$_prefix$gridId');
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List<dynamic>?;
      return list?.map((e) => e.toString()).toList() ?? [];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHiddenFields(String gridId, List<String> hiddenFields) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$gridId', jsonEncode(hiddenFields));
  }
}
