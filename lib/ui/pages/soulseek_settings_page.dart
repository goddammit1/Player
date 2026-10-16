// lib/ui/pages/soulseek_settings_page.dart
//
// Фаза 4 — экран настроек Soulseek.
//
// Компоновка (редизайн по plans/soulseek_pages_redesign_plan.md):
//  - AppBar с круглой кнопкой «Назад» и заголовком 32px
//  - Сверху карточка статуса: состояние + одна кнопка Connect / Cancel /
//    Disconnect и переключатель «Show in search»
//  - Группы Account (скрыта после входа), Search, Downloads и свёрнутый
//    Advanced; плитки групп скруглены как список треков (GroupedTiles)
//  - Только цвета AppColors; красный — лишь сбой и удаление
//  - Анимация появления через _AppearingPageAnimator
//
// Android и Windows (мост внутри процесса); на других платформах и в
// Windows-сборке без моста показывается заглушка.
// Пароль хранится в secure storage (SoulseekCredentials) и НЕ показывается
// в plain text по умолчанию.
//
// Фаза A (SQLite-миграция): все настройки читаются/пишутся через
// SoulseekSettingsRepository (таблица `settings` в player_data.db).
// SharedPreferences больше не используется для настроек Soulseek.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../widgets/grouped_tiles.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/snack.dart';
import '../widgets/soulseek_transfer_sheet.dart';
import 'cached_tracks_page.dart';

/// Репозиторий настроек Soulseek (SQLite). Дефолты и ключи — там же
/// (раньше здесь был класс SoulseekPrefs с SharedPreferences-ключами).
final SoulseekSettingsRepository _repo = SoulseekSettingsRepository.instance;

/// Раздел страницы, к которому прокрутить при открытии.
enum SoulseekSettingsSection { connection }

class SoulseekSettingsPage extends ConsumerStatefulWidget {
  const SoulseekSettingsPage({super.key, this.initialSection});

  /// Раздел, к которому страница прокручивается после первого кадра
  /// (тап по недоступному фильтру Soulseek в поиске → Connection).
  final SoulseekSettingsSection? initialSection;

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
  int _maxParallelDownloads =
      SoulseekSettingsRepository.defaultMaxParallelDownloads;
  bool _preferLossless = SoulseekSettingsRepository.defaultPreferLossless;
  Set<String> _allowedFormats = const {};
  int _maxFileSizeMB = SoulseekSettingsRepository.defaultMaxFileSizeMB;
  int _searchTimeoutSec = SoulseekSettingsRepository.defaultSearchTimeoutSec;
  String _sharingDirectory = '';
  bool _streamingEnabled = SoulseekSettingsRepository.defaultStreamingEnabled;

  // ── Состояние подключения ──
  SoulseekConnectionState _connectionState =
      SoulseekConnectionState.disconnected;
  String? _connectionMessage;
  ProviderSubscription<AsyncValue<SoulseekConnectionEvent?>>? _connectionSub;
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

  // Номер текущей команды connect. Cancel увеличивает его — retry-цикл
  // прежней команды видит, что устарел, прерывается и итог не применяет.
  // Счётчик, а не флаг: Cancel → Connect подряд не «воскрешает» отменённую
  // команду (новая получает свой номер).
  int _connectCommand = 0;

  // Отменённые команды, чей нативный connect ещё не вернулся. Пока они
  // доигрывают, а новой команды нет, их push-события (CONNECTING /
  // CONNECTED) не должны менять статус после Cancel.
  int _cancelledInFlight = 0;

  // ── Активные загрузки (счётчик у строки Downloads) ──
  final Set<String> _activeTransferIds = {};
  StreamSubscription<SoulseekTransferEvent>? _transferSub;

  bool _advancedOpen = false;

  // ── Доступные форматы для multi-select ──
  static const List<String> _allFormats = [
    'flac', 'wav', 'alac', 'mp3', 'aac', 'ogg',
  ];

  bool get _isAvailable => SoulseekPlatformChannel.instance.isAvailable;

