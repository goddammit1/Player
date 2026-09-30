// lib/ui/pages/soulseek_settings_page.dart
//
// Фаза 4 — экран настроек Soulseek.
//
// Следует паттернам appearance_page.dart / cache_page.dart:
//  - AppBar с круглой кнопкой «Назад» и заголовком 32px
//  - Секции через _Section (uppercase заголовок)
//  - Карточки через Container с colors.elevated + outline
//  - Анимация появления через _AppearingPageAnimator
//
// Только для Android: на других платформах показывается заглушка.
// Пароль хранится в secure storage (SoulseekCredentials) и НЕ показывается
// в plain text по умолчанию.
//
// Фаза A (SQLite-миграция): все настройки читаются/пишутся через
// SoulseekSettingsRepository (таблица `settings` в player_data.db).
// SharedPreferences больше не используется для настроек Soulseek.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/secure_storage_diagnostics.dart';
import '../../core/soulseek_credentials.dart';
import '../../core/soulseek_settings_repository.dart';
import '../../sources/soulseek_models.dart';
import '../../sources/soulseek_platform_channel.dart';
import '../../sources/soulseek_source.dart';
import '../../sources/source_registry.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/snack.dart';
import '../widgets/soulseek_cache_sheet.dart';
import '../widgets/soulseek_transfer_sheet.dart';

/// Репозиторий настроек Soulseek (SQLite). Дефолты и ключи — там же
/// (раньше здесь был класс SoulseekPrefs с SharedPreferences-ключами).
final SoulseekSettingsRepository _repo = SoulseekSettingsRepository.instance;

class SoulseekSettingsPage extends ConsumerStatefulWidget {
  const SoulseekSettingsPage({super.key});

  @override
  ConsumerState<SoulseekSettingsPage> createState() =>
      _SoulseekSettingsPageState();
}

class _SoulseekSettingsPageState extends ConsumerState<SoulseekSettingsPage> {
  // ── Флаг включения ──
  bool _enabled = false;

  // ── Учётные данные ──
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  // ── Параметры (дефолты — из SoulseekSettingsRepository) ──
  int _listenPort = SoulseekSettingsRepository.defaultListenPort;
  int _cacheLimitMB = SoulseekSettingsRepository.defaultCacheLimitMB;
  int _maxParallelDownloads =
      SoulseekSettingsRepository.defaultMaxParallelDownloads;
  bool _preferLossless = SoulseekSettingsRepository.defaultPreferLossless;
  Set<String> _allowedFormats = const {};
  int _maxFileSizeMB = SoulseekSettingsRepository.defaultMaxFileSizeMB;
  int _searchTimeoutSec = SoulseekSettingsRepository.defaultSearchTimeoutSec;
  String _sharingDirectory = '';

  // ── Состояние подключения ──
  SoulseekConnectionState _connectionState =
      SoulseekConnectionState.disconnected;
  String? _connectionMessage;
  StreamSubscription<SoulseekConnectionEvent>? _connectionSub;
  bool _connecting = false;

  // Дефект №5: поколение статуса соединения. Инкрементируется перед каждой
  // командой (connect/disconnect) и каждым push-событием; ответ команды
  // применяется только если поколение не изменилось — поздний устаревший
  // ответ не может перезаписать более свежее событие.
  int _connectionGeneration = 0;

  // Команда connect (включая retry-цикл) ещё выполняется. Пока она в полёте,
  // push-событие DISCONNECTED не терминально: при первом bind'е натив шлёт
  // snapshot DISCONNECTED (клиента ещё нет), а между retry-попытками bridge
  // пересоздаёт клиент. Итог определяет ответ команды.
  bool _connectInFlight = false;

  // ── Доступные форматы для multi-select ──
  static const List<String> _allFormats = [
    'flac', 'wav', 'alac', 'mp3', 'aac', 'ogg',
  ];

  // ── Опции лимита кэша ──
  static const List<int> _cacheLimitOptions = [500, 1024, 2048, 5120, 0];
  static const List<String> _cacheLimitLabels = [
    '500 MB', '1 GB', '2 GB', '5 GB', 'Unlimited',
  ];

  bool get _isAvailable => SoulseekPlatformChannel.instance.isAvailable;

