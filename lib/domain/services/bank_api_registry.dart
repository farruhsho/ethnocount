import 'bank_api_provider.dart';

/// Реестр провайдеров банковских API.
/// Регистрируйте реализации (Sberbank, Alfa и т.д.) при инициализации приложения.
class BankApiRegistry {
  BankApiRegistry._();
  static final BankApiRegistry _instance = BankApiRegistry._();
  static BankApiRegistry get instance => _instance;

  final Map<String, BankApiProvider> _providers = {};

  void register(BankApiProvider provider) {
    _providers[provider.bankId] = provider;
  }

  BankApiProvider? get(String bankId) => _providers[bankId];

  List<BankApiProvider> get all => _providers.values.toList();

  bool get hasAny => _providers.isNotEmpty;
}