  final _connectionSectionKey = GlobalKey();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _enabled = SourceRegistry.isSoulseekEnabled;
    _loadSettings();
    _subscribeConnection();
    _subscribeTransfers();
    if (widget.initialSection == SoulseekSettingsSection.connection) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToConnection());
    }
  }

  /// ListView строит секции лениво: если Connection ещё за пределами
  /// cacheExtent (маленький экран, крупный шрифт), листаем на экран вниз
  /// и пробуем снова в следующем кадре.
  void _scrollToConnection([int attempt = 0]) {
    if (!mounted) return;
    final ctx = _connectionSectionKey.currentContext;
    if (ctx == null) {
      if (attempt >= 5 || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.pixels >= pos.maxScrollExtent) return;
      _scrollController.jumpTo(
        (pos.pixels + pos.viewportDimension).clamp(0.0, pos.maxScrollExtent),
      );
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToConnection(attempt + 1));
      return;
    }
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _connectionSub?.close();
    _transferSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Счётчик активных загрузок: снимок при открытии + transfer-события
  /// (паттерн SoulseekDownloadsIndicator).
  Future<void> _subscribeTransfers() async {
    if (!_isAvailable) return;
    final platform = SoulseekPlatformChannel.instance;
    // Трансферы, о которых уже пришло событие, пока снимок в пути: снимок
    // старше события и не должен вернуть уже завершённую загрузку.
    Set<String>? seenBeforeSnapshot = {};
    _transferSub = platform.transferEvents.listen((e) {
      final info = e.transfer;
      seenBeforeSnapshot?.add(info.downloadId);
      final changed = info.state.isActive
          ? _activeTransferIds.add(info.downloadId)
          : _activeTransferIds.remove(info.downloadId);
      if (changed && mounted) setState(() {});
    }, onError: (_) {});
    try {
      final active = await platform.getActiveTransfers();
      final seen = seenBeforeSnapshot;
      if (!mounted) return;
      setState(() {
        _activeTransferIds.addAll(
          active
              .where((t) => t.state.isActive && !seen.contains(t.downloadId))
              .map((t) => t.downloadId),
        );
      });
    } catch (_) {
      // Сервис ещё не поднят — счётчик появится с первым событием.
    } finally {
      seenBeforeSnapshot = null;
    }
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
        _maxParallelDownloads = settings.maxParallelDownloads;
        _preferLossless = settings.preferLossless;
        _allowedFormats = settings.allowedFormats;
        _maxFileSizeMB = settings.maxFileSizeMB;
        _searchTimeoutSec = settings.searchTimeoutSec;
        _sharingDirectory = settings.sharingDirectory;
        _streamingEnabled = settings.streamingEnabled;
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
          streamingEnabled: _streamingEnabled,
        );
    await _repo.applyToSource(source, settings: s);
  }

  /// Статус соединения — из общего [soulseekConnectionProvider] (тот же,
  /// что у фильтра поиска). fireImmediately отдаёт последнее известное
  /// значение: провайдер живёт всё время работы приложения и не пропускает
  /// изменений, поэтому повторный вход на страницу видит актуальный статус
  /// (P2). Неизвестное состояние (UNKNOWN) провайдер не выдаёт — локальный
  /// статус не перезаписывается ложным Disconnected (дефект №3).
  void _subscribeConnection() {
    if (!_isAvailable) return;
    _connectionSub?.close();
    _connectionSub = ref.listenManual<AsyncValue<SoulseekConnectionEvent?>>(
      soulseekConnectionProvider,
      (_, next) => _onConnectionUpdate(next),
      fireImmediately: true,
    );
  }

  void _onConnectionUpdate(AsyncValue<SoulseekConnectionEvent?> next) {
    if (!mounted) return;
    if (next.hasError) {
      _connectionGeneration++;
      setState(() {
        _connectionState = SoulseekConnectionState.failed;
        _connectionMessage = next.error.toString();
        _connecting = false;
      });
      return;
    }
    final event = next.valueOrNull;
    if (event == null) return;
    // Отменённый connect ещё доигрывает в нативе, а новой команды нет —
    // его события не должны вернуть «Connecting…» / «Connected» после
    // Cancel (итог разорвёт сама отменённая команда).
    if (!_connectInFlight && _cancelledInFlight > 0) return;
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
    final command = ++_connectCommand;
    bool cancelled() => command != _connectCommand;

    _connectInFlight = true;
    setState(() {
      _connecting = true;
      _connectionState = SoulseekConnectionState.connecting;
      _connectionMessage = null;
    });

    // Сохраняем один раз, до цикла подключения. Сбой secure storage не
    // блокирует подключение: креды и так уходят в натив только в памяти при
    // каждом connect, а запасного хранилища нет намеренно — пароль живёт
    // только в Keystore. Пользователь лишь узнаёт, что данные не запомнятся.
    final saved = await _trySaveCredentials(username, password);

    // P3: первый коннект после старта сервиса иногда падает по
    // SocketException (DNS proxy errno=111) — C# bridge классифицирует
    // его как retryable. Пробуем подключиться до 3 раз с паузой 2 с,
    // ретраим только retryable-ошибки.
    const maxAttempts = 3;
    const retryDelay = Duration(seconds: 2);

    SoulseekConnectionInfo? info;
    SoulseekException? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (cancelled()) break;
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
        if (!canRetry || cancelled()) break;
        if (mounted) {
          setState(() => _connectionMessage = 'Retrying ($attempt/$maxAttempts)…');
        }
        await Future<void>.delayed(retryDelay);
      } catch (e) {
        // Непредвиденная ошибка платформы — не ретраим.
        lastError = SoulseekException('CONNECT_FAILED', e.toString());
        break;
      }
    }

    if (cancelled()) {
      // Cancel уже показал «Disconnected» и снял _connectInFlight (или его
      // заняла новая команда) — итог этой попытки не применяем. Попытка
      // успела войти после Cancel — разрываем её, если новой команды нет
      // (иначе disconnect оборвал бы новое подключение).
      if (info != null && !_connectInFlight) await _disconnectQuietly();
      _cancelledInFlight--;
      return;
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
      if (!saved) {
        showErrorSnack(
          context,
          "Connected, but credentials couldn't be saved on this device. "
          'See Advanced → Storage diagnostics.',
        );
      }
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

  /// Сохраняет учётные данные для connect. Возвращает false, если secure
  /// storage недоступен — подключение при этом продолжается.
  Future<bool> _trySaveCredentials(String username, String password) async {
    try {
      await SoulseekCredentials.save(username: username, password: password);
      // Фаза B: проталкиваем username в нативную soulseek.db (раньше это
      // делала кнопка «Save credentials», которой больше нет).
      unawaited(_repo.syncToNative(username: username));
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[Soulseek] credentials not saved: $e');
      return false;
    }
  }

  /// Cancel во время connect: прерывает retry-цикл и сразу показывает
  /// «Disconnected»; натив получает disconnect, чтобы бросить попытку.
  /// Без команды в полёте (CONNECTING / RECONNECTING пришли из натива —
  /// автопереподключение) это обычный disconnect.
  Future<void> _cancelConnect() async {
    if (!_connectInFlight) {
      await _disconnect();
      return;
    }
    _connectCommand++;
    _cancelledInFlight++;
    _connectInFlight = false;
    _connectionGeneration++;
    setState(() {
      _connectionState = SoulseekConnectionState.disconnected;
      _connectionMessage = null;
      _connecting = false;
    });
    await _disconnectQuietly();
  }

  Future<void> _disconnectQuietly() async {
    try {
      await SoulseekPlatformChannel.instance.disconnect();
    } catch (_) {
      // Клиента ещё нет — разрывать нечего.
    }
  }

  /// Одна попытка подключения: стартовать сервис, вызвать connect.
  /// Бросает SoulseekException при неудаче.
  Future<SoulseekConnectionInfo> _connectOnce(
    String username,
    String password,
  ) async {
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

  Future<void> _updateMaxParallel(int value) async {
    setState(() => _maxParallelDownloads = value);
    await _repo.setMaxParallelDownloads(value);
  }

  Future<void> _toggleStreaming(bool value) async {
    setState(() => _streamingEnabled = value);
    await _repo.setStreamingEnabled(value);
    await _applyFiltersToSource();
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

  Widget _buildUnavailable(AppColors colors) {
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
              defaultTargetPlatform == TargetPlatform.windows
                  ? 'Soulseek components are missing'
                  : 'Soulseek is only available on Android',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              defaultTargetPlatform == TargetPlatform.windows
                  ? 'The soulseek folder was not found next to the app. '
                      'Build the app with tools/build_windows.ps1.'
                  : 'This feature requires the native Soulseek plugin '
                      'which runs only on Android and Windows.',
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

  Widget _buildContent(AppColors colors) {
    // Аккаунт нужен только для подключения — после входа его поля
    // скрываются, логин виден в подзаголовке статуса.
    final showAccount = _connectionState != SoulseekConnectionState.connected;

    return ListView(
      controller: _scrollController,
      padding: EdgeInsets.only(
        top: 12,
        bottom: 24 +
            NowPlayingOverlay.miniHeight +
            MediaQuery.of(context).padding.bottom,
      ),
      children: [
        // === STATUS ===
        GroupedTiles(
          key: _connectionSectionKey,
          colors: colors,
          children: [
            _buildStatusRow(colors),
            _SwitchRow(
              colors: colors,
              title: 'Show in search',
              value: _enabled,
              onChanged: _toggleEnabled,
            ),
          ],
        ),
        _buildP2PNote(colors),

        // === ACCOUNT ===
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: showAccount
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GroupedTilesLabel(title: 'Account', colors: colors),
                    _buildAccountGroup(colors),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),

        // === SEARCH ===
        GroupedTilesLabel(title: 'Search', colors: colors),
        _buildSearchGroup(colors),

        // === DOWNLOADS ===
        // Лимит размера кэша — на общей странице Cache.
        GroupedTilesLabel(title: 'Downloads', colors: colors),
        _buildDownloadsGroup(colors),

        // === ADVANCED ===
        const SizedBox(height: 24),
        _buildAdvanced(colors),
      ],
    );
  }

  // ── STATUS ──

  Widget _buildStatusRow(AppColors colors) {
    final connected = _connectionState == SoulseekConnectionState.connected;
    final busy = !connected &&
        (_connecting ||
            _connectionState == SoulseekConnectionState.connecting ||
            _connectionState == SoulseekConnectionState.reconnecting);
    final username = _usernameController.text.trim();

    final String subtitle;
    if (connected) {
      subtitle = username.isEmpty ? 'Online' : 'as $username';
    } else if (_connectionMessage != null && _connectionMessage!.isNotEmpty) {
      subtitle = _connectionMessage!;
    } else {
      subtitle = busy ? 'Signing in…' : 'Offline';
    }

    final (label, onTap) = connected
        ? ('Disconnect', _disconnect)
        : busy
            ? ('Cancel', _cancelConnect)
            : ('Connect', _connect);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        children: [
          _ConnectionStatusDot(state: _connectionState, colors: colors),
          const SizedBox(width: 12),
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
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _PillButton(label: label, colors: colors, onTap: onTap),
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

  Widget _buildP2PNote(AppColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.info_outline_rounded,
              size: 14,
              color: colors.textTertiary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Soulseek is a peer-to-peer network: you download directly '
              'from other users, and your shared folder is visible to them.',
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── ACCOUNT ──

  Widget _buildAccountGroup(AppColors colors) {
    return GroupedTiles(
      colors: colors,
      children: [
        _FieldRow(
          colors: colors,
          label: 'Username',
          child: _InlineTextField(
            controller: _usernameController,
            colors: colors,
            hint: 'Your Soulseek username',
          ),
        ),
        _FieldRow(
          colors: colors,
          label: 'Password',
          trailing: IconButton(
            tooltip: _obscurePassword ? 'Show password' : 'Hide password',
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: colors.textTertiary,
              size: 20,
            ),
            onPressed: () {
              setState(() => _obscurePassword = !_obscurePassword);
            },
          ),
          child: _InlineTextField(
            controller: _passwordController,
            colors: colors,
            hint: 'Your Soulseek password',
            obscure: _obscurePassword,
          ),
        ),
      ],
    );
  }

  // ── SEARCH ──

  Widget _buildSearchGroup(AppColors colors) {
    return GroupedTiles(
      colors: colors,
      children: [
        _SwitchRow(
          colors: colors,
          title: 'Lossless only',
          subtitle: 'FLAC, WAV, ALAC, APE, WV',
          value: _preferLossless,
          onChanged: _togglePreferLossless,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
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
        ),
        _Row(
          colors: colors,
          title: 'Max file size',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _fileSizeLabel(_maxFileSizeMB),
                style: TextStyle(color: colors.textSecondary, fontSize: 14),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                color: colors.textTertiary,
                size: 20,
              ),
            ],
          ),
          onTap: () => _pickMaxFileSize(colors),
        ),
        _Row(
          colors: colors,
          title: 'Search timeout',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NumericField(
                key: const Key('soulseek_search_timeout_field'),
                initialValue: _searchTimeoutSec,
                colors: colors,
                hint: '${SoulseekSettingsRepository.defaultSearchTimeoutSec}',
                onChanged: _updateSearchTimeout,
              ),
              const SizedBox(width: 8),
              Text(
                's',
                style: TextStyle(color: colors.textTertiary, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _fileSizeLabel(int mb) => mb <= 0 ? 'Unlimited' : '$mb MB';

  Future<void> _pickMaxFileSize(AppColors colors) async {
    final options = <int>{..._fileSizePresets, _maxFileSizeMB}.toList()..sort();
    // 0 (без лимита) — в начало списка.
    options
      ..remove(0)
      ..insert(0, 0);

    final picked = await showDesktopModalSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _OptionSheet<int>(
        colors: colors,
        title: 'Max file size',
        options: options,
        selected: _maxFileSizeMB,
        labelOf: _fileSizeLabel,
      ),
    );
    if (picked == null || picked == _maxFileSizeMB || !mounted) return;
    setState(() => _maxFileSizeMB = picked);
    await _updateMaxFileSize('$picked');
  }

  // ── DOWNLOADS ──

  Widget _buildDownloadsGroup(AppColors colors) {
    final active = _activeTransferIds.length;
    return GroupedTiles(
      colors: colors,
      children: [
        _SwitchRow(
          colors: colors,
          title: 'Play while downloading',
          subtitle: 'Start before the file is fully downloaded',
          value: _streamingEnabled,
          onChanged: _toggleStreaming,
        ),
        _Row(
          colors: colors,
          title: 'Parallel downloads',
          trailing: _Segmented<int>(
            colors: colors,
            values: const [2, 3, 4, 5],
            selected: _maxParallelDownloads,
            labelOf: (v) => '$v',
            onChanged: _updateMaxParallel,
          ),
        ),
        _Row(
          colors: colors,
          icon: Icons.download_rounded,
          title: 'Downloads',
          trailing: _NavTrailing(
            colors: colors,
            value: active > 0 ? '$active active' : null,
          ),
          onTap: () => showSoulseekTransferSheet(context),
        ),
        _Row(
          colors: colors,
          icon: Icons.storage_rounded,
          title: 'Cached tracks',
          trailing: _NavTrailing(colors: colors),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CachedTracksPage()),
          ),
        ),
      ],
    );
  }

  // ── ADVANCED ──

  Widget _buildAdvanced(AppColors colors) {
    final sharedPath = _sharingDirectory.isNotEmpty
        ? _sharingDirectory
        : 'Internal storage (default)';

    // Одна группа: заголовок и раскрытые строки — общие скругления, как у
    // остальных групп страницы.
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: GroupedTiles(
        colors: colors,
        children: [
          _Row(
            colors: colors,
            title: 'Advanced',
            trailing: AnimatedRotation(
              turns: _advancedOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.expand_more_rounded,
                color: colors.textTertiary,
              ),
            ),
            onTap: () => setState(() => _advancedOpen = !_advancedOpen),
          ),
          if (_advancedOpen) ...[
            _Row(
              colors: colors,
              title: 'Listener port',
              trailing: _NumericField(
                key: const Key('soulseek_listen_port_field'),
                initialValue: _listenPort,
                colors: colors,
                hint: '24150',
                width: 72,
                onChanged: _updateListenPort,
              ),
            ),
            _Row(
              colors: colors,
              title: 'Shared folder',
              subtitle: sharedPath,
              trailing: Icon(
                Icons.info_outline_rounded,
                color: colors.textTertiary,
                size: 20,
              ),
              onTap: () => showAppInfoDialog(
                context: context,
                title: 'Shared folder',
                subtitle: 'Soulseek shares files from the internal '
                    'storage directory of the app. On Android, '
                    "this is the app's private storage area. "
                    'Downloaded files are cached here and '
                    'available for sharing with other Soulseek '
                    'users.',
              ),
            ),
            _Row(
              colors: colors,
              title: 'Storage diagnostics',
              subtitle: 'Report for the developer if credentials '
                  'fail to save. Contains no passwords.',
              trailing: _NavTrailing(colors: colors),
              onTap: () => showAppReportDialog(
                context: context,
                title: 'Diagnostics',
                subtitle: 'Send this report to the developer',
                report: SecureStorageDiagnostics.buildReport(),
                shareSubject: 'Player: secure storage diagnostics',
              ),
            ),
            _Row(
              colors: colors,
              title: 'Clear credentials',
              titleColor: Colors.redAccent,
              onTap: _clearCredentials,
            ),
          ],
        ],
      ),
    );
  }
}

/// Пресеты листа «Max file size» (МБ, 0 — без лимита).
const List<int> _fileSizePresets = [0, 50, 100, 200, 500];

// ═══════════════════════════════════════════════════════════════════════
//  SHARED WIDGETS
// ═══════════════════════════════════════════════════════════════════════

class _Row extends StatelessWidget {
  const _Row({
    required this.colors,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.titleColor,
  });

  final AppColors colors;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: colors.textSecondary, size: 20),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor ?? colors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.colors,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final AppColors colors;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _Row(
      colors: colors,
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeThumbColor: colors.accent,
        activeTrackColor: colors.accent.withValues(alpha: 0.3),
        inactiveThumbColor: colors.textSecondary,
        inactiveTrackColor: colors.background,
      ),
    );
  }
}

