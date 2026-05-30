# Ethnocount — Partner-Channel Improvement Prompt
> **Назначение:** этот документ — техзадание для следующего раунда работы по партнёрским переводам. Каждый пункт = конкретная боль из текущей системы, которую нужно закрыть, чтобы можно было считать **реальные деньги** в проде.
>
> **Перед началом — прочитай `docs/AGENT_PROMPT.md` (мастер-контекст).** Здесь только пробелы и улучшения.
>
> **Версия аудита:** 2026-05-22, после применения миграций 022-046.

## Текущий статус закрытия пунктов

| Пункт | Статус |
|---|---|
| **P0.1** Transfer.viaCounterpartyId | ✅ Готово |
| **P0.2** Recompute spread на replace | ✅ Готово (мигр. 044) |
| **P0.3** Commission income materialization | ⏳ Ждёт бизнес-решения |
| **P0.4** Settlement same-currency | ⏳ В очереди (минорный) |
| **P0.5** Account_balances для commission | = P0.3 |
| **P1.1** Dealer mode в обычной форме | ✅ Готово (мигр. 044 + UI) |
| **P1.2** Detach UI | ✅ Готово |
| **P1.3** Receiver name в TX-tile | ✅ Готово (мигр. 045) |
| **P1.4** Auto-fill курсов | ✅ Готово (обе формы) |
| **P1.5** Partner-pending статус | ⏳ Ждёт бизнес-решения |
| **P1.6** Settlement в monthly chart | ✅ Готово (мигр. 044) |
| **P1.7** Mobile/desktop unify | ✅ Готово (`_buildDetailPanel`) |
| **P1.8** Edit dialog с dealer | ✅ Готово |
| **P1.9** home_branch_id check | ✅ Готово (мигр. 046) |
| **P1.10** Settle preview saldo | ✅ Готово |
| **P2.2** Pull-to-refresh | ✅ Готово |
| **P2.*** прочие polish | ⏳ По запросу |

**Применённые миграции:** 022 → 046. Все идемпотентны (`CREATE OR REPLACE` + `DROP IF EXISTS`).

---

## Как читать

| Метка | Значение |
|---|---|
| 🔴 **P0** | Прод-блокер. Деньги уже могут разойтись или UI обманывает пользователя. |
| 🟠 **P1** | UX-дыра или incomplete-feature. Не блокер, но юзер ругается каждый день. |
| 🟢 **P2** | Polish, nice-to-have. Можно отложить. |
| 📁 | Где править (файл/миграция). |
| ✅ | Acceptance criterion — когда считаем сделанным. |
| 🧪 | Test scenario — как воспроизвести/проверить. |

---

## 🔴 P0. Production blockers

### P0.1 — `Transfer` entity не знает что он партнёрский
**Боль:** в Dart `Transfer` нет поля `viaCounterpartyId`. UI на странице переводов показывает кнопку «На партнёрский» даже для уже привязанных → юзер клацает → RPC отбивает «уже привязан к другому» → конфуз. То же — нет ленты-маркера «партнёрский» в списке переводов.

**📁:**
- `lib/domain/entities/transfer.dart` — добавить `String? viaCounterpartyId`
- `lib/data/datasources/remote/transfer_remote_ds.dart` — добавить в `.select(...)` и mapping
- `lib/presentation/transfers/pages/transfers_page.dart`:
  - в `_buildActions`: показывай «На партнёрский» только если `t.viaCounterpartyId == null`
  - если привязан → показывай «Открепить» (вызов `detach_transfer_from_partner`)
  - в `_StatusHeader` или `_PartiesBlock` — бейдж «🤝 Через партнёра» с именем

**✅:**
- В детализации перевода видно к какому партнёру привязан (имя + ссылка)
- Кнопка «На партнёрский» появляется только когда не привязан
- Кнопка «Открепить» только когда привязан

**🧪:**
1. Создай обычный перевод → детализация → жми «На партнёрский» → привяжи к Тиме
2. Закрой/открой детализацию → видна плашка «Через Тиму»
3. Кнопка «На партнёрский» исчезла, появилась «Открепить»
4. Жми «Открепить» → подтверждение → saldo откатилось → плашка ушла

---

### P0.2 — `replace_pending_transfer` не пересчитывает `spread_profit`
**Боль:** оператор отредактировал pending-перевод (поменял amount) — `spread_profit` остался от старой суммы. Аналитика покажет фальшивую прибыль.

