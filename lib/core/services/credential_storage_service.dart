import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Securely stores and retrieves saved login credentials.
class CredentialStorageService {
  static const _keyEmail = 'saved_email';
  static const _keyPassword = 'saved_password';
  static const _keyRememberMe = 'saved_remember_me';
  static const _keyRememberMePreference = 'remember_me_preference';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> saveCredentials({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    await _saveRememberMePreference(rememberMe);
    if (rememberMe) {
      await _storage.write(key: _keyEmail, value: email);
      await _storage.write(key: _keyPassword, value: password);
      await _storage.write(key: _keyRememberMe, value: 'true');
    } else {
      await clearCredentials();
    }
  }

  Future<void> clearCredentials() async {
    await _storage.delete(key: _keyEmail);
    await _storage.delete(key: _keyPassword);
    await _storage.delete(key: _keyRememberMe);
  }

  Future<void> saveRememberMePreference(bool value) async {
    await _saveRememberMePreference(value);
  }

  Future<void> _saveRememberMePreference(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRememberMePreference, value);
  }

  Future<({String? email, String? password, bool rememberMe})> loadCredentials() async {
    final email = await _storage.read(key: _keyEmail);
    final password = await _storage.read(key: _keyPassword);
    final rememberMe = await _storage.read(key: _keyRememberMe);
    final prefs = await SharedPreferences.getInstance();
    final prefRemember = prefs.getBool(_keyRememberMePreference);
    return (
      email: email,
      password: password,
      rememberMe: rememberMe == 'true' || (prefRemember ?? false),
    );
  }
}