/// Строка формы: метка фиксированной ширины + поле ввода.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.colors,
    required this.label,
    required this.child,
    this.trailing,
  });

  final AppColors colors;
  final String label;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: EdgeInsets.only(left: 16, right: trailing == null ? 16 : 4),
        child: Row(
          children: [
            SizedBox(
              width: 88,
              child: Text(
                label,
                style: TextStyle(color: colors.textTertiary, fontSize: 13),
              ),
            ),
            Expanded(child: child),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _InlineTextField extends StatelessWidget {
  const _InlineTextField({
    required this.controller,
    required this.colors,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final AppColors colors;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: !obscure,
      style: TextStyle(color: colors.textPrimary, fontSize: 15),
      cursorColor: colors.textPrimary,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: colors.textTertiary, fontSize: 15),
        border: InputBorder.none,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
  }
}

/// Значение справа у навигационной строки + шеврон.
class _NavTrailing extends StatelessWidget {
  const _NavTrailing({required this.colors, this.value});

  final AppColors colors;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null) ...[
          Text(
            value!,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 4),
        ],
        Icon(Icons.chevron_right_rounded, color: colors.textTertiary, size: 20),
      ],
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.colors,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final AppColors colors;
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in values)
            _SegmentOption(
              label: labelOf(v),
              selected: v == selected,
              colors: colors,
              onTap: () => onChanged(v),
            ),
        ],
      ),
    );
  }
}

