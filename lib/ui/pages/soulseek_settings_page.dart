// lib/ui/pages/soulseek_settings_page.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/haptic_helper.dart';
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
import '../widgets/byte_format.dart';
import '../widgets/grouped_tiles.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/snack.dart';
import 'downloads_page.dart';

final SoulseekSettingsRepository _repo = SoulseekSettingsRepository.instance;

enum SoulseekSettingsSection { connection }

class SoulseekSettingsPage extends ConsumerStatefulWidget {
  const SoulseekSettingsPage({super.key, this.initialSection});

  final SoulseekSettingsSection? initialSection;

  @override
  ConsumerState<SoulseekSettingsPage> createState() =>
      _SoulseekSettingsPageState();
}

class _SoulseekSettingsPageState extends ConsumerState<SoulseekSettingsPage> {
  // ── Учётные данные ──
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  String _savedUsername = '';
  String _savedPassword = '';
  bool _accountDirty = false;
  String _accountName = '';

  // ── Параметры ──
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
  bool _showConnectionStatus = false;

  int _connectionGeneration = 0;
  bool _connectInFlight = false;
  int _connectCommand = 0;
  int _cancelledInFlight = 0;

  final Map<String, int> _activeSpeeds = {};
  StreamSubscription<SoulseekTransferEvent>? _transferSub;

  bool _advancedOpen = false;

  static const List<String> _allFormats = [
    'flac', 'wav', 'alac', 'mp3', 'aac', 'ogg',
  ];

  bool get _isAvailable => SoulseekPlatformChannel.instance.isAvailable;

