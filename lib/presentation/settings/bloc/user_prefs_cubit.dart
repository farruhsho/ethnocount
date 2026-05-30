import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Локальные (per-device) предпочтения пользователя. Сейчас хранит флаг
/// «использовать курсы валют». Можно дополнять по мере появления настроек.
class UserPrefs extends Equatable {
  final bool useExchangeRates;
  const UserPrefs({this.useExchangeRates = true});

  UserPrefs copyWith({bool? useExchangeRates}) =>
      UserPrefs(useExchangeRates: useExchangeRates ?? this.useExchangeRates);

  @override
  List<Object?> get props => [useExchangeRates];
}

class UserPrefsCubit extends Cubit<UserPrefs> {
  static const _kUseRates = 'pref.useExchangeRates';

  UserPrefsCubit() : super(const UserPrefs()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final useRates = prefs.getBool(_kUseRates) ?? true;
    emit(state.copyWith(useExchangeRates: useRates));
  }

  Future<void> setUseExchangeRates(bool v) async {
    emit(state.copyWith(useExchangeRates: v));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUseRates, v);
  }
}
