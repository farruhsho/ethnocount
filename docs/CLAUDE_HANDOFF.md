# Ethnocount — handoff для нового Claude-агента (Opus 4.5+)

> Этот файл — короткий «вход в проект» для свежей сессии. Прочитай его
> первым, потом смотри код. Без этого контекста можно потратить час на
> то, что объясняется тут за 5 минут.

---

## 1. Что это за проект

**Ethnocount** — внутренний treasury / денежные-переводы платформа для
сети филиалов в УЗ / РФ / КЗ / КГ / ТУР / ОАЭ / КНР. Оператор-бухгалтер
ведёт:

- **переводы** между филиалами (cash и карты);
- **клиентов** с мульти-валютными кошельками (`client_balances.balances`
  jsonb);
- **контрагентов-партнёров** в др. городах — посредники, через которых
  выплачиваем переводы, ведя с ними сальдо (`counterparties.saldo_by_currency`
  jsonb);
- **счета филиала** (`branch_accounts`: cash / card / reserve / transit) —
  это «наши деньги»;
- **курсы** валют (мы — реальный обменник, держим buy/sell rates);
- **комиссии** и spread-profit аналитику;
- **согласования** удалений/изменений через `pending_approvals`.

Пользователь — **Фаррух** (`farruhmuzrabov@gmail.com`), пишет
русским/транслитом. **Отвечать по-русски.**

---

## 2. Стек

- **Flutter 3** (Material 3, dark + light), Riverpod НЕ используется —
  **BLoC** + **flutter_bloc**.
- **go_router** с `ShellRoute` и `AdaptiveShell` (desktop ↔ mobile).
- **DI**: `get_it` через `sl<T>()` из `lib/core/di/injection.dart`.
- **Backend**: **Supabase** (PostgreSQL + RLS + RPC + Realtime).
- **Иконки**: только через `AppIcons` facade (`lib/core/icons/app_icons.dart`)
  на базе `lucide_icons_flutter`. **Никогда** не использовать `Icons.*`
  напрямую (за редкими исключениями).
