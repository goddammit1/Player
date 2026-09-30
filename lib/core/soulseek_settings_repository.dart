// lib/core/soulseek_settings_repository.dart
//
// Фаза A (SQLite-миграция настроек Soulseek).
//
// Все настройки Soulseek (кроме пароля) переведены с SharedPreferences на
// SQLite (player_data.db, key-value таблица `settings`). Паттерн — как у
// SettingsDao / SearchViewModeNotifier: ленивый load и точечные save через
// `AppDatabase.instance.getSetting / setSetting`.
//
// - Пароль по-прежнему ТОЛЬКО в flutter_secure_storage (SoulseekCredentials).
// - Несекретный username тоже хранится в БД (ключ `soulseek_username`) —
//   см. SoulseekCredentials.save / loadUsernameQuick.
// - soulseek_cache_index (индекс кэша в SharedPreferences) намеренно НЕ
//   затрагивается: это данные кэша, а не настройки.
//
// Разрыв №2: [applyToSource] применяется и на старте приложения (main.dart,
// сразу после registerDefaults), и со страницы настроек — фильтры поиска
// работают после рестарта без открытия страницы настроек.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sources/soulseek_models.dart';
import '../sources/soulseek_platform_channel.dart';
import '../sources/soulseek_source.dart';
import 'database/app_database.dart';

/// Типизированный снапшот настроек Soulseek.
///
/// Значения по умолчанию перенесены из бывшего класса `SoulseekPrefs`
/// (lib/ui/pages/soulseek_settings_page.dart) без изменений.
class SoulseekSettings {
  final bool enabled;
  final int listenPort;
  final int cacheLimitMB;
  final int maxParallelDownloads;
  final bool preferLossless;
  final Set<String> allowedFormats;
  final int maxFileSizeMB;
  final int searchTimeoutSec;
  final String sharingDirectory;

  const SoulseekSettings({
    this.enabled = false,
    this.listenPort = SoulseekSettingsRepository.defaultListenPort,
    this.cacheLimitMB = SoulseekSettingsRepository.defaultCacheLimitMB,
    this.maxParallelDownloads =
        SoulseekSettingsRepository.defaultMaxParallelDownloads,
    this.preferLossless = SoulseekSettingsRepository.defaultPreferLossless,
    this.allowedFormats = const {},
    this.maxFileSizeMB = SoulseekSettingsRepository.defaultMaxFileSizeMB,
    this.searchTimeoutSec = SoulseekSettingsRepository.defaultSearchTimeoutSec,
    this.sharingDirectory = '',
  });
}

/// Репозиторий настроек Soulseek поверх SQLite (таблица `settings`).
///
/// Синглтон по образцу SettingsDao. Несекретные значения; секретный пароль
/// живёт в flutter_secure_storage и сюда не попадает.
class SoulseekSettingsRepository {
  SoulseekSettingsRepository._();

  static final SoulseekSettingsRepository instance =
      SoulseekSettingsRepository._();

  // ── Ключи в таблице settings ──
  static const String keyEnabled = 'soulseek_enabled';
  static const String keyListenPort = 'soulseek_listen_port';
  static const String keyCacheLimitMB = 'soulseek_cache_limit_mb';
  static const String keyMaxParallelDownloads = 'soulseek_max_parallel_downloads';
  static const String keyPreferLossless = 'soulseek_prefer_lossless';
  static const String keyAllowedFormats = 'soulseek_allowed_formats';
  static const String keyMaxFileSizeMB = 'soulseek_max_file_size_mb';
  static const String keySearchTimeoutSec = 'soulseek_search_timeout_sec';
  static const String keySharingDirectory = 'soulseek_sharing_directory';

  // ── Дефолты (как в бывшем SoulseekPrefs) ──
  static const int defaultListenPort = 24150;
  static const int defaultCacheLimitMB = 1024;
  static const int defaultMaxParallelDownloads = 3;
  static const bool defaultPreferLossless = false;
  static const String defaultAllowedFormats = 'flac,wav,alac,mp3,aac,ogg';
  static const int defaultMaxFileSizeMB = 0; // 0 = unlimited
  /// Жёсткий общий бюджет поиска (обычно поиск завершается раньше —
  /// по окну тишины или лимиту файлов, см. SoulseekSource).
  static const int defaultSearchTimeoutSec = 10;

