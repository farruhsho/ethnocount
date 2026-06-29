import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Securely stores and retrieves saved login credentials.
///
/// SEC-2: мы НЕ храним сырой пароль. «Запомнить меня» сохраняет только email
/// (для автозаполнения поля логина) и флаг предпочтения. Сама сессия держится
/// на Supabase access/refresh-токенах, поэтому пароль на устройстве не нужен.
class CredentialStorageService {
  static const _keyEmail = 'saved_email';
  static const _keyRememberMe = 'saved_remember_me';
  static const _keyRememberMePreference = 'remember_me_preference';
  // Legacy-ключ: использовался для хранения пароля в открытом виде.
  // Больше не пишется; чистим при любой записи/очистке, чтобы вычистить
  // ранее сохранённые на устройстве пароли.
  static const _legacyKeyPassword = 'saved_password';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> saveCredentials({
    required String email,
    required bool rememberMe,
  }) async {
    await _saveRememberMePreference(rememberMe);
    // На всякий случай удаляем легаси-пароль, если он остался с прошлых версий.
    await _storage.delete(key: _legacyKeyPassword);
    if (rememberMe) {
      await _storage.write(key: _keyEmail, value: email);
      await _storage.write(key: _keyRememberMe, value: 'true');
    } else {
      await clearCredentials();
    }
  }

  Future<void> clearCredentials() async {
    await _storage.delete(key: _keyEmail);
    await _storage.delete(key: _legacyKeyPassword);
    await _storage.delete(key: _keyRememberMe);
  }

  Future<void> saveRememberMePreference(bool value) async {
    await _saveRememberMePreference(value);
  }

  Future<void> _saveRememberMePreference(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRememberMePreference, value);
  }

  Future<({String? email, bool rememberMe})> loadCredentials() async {
    final email = await _storage.read(key: _keyEmail);
    final rememberMe = await _storage.read(key: _keyRememberMe);
    final prefs = await SharedPreferences.getInstance();
    final prefRemember = prefs.getBool(_keyRememberMePreference);
    return (
      email: email,
      rememberMe: rememberMe == 'true' || (prefRemember ?? false),
    );
  }
}