**📁:** `supabase/migrations/044_recompute_spread_on_replace.sql` (новая)
- В `private.replace_pending_transfer` после `UPDATE transfers SET amount = ...` добавь recompute:
  ```sql
  IF v_t.buy_rate IS NOT NULL AND v_t.sell_rate IS NOT NULL THEN
    UPDATE transfers SET spread_profit = private.calc_spread_profit(
      v_amount, v_t.buy_rate, v_t.sell_rate
    ) WHERE id = p_transfer_id;
  END IF;
  ```
- Аналогично для via_counterparty_id ≠ null: пересчитать `counterparty_transactions.amount` (paid_for_us) и saldo: вычесть старое, добавить новое.

**✅:**
- После edit pending-перевода `spread_profit` соответствует новой `amount`
- Saldo партнёра пересчитано корректно

**🧪:**
1. Создай партнёрский перевод 1000 UZS, buy=10, sell=8 → spread = 200 UZS, saldo[base] -= 100
2. Edit → amount = 2000 UZS → spread должен стать 400 UZS, saldo[base] = -200 (а не -300)
3. `partner_profit_summary` показывает spread 400

---

### P0.3 — Confirm обычного перевода: commission «исчезает»
**Боль:** при `confirm_transfer` создаётся запись в `commissions`, но `account_balances` НЕ обновляется на сумму commission. То есть мы говорим бухгалтеру «комиссия 10 USD» но **денег на специальном счёте нет**. Это работает только для `commission_mode='fromAccount'` (миграция 032 фиксит). Для других режимов commission «не материализуется» как доход.

**📁:** `supabase/migrations/045_commission_income_on_confirm.sql` (новая)
- При `confirm_transfer` для `commission_mode IN ('fromSender', 'fromTransfer', 'toReceiver')` создать credit на «commission income» счёт филиала. Или ввести системный аккаунт `branch.commission_income_account_id`.
- Решение бизнес-уровня нужно: КУДА капает commission для не-fromAccount режимов? Если «в кассу филиала» — нужна явная привязка branch → account.

**✅:**
- `admin_commission_summary()` возвращает совпадающие цифры с `commissions` таблицей
- Где-то на UI можно показать «У филиала комиссионный доход за месяц = X»

**🧪:**
1. 10 переводов с commission 5%, mode=fromTransfer, amount=100 USD → каждый дал 5 USD commission
2. `admin_commission_summary` → total = 50 USD
3. На счёте commission income филиала должно быть +50 USD

⚠️ Это **бизнес-вопрос**, не чисто техническая фикс. Обсуди с пользователем КАК материализовать commission в balance для не-fromAccount режимов.

---

### P0.4 — Settlement profit не считается для same-currency
**Боль:** если партнёр привёз ровно ту валюту что и saldo (USD/USD), но по другому курсу — формально spread = 0 (т.к. mismatch формула требует cross-currency). Но реально может быть выгода/убыток если мы переводим в локальную валюту мысленно.

**📁:** `supabase/migrations/046_settle_same_currency_spread.sql`
- В `record_counterparty_op` если currency=closes_currency, но передан `p_expected_rate ≠ 1` — это означает что мы хотим зафиксировать notional профит относительно внешнего бенчмарка.
- Расширить логику: если `expected_rate != actual_rate (=1)` и same-currency → spread = (1 − expected_rate) × amount.

**Альтернатива:** запретить `expected_rate` для same-currency, чтобы UI не показывал бессмысленные поля.

**✅:**
- UI _RecordOpDialog: «Cross-currency расчёт» toggle блокируется когда close_currency = currency
- Или: правильно считается spread при отличающемся expected_rate

**🧪:** обсуди с пользователем сценарий — нужно или нет.

---

### P0.5 — `account_balances.balance` не имеет `commission income` для не-fromAccount режимов
*См. P0.3 — это та же боль другой стороной.*

---

## 🟠 P1. UX & UX correctness

### P1.1 — UI создания обычного перевода не имеет dealer mode (buy/sell)
**Боль:** Бухгалтер из филиала Ташкент → Москва (наш филиал) принимает у клиента UZS. Хочет зафиксировать spread (наш buy 12500 vs внутренний sell 12000 при списании с Москвы). Сейчас это можно сделать только через backfill после создания.

**📁:** `lib/presentation/transfers/pages/create_transfer_page.dart`
- Добавить такой же `_DealerModeToggle` + `_DealerRatesBlock` как в `partner_transfer_dialog.dart`
- В RPC `create_transfer` принять `p_buy_rate`, `p_sell_rate`, `p_base_currency` (миграция 047)
- При INSERT в transfers сохранить + `calc_spread_profit`