  /// Legacy-ключи SharedPreferences, перенесённые в БД миграцией v3.
  ///
  /// `soulseek_cache_index` сюда НЕ входит: это индекс кэша, а не настройка.
  static const List<String> legacyPrefKeys = [
    keyEnabled,
    keyListenPort,
    keyCacheLimitMB,
    keyMaxParallelDownloads,
    keyPreferLossless,
    keyAllowedFormats,
    keyMaxFileSizeMB,
    keySearchTimeoutSec,
    keySharingDirectory,
    'soulseek_username_display',
  ];

  // ── Чтение ──

  Future<bool> _readBool(String key, bool fallback) async {
    final raw = await AppDatabase.instance.getSetting(key);
    if (raw == null) return fallback;
    return raw == 'true' || raw == '1';
  }

  Future<int> _readInt(String key, int fallback) async {
    final raw = await AppDatabase.instance.getSetting(key);
    final value = raw == null ? null : int.tryParse(raw);
    return value ?? fallback;
  }

  Future<String> _readString(String key, String fallback) async {
    return await AppDatabase.instance.getSetting(key) ?? fallback;
  }

  /// Загружает все настройки из БД (с дефолтами при отсутствии значений).
  Future<SoulseekSettings> loadAll() async {
    final formatsRaw =
        await _readString(keyAllowedFormats, defaultAllowedFormats);
    return SoulseekSettings(
      enabled: await _readBool(keyEnabled, false),
      listenPort: await _readInt(keyListenPort, defaultListenPort),
      cacheLimitMB: await _readInt(keyCacheLimitMB, defaultCacheLimitMB),
      maxParallelDownloads:
          await _readInt(keyMaxParallelDownloads, defaultMaxParallelDownloads),
      preferLossless: await _readBool(keyPreferLossless, defaultPreferLossless),
      allowedFormats: formatsRaw
          .split(',')
          .where((s) => s.isNotEmpty)
          .toSet(),
      maxFileSizeMB: await _readInt(keyMaxFileSizeMB, defaultMaxFileSizeMB),
      searchTimeoutSec:
          await _readInt(keySearchTimeoutSec, defaultSearchTimeoutSec),
      sharingDirectory: await _readString(keySharingDirectory, ''),
    );
  }

  /// Текущее значение feature flag Soulseek (дефолт — false).
  Future<bool> isEnabled() => _readBool(keyEnabled, false);

  // ── Запись (точечная, по одному ключу) ──

  Future<void> setEnabled(bool value) =>
      AppDatabase.instance.setSetting(keyEnabled, value.toString());

  /// set-методы натив-релевантных ключей (порт/кэш/параллелизм) после
  /// записи в Dart-БД проталкивают значения в нативную soulseek.db —
  /// см. [syncToNative] (Фаза B, разрыв №3).

  Future<void> setListenPort(int value) async {
    await AppDatabase.instance.setSetting(keyListenPort, value.toString());
    await syncToNative();
  }

  Future<void> setCacheLimitMB(int value) async {
    await AppDatabase.instance.setSetting(keyCacheLimitMB, value.toString());
    await syncToNative();
  }

  Future<void> setMaxParallelDownloads(int value) async {
    await AppDatabase.instance
        .setSetting(keyMaxParallelDownloads, value.toString());
    await syncToNative();
  }

  Future<void> setPreferLossless(bool value) =>
      AppDatabase.instance.setSetting(keyPreferLossless, value.toString());

  Future<void> setAllowedFormats(Set<String> formats) =>
      AppDatabase.instance.setSetting(keyAllowedFormats, formats.join(','));

  Future<void> setMaxFileSizeMB(int value) =>
      AppDatabase.instance.setSetting(keyMaxFileSizeMB, value.toString());

  Future<void> setSearchTimeoutSec(int value) =>
      AppDatabase.instance.setSetting(keySearchTimeoutSec, value.toString());

  Future<void> setSharingDirectory(String value) =>
      AppDatabase.instance.setSetting(keySharingDirectory, value);

  // ── Применение к источнику ──

