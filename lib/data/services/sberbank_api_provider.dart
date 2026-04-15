import 'package:ethnocount/domain/entities/bank_transaction.dart';
import 'package:ethnocount/domain/services/bank_api_provider.dart';

/// Заглушка провайдера Sber API.
///
/// Для подключения:
/// 1. Зарегистрируйтесь на https://developers.sber.ru
/// 2. Создайте приложение, получите client_id и client_secret
/// 3. Настройте redirect_uri (например, ethnocount://oauth/callback)
/// 4. Реализуйте OAuth 2.0 flow (authorization_code)
/// 5. Используйте API выписок: GET /v1/accounts/{accountId}/statements
///
/// Документация: https://developers.sber.ru/docs/ru/sber-api/overview
class SberbankApiProvider implements BankApiProvider {
  // TODO: добавить в .env или SecureStorage
  static const String _clientId = 'YOUR_SBER_CLIENT_ID';
  static const String _clientSecret = 'YOUR_SBER_CLIENT_SECRET';
  static const String _baseUrl = 'https://api.sberbank.ru';

  @override
  String get bankId => 'sberbank';

  @override
  String get displayName => 'Сбербанк';

  @override
  Future<BankConnectionStatus> getConnectionStatus(String userId) async {
    // TODO: проверить наличие и валидность токена в SecureStorage
    return BankConnectionStatus.disconnected;
  }

  @override
  Future<String> getAuthorizationUrl({
    required String userId,
    required String redirectUri,
    required String state,
  }) async {
    // TODO: обменять code на access_token; поля ниже — заготовка для реального OAuth.
    return '$_baseUrl/oauth/authorize'
        '?client_id=$_clientId'
        '&redirect_uri=${Uri.encodeComponent(redirectUri)}'
        '&state=${Uri.encodeComponent(state)}'
        '&response_type=code'
        '&scope=openid'
        '&_stub_has_secret=${_clientSecret.isNotEmpty}';
  }

  @override
  Future<BankConnectionResult> exchangeCodeForTokens({
    required String userId,
    required String code,
    required String redirectUri,
  }) async {
    // TODO: POST к /oauth/token, сохранить access_token и refresh_token
    return const BankConnectionResult(status: BankConnectionStatus.error,
        errorMessage: 'API не настроен');
  }

  @override
  Future<List<BankTransaction>> fetchTransactions({
    required String userId,
    required String accountId,
    required DateTime from,
    required DateTime to,
  }) async {
    // TODO: GET выписки, преобразовать в List<BankTransaction>
    return [];
  }

  @override
  Future<void> disconnect(String userId) async {
    // TODO: удалить токены из SecureStorage
  }
}