  @override
  void initState() {
    super.initState();
    _enabled = SourceRegistry.isSoulseekEnabled;
    _loadSettings();
    _subscribeConnection();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _connectionSub?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    // Учётные данные: пароль из secure storage, username — быстрый путь
    // из БД (soulseek_username).
    final creds = await SoulseekCredentials.load();
    final usernameQuick = await SoulseekCredentials.loadUsernameQuick();

    // Настройки — из SQLite через репозиторий.
    final settings = await _repo.loadAll();

    if (mounted) {
      setState(() {
        // username: из secure storage (с паролем) или из БД (быстрый путь).
        _usernameController.text = creds?.username ?? usernameQuick ?? '';
        _passwordController.text = creds?.password ?? '';

        _enabled = settings.enabled;
        _listenPort = settings.listenPort;
        _cacheLimitMB = settings.cacheLimitMB;
        _maxParallelDownloads = settings.maxParallelDownloads;
        _preferLossless = settings.preferLossless;
        _allowedFormats = settings.allowedFormats;
        _maxFileSizeMB = settings.maxFileSizeMB;
        _searchTimeoutSec = settings.searchTimeoutSec;
        _sharingDirectory = settings.sharingDirectory;
      });
    }

    _applyFiltersToSource(settings: settings);
  }

  /// Применяет настройки фильтров к зарегистрированному [SoulseekSource]
  /// через репозиторий (SQLite). Если [settings] не переданы — читаются
  /// из БД. Вызывается при загрузке страницы и после смены фильтров.
  Future<void> _applyFiltersToSource({SoulseekSettings? settings}) async {
    final source = SourceRegistry.instance.get('soulseek');
    if (source is! SoulseekSource) return;

    final s = settings ??
        SoulseekSettings(
          allowedFormats: _allowedFormats,
          maxFileSizeMB: _maxFileSizeMB,
          preferLossless: _preferLossless,
          searchTimeoutSec: _searchTimeoutSec,
        );
    await _repo.applyToSource(source, settings: s);
  }

  void _subscribeConnection() {
    if (!_isAvailable) return;
    _connectionSub?.cancel();
    _connectionSub =
        SoulseekPlatformChannel.instance.connectionEvents.listen(
      (event) {
        if (!mounted) return;
        // Snapshot при bind'е / промежуточный дисконнект между попытками
        // не должен сбрасывать «Connecting…» и разблокировать кнопку —
        // иначе первое нажатие выглядит так, будто ничего не произошло.
        if (_connectInFlight &&
            event.state == SoulseekConnectionState.disconnected) {
          return;
        }
        // Push-событие — самый свежий источник: делает устаревшими все
        // ответы команд, отправленные до него (дефект №5).
        _connectionGeneration++;
        setState(() {
          _connectionState = event.state;
          _connectionMessage = event.message;
          // Дефект №6: CONNECTED теперь означает завершённый логин
          // (Connected+LoggedIn), CONNECTING — промежуточное состояние.
          // _connecting сбрасываем только на терминальных для команды
          // состояниях: CONNECTED / DISCONNECTED / FAILED (и RECONNECTING —
          // исходная команда connect уже не «в процессе»).
          switch (event.state) {
            case SoulseekConnectionState.connected:
            case SoulseekConnectionState.disconnected:
            case SoulseekConnectionState.failed:
            case SoulseekConnectionState.reconnecting:
              _connecting = false;
            case SoulseekConnectionState.connecting:
              break;
          }
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        _connectionGeneration++;
        setState(() {
          _connectionState = SoulseekConnectionState.failed;
          _connectionMessage = e.toString();
          _connecting = false;
        });
      },
    );

    // P2: connectionEvents приходят только при ИЗМЕНЕНИЯХ. При повторном
    // входе на страницу живое соединение иначе отображалось бы устаревшим
    // Disconnected — перезапрашиваем актуальный статус у натива.
    // Дефект №3: с bind'ом snapshot теперь приходит и через event channel.
    _queryConnectionState();
  }

  Future<void> _queryConnectionState() async {
    try {
      final state = await SoulseekPlatformChannel.instance
          .getConnectionState();
      if (!mounted) return;
      // Дефект №3: null = native не знает состояния (binder не привязан,
      // сервис может работать) — не перезаписываем локальный статус.
      if (state == null) return;
      // Не затираем прогресс текущего подключения и не конкурируем со
      // свежими push-событиями (дефект №5).
      if (_connecting) return;
      setState(() => _connectionState = state);
    } catch (_) {
      // Сервис не запущен / платформа недоступна — остаёмся на default.
    }
  }

  // ── Действия ──

  Future<void> _toggleEnabled(bool value) async {
    setState(() => _enabled = value);
    await SourceRegistry.setSoulseekEnabled(value);
    if (mounted) {
      showSnack(
        context,
        value ? 'Soulseek enabled' : 'Soulseek disabled',
      );
    }
  }

  Future<void> _saveCredentials() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      if (mounted) {
        showSnack(context, 'Enter username and password');
      }
      return;
    }

    try {
      await SoulseekCredentials.save(
        username: username,
        password: password,
      );
      // Фаза B: проталкиваем username в нативную soulseek.db (вместе с
      // остальными натив-релевантными настройками) — раньше Dart никогда
      // не вызывал configureAccount, и натив жил на сид-дефолтах.
      await _repo.syncToNative(username: username);
      if (mounted) showSnack(context, 'Credentials saved');
    } catch (_) {
      if (mounted) {
        showSnack(context, 'Failed to save credentials (secure storage)');
      }
    }
  }