**✅:**
- Bookkeeper включил dealer toggle → spread сохраняется на момент создания
- `transfer_profit_summary` (общий) показывает spread не только для партнёрских

**🧪:**
1. Создай Ташкент→Москва, amount=12 500 000 UZS, buy=12500, sell=12000, base=USD
2. `transfer_profit_summary` для филиала Ташкент: spread_profit = 500 000 UZS

---

### P1.2 — Detach UI отсутствует
**Боль:** RPC `detach_transfer_from_partner` существует (миграция 041), UI кнопки нет.

**📁:** `lib/presentation/transfers/pages/transfers_page.dart`
- В `_buildActions`: если `t.viaCounterpartyId != null` и `canManageTransfers` → кнопка «Открепить от партнёра» с подтверждающим диалогом
- (Зависит от P0.1 — нужно поле `viaCounterpartyId` в entity)

**✅:**
- Прикрепить → проверить → открепить → saldo вернулось

---

### P1.3 — История партнёра не показывает имя получателя в TX-tile
**Боль:** Юзер сказал «понять что мы перевели через него». Сейчас в TX-tile видно `kind`, сумму, описание (которое включает имя если оно было). Но это в description, не явно.

**📁:** `lib/presentation/counterparties/pages/counterparties_page.dart` → `_TxTile`
- В `counterparty_tx_detail` RPC (миграция 038) добавить `receiver_name`, `receiver_phone`
- В UI показать прямо под transaction_code: «Получатель: Иван Иванов (+7 999...)»

**📁:** `supabase/migrations/048_counterparty_tx_detail_receiver.sql`

**✅:**
- В истории партнёра видно ФИО и телефон каждого получателя

---

### P1.4 — Курсы exchange_rates не подтягиваются в форму
**Боль:** Юзер каждый раз вводит buy/sell руками. Можем подставлять последний `exchange_rates` для пары `base→currency` и `currency→base` соответственно.

**📁:** `lib/presentation/counterparties/widgets/partner_transfer_dialog.dart` + create_transfer_page
- При выборе base_currency дёрнуть `ExchangeRateRepository.getLatestRate(base, currency)` → подставить как hint в buy_rate
- То же для sell (с offset/коммисией если бизнес-логика говорит «sell = market − 1%»)

**✅:**
- Открыл форму → buy/sell уже заполнены рыночным курсом
- Можно поправить

---

### P1.5 — Партнёрский перевод сразу `delivered` — нет «pending выплаты»
**Боль:** мы фиксируем что Тима выплатил **в момент создания**. Но реально партнёр выплачивает потом. Если что-то пошло не так — нужно delete_transfer.

**📁:** возможно нужен новый статус `partnerPending`. Это большое изменение.

**Альтернатива (мягкая):**
- В `create_partner_transfer` принять флаг `p_already_paid bool DEFAULT true`
- Если `false` → status = `created` (как обычный), saldo НЕ двигается, partner_transactions НЕ создаётся
- Потом отдельный RPC `confirm_partner_payout(transfer_id)` который делает то что сейчас делает атомарно

**✅:**
- Можно создать partner-перевод в pending → потом подтвердить когда партнёр реально выплатил
- Saldo не уходит в минус до подтверждения

**🧪:**
1. Создай partner_transfer с already_paid=false → status='created', saldo неизменно
2. Подтверди через UI «Партнёр выплатил» → saldo сдвинется

---

### P1.6 — `partner_profit_summary` settlement_profit без timeseries
**Боль:** есть `partner_profit_monthly` с spread+commission, но settlement_profit там не выводится — он живёт в counterparty_transactions, а monthly агрегирует transfers.

**📁:** `supabase/migrations/049_partner_profit_monthly_with_settlement.sql`
- Расширить `partner_profit_monthly` чтобы JOIN-ить `counterparty_transactions` per month и добавить колонку `settlement_profit`
- UI: bar chart показывает 3 стека вместо 2 (spread/commission/settlement)

**✅:**
- На вкладке Партнёры график показывает все 3 источника прибыли по месяцам

---