  final _connectionSectionKey = GlobalKey();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onAccountEdited);
    _passwordController.addListener(_onAccountEdited);
    _loadSettings();
    _subscribeConnection();
    _subscribeTransfers();
    if (widget.initialSection == SoulseekSettingsSection.connection) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToConnection());
    }
  }

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
    _usernameController.removeListener(_onAccountEdited);
    _passwordController.removeListener(_onAccountEdited);
    _usernameController.dispose();
    _passwordController.dispose();
    _connectionSub?.close();
    _transferSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  static bool _isActiveTransfer(SoulseekTransferState s) =>
      s.isActive || s == SoulseekTransferState.prebuffered;

  void _onAccountEdited() {
    final dirty = _usernameController.text.trim() != _savedUsername ||
        _passwordController.text != _savedPassword;
    if (dirty == _accountDirty || !mounted) return;
    setState(() => _accountDirty = dirty);
  }

  Future<void> _subscribeTransfers() async {
    if (!_isAvailable) return;
    final platform = SoulseekPlatformChannel.instance;
    Set<String>? seenBeforeSnapshot = {};
    _transferSub = platform.transferEvents.listen((e) {
      final info = e.transfer;
      seenBeforeSnapshot?.add(info.downloadId);
      if (_isActiveTransfer(info.state)) {
        if (_activeSpeeds[info.downloadId] == info.bytesPerSecond) return;
        _activeSpeeds[info.downloadId] = info.bytesPerSecond;
      } else if (_activeSpeeds.remove(info.downloadId) == null) {
        return;
      }
      if (mounted) setState(() {});
    }, onError: (_) {});
    try {
      final active = await platform.getActiveTransfers();
      final seen = seenBeforeSnapshot;
      if (!mounted) return;
      setState(() {
        for (final t in active) {
          if (_isActiveTransfer(t.state) && !seen.contains(t.downloadId)) {
            _activeSpeeds[t.downloadId] = t.bytesPerSecond;
          }
        }
      });
    } catch (_) {
      // Сервис не поднят
    } finally {
      seenBeforeSnapshot = null;
    }
  }

  Future<void> _loadSettings() async {
    final creds = await SoulseekCredentials.load();
    final usernameQuick = await SoulseekCredentials.loadUsernameQuick();
    final settings = await _repo.loadAll();

    if (mounted) {
      setState(() {
        _usernameController.text = creds?.username ?? usernameQuick ?? '';
        _passwordController.text = creds?.password ?? '';
        _savedUsername = _usernameController.text.trim();
        _savedPassword = _passwordController.text;
        _accountName = _savedUsername;
        _accountDirty = false;

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
        _showConnectionStatus = true;
      });
      return;
    }
    final event = next.valueOrNull;
    if (event == null) return;
    if (!_connectInFlight && _cancelledInFlight > 0) return;
    if (_connectInFlight &&
        event.state == SoulseekConnectionState.disconnected) {
      return;
    }
    _connectionGeneration++;
    setState(() {
      _connectionState = event.state;
      _connectionMessage = event.message;
      if (event.state != SoulseekConnectionState.disconnected) {
        _showConnectionStatus = true;
      }
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

  Future<void> _connect() async {
    if (!_isAvailable) return;

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      HapticHelper.error(ref: ref);
      if (mounted) showSnack(context, 'Enter username and password');
      return;
    }

    final generation = ++_connectionGeneration;
    final command = ++_connectCommand;
    bool cancelled() => command != _connectCommand;

    _connectInFlight = true;
    setState(() {
      _showConnectionStatus = true;
      _accountName = username;
      _connecting = true;
      _connectionState = SoulseekConnectionState.connecting;
      _connectionMessage = null;
    });

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
        final effectiveRetryable = e.retryable || e.isServiceBindRace;
        final canRetry = effectiveRetryable && attempt < maxAttempts;
        if (!canRetry || cancelled()) break;
        if (mounted) {
          setState(() => _connectionMessage = 'Retrying ($attempt/$maxAttempts)…');
        }
        await Future<void>.delayed(retryDelay);
      } catch (e) {
        lastError = SoulseekException('CONNECT_FAILED', e.toString());
        break;
      }
    }

    if (cancelled()) {
      if (info != null && !_connectInFlight) await _disconnectQuietly();
      _cancelledInFlight--;
      return;
    }

    final saved = info == null || await _trySaveCredentials(username, password);

    _connectInFlight = false;
    if (!mounted) return;

    final stale = generation != _connectionGeneration;

    if (info != null) {
      HapticHelper.success(ref: ref);
      final connected = info;
      setState(() {
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
      HapticHelper.error(ref: ref);
      final e = lastError ?? const SoulseekException('CONNECT_FAILED', 'Connect failed');
      setState(() {
        if (_connectionState != SoulseekConnectionState.connected) {
          _connectionState = SoulseekConnectionState.failed;
          _connectionMessage = e.message;
        }
        _connecting = false;
      });
      showSnack(context, 'Connection failed: ${e.message}');
    }
  }

  Future<bool> _trySaveCredentials(String username, String password) async {
    try {
      await SoulseekCredentials.save(username: username, password: password);
      unawaited(_repo.syncToNative(username: username));
      _savedUsername = username;
      _savedPassword = password;
      _onAccountEdited();
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[Soulseek] credentials not saved: $e');
      return false;
    }
  }

  Future<void> _saveAccount() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      HapticHelper.error(ref: ref);
      showSnack(context, 'Enter username and password');
      return;
    }
    FocusScope.of(context).unfocus();
    if (_connectionState == SoulseekConnectionState.connected) {
      await _disconnectQuietly();
      if (mounted) await _connect();
      return;
    }
    final saved = await _trySaveCredentials(username, password);
    if (!mounted) return;
    if (saved) {
      HapticHelper.success(ref: ref);
      showSnack(context, 'Saved');
    } else {
      HapticHelper.error(ref: ref);
      showErrorSnack(
        context,
        "Credentials couldn't be saved on this device. "
        'See Advanced → Storage diagnostics.',
      );
    }
  }

  Future<void> _cancelConnect() async {
    HapticHelper.weak(ref: ref);
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
      _showConnectionStatus = false;
    });
    await _disconnectQuietly();
  }

  Future<void> _disconnectQuietly() async {
    try {
      await SoulseekPlatformChannel.instance.disconnect();
    } catch (_) {}
  }

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
    HapticHelper.weak(ref: ref);
    final generation = ++_connectionGeneration;
    try {
      await SoulseekPlatformChannel.instance.disconnect();
      if (mounted) {
        if (generation == _connectionGeneration) {
          setState(() {
            _connectionState = SoulseekConnectionState.disconnected;
            _connectionMessage = null;
            _showConnectionStatus = false;
          });
        }
        showSnack(context, 'Disconnected');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Disconnect failed');
    }
  }

  Future<void> _clearCredentials() async {
    HapticHelper.medium(ref: ref);
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
    if (confirmed != true) {
      HapticHelper.weak(ref: ref);
      return;
    }

    try {
      await SoulseekCredentials.clear();
      if (mounted) {
        HapticHelper.confirmDelete(ref: ref);
        _savedUsername = '';
        _savedPassword = '';
        setState(() {
          _usernameController.clear();
          _passwordController.clear();
        });
        showSnack(context, 'Credentials cleared');
      }
    } catch (_) {
      if (mounted) {
        HapticHelper.error(ref: ref);
        showSnack(context, 'Failed to clear credentials');
      }
    }
  }

  // ── Персист (SQLite) ──

  Future<void> _editListenPort() async {
    HapticHelper.light(ref: ref);
    final text = await showAppInputDialog(
      context: context,
      title: 'Listener port',
      subtitle: 'Port for incoming peer connections (1–65535)',
      initialValue: '$_listenPort',
      hintText: '${SoulseekSettingsRepository.defaultListenPort}',
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
    if (text == null || !mounted) return;
    final port = int.tryParse(text);
    if (port == null || port < 1 || port > 65535) {
      HapticHelper.error(ref: ref);
      showErrorSnack(context, 'Port must be between 1 and 65535');
      return;
    }
    if (port == _listenPort) return;
    HapticHelper.success(ref: ref);
    setState(() => _listenPort = port);
    await _repo.setListenPort(port);
  }

  Future<void> _updateMaxParallel(int value) async {
    setState(() => _maxParallelDownloads = value);
    await _repo.setMaxParallelDownloads(value);
  }

  Future<void> _toggleStreaming(bool value) async {
    HapticHelper.light(ref: ref);
    setState(() => _streamingEnabled = value);
    await _repo.setStreamingEnabled(value);
    await _applyFiltersToSource();
  }

  Future<void> _togglePreferLossless(bool value) async {
    HapticHelper.light(ref: ref);
    setState(() => _preferLossless = value);
    await _repo.setPreferLossless(value);
    await _applyFiltersToSource();
  }

  Future<void> _toggleFormat(String fmt, bool selected) async {
    HapticHelper.light(ref: ref);
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

  Future<void> _updateMaxFileSize(int mb) async {
    if (mb < 0 || mb == _maxFileSizeMB) return;
    setState(() => _maxFileSizeMB = mb);
    await _repo.setMaxFileSizeMB(mb);
    await _applyFiltersToSource();
  }

  Future<void> _updateSearchTimeout(int sec) async {
    if (sec < 1) return;
    _searchTimeoutSec = sec;
    await _repo.setSearchTimeoutSec(sec);
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
                padding: const EdgeInsets.fromLTRB(16, 56, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (Navigator.of(context).canPop())
                      _CircleButton(
                        icon: Icons.chevron_left_rounded,
                        onTap: () {
                          HapticHelper.light(ref: ref);
                          Navigator.of(context).maybePop();
                        },
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
    return ListView(
      controller: _scrollController,
      padding: EdgeInsets.only(
        top: 12,
        bottom: 24 +
            NowPlayingOverlay.miniHeight +
            MediaQuery.of(context).padding.bottom,
      ),
      children: [
        KeyedSubtree(
          key: _connectionSectionKey,
          child: _buildStatusCard(colors),
        ),
        _buildP2PNote(colors),

        _SectionLabel(title: 'Account', colors: colors),
        _buildAccountGroup(colors),

        _SectionLabel(title: 'Search', colors: colors),
        _buildSearchGroup(colors),
        _Caption(
          text: 'Larger files are hidden from search results',
          colors: colors,
        ),

        _SectionLabel(title: 'Downloads', colors: colors),
        _buildDownloadsGroup(colors),

        _SectionLabel(title: 'Advanced', colors: colors),
        _buildAdvanced(colors),
      ],
    );
  }

  // ── STATUS ──

  Widget _buildStatusCard(AppColors colors) {
    final connected = _connectionState == SoulseekConnectionState.connected;
    final busy = !connected &&
        (_connecting ||
            _connectionState == SoulseekConnectionState.connecting ||
            _connectionState == SoulseekConnectionState.reconnecting);

    final String subtitle;
    if (connected) {
      final speed = _activeSpeeds.values.fold<int>(0, (a, b) => a + b);
      final who = _accountName.isEmpty ? 'Online' : 'as $_accountName';
      subtitle = speed > 0 ? '$who · ${formatSpeed(speed)}' : who;
    } else if (_connectionMessage != null && _connectionMessage!.isNotEmpty) {
      subtitle = _connectionMessage!;
    } else {
      subtitle = busy ? 'Signing in…' : 'Offline';
    }

    final (label, onTap) = connected
        ? ('Disconnect', _disconnect)
        : busy
            ? ('Cancel', _cancelConnect)
            : ('Connect', () {
                HapticHelper.medium(ref: ref);
                _connect();
              });

    final showStatus = _showConnectionStatus &&
        (busy ||
            connected ||
            _connectionState == SoulseekConnectionState.failed ||
            (_connectionMessage != null && _connectionMessage!.isNotEmpty));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BigButton(
              label: label,
              colors: colors,
              filled: !connected && !busy,
              outlined: true,
              onTap: onTap,
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: showStatus
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                      child: Row(
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
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.textTertiary,
                                    fontSize: 12,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ],
        ),
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
    final connected = _connectionState == SoulseekConnectionState.connected;
    final busy = _connecting ||
        _connectionState == SoulseekConnectionState.connecting ||
        _connectionState == SoulseekConnectionState.reconnecting;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: GroupedTiles(
        colors: colors,
        children: [
          _InlineTextField(
            controller: _usernameController,
            colors: colors,
            hint: 'Username',
          ),
          _InlineTextField(
            controller: _passwordController,
            colors: colors,
            hint: 'Password',
            obscure: _obscurePassword,
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
                HapticHelper.light(ref: ref);
                setState(() => _obscurePassword = !_obscurePassword);
              },
            ),
          ),
          if (_accountDirty)
            Material(
              color: colors.accent,
              child: InkWell(
                onTap: busy
                    ? null
                    : () {
                        HapticHelper.medium(ref: ref);
                        _saveAccount();
                      },
                child: SizedBox(
                  height: 56,
                  child: Center(
                    child: Text(
                      connected ? 'Save and reconnect' : 'Save',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── SEARCH ──

  Widget _buildSearchGroup(AppColors colors) {
    final sizeIndex = _nearestFileSizeIndex(_maxFileSizeMB);
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
        // Форматы — одинаковая высота 56px, центрирование и горизонтальный скролл чипов
        SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'Formats',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: _allFormats.map((fmt) {
                          final selected = _allowedFormats.contains(fmt);
                          return Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _FormatChip(
                              label: fmt.toUpperCase(),
                              selected: selected,
                              colors: colors,
                              onTap: () => _toggleFormat(fmt, !selected),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _Row(
          colors: colors,
          title: 'Search timeout',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _WheelPicker(
                key: const Key('soulseek_search_timeout_wheel'),
                semanticLabel: 'Search timeout, seconds',
                min: _minSearchTimeoutSec,
                max: _maxSearchTimeoutSec,
                value: _searchTimeoutSec,
                colors: colors,
                onChanged: _updateSearchTimeout,
              ),
              const SizedBox(width: 2),
              Text(
                's',
                style: TextStyle(color: colors.textPrimary, fontSize: 16),
              ),
            ],
          ),
        ),
        // Исключение: Max file size со слайдером
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'Max file size',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Badge(label: _fileSizeLabel(_maxFileSizeMB), colors: colors),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _fileSizeLabel(_fileSizeSteps.first),
                    style: TextStyle(color: colors.textTertiary, fontSize: 11),
                  ),
                  Text(
                    _fileSizeLabel(_fileSizeSteps.last),
                    style: TextStyle(color: colors.textTertiary, fontSize: 11),
                  ),
                ],
              ),
              _StepSlider(
                key: const Key('soulseek_max_file_size_slider'),
                semanticLabel: 'Max file size',
                colors: colors,
                count: _fileSizeSteps.length,
                index: sizeIndex,
                labelOf: (i) => _fileSizeLabel(_fileSizeSteps[i]),
                onChanged: (i) => _updateMaxFileSize(_fileSizeSteps[i]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _fileSizeLabel(int mb) => mb <= 0 ? 'Unlimited' : '$mb MB';

  static int _nearestFileSizeIndex(int mb) {
    if (mb <= 0) return _fileSizeSteps.length - 1;
    var best = 0;
    for (var i = 0; i < _fileSizeSteps.length - 1; i++) {
      if ((_fileSizeSteps[i] - mb).abs() < (_fileSizeSteps[best] - mb).abs()) {
        best = i;
      }
    }
    return best;
  }

  // ── DOWNLOADS ──

  Widget _buildDownloadsGroup(AppColors colors) {
    final active = _activeSpeeds.length;
    final parallelIndex = _parallelSteps.indexOf(_maxParallelDownloads);
    return GroupedTiles(
      colors: colors,
      children: [
        _SwitchRow(
          colors: colors,
          title: 'Play while downloading',
          subtitle: 'Start before the download finishes',
          value: _streamingEnabled,
          onChanged: _toggleStreaming,
        ),
        // Исключение: Parallel downloads со слайдером
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Parallel downloads',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 10),
              _StepLabels(
                colors: colors,
                labels: [for (final v in _parallelSteps) '$v'],
                selected: parallelIndex,
              ),
              _StepSlider(
                key: const Key('soulseek_parallel_slider'),
                semanticLabel: 'Parallel downloads',
                colors: colors,
                count: _parallelSteps.length,
                index: parallelIndex >= 0
                    ? parallelIndex
                    : (_maxParallelDownloads < _parallelSteps.first
                        ? 0
                        : _parallelSteps.length - 1),
                showTicks: true,
                labelOf: (i) => '${_parallelSteps[i]}',
                onChanged: (i) => _updateMaxParallel(_parallelSteps[i]),
              ),
            ],
          ),
        ),
        _Row(
          colors: colors,
          title: 'Downloads',
          trailing: _NavTrailing(
            colors: colors,
            value: active > 0 ? '$active active' : null,
          ),
          onTap: () {
            HapticHelper.light(ref: ref);
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadsPage()),
            );
          },
        ),
      ],
    );
  }

  // ── ADVANCED ──

  Widget _buildAdvanced(AppColors colors) {
    final sharedPath = _sharingDirectory.isNotEmpty
        ? _sharingDirectory
        : 'Internal storage (default)';

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: GroupedTiles(
        colors: colors,
        children: [
          _Row(
            colors: colors,
            title: _advancedOpen ? 'Show less' : 'Show more',
            trailing: AnimatedRotation(
              turns: _advancedOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.expand_more_rounded,
                color: colors.textTertiary,
              ),
            ),
            onTap: () {
              HapticHelper.light(ref: ref);
              setState(() => _advancedOpen = !_advancedOpen);
            },
          ),
          if (_advancedOpen) ...[
            _Row(
              colors: colors,
              title: 'Listener port',
              subtitle: '$_listenPort',
              trailing: _NavTrailing(colors: colors),
              onTap: _editListenPort,
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
              onTap: () {
                HapticHelper.light(ref: ref);
                showAppInfoDialog(
                  context: context,
                  title: 'Shared folder',
                  subtitle: 'Soulseek shares files from the internal '
                      'storage directory of the app. On Android, '
                      "this is the app's private storage area. "
                      'Downloaded files are cached here and '
                      'available for sharing with other Soulseek '
                      'users.',
                );
              },
            ),
            _Row(
              colors: colors,
              title: 'Storage diagnostics',
              subtitle: 'Report for the developer if credentials '
                  'fail to save. Contains no passwords.',
              trailing: _NavTrailing(colors: colors),
              onTap: () {
                HapticHelper.light(ref: ref);
                showAppReportDialog(
                  context: context,
                  title: 'Diagnostics',
                  subtitle: 'Send this report to the developer',
                  report: SecureStorageDiagnostics.buildReport(),
                  shareSubject: 'Player: secure storage diagnostics',
                );
              },
            ),
            _Row(
              colors: colors,
              title: 'Clear account data',
              titleColor: Colors.redAccent,
              onTap: _clearCredentials,
            ),
          ],
        ],
      ),
    );
  }
}

const List<int> _fileSizeSteps = [10, 20, 30, 50, 75, 100, 150, 200, 300, 500, 0];
const List<int> _parallelSteps = [1, 2, 3, 4, 5];
const int _minSearchTimeoutSec = 3;
const int _maxSearchTimeoutSec = 120;

// ═══════════════════════════════════════════════════════════════════════
//  SHARED WIDGETS
// ═══════════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.colors});

  final String title;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 10),
      child: Text(
        title,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption({required this.text, required this.colors});

  final String text;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
      child: Text(
        text,
        style: TextStyle(color: colors.textTertiary, fontSize: 12),
      ),
    );
  }
}