- **Тема**: dark-fintech уже реализован, есть готовая дизайн-система
  (`AppColors.darkCard`, `darkSurface`, `darkBorder`, `darkTextPrimary/
  Secondary/Tertiary`, `primary` (#00D1A0), `secondary` (#4C7CF5),
  `purple`, `warning`, `error`).
- **Шрифты**: `google_fonts.GoogleFonts.inter()` для UI текста, `jetBrainsMono`
  для чисел/кодов.
- **Таблицы**: `trina_grid` (универсальный wrapper — `DesktopDataGrid`
  в `lib/presentation/common/widgets/desktop_data_grid.dart`).

### Структура папок

```
lib/
  core/           — DI, константы, утилы (currency, phone, date)
  domain/         — entities, repositories, services (абстракции)
  data/           — datasources (remote = supabase), repositoryImpl
  presentation/
    auth/         — bloc + pages
    dashboard/    — bloc держит branches + branch_accounts
    transfers/    — pages, widgets, bloc
    clients/      — pages, widgets
    counterparties/ — partners (всё private внутри одного файла)
    accounts/     — branch_accounts (cash/card/...)
    notifications/, approvals/, rates/, analytics/, ...
supabase/
  migrations/     — все DB-изменения, идемпотентные, нумерованные
```

---

## 3. Жёсткие правила (нарушать нельзя)

### 3.1 Доменная модель — три раздельных слоя денег
```
branch_accounts.balance       ← наши деньги (касса/карта/резерв)
counterparties.saldo_by_currency ← сальдо с партнёром (jsonb)
client_balances.balances      ← кошелёк клиента (jsonb)
```
Эти три **никогда** не смешиваются. Контрагент НЕ создаёт строку в
`branch_accounts`. Перевод через counterparty не трогает наш
`branch_accounts.balance` (миграция 047), только sальдо партнёра.
Settlement-операции (`settle_to_us` / `settle_from_us`) — единственный
мост между branch_accounts и counterparties, и они делаются вручную
оператором через RecordOpDialog.

### 3.2 Roles & видимость
- **Creator / Director** — видят данные всех филиалов, могут всё.
- **Accountant** (бухгалтер) — видит только свои `assignedBranchIds`.
  Удаление/изменение переводов, клиентов, счетов идёт через
  **in-app approve-workflow** (`pending_approvals`).

Утилы: `lib/core/utils/branch_access.dart`:
- `userSeesAllBranches(user)`
- `filterBranchesByAccess(branches, user)`
- `accessibleBranchIds(user)` → `null` = без фильтра, set = только эти

### 3.3 Курсы валют — tier-based «сильной стороны»
Когда оператор вводит курс конвертации, он всегда видит «1 strong = X weak».
Tier-map в `create_transfer_page.dart` и `partner_transfer_dialog.dart`
(идентичные):

```dart
static const _currencyTier = <String, int>{
  'EUR':  10, 'GBP':  11,
  'USD':  20, 'USDT': 21,
  'CNY':  30, 'TRY':  31, 'AED':  32,
  'RUB':  40, 'KZT':  41,
  'UZS':  50, 'KGS':  51, 'TJS':  52,
};
```
Меньше число = сильнее. `_quotePair(from, to)` возвращает пару
(strong, weak). Пример: UZS→RUB пишет «1 RUB = X UZS», программа
сама пересчитывает 100 000 UZS / X = Y RUB.

### 3.4 Иконки
**Только** `AppIcons.xxx`. Если нужного нет — добавить в
`lib/core/icons/app_icons.dart` через `LucideIcons.xxx`. Иначе на
Windows сломаются emoji-флажки и пр.

### 3.5 Country-флажки
Не emoji (Windows их не поддерживает), а `CountryBadge` из
`lib/core/utils/phone_country.dart`. Префиксы: +7→RU, +77→KZ,
+998→UZ, +996→KG, +992→TJ, +90→TR, +86→CN, +971→AE. Используется
в `ContactAutocompleteField` (transfers) и в clients create dialog.

### 3.6 Flutter web — mouse_tracker assertion
Был критический баг: `_debugDuringDeviceUpdate` падал при создании
перевода на web. Причины:
- `AnimatedContainer` пере-декорирующийся внутри `InkWell` mid-hover;
- `LayoutBuilder` глубоко в hero-цепочке;
- Динамические `Tooltip` сообщения, меняющиеся на hover.

Если делаешь новый widget — избегать. На дальних подсветках лучше
обычный `Container` без implicit animation.

### 3.7 Защита от ошибок ввода сумм
Миграция 053 ставит `CHECK constraint` на `client_transactions.amount`:
`0 < amount <= 1e12`, не NaN. BEFORE-trigger на `client_balances.balances`
валидирует jsonb. **Не убирать** — был реальный прод-инцидент с
`1e+61` USD который сломал UI layout.

### 3.8 Git коммиты
**НЕ коммитить без явной просьбы пользователя.** Если просит —
формат: `Type: краткое описание` (Add / Update / Fix / Refactor / Docs).
Подпись:
```
Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

### 3.9 Документация
- **Не создавать `.md` файлы** без явной просьбы.
- **Не использовать emoji** в коде/файлах если пользователь не попросил.
- Комментарии **на русском** с объяснением «почему», а не «что».

### 3.10 Supabase
- Миграции **идемпотентны**: `DROP IF EXISTS`, `CREATE OR REPLACE`.
- Нумерация продолжается монотонно: следующая будет **054**.
- Применять через `mcp__supabase__apply_migration` (имя без расширения).
- RLS политики — обязательно для каждой новой таблицы.
- Перед изменением схемы — `list_tables`, перед дебагом — `get_logs` /
  `get_advisors`.

---

## 4. Что уже сделано в последних сессиях

### Миграции 047–053 (все применены к live DB)
| № | Что |
|---|---|
| **047** | Партнёр-сальдо в валюте перевода (без base-currency сворачивания) |
| **048** | `user_can_manage_branch_account()` + admin_* RPC принимают accountant |
| **049** | `confirm_transfer` гибкая валюта счёта-приёмника + amendment_history |
| **050** | `commission_profit_by_branch` и `commission_profit_totals` RPC |
| **051** | Cross-branch notifications (4 триггера + RLS `notifications_delete`) |
| **052** | `request_approval` пишет `_before` snapshot в payload |
| **053** | Sanity-caps на client amounts (CHECK + jsonb trigger) |

### UI улучшения
- **Create Transfer** — auto-флажок страны получателя по префиксу
  телефона, tier-based курсы;
- **Transfers list (desktop)** — колонка «Партнёр» (с ⇄ chip), Статус
  перенесён на 1-ю позицию (frozen), 3 frozen колонки, новый `gridId:
  'transfers_v2'` чтобы инвалидировать старые preferences;
- **Transfers list (mobile)** — `TransferRowCard` показывает partner
  badge (purple chip с именем counterparty);
- **TransferFilterBar** — новый card-style фильтр-стрип с
  статус-чипами, branch dropdown, period button, partner-mode toggle
  (Все / Через партнёра / Свои), search field (код/имя/телефон),
  reset-all;
- **PartnerTransferDialog** — tier-based курсы (UZS↔RUB теперь
  правильно), helper text с ориентирами («1 USD ≈ 12 700 UZS»), live
  preview под полем курса;
- **Notifications / Approvals** — swipe-actions, фильтр-чипы для
  approvals, before/after diff, pulse-wave анимация для непрочитанных.

### Архитектурные решения
- **Counterparties — НЕ как branch_accounts.** Это разные сущности.
  Проверено SQL-запросом: в `branch_accounts` нет ни одной строки,
  привязанной к counterparty (нет type='transit' с partner-имeнем).
- **`_PartnerLite` map в TransfersPage** — лёгкий снимок партнёров
  `{id → (name, city)}`, грузится один раз через прямой `from('counterparties')
  .select('id,name,city')`. НЕ через bloc — counterparties модель
  всё ещё private (`_Counterparty` внутри counterparties_page.dart).

---

## 5. Где мы сейчас

### Текущее состояние
- Все 5 задач последней сессии **завершены**, `flutter analyze` чистый.
- DB миграции **актуальные** до **053**.
- В **проде сейчас** новый transfer-list с partner-колонкой, фильтр-баром,
  улучшенным partner-dialog.

### Открытые направления (не сделано, ждут решения пользователя)
1. **Promote `_Counterparty` в domain entity.** Сейчас он private
   внутри `counterparties_page.dart`. Из-за этого в transfers page
   используется отдельный `_PartnerLite`. Если делать
   `counterparties` как bloc — это сэкономит дублирование.
2. **Фильтр «через конкретного партнёра»** в `TransferFilterBar`.
   Сейчас есть только toggle «все/через партнёра/свои», нет dropdown'а
   с именами партнёров.
3. **Partner-name в detail-sheet статус-хедера** перевода (сейчас там
   только «Через партнёра» badge без имени counterparty).
4. **UI input limits в client deposit/debit dialog** — backend защищён
   миграцией 053, но front-валидация ≤ 1e12 не добавлена. Хорошее UX
   улучшение — не давать ввести 25 цифр.

### О чём пользователь явно говорил, что не нравится
- **Drag-and-drop колонок** в trina_grid он называл «неудобным» — нужно
  посмотреть включён ли он по умолчанию и есть ли preset «вернуть
  стандартный порядок». Возможно стоит добавить кнопку «Reset layout»
  в `_GridToolbar` (`desktop_data_grid.dart`).
- **«scheta contra agentov v nashih kartah»** — пользователь видел
  где-то в UI смешивание счетов партнёров и наших счетов. SQL
  проверка показала чистую БД, но просьба «где именно в UI» осталась
  без ответа. Может всплыть снова.

---

## 6. Как работать дальше (рекомендации)

1. **Начинай с чтения этого файла.** Потом — то что просит юзер.
2. **Не делай predicate агентов / sub-agents** если пользователь не просил.
   В этом проекте все правки делаются inline через Read/Edit/Write.
3. **При больших файлах** (transfers_page.dart = 4286 строк,
   partner_transfer_dialog.dart = 1815) — не читай целиком. Используй
   `Grep` чтобы найти секцию, потом `Read` с offset+limit.
4. **После каждого блока правок** — `flutter analyze <file>` локально
   (через Bash). Не закрывай задачу пока не «No issues found».
5. **DB изменения**: новая миграция = новый файл с следующим номером
   (054, 055…) + `apply_migration` через MCP.
6. **Стиль комментариев** — длинные многострочные, объясняют
   архитектурные решения и «почему». Пользователь часто читает код
   при ревью, поэтому комментарий должен спасать его от вопроса
   «зачем тут это».
7. **Не пиши emoji** в коде, файлах, commit-сообщениях если явно не
   просили. В UI — только когда дизайн требует.
8. **Tasks**: использовать `TaskCreate` / `TaskUpdate` для задач
   ≥ 3 шагов. Простые правки — без них.

---

## 7. Файлы которые надо знать

| Файл | Зачем |
|---|---|
| `lib/core/constants/app_colors.dart` | Цветовая палитра, dark+light |
| `lib/core/icons/app_icons.dart` | Facade над lucide_icons_flutter |
| `lib/core/utils/branch_access.dart` | Role-based видимость филиалов |
| `lib/core/utils/phone_country.dart` | Авто-страна по +префиксу |
| `lib/core/utils/currency_utils.dart` | `CurrencyUtils.flag(cur)` |
| `lib/domain/entities/transfer.dart` | Главный entity, есть `viaCounterpartyId`, `isPartnerTransfer`, `hasDealerRates`, `spreadProfit` |
| `lib/presentation/common/widgets/desktop_data_grid.dart` | Универсальный wrapper над trina_grid с persistence |
| `lib/presentation/transfers/pages/transfers_page.dart` | Список переводов (desktop+mobile) |
| `lib/presentation/transfers/pages/create_transfer_page.dart` | Создание перевода |
| `lib/presentation/transfers/widgets/transfer_filter_bar.dart` | Новый фильтр-стрип |
| `lib/presentation/transfers/widgets/transfer_row_card.dart` | Мобильная строка |
| `lib/presentation/transfers/widgets/contact_autocomplete_field.dart` | Поиск контактов из истории + страна-флажок |
| `lib/presentation/counterparties/pages/counterparties_page.dart` | Партнёры (всё в одном файле) |
| `lib/presentation/counterparties/widgets/partner_transfer_dialog.dart` | Создание партнёр-перевода |
| `supabase/migrations/053_*.sql` | Последняя применённая миграция |

---

## 8. Контекст об операторе

- Работает с переводами **много раз в день**, ошибка в курсе или
  не выбранный филиал = реальный денежный убыток.
- Видел случай с overflow (1e+61 USD) — теперь параноит про большие суммы.
- Часто пишет на транслите без пунктуации. Не уточнять что значит
  каждое слово — отвечать на смысловом уровне.
- Любит **аудит-стиль ответов**: «проверено / решено / открыто».
- Не любит когда что-то делаешь без объяснения «почему».
- Когда говорит «ne uobno» / «ne pokazivaet» / «peremeshka» — это
  жалоба на UX, нужно посмотреть конкретное место и предложить fix.
