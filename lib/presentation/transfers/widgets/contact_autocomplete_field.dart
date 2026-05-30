import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/core/utils/phone_country.dart';
import 'package:ethnocount/core/utils/phone_input_formatter.dart';
import 'package:ethnocount/data/datasources/remote/transfer_remote_ds.dart';

/// Поле «Телефон отправителя/получателя» с живым выпадающим списком
/// контактов из истории переводов.
///
/// Поведение:
///   • при вводе ≥2 символов в поле телефона ИЛИ имени отправляется
///     дебаунс-запрос `searchContacts(query, side)`;
///   • найденные контакты показываются в overlay под полем (телефон, ФИО,
///     валюта-флажок);
///   • по тапу подставляются ВСЕ поля (имя/телефон/доп.инфо), а для
///     отправителя — ещё и валюта перевода через [onCurrencyPicked].
///
/// Виджет получает извне три контроллера, чтобы их значения видела
/// родительская форма. Поиск можно дёрнуть с другого поля через
/// [externalQueryTrigger] — например, когда меняется имя, а виджет рисует
/// только телефон.
class ContactAutocompleteField extends StatefulWidget {
  const ContactAutocompleteField({
    super.key,
    required this.side,
    required this.phoneController,
    required this.nameController,
    required this.infoController,
    required this.label,
    required this.hintText,
    this.onCurrencyPicked,
  });

  /// 'sender' — ищем в sender_* колонках; 'receiver' — в receiver_*.
  final String side;
  final TextEditingController phoneController;
  final TextEditingController nameController;
  final TextEditingController infoController;
  final String label;
  final String hintText;

  /// Только для отправителя — куда подставить валюту выбранного контакта.
  final ValueChanged<String>? onCurrencyPicked;

  @override
  State<ContactAutocompleteField> createState() =>
      _ContactAutocompleteFieldState();
}

class _ContactAutocompleteFieldState extends State<ContactAutocompleteField> {
  final _layerLink = LayerLink();
  final _focusNode = FocusNode();
  OverlayEntry? _overlay;
  Timer? _debounce;
  List<TransferContactSnapshot> _results = const [];
  bool _loading = false;
  String _lastQuery = '';
  /// True сразу после `_select(...)` — блокирует повторный поиск/overlay
  /// пока пользователь не введёт что-то новое руками. Без этого после
  /// клика по чипу overlay появлялся снова через 350мс (debounce),
  /// маскируя что выбор сработал.
  bool _justSelected = false;

  /// Авто-определение страны по префиксу телефона. Обновляется в
  /// `_onPhoneChanged`, рендерится как prefixIcon (CountryBadge) вместо
  /// обычной phone-иконки. Помогает оператору сразу понять что система
  /// поняла «+7…» как Россию, «+998…» как Узбекистан и т.д.
  CountryMatch? _country;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    widget.phoneController.addListener(_onPhoneChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode.removeListener(_onFocusChange);
    widget.phoneController.removeListener(_onPhoneChanged);
    _focusNode.dispose();
    _hideOverlay();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      if (_results.isNotEmpty && !_justSelected) _showOverlay();
    } else {
      // Закрываем с задержкой 220мс — это больше чем тап (обычно 100-150мс).
      // Раньше было 120мс и тап по элементу overlay не успевал
      // зарегистрироваться: focus уходил → overlay скрывался → tap «не
      // выбирал с первого раза».
      Future.delayed(const Duration(milliseconds: 220), _hideOverlay);
    }
  }

  void _onPhoneChanged() {
    // Авто-определение страны по префиксу. Делаем ВСЕГДА (даже после
    // программной подстановки в _select), чтобы при выборе контакта из
    // подсказок флажок страны сразу нарисовался без ожидания первого
    // ручного клика.
    final match = PhoneCountryDetector.detect(widget.phoneController.text);
    if (match?.countryCode != _country?.countryCode) {
      setState(() => _country = match);
    }

    // Если только что выбрали контакт — controller.text был программно
    // подставлен, не считаем это вводом пользователя.
    if (_justSelected) return;
    _scheduleSearch(widget.phoneController.text);
  }

  void _scheduleSearch(String raw) {
    _debounce?.cancel();
    final q = raw.trim();
    if (q.length < 2) {
      _results = const [];
      _hideOverlay();
      return;
    }
    if (q == _lastQuery) return;
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      _lastQuery = q;
      if (!mounted) return;
      setState(() => _loading = true);
      try {
        final res = await sl<TransferRemoteDataSource>()
            .searchContacts(query: q, side: widget.side);
        if (!mounted) return;
        setState(() {
          _results = res;
          _loading = false;
        });
        if (_focusNode.hasFocus && res.isNotEmpty) {
          _showOverlay();
        } else {
          _hideOverlay();
        }
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _results = const [];
          _loading = false;
        });
        _hideOverlay();
      }
    });
  }

  void _showOverlay() {
    _hideOverlay();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    final width = renderBox?.size.width ?? 280;
    _overlay = OverlayEntry(
      builder: (ctx) => Positioned(
        width: width,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 6),
          targetAnchor: Alignment.bottomLeft,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            color: Theme.of(context).colorScheme.surface,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _results.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.12),
                ),
                itemBuilder: (_, i) {
                  final c = _results[i];
                  return _ContactTile(
                    contact: c,
                    onTap: () => _select(c),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_overlay!);
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _select(TransferContactSnapshot c) {
    _justSelected = true;
    _debounce?.cancel();
    widget.phoneController.text = c.phone;
    if ((c.name ?? '').isNotEmpty) widget.nameController.text = c.name!;
    if ((c.info ?? '').isNotEmpty) widget.infoController.text = c.info!;
    if (widget.side == 'sender' &&
        (c.currency ?? '').isNotEmpty &&
        widget.onCurrencyPicked != null) {
      widget.onCurrencyPicked!(c.currency!);
    }
    _lastQuery = c.phone.trim();
    _hideOverlay();
    _focusNode.unfocus();
    // Снимаем флаг через короткий промежуток — после этого пользователь
    // может изменить телефон и снова получить подсказки.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _justSelected = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextFormField(
        controller: widget.phoneController,
        focusNode: _focusNode,
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
          // Авто-флажок страны вместо обычной phone-иконки если префикс
          // распознан. Так оператор сразу видит куда улетит перевод
          // (RU/UZ/KG/...) — не надо вручную выбирать страну.
          prefixIcon: _country == null
              ? const Icon(AppIcons.phone, size: 20)
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    widthFactor: 1,
                    child: CountryBadge(match: _country!, size: 22),
                  ),
                ),
          isDense: true,
          hintText: widget.hintText,
          suffixIcon: _loading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                )
              : (_results.isNotEmpty
                  ? IconButton(
                      tooltip: 'Показать найденные',
                      icon: const Icon(Icons.expand_more, size: 20),
                      onPressed: () {
                        _focusNode.requestFocus();
                        _showOverlay();
                      },
                    )
                  : null),
        ),
        keyboardType: TextInputType.phone,
        inputFormatters: [
          PhoneInputFormatter(),
          LengthLimitingTextInputFormatter(kPhoneMaxFormattedLength),
        ],
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, required this.onTap});
  final TransferContactSnapshot contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = (contact.name ?? '').trim();
    final phone = contact.phone;
    final info = (contact.info ?? '').trim();
    final cur = (contact.currency ?? '').trim();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Text(
                name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name.isEmpty ? phone : name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    [
                      if (name.isNotEmpty) phone,
                      if (info.isNotEmpty) info,
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (cur.isNotEmpty) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  '${CurrencyUtils.flag(cur)} $cur',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