/// Стандартная плитка настроек высотой ровно 56px
class _Row extends StatelessWidget {
  const _Row({
    required this.colors,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.titleColor,
  });

  final AppColors colors;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 12,
                          height: 1.2,
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
        activeThumbColor: colors.textPrimary,
        activeTrackColor: colors.accent,
        inactiveThumbColor: colors.textSecondary,
        inactiveTrackColor: colors.background,
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : colors.outline,
        ),
      ),
    );
  }
}

/// Поле ввода высотой ровно 56px
class _InlineTextField extends StatelessWidget {
  const _InlineTextField({
    required this.controller,
    required this.colors,
    required this.hint,
    this.obscure = false,
    this.trailing,
  });

  final TextEditingController controller;
  final AppColors colors;
  final String hint;
  final bool obscure;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: EdgeInsets.only(left: 16, right: trailing == null ? 16 : 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
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
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

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
        Icon(Icons.chevron_right_rounded, color: colors.textTertiary, size: 22),
      ],
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.label,
    required this.colors,
    required this.onTap,
    this.filled = false,
    this.outlined = false,
  });

  final String label;
  final AppColors colors;
  final VoidCallback? onTap;
  final bool filled;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final background = filled ? colors.accent : colors.elevatedVariant;
    return Material(
      color: enabled ? background : background.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: outlined && !filled
            ? BorderSide(color: colors.outline)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: enabled ? colors.textPrimary : colors.textTertiary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.colors});

  final String label;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

