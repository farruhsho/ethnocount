import 'package:supabase_flutter/supabase_flutter.dart';

/// Полная snapshot настроек одной таблицы для одного пользователя.
class GridPreferencesSnapshot {
  const GridPreferencesSnapshot({
    this.hidden = const [],
    this.widths = const {},
    this.order = const [],
    this.sortField,
    this.sortAsc,
  });

  final List<String> hidden;
  final Map<String, double> widths;
  final List<String> order;
  final String? sortField;
  final bool? sortAsc;

  bool get isEmpty =>
      hidden.isEmpty &&
      widths.isEmpty &&
      order.isEmpty &&
      sortField == null;

  GridPreferencesSnapshot copyWith({
    List<String>? hidden,
    Map<String, double>? widths,
    List<String>? order,
    String? sortField,
    bool? sortAsc,
    bool clearSort = false,
  }) {
    return GridPreferencesSnapshot(
      hidden: hidden ?? this.hidden,
      widths: widths ?? this.widths,
      order: order ?? this.order,
      sortField: clearSort ? null : (sortField ?? this.sortField),
      sortAsc: clearSort ? null : (sortAsc ?? this.sortAsc),
    );
  }
}

/// Сохраняет настройки таблицы для каждого пользователя в Supabase
/// (таблица `user_grid_preferences` + RLS own row only). Синхронизируется
/// между устройствами автоматически — даже после выхода/входа.
class GridColumnPreferencesService {
  GridColumnPreferencesService(this._client);

  final SupabaseClient _client;

  /// Кеш в памяти, чтобы не дёргать сеть на каждом open страницы.
  final _cache = <String, GridPreferencesSnapshot>{};

  String? get _uid => _client.auth.currentUser?.id;

  String _key(String gridId) => '${_uid ?? '_'}:$gridId';

  /// Полный snapshot настроек. Возвращает пустой [GridPreferencesSnapshot]
  /// если строки нет или пользователь не авторизован.
  Future<GridPreferencesSnapshot> load(String gridId) async {
    if (_uid == null) return const GridPreferencesSnapshot();
    final cached = _cache[_key(gridId)];
    if (cached != null) return cached;

    try {
      final data = await _client
          .from('user_grid_preferences')
          .select('hidden, widths, col_order, sort_field, sort_asc')
          .eq('user_id', _uid!)
          .eq('grid_id', gridId)
          .maybeSingle();

      if (data == null) {
        return _cache[_key(gridId)] = const GridPreferencesSnapshot();
      }
      final snap = GridPreferencesSnapshot(
        hidden: _asStringList(data['hidden']),
        widths: _asWidths(data['widths']),
        order: _asStringList(data['col_order']),
        sortField: data['sort_field'] as String?,
        sortAsc: data['sort_asc'] as bool?,
      );
      return _cache[_key(gridId)] = snap;
    } catch (_) {
      return const GridPreferencesSnapshot();
    }
  }

  /// Полный upsert. Лучше дёргать через debounce / на dispose страницы,
  /// а не на каждый ресайз — иначе кучу запросов.
  Future<void> save(String gridId, GridPreferencesSnapshot snap) async {
    if (_uid == null) return;
    _cache[_key(gridId)] = snap;
    try {
      await _client.rpc('save_grid_preferences', params: {
        'p_grid_id': gridId,
        'p_hidden': snap.hidden,
        'p_widths': snap.widths,
        'p_col_order': snap.order,
        'p_sort_field': snap.sortField,
        'p_sort_asc': snap.sortAsc,
      });
    } catch (_) {
      // Тихо игнорим — настройки таблицы не критичны, переживём reload.
    }
  }

  // ─── Backwards compatibility helpers ───────────────────────────────
  // Внутри проекта раньше был API loadHiddenFields/saveHiddenFields на
  // SharedPreferences. Чтобы не переписывать все callsite разом, оставляем
  // тонкие обёртки над snapshot.

  Future<List<String>> loadHiddenFields(String gridId) async {
    return (await load(gridId)).hidden;
  }

  Future<void> saveHiddenFields(String gridId, List<String> hidden) async {
    final cur = await load(gridId);
    await save(gridId, cur.copyWith(hidden: hidden));
  }

  /// Сбросить кеш, когда пользователь сменился.
  void invalidateAll() => _cache.clear();

  static List<String> _asStringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString()).toList();
  }

  static Map<String, double> _asWidths(dynamic raw) {
    if (raw is! Map) return const {};
    final out = <String, double>{};
    raw.forEach((k, v) {
      final d = v is num ? v.toDouble() : double.tryParse(v.toString());
      if (d != null) out[k.toString()] = d;
    });
    return out;
  }
}
