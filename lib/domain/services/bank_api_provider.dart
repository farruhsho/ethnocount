import '../entities/bank_transaction.dart';

/// Статус подключения к банку через API.
enum BankConnectionStatus {
  disconnected,
  connecting,
  connected,
  expired,
  error,
}

/// Результат подключения к API банка.
class BankConnectionResult {
  final BankConnectionStatus status;
  final String? errorMessage;

  const BankConnectionResult({
    required this.status,
    this.errorMessage,
  });

  bool get isConnected => status == BankConnectionStatus.connected;
}

/// Абстрактный провайдер API банка.
/// Реализации: SberbankApiProvider, AlfaBankApiProvider, TinkoffApiProvider и т.д.
///
/// Подключение требует:
/// - Регистрации в портале банка (developers.sber.ru, alfabank.ru и т.д.)
/// - OAuth 2.0 flow для получения токена
/// - Безопасного хранения refresh_token (flutter_secure_storage)
abstract class BankApiProvider {
  /// Идентификатор банка (sberbank, alfa, tinkoff).
  String get bankId;

  /// Отображаемое имя.
  String get displayName;

  /// Проверить, подключён ли аккаунт.
  Future<BankConnectionStatus> getConnectionStatus(String userId);

  /// Запустить OAuth — открыть URL для авторизации в браузере.
  /// После успешной авторизации банк перенаправит на redirect_uri с code.
  Future<String> getAuthorizationUrl({
    required String userId,
    required String redirectUri,
    required String state,
  });

  /// Обмен code на токены и сохранение.
  Future<BankConnectionResult> exchangeCodeForTokens({
    required String userId,
    required String code,
    required String redirectUri,
  });

  /// Загрузить транзакции за период.
  Future<List<BankTransaction>> fetchTransactions({
    required String userId,
    required String accountId,
    required DateTime from,
    required DateTime to,
  });

  /// Отключить (удалить токены).
  Future<void> disconnect(String userId);
}