const double _sliderTrackHeight = 18;
const double _sliderThumbSize = 14;

class _StepSlider extends StatelessWidget {
  const _StepSlider({
    super.key,
    required this.colors,
    required this.count,
    required this.index,
    required this.onChanged,
    required this.labelOf,
    required this.semanticLabel,
    this.showTicks = false,
  });

  final AppColors colors;
  final String semanticLabel;
  final int count;
  final int index;
  final ValueChanged<int> onChanged;
  final String Function(int index) labelOf;
  final bool showTicks;

  @override
  Widget build(BuildContext context) {
    const h = _sliderTrackHeight;
    const thumb = _sliderThumbSize;
    final canIncrease = index < count - 1;
    final canDecrease = index > 0;
    return Semantics(
      container: true,
      slider: true,
      label: semanticLabel,
      value: labelOf(index),
      increasedValue: canIncrease ? labelOf(index + 1) : null,
      decreasedValue: canDecrease ? labelOf(index - 1) : null,
      onIncrease: canIncrease ? () => onChanged(index + 1) : null,
      onDecrease: canDecrease ? () => onChanged(index - 1) : null,
      child: _KeyStepper(
        colors: colors,
        onStep: (delta) {
          final i = (index + delta).clamp(0, count - 1);
          if (i != index) {
            HapticHelper.microTick();
            onChanged(i);
          }
        },
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            double xOf(int i) => h / 2 + (w - h) * (count < 2 ? 0 : i / (count - 1));
            void select(double dx) {
              final i = ((dx - h / 2) / (w - h) * (count - 1))
                  .round()
                  .clamp(0, count - 1);
              if (i != index) {
                HapticHelper.microTick();
                onChanged(i);
              }
            }

            const duration = Duration(milliseconds: 160);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => select(d.localPosition.dx),
              onHorizontalDragStart: (d) => select(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => select(d.localPosition.dx),
              child: SizedBox(
                height: 48,
                child: Center(
                  child: SizedBox(
                    height: h,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.background,
                              borderRadius: BorderRadius.circular(h / 2),
                            ),
                          ),
                        ),
                        AnimatedPositioned(
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: xOf(index) + h / 2,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.accent,
                              borderRadius: BorderRadius.circular(h / 2),
                            ),
                          ),
                        ),
                        if (showTicks)
                          for (var i = 0; i < count; i++)
                            if (i != index)
                              Positioned(
                                left: xOf(i) - 3,
                                top: h / 2 - 3,
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: i < index
                                        ? colors.background
                                        : colors.textTertiary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                        AnimatedPositioned(
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          left: xOf(index) - thumb / 2,
                          top: (h - thumb) / 2,
                          child: Container(
                            width: thumb,
                            height: thumb,
                            decoration: BoxDecoration(
                              color: colors.textPrimary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _KeyStepper extends StatefulWidget {
  const _KeyStepper({
    required this.colors,
    required this.onStep,
    required this.child,
  });

  final AppColors colors;
  final ValueChanged<int> onStep;
  final Widget child;

  @override
  State<_KeyStepper> createState() => _KeyStepperState();
}

class _KeyStepperState extends State<_KeyStepper> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      widget.onStep(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      widget.onStep(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _focused ? widget.colors.elevatedHi : Colors.transparent,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

class _StepLabels extends StatelessWidget {
  const _StepLabels({
    required this.colors,
    required this.labels,
    required this.selected,
  });

  final AppColors colors;
  final List<String> labels;
  final int selected;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    return SizedBox(
      height: 22,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (i, label) in labels.indexed)
            SizedBox(
              width: _sliderTrackHeight,
              child: OverflowBox(
                maxWidth: 40,
                alignment: Alignment.bottomCenter,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 160),
                  style: base.copyWith(
                    color: i == selected
                        ? colors.textPrimary
                        : colors.textTertiary,
                    fontSize: i == selected ? 17 : 12,
                    fontWeight: i == selected ? FontWeight.w600 : FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  child: Text(label, textAlign: TextAlign.center),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WheelPicker extends StatefulWidget {
  const _WheelPicker({
    super.key,
    required this.min,
    required this.max,
    required this.value,
    required this.colors,
    required this.onChanged,
    required this.semanticLabel,
  });

  final int min;
  final int max;
  final int value;
  final AppColors colors;
  final ValueChanged<int> onChanged;
  final String semanticLabel;

  @override
  State<_WheelPicker> createState() => _WheelPickerState();
}

class _WheelPickerState extends State<_WheelPicker> {
  static const double _itemExtent = 30;
  static const _debounceDelay = Duration(milliseconds: 500);

  late final FixedExtentScrollController _controller;
  late int _current;
  Timer? _debounce;

  int _clamp(int v) => v.clamp(widget.min, widget.max);

  @override
  void initState() {
    super.initState();
    _current = _clamp(widget.value);
    _controller = FixedExtentScrollController(
      initialItem: _current - widget.min,
    );
  }

  @override
  void didUpdateWidget(covariant _WheelPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    if (_debounce != null) return;
    final v = _clamp(widget.value);
    if (v == _current) return;
    _current = v;
    if (_controller.hasClients) _controller.jumpToItem(v - widget.min);
  }

  @override
  void dispose() {
    if (_debounce != null) {
      _debounce!.cancel();
      _debounce = null;
      widget.onChanged(_current);
    }
    _controller.dispose();
    super.dispose();
  }

  void _onSelected(int index) {
    final value = widget.min + index;
    if (value == _current) return;
    HapticHelper.microTick();
    setState(() => _current = value);
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      _debounce = null;
      widget.onChanged(_current);
    });
  }

  void _step(int delta) {
    final target = _clamp(_current + delta);
    if (target == _current) return;
    HapticHelper.microTick();
    _controller.animateToItem(
      target - widget.min,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Semantics(
      container: true,
      slider: true,
      label: widget.semanticLabel,
      value: '$_current',
      increasedValue: _current < widget.max ? '${_current + 1}' : null,
      decreasedValue: _current > widget.min ? '${_current - 1}' : null,
      onIncrease: _current < widget.max ? () => _step(1) : null,
      onDecrease: _current > widget.min ? () => _step(-1) : null,
      child: _KeyStepper(
        colors: colors,
        onStep: _step,
        child: ExcludeSemantics(
          child: GestureDetector(
            onTapUp: (d) {
              if (d.localPosition.dx < _itemExtent) {
                _step(-1);
              } else if (d.localPosition.dx > _itemExtent * 2) {
                _step(1);
              }
            },
            child: SizedBox(
              width: _itemExtent * 3,
              height: 48,
              child: RotatedBox(
                quarterTurns: 3,
                child: ListWheelScrollView.useDelegate(
                  controller: _controller,
                  itemExtent: _itemExtent,
                  diameterRatio: 100,
                  physics: const FixedExtentScrollPhysics(),
                  onSelectedItemChanged: _onSelected,
                  childDelegate: ListWheelChildBuilderDelegate(
                    childCount: widget.max - widget.min + 1,
                    builder: (context, i) {
                      final selected = widget.min + i == _current;
                      return RotatedBox(
                        quarterTurns: 1,
                        child: Center(
                          child: Text(
                            '${widget.min + i}',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              color: selected
                                  ? colors.textPrimary
                                  : colors.textTertiary,
                              fontSize: selected ? 17 : 12,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w500,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
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
      width: 8,
      height: 8,
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
            width: 8,
            height: 8,
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