  Future<void> _connect() async {
    if (!_isAvailable) return;

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      if (mounted) showSnack(context, 'Enter username and password');
      return;
    }

    // Дефект №5: фиксируем поколение — результат команды применяем, только
    // если после её старта не приходило более свежих push-событий.
    final generation = ++_connectionGeneration;

    _connectInFlight = true;
    setState(() {
      _connecting = true;
      _connectionState = SoulseekConnectionState.connecting;
      _connectionMessage = null;
    });

    // P3: первый коннект после старта сервиса иногда падает по
    // SocketException (DNS proxy errno=111) — C# bridge классифицирует
    // его как retryable. Пробуем подключиться до 3 раз с паузой 2 с,
    // ретраим только retryable-ошибки.
    const maxAttempts = 3;
    const retryDelay = Duration(seconds: 2);

    SoulseekConnectionInfo? info;
    SoulseekException? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        info = await _connectOnce(username, password);
        break;
      } on SoulseekException catch (e) {
        lastError = e;
        // P3: «Service not bound» / таймаут bind'а — гонка старта сервиса,
        // не ошибка кредов. Классифицируем как retryable, чтобы существующий
        // retry-цикл 3×2с подхватил даже если нативный флаг не дошёл.
        final effectiveRetryable = e.retryable || e.isServiceBindRace;
        final canRetry = effectiveRetryable && attempt < maxAttempts;
        if (kDebugMode) {
          debugPrint(
            '[Soulseek] connect attempt $attempt/$maxAttempts failed: '
            '${e.code} (retryable: $effectiveRetryable)',
          );
        }
        if (!canRetry) break;
        if (mounted) {
          setState(() => _connectionMessage = 'Retrying ($attempt/$maxAttempts)…');
        }
        await Future<void>.delayed(retryDelay);
      } catch (e) {
        // Непредвиденная ошибка (secure storage и т.п.) — не ретраим.
        lastError = SoulseekException('CONNECT_FAILED', e.toString());
        break;
      }
    }

    _connectInFlight = false;
    if (!mounted) return;

    // Дефект №5: если после старта команды пришло push-событие, его статус
    // новее — ответ команды статус не перезаписывает.
    final stale = generation != _connectionGeneration;

    // Команда завершилась — кнопка разблокируется в любом случае (иначе
    // при stale-ответе и последнем событии CONNECTING она залипала бы).
    if (info != null) {
      final connected = info;
      setState(() {
        // Промежуточный CONNECTING от push-события успешный ответ уточняет.
        if (!stale ||
            _connectionState == SoulseekConnectionState.connecting) {
          _connectionState = connected.state;
          _connectionMessage = null;
        }
        _connecting = false;
      });
    } else {
      final e = lastError ?? const SoulseekException('CONNECT_FAILED', 'Connect failed');
      setState(() {
        // DISCONNECTED-события во время команды игнорировались, поэтому
        // провал показываем сами — если только более свежее событие не
        // сообщило о реальном соединении (дефект №5).
        if (_connectionState != SoulseekConnectionState.connected) {
          _connectionState = SoulseekConnectionState.failed;
          _connectionMessage = e.message;
        }
        _connecting = false;
      });
      showSnack(context, 'Connection failed: ${e.message}');
    }
  }

  /// Одна попытка подключения: сохранить учётные данные, стартовать
  /// сервис, вызвать connect. Бросает SoulseekException при неудаче.
  Future<SoulseekConnectionInfo> _connectOnce(
    String username,
    String password,
  ) async {
    await SoulseekCredentials.save(
      username: username,
      password: password,
    );

    await SoulseekPlatformChannel.instance.startService();

    return SoulseekPlatformChannel.instance.connect(
      username: username,
      password: password,
      listenPort: _listenPort,
    );
  }

  Future<void> _disconnect() async {
    if (!_isAvailable) return;
    // Дефект №5: ответ disconnect не перезаписывает более свежие события.
    final generation = ++_connectionGeneration;
    try {
      await SoulseekPlatformChannel.instance.disconnect();
      if (mounted) {
        if (generation == _connectionGeneration) {
          setState(() {
            _connectionState = SoulseekConnectionState.disconnected;
            _connectionMessage = null;
          });
        }
        showSnack(context, 'Disconnected');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Disconnect failed');
    }
  }

  Future<void> _clearCredentials() async {
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: 'Clear credentials?',
      subtitle:
          'Your Soulseek username and password will be permanently '
          'removed from this device. You will need to enter them again '
          'to reconnect.',
      confirmLabel: 'Clear',
      isDestructive: true,
    );
    if (confirmed != true) return;

    try {
      await SoulseekCredentials.clear();
      if (mounted) {
        setState(() {
          _usernameController.clear();
          _passwordController.clear();
        });
        showSnack(context, 'Credentials cleared');
      }
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to clear credentials');
    }
  }

  // ── Персист (SQLite через репозиторий) ──

  Future<void> _updateListenPort(String text) async {
    final port = int.tryParse(text);
    if (port == null || port < 1 || port > 65535) return;
    _listenPort = port;
    await _repo.setListenPort(port);
  }

  Future<void> _updateCacheLimit(int mb) async {
    setState(() => _cacheLimitMB = mb);
    await _repo.setCacheLimitMB(mb);
  }

  Future<void> _updateMaxParallel(int value) async {
    setState(() => _maxParallelDownloads = value);
    await _repo.setMaxParallelDownloads(value);
  }

  Future<void> _togglePreferLossless(bool value) async {
    setState(() => _preferLossless = value);
    await _repo.setPreferLossless(value);
    await _applyFiltersToSource();
  }

  Future<void> _toggleFormat(String fmt, bool selected) async {
    setState(() {
      if (selected) {
        _allowedFormats = {..._allowedFormats, fmt};
      } else {
        _allowedFormats = _allowedFormats.where((f) => f != fmt).toSet();
      }
    });
    await _repo.setAllowedFormats(_allowedFormats);
    await _applyFiltersToSource();
  }

  Future<void> _updateMaxFileSize(String text) async {
    final mb = int.tryParse(text);
    if (mb == null || mb < 0) return;
    _maxFileSizeMB = mb;
    await _repo.setMaxFileSizeMB(mb);
    await _applyFiltersToSource();
  }

  Future<void> _updateSearchTimeout(String text) async {
    final sec = int.tryParse(text);
    if (sec == null || sec < 1) return;
    _searchTimeoutSec = sec;
    await _repo.setSearchTimeoutSec(sec);
    // Разрыв №3: применяем новый таймаут к SoulseekSource сразу (как у
    // фильтров в _updateMaxFileSize). Ленивая загрузка в источнике
    // одноразовая (_searchTimeoutLoaded), без этого новый таймаут
    // дожидался бы переоткрытия страницы или рестарта приложения.
    await _applyFiltersToSource();
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);

    return _AppearingPageAnimator(
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: colors.background,
            appBar: AppBar(
              backgroundColor: colors.background,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              toolbarHeight: 132,
              automaticallyImplyLeading: false,
              titleSpacing: 0,
              title: Padding(
                padding: const EdgeInsets.fromLTRB(16, 64, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (Navigator.of(context).canPop())
                      _CircleButton(
                        icon: Icons.chevron_left_rounded,
                        onTap: () => Navigator.of(context).maybePop(),
                        colors: colors,
                      ),
                    const SizedBox(height: 16),
                    Text(
                      'Soulseek',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
            body: LayoutBuilder(
              builder: (context, c) => Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isDesktop ? 760 : double.infinity,
                    maxHeight: c.maxHeight,
                  ),
                  child: !_isAvailable
                      ? _buildUnavailable(colors)
                      : _buildContent(colors),
                ),
              ),
            ),
          ),
          if (!isDesktop) const NowPlayingOverlay(),
        ],
      ),
    );
  }

  Widget _buildUnavailable(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.devices_other_rounded,
              size: 48,
              color: colors.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              'Soulseek is only available on Android',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This feature requires the native Soulseek plugin '
              'which runs only on Android devices.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(dynamic colors) {
    return ListView(
      padding: EdgeInsets.only(
        top: 0,
        bottom: 8 +
            NowPlayingOverlay.miniHeight +
            MediaQuery.of(context).padding.bottom,
      ),
      children: [
        // === P2P WARNING ===
        _buildP2PWarning(colors),
        const SizedBox(height: 8),

        // === ENABLE TOGGLE ===
        _Section(
          title: 'Source',
          colors: colors,
          children: [
            SwitchListTile(
              secondary: Icon(
                Icons.hub_rounded,
                color: colors.textPrimary,
              ),
              title: Text(
                'Enable Soulseek',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                'Include Soulseek results in search',
                style: TextStyle(color: colors.textSecondary, fontSize: 13),
              ),
              value: _enabled,
              onChanged: _toggleEnabled,
              activeThumbColor: colors.accent,
              activeTrackColor: colors.accent.withValues(alpha: 0.3),
              inactiveThumbColor: colors.textSecondary,
              inactiveTrackColor: colors.elevated,
            ),
          ],
        ),
        const SizedBox(height: 8),

        // === ACCOUNT ===
        _Section(
          title: 'Account',
          colors: colors,
          children: [
            _buildAccountSection(colors),
          ],
        ),
        const SizedBox(height: 8),

        // === CONNECTION STATUS ===
        _Section(
          title: 'Connection',
          colors: colors,
          children: [
            _buildConnectionSection(colors),
          ],
        ),
        const SizedBox(height: 8),

        // === SEARCH FILTERS ===
        _Section(
          title: 'Search filters',
          colors: colors,
          children: [
            _buildSearchFiltersSection(colors),
          ],
        ),
        const SizedBox(height: 8),

        // === CACHE ===
        _Section(
          title: 'Cache',
          colors: colors,
          children: [
            _buildCacheSection(colors),
          ],
        ),
        const SizedBox(height: 8),

        // === SHARING ===
        _Section(
          title: 'Sharing',
          colors: colors,
          children: [
            _buildSharingSection(colors),
          ],
        ),
        const SizedBox(height: 8),

        // === TROUBLESHOOTING ===
        _Section(
          title: 'Troubleshooting',
          colors: colors,
          children: [
            _buildTroubleshootingSection(colors),
          ],
        ),
        const SizedBox(height: 8),

        // === DANGER ZONE ===
        _Section(
          title: 'Danger zone',
          colors: colors,
          children: [
            _buildDangerZone(colors),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ── P2P WARNING ──

  Widget _buildP2PWarning(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.orangeAccent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.orangeAccent.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.orangeAccent,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Soulseek is a peer-to-peer (P2P) network. '
                'When you download music, you connect directly to '
                'other users\' computers. Your shared folder is '
                'visible to others.',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── ACCOUNT SECTION ──

  Widget _buildAccountSection(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Username
          Text(
            'Username',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          _TextField(
            controller: _usernameController,
            colors: colors,
            hint: 'Your Soulseek username',
            icon: Icons.person_outline_rounded,
          ),
          const SizedBox(height: 16),

          // Password
          Text(
            'Password',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          _TextField(
            controller: _passwordController,
            colors: colors,
            hint: 'Your Soulseek password',
            icon: Icons.lock_outline_rounded,
            obscure: _obscurePassword,
            suffix: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: colors.textSecondary,
                size: 20,
              ),
              onPressed: () {
                setState(() => _obscurePassword = !_obscurePassword);
              },
            ),
          ),
          const SizedBox(height: 16),

          // Save button
          SizedBox(
            width: double.infinity,
            child: _ActionButton(
              label: 'Save credentials',
              icon: Icons.save_outlined,
              colors: colors,
              onTap: _saveCredentials,
            ),
          ),
        ],
      ),
    );
  }

  // ── CONNECTION SECTION ──

  Widget _buildConnectionSection(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status row
          Row(
            children: [
              _ConnectionStatusDot(
                state: _connectionState,
                colors: colors,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _connectionStateLabel,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_connectionMessage != null &&
                        _connectionMessage!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        _connectionMessage!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Listen port
          Text(
            'Listener port',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          _NumericField(
            initialValue: _listenPort,
            colors: colors,
            hint: '24150',
            icon: Icons.router_rounded,
            onChanged: _updateListenPort,
          ),
          const SizedBox(height: 16),

          // Connect / Disconnect buttons
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: _connecting ? 'Connecting…' : 'Connect',
                  icon: Icons.power_settings_new_rounded,
                  colors: colors,
                  onTap: _connecting ? null : _connect,
                  primary: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'Disconnect',
                  icon: Icons.power_off_rounded,
                  colors: colors,
                  onTap: _disconnect,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String get _connectionStateLabel {
    switch (_connectionState) {
      case SoulseekConnectionState.disconnected:
        return 'Disconnected';
      case SoulseekConnectionState.connecting:
        return 'Connecting…';
      case SoulseekConnectionState.connected:
        return 'Connected';
      case SoulseekConnectionState.reconnecting:
        return 'Reconnecting…';
      case SoulseekConnectionState.failed:
        return 'Connection failed';
    }
  }

  // ── SEARCH FILTERS SECTION ──

  Widget _buildSearchFiltersSection(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Prefer lossless
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Prefer lossless',
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              'Only show FLAC, WAV, ALAC, APE, WV',
              style: TextStyle(color: colors.textSecondary, fontSize: 13),
            ),
            value: _preferLossless,
            onChanged: _togglePreferLossless,
            activeThumbColor: colors.accent,
            activeTrackColor: colors.accent.withValues(alpha: 0.3),
            inactiveThumbColor: colors.textSecondary,
            inactiveTrackColor: colors.elevated,
          ),
          const SizedBox(height: 8),

          // Allowed formats
          Text(
            'Allowed formats',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _allFormats.map((fmt) {
              final selected = _allowedFormats.contains(fmt);
              return _FormatChip(
                label: fmt.toUpperCase(),
                selected: selected,
                colors: colors,
                onTap: () => _toggleFormat(fmt, !selected),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // Max file size
          Text(
            'Max file size (MB, 0 = unlimited)',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          _NumericField(
            initialValue: _maxFileSizeMB,
            colors: colors,
            hint: '0',
            icon: Icons.compress_rounded,
            onChanged: _updateMaxFileSize,
          ),
          const SizedBox(height: 16),

          // Search timeout
          Text(
            'Search timeout (seconds)',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          _NumericField(
            initialValue: _searchTimeoutSec,
            colors: colors,
            hint: '${SoulseekSettingsRepository.defaultSearchTimeoutSec}',
            icon: Icons.timer_outlined,
            onChanged: _updateSearchTimeout,
          ),
        ],
      ),
    );
  }

  // ── CACHE SECTION ──

  Widget _buildCacheSection(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cache size limit',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(_cacheLimitOptions.length, (i) {
              final mb = _cacheLimitOptions[i];
              final label = _cacheLimitLabels[i];
              final isSelected = _cacheLimitMB == mb;
              return _LimitChip(
                label: label,
                isSelected: isSelected,
                colors: colors,
                onTap: () => _updateCacheLimit(mb),
              );
            }),
          ),
          const SizedBox(height: 16),

          // Max parallel downloads
          Text(
            'Max parallel downloads',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$_maxParallelDownloads',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          Slider(
            value: _maxParallelDownloads.toDouble(),
            min: 2,
            max: 5,
            divisions: 3,
            activeColor: colors.accent,
            inactiveColor: colors.elevated,
            onChanged: (v) => _updateMaxParallel(v.round()),
          ),
          const SizedBox(height: 16),

          // Quick access: active downloads
          SizedBox(
            width: double.infinity,
            child: _ActionButton(
              label: 'Active downloads',
              icon: Icons.download_rounded,
              colors: colors,
              onTap: () => showSoulseekTransferSheet(context),
            ),
          ),
          const SizedBox(height: 10),

          // Quick access: cached files
          SizedBox(
            width: double.infinity,
            child: _ActionButton(
              label: 'Cached files',
              icon: Icons.storage_rounded,
              colors: colors,
              onTap: () => showSoulseekCacheSheet(context),
            ),
          ),
        ],
      ),
    );
  }

  // ── SHARING SECTION ──

  Widget _buildSharingSection(dynamic colors) {
    final displayPath = _sharingDirectory.isNotEmpty
        ? _sharingDirectory
        : 'Internal storage (default)';

    return ListTile(
      leading: Icon(Icons.folder_shared_outlined, color: colors.textPrimary),
      title: Text(
        'Shared directory',
        style: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        displayPath,
        style: TextStyle(color: colors.textSecondary, fontSize: 13),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(
        Icons.info_outline_rounded,
        color: colors.textTertiary,
        size: 20,
      ),
      onTap: () {
        if (mounted) {
          showAppInfoDialog(
            context: context,
            title: 'Shared directory',
            subtitle: 'Soulseek shares files from the internal storage '
                'directory of the app. On Android, this is the app\'s '
                'private storage area. Downloaded files are cached here '
                'and available for sharing with other Soulseek users.',
          );
        }
      },
    );
  }

  // ── TROUBLESHOOTING ──

  Widget _buildTroubleshootingSection(dynamic colors) {
    return ListTile(
      leading: Icon(Icons.bug_report_outlined, color: colors.textPrimary),
      title: Text(
        'Secure storage diagnostics',
        style: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        'Report for the developer if credentials fail to save. '
        'Contains no passwords.',
        style: TextStyle(color: colors.textSecondary, fontSize: 13),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: colors.textTertiary,
        size: 20,
      ),
      onTap: () => showAppReportDialog(
        context: context,
        title: 'Diagnostics',
        subtitle: 'Send this report to the developer',
        report: SecureStorageDiagnostics.buildReport(),
        shareSubject: 'Player: secure storage diagnostics',
      ),
    );
  }

  // ── DANGER ZONE ──

  Widget _buildDangerZone(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: _ActionButton(
        label: 'Clear credentials',
        icon: Icons.no_encryption_gmailerrorred_outlined,
        colors: colors,
        onTap: _clearCredentials,
        destructive: true,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  SHARED WIDGETS
// ═══════════════════════════════════════════════════════════════════════

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    required this.colors,
  });

  final String title;
  final List<Widget> children;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              color: colors.textTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 60,
          height: 60,
          child: Icon(icon, color: colors.textPrimary, size: 28),
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.colors,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.suffix,
  });

  final TextEditingController controller;
  final dynamic colors;
  final String hint;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: TextStyle(color: colors.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: colors.textTertiary, fontSize: 15),
        filled: true,
        fillColor: colors.elevated,
        prefixIcon: Icon(icon, color: colors.textSecondary, size: 20),
        suffixIcon: suffix,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.outline, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.outline, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.accent.withValues(alpha: 0.5), width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}

class _NumericField extends StatefulWidget {
  const _NumericField({
    required this.initialValue,
    required this.colors,
    required this.hint,
    required this.icon,
    required this.onChanged,
  });

  final int initialValue;
  final dynamic colors;
  final String hint;
  final IconData icon;

  /// Вызывается, когда значение поля считается подтверждённым: по Enter
  /// (onSubmitted), по потере фокуса или по debounce ~500 мс после
  /// последнего изменения (Фаза A: сохранение не только onSubmitted).
  final ValueChanged<String> onChanged;

  @override
  State<_NumericField> createState() => _NumericFieldState();
}

class _NumericFieldState extends State<_NumericField> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  /// Debounce-таймер: сохраняем не чаще, чем раз в 500 мс после
  /// последнего нажатия клавиши.
  Timer? _debounce;
  static const _debounceDelay = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue.toString());
    _focusNode.addListener(_onFocusChanged);
  }

  /// Баг «таймаут всегда 15»: начальное значение поля ставится в
  /// initState из дефолта (15), а настройки из БД догружаются
  /// асинхронно уже после первого кадра (setState родителя). Без этого
  /// хука контроллер навсегда оставался со значением первого кадра —
  /// сохранённое в БД значение никогда не показывалось в поле.
  @override
  void didUpdateWidget(covariant _NumericField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue == oldWidget.initialValue) return;
    // Не перетираем ввод, пока пользователь редактирует поле.
    if (_focusNode.hasFocus) return;
    // Контроллер уже отражает новое значение — не трогаем (иначе
    // сбросится выделение/курсор).
    if (int.tryParse(_controller.text) == widget.initialValue) return;
    _controller.text = widget.initialValue.toString();
  }

  @override
  void dispose() {
    // Баг «debounce теряется при закрытии»: если страница закрылась
    // раньше 500-мс таймера, правка раньше просто отменялась. Коммитим
    // незасейвленное значение ДО отмены таймера — колбэк родителя
    // (напр. _updateSearchTimeout) не зовёт setState, поэтому вызов из
    // dispose безопасен (дети демонтируются раньше родителя).
    if (_debounce != null) {
      _debounce!.cancel();
      _debounce = null;
      widget.onChanged(_controller.text);
    }
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    // Focus lost → немедленно коммитим незасейвленное значение
    // (отменяя отложенный debounce-запуск).
    if (!_focusNode.hasFocus) {
      _commitNow();
    }
  }

  /// Немедленно вызывает [widget.onChanged], отменяя отложенный запуск.
  void _commitNow() {
    _debounce?.cancel();
    _debounce = null;
    widget.onChanged(_controller.text);
  }

  void _onTextChanged() {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, _commitNow);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: TextInputType.number,
      style: TextStyle(color: widget.colors.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: TextStyle(color: widget.colors.textTertiary, fontSize: 15),
        filled: true,
        fillColor: widget.colors.elevated,
        prefixIcon: Icon(widget.icon, color: widget.colors.textSecondary, size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: widget.colors.outline, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: widget.colors.outline, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: widget.colors.accent.withValues(alpha: 0.5), width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      onChanged: (_) => _onTextChanged(),
      onSubmitted: (_) => _commitNow(),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.colors,
    required this.onTap,
    this.primary = false,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final dynamic colors;
  final VoidCallback? onTap;
  final bool primary;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final bgColor = destructive
        ? Colors.redAccent.withValues(alpha: 0.08)
        : primary
            ? colors.elevatedHi
            : colors.elevated;
    final fgColor = destructive
        ? Colors.redAccent
        : primary
            ? Colors.white
            : colors.textPrimary;
    final borderColor = destructive
        ? Colors.redAccent.withValues(alpha: 0.2)
        : colors.outline;

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fgColor, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: fgColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FormatChip extends StatelessWidget {
  const _FormatChip({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final dynamic colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? colors.accent.withValues(alpha: 0.15)
          : colors.elevated,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? colors.accent.withValues(alpha: 0.4)
                  : colors.outline,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.accent : colors.textSecondary,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _LimitChip extends StatelessWidget {
  const _LimitChip({
    required this.label,
    required this.isSelected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final dynamic colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected
          ? colors.accent.withValues(alpha: 0.15)
          : colors.elevated,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? colors.accent.withValues(alpha: 0.4)
                  : colors.outline,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? colors.accent : colors.textSecondary,
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionStatusDot extends StatelessWidget {
  const _ConnectionStatusDot({
    required this.state,
    required this.colors,
  });

  final SoulseekConnectionState state;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final (color, pulsing) = switch (state) {
      SoulseekConnectionState.connected => (Colors.greenAccent, false),
      SoulseekConnectionState.connecting => (Colors.orangeAccent, true),
      SoulseekConnectionState.reconnecting => (Colors.orangeAccent, true),
      SoulseekConnectionState.failed => (Colors.redAccent, false),
      SoulseekConnectionState.disconnected => (colors.textTertiary, false),
    };

    if (pulsing) {
      return _PulsingDot(color: color);
    }
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Opacity(
          opacity: 0.4 + (_controller.value * 0.6),
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  SHARED ANIMATOR
// ═══════════════════════════════════════════════════════════════════════

class _AppearingPageAnimator extends StatefulWidget {
  const _AppearingPageAnimator({required this.child});
  final Widget child;

  @override
  State<_AppearingPageAnimator> createState() => _AppearingPageAnimatorState();
}

class _AppearingPageAnimatorState extends State<_AppearingPageAnimator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween<double>(begin: 10, end: 0)
        .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _fade = Tween<double>(begin: 0.7, end: 1)
        .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _anim.forward();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Transform.translate(
        offset: Offset(0, _slide.value),
        child: Opacity(opacity: _fade.value, child: widget.child),
      ),
    );
  }
}