### P1.7 — Mobile/Desktop разнобой для детализации партнёра
**Боль:** на desktop справа панель, на mobile — отдельный `MaterialPageRoute`. Логика дублирована (передача callback'ов вручную в двух местах). Если добавляешь новую кнопку — забываешь в одном из мест.

**📁:** `lib/presentation/counterparties/pages/counterparties_page.dart`
- Извлечь общий вызов в один метод `_buildDetailPanel(c)` который возвращает виджет
- В обоих случаях (desktop Expanded и mobile MaterialPageRoute) вызывать его

**✅:**
- При добавлении новой кнопки правишь ровно одно место
- На mobile и desktop UI идентичен

---

### P1.8 — Edit transfer dialog не имеет dealer mode
**Боль:** через UI «Изменить» нельзя поменять buy/sell. Только через backfill в карточке партнёра (TX-tile → «Указать курсы»). Это нелогично — основной сценарий «edit» должен покрывать всё.

**📁:** `lib/presentation/transfers/widgets/edit_transfer_dialog.dart`
- Добавить ту же `_DealerRatesBlock` секцию
- При сохранении вызывать `replace_pending_transfer` с дополнительными `p_buy_rate`, `p_sell_rate`, `p_base_currency`
- В RPC `replace_pending_transfer` расширить сигнатуру (миграция 050)

**✅:**
- Через edit можно изменить курсы → spread пересчитан (см. P0.2)

---

### P1.9 — `home_branch_id` партнёра не проверяется при attach/transfer
**Боль:** партнёр Тима привязан к филиалу Москва (home_branch_id). Бухгалтер из Алматы делает перевод через Тиму — это разумно? Может бизнес хочет ограничения.

**📁:** обсудить с бизнесом. Если ограничение нужно:
- В `create_partner_transfer` и `attach_transfer_to_partner` добавить проверку:
  ```sql
  IF v_cp.home_branch_id IS NOT NULL
     AND v_t.from_branch_id <> v_cp.home_branch_id
     AND v_role = 'accountant' THEN
     RAISE EXCEPTION '...';
  END IF;
  ```

**✅:** бизнес даёт ответ.

---

### P1.10 — Settle dialog: нет показа «после операции saldo станет X»
**Боль:** в `_RecordOpDialog` для settle нет preview итогового сальдо. Юзер не уверен что вводит правильно.

**📁:** `lib/presentation/counterparties/pages/counterparties_page.dart` → `_RecordOpDialog`
- Добавить блок под суммой:
  ```
  Текущее saldo[currency]: −1000 USD
  После операции: 0 USD ✓
  ```
- Расчёт: `_currentSaldo + _saldoDelta`

**✅:**
- Юзер видит итог перед кликом «Записать»

---

## 🟢 P2. Polish

### P2.1 — Дубликатная проверка партнёра по имени+телефону при создании
- При `create_counterparty` если такое имя+телефон уже есть → предупреждение, не блокер

### P2.2 — Pull-to-refresh на странице партнёров (mobile)
- Сейчас только кнопка обновить

### P2.3 — Bulk backfill курсов
- Если у партнёра 50 переводов без buy/sell — диалог «Установить курсы для всех за период X»

### P2.4 — Notifications: партнёрский перевод
- При `create_partner_transfer` отправлять notification в `home_branch_id` партнёра (или всем у кого permission «партнёры»)

### P2.5 — Export всех операций партнёра как Excel (XLSX)
- Сейчас CSV в буфер. Для крупных партнёров нужен real XLSX (через `excel` package или server-side generator)

### P2.6 — Печатная форма для партнёра
- «Акт сверки» с партнёром: saldo по валютам + история операций за период + подпись

### P2.7 — Telegram-уведомления для партнёра
- При новом партнёрском переводе слать Тиме в Telegram сумму/получателя автоматически

### P2.8 — Архивные партнёры — отдельная вкладка/раздел
- Сейчас filter chip, можно сделать как отдельную секцию

---

## 🧪 Production Validation Plan

Прежде чем считать **реальные деньги**, прогони эти сценарии на dev/staging Supabase:

### Cycle 1: Обычный perfect-flow
```
[Ташкент] create_transfer(1000 USD → Москва) →
[Москва] confirm_transfer(to_account) →
[Москва] dispatch_to_courier →
[Москва] issue_transfer →
admin_audit_balances() → diff = 0
```

### Cycle 2: Партнёрский с dealer-spread
```
[Ташкент] create_partner_transfer(12_500_000 UZS, buy=12500, sell=12000, base=USD)
  → spread_profit = 500_000 UZS, saldo[Тима][USD] -= 1000
[Тима привёз 12_300_000 UZS]
[Ташкент] record_counterparty_op(settle_to_us, cash_amount=12_300_000 UZS,
  close_amount=1000 USD, expected_rate=12500)
  → settlement_profit = (12300−12500)×1000 = −200_000 UZS (убыток)
  → saldo[Тима][USD] = 0
admin_audit_balances() → diff = 0
partner_profit_summary(Тима) → spread=500_000, commission=0, settlement=-200_000, net=300_000
```

### Cycle 3: Прикрепление существующего
```
[Ташкент] create_transfer(1000 USD)
[Ташкент] attach_transfer_to_partner(Тима, buy=10, sell=8, base=BASE)
  → spread = 1000 − (1000/10)*8 = 200 USD, saldo[Тима][BASE] -= 100
[Detach]
  → saldo откатилось, spread NULL, via_counterparty_id NULL
admin_audit_balances() → diff = 0
```

### Cycle 4: Доступ accountant
```
Accountant Ташкент пытается create_transfer(from_branch=Москва)
  → 42501 «Бухгалтер не привязан к филиалу-отправителю»
Accountant видит только Ташкент-переводы в списке (RLS + клиентский фильтр)
Accountant пытается delete_transfer чужого (от другого бухгалтера в Ташкенте)
  → разрешено (один филиал = одна семья), но проверь что это OK по бизнесу
```

### Cycle 5: Денежная консистентность под нагрузкой
- Сделай 100 создание+confirm+issue одновременно через скрипт
- admin_audit_balances → каждая строка diff = 0

---

## ⚙️ Checklist для merge каждого пункта

- [ ] Миграция применена через MCP / `supabase db push`, `list_migrations` подтвердил
- [ ] `flutter analyze lib/` → 0 errors, 0 warnings (в моих файлах)
- [ ] Сценарий из 🧪 прогон вручную или скриптом
- [ ] `admin_audit_balances()` → diff = 0 после сценария
- [ ] Race condition test: двойной клик → один результат (idempotency_key защищает)
- [ ] Mobile + Desktop UI оба работают
- [ ] Roll-back path продуман (что делать если что-то пошло не так в проде)

---

## 📋 Suggested merge order

```
P0.1 (Transfer.viaCounterpartyId)  ──┐
P0.2 (replace recompute spread)      │ 1 неделя — критический фикс
P0.3 (commission materialization)  ──┘

P1.1 (dealer mode в обычной форме)  ──┐
P1.2 (detach UI)                      │
P1.7 (mobile/desktop refactor)        │ 2 неделя — фичи
P1.8 (edit с dealer)                  │
P1.10 (settle preview)                │
P1.3 (receiver_name в TX-tile)      ──┘

P1.4 (exchange_rates auto-fill)     ──┐
P1.5 (partner pending status)         │ 3 неделя — UX-улучшения
P1.6 (settlement в monthly chart)     │
P1.9 (home_branch проверка)         ──┘

P2.* (по запросу) — отдельный backlog
```

После P0+P1 — система готова к **реальным деньгам**. P2 — для масштабирования.

---

## 🎯 Definition of «можно запускать в проде»

1. ✅ Все P0 закрыты + Cycle 1-5 прогон на staging без ошибок
2. ✅ `admin_audit_balances()` показывает diff = 0 на staging после 1000+ операций
3. ✅ Phone-нормализация работает: один номер `+7 999 999 99 99` → `+79999999999` везде
4. ✅ Бухгалтер физически не может создать перевод из чужого филиала (RPC 42501)
5. ✅ Двойной клик не создаёт два перевода (idempotency)
6. ✅ Отрицательного баланса нет на счетах где не было дебита (recompute сошёлся)
7. ✅ Все Cancel/Delete операции имеют snapshot в `deleted_transfers`
8. ✅ Roll-out план: `supabase db push` запущен на staging → 24ч прогон → потом prod

После этого можно открывать систему для реальных переводов.

---

## 🚨 Что НЕ трогать

Эти миграции/файлы — фундамент, ломать опасно:

- `001_initial_schema.sql` — структура users/branches/transfers/ledger
- `005_fix_ledger_consistency.sql` — base invariant maintenance
- `022_status_redesign.sql` — state machine (триггер `tg_transfers_status_guard`)
- `031_recompute_balances.sql` — самовосстановление балансов
- `private.calc_spread_profit()` — формула

Если **обязательно** надо менять — создавай новую миграцию которая `CREATE OR REPLACE`-аит конкретную функцию, не редактируй старые SQL-файлы.

---

**Конец improvement-промпта.** Возвращайся к нему после каждого merged-PR — приоритеты могут двигаться.
