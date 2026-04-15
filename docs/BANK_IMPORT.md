# Импорт банковских операций

## Текущая реализация

### Импорт из файла (CSV / Excel)

1. **Журнал** → кнопка **«Импорт из банка»** или **Dashboard** → **«Импорт из банка»**
2. Выберите файл выписки (CSV или Excel)
3. Укажите филиал, счёт/карту и опционально категорию
4. Нажмите **«Импортировать»**

Поддерживаются форматы Сбербанка, Альфа-Банка, Тинькофф и других банков. Автоопределение колонок: дата, сумма, описание, тип (приход/расход), контрагент.

### Категории и контрагенты

- **Категория** — добавляется к описанию в формате `[Категория] Описание`
- **Контрагент** — берётся из выписки (если есть колонка) и добавляется в описание

## Подключение API банков

### Архитектура

В проекте подготовлена основа для API:

- `lib/domain/services/bank_api_provider.dart` — абстрактный интерфейс провайдера
- `lib/domain/services/bank_api_registry.dart` — реестр провайдеров
- `lib/data/services/sberbank_api_provider.dart` — шаблон для Сбербанка

### Шаги подключения Сбербанк

1. Регистрация на [developers.sber.ru](https://developers.sber.ru)
2. Создание приложения → получение `client_id` и `client_secret`
3. Настройка `redirect_uri` (например, `ethnocount://oauth/callback`)
4. Реализация OAuth 2.0 (authorization_code) в `SberbankApiProvider`
5. Хранение токенов в `flutter_secure_storage` (по `userId`)
6. Вызов API выписок: `GET /v1/accounts/{accountId}/statements`

### Альфа-Банк

- [alfabank.ru/api](https://alfabank.ru) — API для бизнеса
- Создать `AlfaBankApiProvider` по аналогии с `SberbankApiProvider`

### Регистрация провайдера

В `initDependencies()` или при старте приложения:

```dart
BankApiRegistry.instance.register(SberbankApiProvider());
```

### UI для API

Добавить экран «Подключить банк»:
- Список доступных банков (`BankApiRegistry.instance.all`)
- Кнопка «Подключить» → `getAuthorizationUrl()` → `url_launcher`
- Обработка deep link с `code` → `exchangeCodeForTokens()`
- Периодическая синхронизация через `fetchTransactions()`
