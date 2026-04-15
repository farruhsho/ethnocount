# Автообновление desktop-приложения EthnoCount

Используется пакет **auto_updater** (Sparkle/WinSparkle).

## Как это работает

При запуске приложение проверяет `appcast.xml` по указанному URL. Если доступна новая версия — показывается стандартный диалог обновления (WinSparkle на Windows, Sparkle на macOS).

## Настройка

### 1. URL appcast.xml

Измените URL в `lib/core/constants/app_update_config.dart`:

```dart
const String appcastUrl = 'https://ВАШ_СЕРВЕР/updates/appcast.xml';
```

### 2. Windows: OpenSSL

Установите OpenSSL (через Chocolatey):

```
choco install openssl
```

### 3. Генерация ключей подписи (для безопасности)

```bash
dart run auto_updater:generate_keys
```

На Windows создаются `dsa_priv.pem` и `dsa_pub.pem`. Добавьте публичный ключ в `windows/runner/Runner.rc`:

```
DSAPub DSAPEM "../../dsa_pub.pem"
```

### 4. Сборка релиза

Используйте [Flutter Distributor](https://github.com/leanflutter/flutter_distributor) или вручную:

```bash
flutter build windows --release
```

### 5. Подпись обновления (Windows)

```bash
dart run auto_updater:sign_update dist/1.0.0+1/ethnocount-1.0.0+1-windows.exe
```

Скопируйте полученный `sparkle:dsaSignature` в appcast.xml.

### 6. Формат appcast.xml

См. `updates/appcast.xml` — шаблон. Для каждого релиза добавьте `<item>` с:
- `sparkle:version` — build number (например 2 для 1.0.0+2)
- `sparkle:shortVersionString` — версия (1.0.0)
- `enclosure` с `url` (путь к exe/zip), `sparkle:dsaSignature`, `length`

### 7. Хостинг

Загрузите `appcast.xml` и папки с бинарниками на Firebase Storage, свой сервер или CDN. URL должен быть публичным.