  /// Строит поисковые фильтры из настроек (логика бывшего
  /// `_applyFiltersToSource` страницы настроек).
  ///
  /// Пустой набор форматов и maxFileSizeMB == 0 означают «без ограничения».
  @visibleForTesting
  SoulseekSearchFilters buildFilters(SoulseekSettings settings) {
    final extensions = settings.allowedFormats.toList(growable: false);
    return SoulseekSearchFilters(
      extensions: extensions.isNotEmpty ? extensions : null,
      maxSizeBytes: settings.maxFileSizeMB > 0
          ? settings.maxFileSizeMB * 1024 * 1024
          : null,
      losslessOnly: settings.preferLossless,
    );
  }

  /// Применяет настройки к [source]: поисковые фильтры + таймаут поиска.
  ///
  /// Если [settings] не переданы — лениво читаются из БД. Вызывается на
  /// старте приложения (устранение разрыва №2) и со страницы настроек.
  Future<void> applyToSource(
    SoulseekSource source, {
    SoulseekSettings? settings,
  }) async {
    final s = settings ?? await loadAll();
    source.searchFilters = buildFilters(s);
    source.applySearchTimeoutSec(s.searchTimeoutSec);
  }

  // ── Синк в нативную soulseek.db (Фаза B, разрыв №3) ──

  /// Ключ username в Dart-БД (пишется SoulseekCredentials.save; константа
  /// продублирована, чтобы не тянуть flutter_secure_storage в этот файл).
  static const String dbKeyUsername = 'soulseek_username';

  /// Проталкивает натив-релевантные настройки (listen port, лимит кэша,
  /// параллелизм, username) из Dart-БД в нативную soulseek.db, чтобы
  /// foreground service работал с теми же значениями, что показывает UI
  /// (устранение разрыва №3: LRU eviction / параллелизм / порт раньше
  /// всегда жили на нативных дефолтах).
  ///
  /// Натив пишет в soulseek.db БЕЗ старта foreground service; если сервис
  /// уже запущен — применяет лимит кэша на лету. Единицы: лимит кэша
  /// передаётся в MB и конвертируется в байты на Kotlin-стороне
  /// (soulseek.db хранит `max_cache_size` в байтах; 0 = unlimited).
  ///
  /// Best-effort: на не-Android — no-op; ошибки платформы логируются и
  /// глотаются (значения уже сохранены в Dart-БД вызывающим кодом).
  ///
  /// [username] переопределяет значение из БД (например, сразу после
  /// сохранения кредов); null/empty — username не отправляется.
  Future<void> syncToNative({String? username}) async {
    try {
      final channel = SoulseekPlatformChannel.instance;
      if (!channel.isAvailable) return;
      final s = await loadAll();
      final storedUsername =
          username ?? await AppDatabase.instance.getSetting(dbKeyUsername);
      await channel.updateNativeSettings(
        listenPort: s.listenPort,
        cacheLimitMb: s.cacheLimitMB,
        maxParallelDownloads: s.maxParallelDownloads,
        username: (storedUsername != null && storedUsername.isNotEmpty)
            ? storedUsername
            : null,
      );
    } catch (e) {
      debugPrint('[SoulseekSettings] native sync skipped: $e');
    }
  }

  // ── Одноразовая очистка legacy SharedPreferences (миграция v3) ──

  /// Удаляет legacy soulseek_* ключи из SharedPreferences после того, как
  /// миграция v3 (см. AppDatabase.migrateFromSharedPreferences) перенесла
  /// их в БД. Идемпотентна: пока флаг `migration_v3_soulseek` не стоит в
  /// БД, ничего не делает. Индекс кэша (soulseek_cache_index) не трогает.
  static Future<void> purgeLegacySoulseekPrefs() async {
    try {
      final flag = await AppDatabase.instance
          .getSetting(AppDatabase.migrationV3SoulseekFlag);
      if (flag != '1') return;
      final prefs = await SharedPreferences.getInstance();
      for (final key in legacyPrefKeys) {
        await prefs.remove(key);
      }
    } catch (e) {
      // best-effort: ключи будут удалены при следующем запуске.
      debugPrint('[SoulseekSettings] legacy prefs purge skipped: $e');
    }
  }
}
