import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/data/datasources/remote/system_settings_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/user_session_remote_ds.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/settings/bloc/theme_cubit.dart';
import 'package:ethnocount/presentation/common/animations/fade_slide.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            children: [
              Text(
                'Настройки',
                style: context.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),

              // Profile
              BlocBuilder<AuthBloc, AuthState>(
                builder: (context, state) {
                  final user = state.user;
                  if (user == null) return const SizedBox.shrink();

                  return FadeSlideTransition(
                    child: _SettingsCard(
                      children: [
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                            child: Text(
                              user.displayName.isNotEmpty
                                  ? user.displayName[0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          title: Text(user.displayName),
                          subtitle: Text('${user.email} • ${user.role.displayName}'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.md),

              // Appearance
              FadeSlideTransition(
                delay: const Duration(milliseconds: 50),
                child: _SettingsCard(
                  title: 'Внешний вид',
                  children: [
                    BlocBuilder<ThemeCubit, ThemeMode>(
                      builder: (context, themeMode) {
                        return RadioGroup<ThemeMode>(
                          groupValue: themeMode,
                          onChanged: (v) =>
                              context.read<ThemeCubit>().setThemeMode(v!),
                          child: Column(
                            children: const [
                              RadioListTile<ThemeMode>(
                                title: Text('Системная тема'),
                                subtitle:
                                    Text('Следовать настройкам ОС'),
                                value: ThemeMode.system,
                                dense: true,
                              ),
                              RadioListTile<ThemeMode>(
                                title: Text('Светлая тема'),
                                value: ThemeMode.light,
                                dense: true,
                              ),
                              RadioListTile<ThemeMode>(
                                title: Text('Тёмная тема'),
                                value: ThemeMode.dark,
                                dense: true,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // Session duration (Creator only)
              BlocBuilder<AuthBloc, AuthState>(
                buildWhen: (a, b) => a.user?.role != b.user?.role,
                builder: (context, state) {
                  final isCreator = state.user?.role.isCreator ?? false;
                  if (!isCreator) return const SizedBox.shrink();

                  return FadeSlideTransition(
                    delay: const Duration(milliseconds: 75),
                    child: _SettingsCard(
                      title: 'Безопасность',
                      children: [
                        StreamBuilder<int>(
                          stream: sl<SystemSettingsRemoteDataSource>()
                              .watchSessionDurationDays(),
                          builder: (context, snap) {
                            final days = snap.data ?? 7;
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  const Text('Длительность сессии'),
                                  const SizedBox(width: 16),
                                  DropdownButton<int>(
                                    value: days.clamp(1, 365),
                                    items: const [
                                      DropdownMenuItem(value: 1, child: Text('1 день')),
                                      DropdownMenuItem(value: 7, child: Text('7 дней')),
                                      DropdownMenuItem(value: 14, child: Text('14 дней')),
                                      DropdownMenuItem(value: 30, child: Text('30 дней')),
                                      DropdownMenuItem(value: 90, child: Text('90 дней')),
                                    ],
                                    onChanged: (v) {
                                      if (v != null) {
                                        sl<SystemSettingsRemoteDataSource>()
                                            .setSessionDurationDays(v);
                                      }
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.md),

              // Devices
              BlocBuilder<AuthBloc, AuthState>(
                buildWhen: (a, b) => a.user?.id != b.user?.id,
                builder: (context, state) {
                  final user = state.user;
                  if (user == null) return const SizedBox.shrink();

                  return FadeSlideTransition(
                    delay: const Duration(milliseconds: 100),
                    child: _SettingsCard(
                      title: 'Устройства',
                      subtitle: 'Сессии входа в аккаунт',
                      children: [
                        FutureBuilder<String>(
                          future: sl<UserSessionRemoteDataSource>().getOurSessionId(),
                          builder: (ctx, ourIdSnap) {
                            final ourSessionId = ourIdSnap.data;
                            return StreamBuilder<List<UserSessionRecord>>(
                              stream: sl<UserSessionRemoteDataSource>()
                                  .watchSessions(user.id),
                              builder: (context, snap) {
                                final sessions = snap.data ?? [];
                                if (sessions.isEmpty) {
                                  return const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Text(
                                      'Нет записей о сессиях',
                                      style: TextStyle(
                                        color: AppColors.lightTextSecondary,
                                      ),
                                    ),
                                  );
                                }
                                return Column(
                                  children: sessions
                                      .map((s) => _DeviceTile(
                                            session: s,
                                            userId: user.id,
                                            isCurrentDevice: s.id == ourSessionId,
                                          ))
                                      .toList(),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.md),

              // Keyboard shortcuts
              FadeSlideTransition(
                delay: const Duration(milliseconds: 150),
                child: _SettingsCard(
                  title: 'Горячие клавиши',
                  children: [
                    _ShortcutRow(shortcut: 'Ctrl + 1', description: 'Обзор'),
                    _ShortcutRow(shortcut: 'Ctrl + 2', description: 'Переводы'),
                    _ShortcutRow(shortcut: 'Ctrl + 3', description: 'Журнал'),
                    _ShortcutRow(shortcut: 'Ctrl + 4', description: 'Аналитика'),
                    _ShortcutRow(shortcut: 'Ctrl + 5', description: 'Курсы валют'),
                    _ShortcutRow(shortcut: 'Ctrl + 6', description: 'Отчёты'),
                    _ShortcutRow(shortcut: 'Ctrl + 7', description: 'Уведомления'),
                    _ShortcutRow(shortcut: 'Ctrl + 8', description: 'Настройки'),
                    _ShortcutRow(shortcut: 'Ctrl + F', description: 'Поиск/Фильтр в таблице'),
                    _ShortcutRow(shortcut: 'Ctrl + E', description: 'Экспорт в Excel'),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // About
              FadeSlideTransition(
                delay: const Duration(milliseconds: 200),
                child: _SettingsCard(
                  title: 'О системе',
                  children: [
                    ListTile(
                      title: const Text('EthnoCount'),
                      subtitle: const Text('Казначейская система Ethno Logistics\nВерсия 1.0.0'),
                      isThreeLine: true,
                      dense: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),

              // Sign Out
              FadeSlideTransition(
                delay: const Duration(milliseconds: 250),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Выйти из всех устройств'),
                            content: const Text(
                              'Все сессии будут завершены. Вам потребуется войти заново на каждом устройстве.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Отмена'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Выйти везде'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true && context.mounted) {
                          context.read<AuthBloc>().add(const AuthSignOutAllDevicesRequested());
                        }
                      },
                      icon: const Icon(Icons.devices_other_rounded, size: 18),
                      label: const Text('Выйти из всех устройств'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: BorderSide(color: AppColors.error.withValues(alpha: 0.3)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        context.read<AuthBloc>().add(const AuthSignOutRequested());
                      },
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('Выйти из системы'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: BorderSide(color: AppColors.error.withValues(alpha: 0.3)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({this.title, this.subtitle, required this.children});

  final String? title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 11,
                        color: (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)
                            .withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}

class _DeviceTile extends StatefulWidget {
  const _DeviceTile({
    required this.session,
    required this.userId,
    this.isCurrentDevice = false,
  });

  final UserSessionRecord session;
  final String userId;
  final bool isCurrentDevice;

  @override
  State<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<_DeviceTile> {
  bool _revoking = false;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final fmt = DateFormat('dd.MM.yyyy HH:mm');
    final session = widget.session;
    return ListTile(
      leading: Icon(
        session.deviceType == 'Desktop'
            ? Icons.desktop_windows_outlined
            : session.deviceType == 'Mobile'
                ? Icons.smartphone_outlined
                : Icons.language,
        color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
      ),
      title: Text(
        '${session.platform} • ${session.deviceType}',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
        ),
      ),
      subtitle: Text(
        [
          if (widget.isCurrentDevice) 'Текущее устройство',
          if (session.ip != null) 'IP: ${session.ip}',
          'Вход: ${fmt.format(session.lastSeen)}',
        ].where((x) => x.isNotEmpty).join(' • '),
        style: TextStyle(
          fontSize: 12,
          color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
        ),
      ),
      trailing: widget.isCurrentDevice
          ? null
          : IconButton(
        icon: _revoking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                Icons.logout_rounded,
                size: 18,
                color: AppColors.error.withValues(alpha: 0.8),
              ),
        tooltip: 'Завершить сессию',
        onPressed: _revoking
            ? null
            : () async {
                setState(() => _revoking = true);
                try {
                  await sl<UserSessionRemoteDataSource>()
                      .deleteSession(widget.userId, session.id);
                } finally {
                  if (mounted) setState(() => _revoking = false);
                }
              },
            ),
      dense: true,
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.shortcut, required this.description});

  final String shortcut;
  final String description;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightBg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                width: 0.5,
              ),
            ),
            child: Text(
              shortcut,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFamily: 'JetBrains Mono',
                color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            description,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