class _SegmentOption extends StatelessWidget {
  const _SegmentOption({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final AppColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? colors.elevatedVariant : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minWidth: 34, minHeight: 30),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.textPrimary : colors.textTertiary,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final AppColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevatedVariant,
      shape: StadiumBorder(side: BorderSide(color: colors.outline)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Лист выбора одного значения из списка (галочка у текущего).
class _OptionSheet<T> extends StatelessWidget {
  const _OptionSheet({
    required this.colors,
    required this.title,
    required this.options,
    required this.selected,
    required this.labelOf,
  });

  final AppColors colors;
  final String title;
  final List<T> options;
  final T selected;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colors.textTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
            child: Text(
              title,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GroupedTiles(
            colors: colors,
            children: [
              for (final o in options)
                _Row(
                  colors: colors,
                  title: labelOf(o),
                  trailing: Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: o == selected
                        ? colors.textPrimary
                        : Colors.transparent,
                  ),
                  onTap: () => Navigator.of(context).pop(o),
                ),
            ],
          ),
        ],
      ),
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

/// Компактное числовое поле в строке (таймаут, порт).
class _NumericField extends StatefulWidget {
  const _NumericField({
    super.key,
    required this.initialValue,
    required this.colors,
    required this.hint,
    required this.onChanged,
    this.width = 56,
  });

  final int initialValue;
  final AppColors colors;
  final String hint;
  final double width;

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
    final colors = widget.colors;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: colors.outline, width: 1),
    );
    return SizedBox(
      width: widget.width,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        cursorColor: colors.textPrimary,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 14,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: TextStyle(color: colors.textTertiary, fontSize: 14),
          filled: true,
          fillColor: colors.background,
          isDense: true,
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(color: colors.elevatedHi, width: 1),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        ),
        onChanged: (_) => _onTextChanged(),
        onSubmitted: (_) => _commitNow(),
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
  final AppColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? colors.elevatedVariant : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? colors.elevatedHi : colors.outline,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.textPrimary : colors.textTertiary,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: 0.3,
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
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    // Монохромно в цветах палитры; цветной — только сбой.
    final (color, pulsing) = switch (state) {
      SoulseekConnectionState.connected => (colors.textPrimary, false),
      SoulseekConnectionState.connecting => (colors.textSecondary, true),
      SoulseekConnectionState.reconnecting => (colors.textSecondary, true),
      SoulseekConnectionState.failed => (Colors.redAccent, false),
      SoulseekConnectionState.disconnected => (colors.textTertiary, false),
    };

    if (pulsing) {
      return _PulsingDot(color: color);
    }
    return Container(
      width: 10,
      height: 10,
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
            width: 10,
            height: 10,
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
