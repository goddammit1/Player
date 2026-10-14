import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'windows_update_installer.dart';

class AppRelease {
  const AppRelease({
    required this.version,
    required this.name,
    required this.notes,
    required this.assetUrl,
    required this.pageUrl,
  });

  final String version;
  final String name;
  final String notes;

  /// Ссылка на пакет для текущей платформы: APK на Android, zip на Windows
  /// (см. [UpdateService.releaseAssetName]).
  final String assetUrl;
  final String pageUrl;

  /// Бета-релиз: версия манифеста (тег GitHub-релиза) содержит
  /// prerelease-суффикс «-beta» / «-b» (в т.ч. с нумерацией «-beta.2»).
  bool get isBeta =>
      RegExp(r'-(?:beta|b)(?:\.|$)', caseSensitive: false).hasMatch(version);
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.release,
    required this.updateAvailable,
  });

  final String currentVersion;
  final AppRelease release;
  final bool updateAvailable;
}

enum InstallOutcome {
  /// Android: системный установщик открыт.
  started,

  /// Android: система увела за разрешением «Установка неизвестных
  /// приложений»; файл сохранён.
  permissionRequired,

  /// Windows: файлы распакованы, скрипт замены запущен — приложение
  /// закрывается и перезапускается уже обновлённым.
  restarting,

  /// Windows: папка приложения недоступна на запись — обновить можно
  /// только вручную со страницы релиза.
  manualRequired,
}

class UpdateService {
  UpdateService._();

  static const repository = 'goddammit1/Player';
  static const _installChannel = MethodChannel('player/app_update');

  static final Dio _prodDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Player-Updater',
      },
    ),
  );

  static Dio? _testDio;

  /// HTTP-клиент сервиса. В тестах подменяется через
  /// [setDioForTesting], чтобы не ходить в реальный GitHub API.
  static Dio get _dio => _testDio ?? _prodDio;

  /// Подменяет HTTP-клиент для юнит-тестов [check] (mock-Dio);
  /// `null` — вернуть продакшн-клиент.
  @visibleForTesting
  static void setDioForTesting(Dio? dio) => _testDio = dio;

  /// Имя пакета обновления в GitHub-релизе для Windows: результат
  /// `tools/build_windows.ps1 -Zip`.
  static const windowsAssetName = 'player-windows-x64.zip';

  /// Имя пакета обновления для Android: канонический fat APK.
  static const androidAssetName = 'app-release.apk';

  static String? _assetNameOverride;

  /// Подменяет платформу в [releaseAssetName] (тесты идут на Windows-хосте,
  /// а проверяют и APK-сценарий); `null` — по текущей платформе.
  @visibleForTesting
  static void setAssetNameForTesting(String? name) =>
      _assetNameOverride = name;

  /// Какой ассет релиза нужен текущей платформе.
  static String get releaseAssetName =>
      _assetNameOverride ??
      (Platform.isWindows ? windowsAssetName : androidAssetName);

  static Future<UpdateCheckResult> check() async {
    final packageInfo = await PackageInfo.fromPlatform();

    // На iOS in-app обновления не поддерживаются (используется App Store).
    // Возвращаем фиктивный результат без попытки стучаться в GitHub API.
    if (Platform.isIOS) {
      return UpdateCheckResult(
        currentVersion: packageInfo.version,
        release: const AppRelease(
          version: '',
          name: '',
          notes: '',
          assetUrl: '',
          pageUrl: '',
        ),
        updateAvailable: false,
      );
    }

    // `releases/latest` never returns prereleases (nor drafts), so a
    // release published as a GitHub prerelease was invisible to the
    // updater. List recent releases instead: GitHub sorts them by
    // creation date descending (prereleases included), and the first
    // published (non-draft) entry is the newest release.
    final response = await _dio.get<List<dynamic>>(
      'https://api.github.com/repos/$repository/releases?per_page=10',
    );
    final releases = response.data;
    if (response.statusCode != 200 || releases == null) {
      throw StateError('GitHub returned HTTP ${response.statusCode}.');
    }

    Map<String, dynamic>? data;
    for (final entry in releases) {
      if (entry is! Map) continue;
      if (entry['draft'] == true) continue;
      data = Map<String, dynamic>.from(entry);
      break;
    }
    if (data == null) {
      throw StateError('GitHub returned no published releases.');
    }

    final assetName = releaseAssetName;
    final assets = data['assets'];
    String? assetUrl;
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name']?.toString() ?? '';
        final url = asset['browser_download_url']?.toString() ?? '';
        // Only use the canonical package (fat APK / Windows zip) so
        // architecture and signing always match the locally built release
        // artifact.
        if (name.toLowerCase() == assetName && url.isNotEmpty) {
          assetUrl = url;
          break;
        }
      }
    }

    if (assetUrl == null) {
      throw StateError(
        'The newest GitHub release does not contain $assetName. '
        'Make sure the release artifact is named exactly $assetName.',
      );
    }

    final tag = data['tag_name']?.toString().trim() ?? '';
    if (tag.isEmpty) {
      throw StateError('The newest GitHub release has no version tag.');
    }

    final release = AppRelease(
      version: tag.replaceFirst(RegExp(r'^v', caseSensitive: false), ''),
      name: data['name']?.toString().trim() ?? '',
      notes: data['body']?.toString().trim() ?? '',
      assetUrl: assetUrl,
      pageUrl: data['html_url']?.toString() ?? '',
    );

    return UpdateCheckResult(
      currentVersion: packageInfo.version,
      release: release,
      updateAvailable:
          compareVersions(release.version, packageInfo.version) > 0,
    );
  }

  /// Скачивает пакет обновления (APK / zip) один раз и кэширует его во
  /// временной папке. Если файл этого же релиза уже загружен —
  /// переиспользуем его, чтобы возврат из системных настроек не запускал
  /// скачивание заново.
  static Future<String> download(
    AppRelease release, {
    required void Function(double progress) onProgress,
  }) async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      throw UnsupportedError(
        'In-app installation is available only on Android and Windows.',
      );
    }

    final tempDirectory = await getTemporaryDirectory();
    final sep = Platform.pathSeparator;
    final ext = Platform.isWindows ? 'zip' : 'apk';
    final package = File(
      '${tempDirectory.path}${sep}player-update-${release.version}.$ext',
    );

    // Уже скачан валидный пакет этого релиза — не качаем повторно.
    if (await package.exists() && await package.length() > 0) {
      onProgress(1);
      return package.path;
    }

    // Чистим устаревшие/битые файлы.
    final legacy = File('${tempDirectory.path}${sep}player-update.apk');
    if (await legacy.exists()) await legacy.delete();
    final partial = File('${package.path}.part');
    if (await partial.exists()) await partial.delete();

    await _dio.download(
      release.assetUrl,
      partial.path,
      deleteOnError: true,
      options: Options(
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 10),
      ),
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );

    if (!await partial.exists() || await partial.length() == 0) {
      throw StateError('The downloaded update package is empty.');
    }

    // Переименовываем только полностью скачанный файл — так в кэше
    // никогда не окажется обрезанный пакет, пригодный для переиспользования.
    await partial.rename(package.path);
    return package.path;
  }

  /// Запускает установку уже скачанного пакета. Android: либо установщик
  /// открыт, либо система увела за разрешением «Установка неизвестных
  /// приложений» (файл при этом сохранён). Windows: см.
  /// [WindowsUpdateInstaller.install].
  static Future<InstallOutcome> install(String packagePath) async {
    if (Platform.isWindows) {
      return WindowsUpdateInstaller().install(packagePath);
    }
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'In-app installation is available only on Android.',
      );
    }

    final status = await _installChannel.invokeMethod<String>(
      'installApk',
      {'path': packagePath},
    );
    return status == 'permissionRequired'
        ? InstallOutcome.permissionRequired
        : InstallOutcome.started;
  }

  /// Semver-совместимое сравнение версий с учётом prerelease-тегов:
  /// `3.0.0-beta > 2.5.2`, `3.0.0 > 3.0.0-beta`,
  /// `3.0.0-beta.2 > 3.0.0-beta.1`. Build-метаданные (`+31`)
  /// игнорируются, ведущий `v` срезается.
  static int compareVersions(String left, String right) {
    final a = _ParsedVersion.parse(left);
    final b = _ParsedVersion.parse(right);
    for (var index = 0; index < 3; index++) {
      if (a.core[index] != b.core[index]) {
        return a.core[index].compareTo(b.core[index]);
      }
    }
    // Одинаковые x.y.z: stable-версия старше любой prerelease-версии.
    if (a.prerelease.isEmpty && b.prerelease.isEmpty) return 0;
    if (a.prerelease.isEmpty) return 1;
    if (b.prerelease.isEmpty) return -1;
    return _comparePrerelease(a.prerelease, b.prerelease);
  }

  /// Сравнение prerelease-идентификаторов по правилам semver: числовые
  /// сравниваются численно и младше строковых, строки — лексикографически;
  /// при равном префиксе более длинный список идентификаторов старше.
  static int _comparePrerelease(List<String> a, List<String> b) {
    final common = a.length < b.length ? a.length : b.length;
    for (var index = 0; index < common; index++) {
      final left = a[index];
      final right = b[index];
      if (left == right) continue;
      final leftNum = int.tryParse(left);
      final rightNum = int.tryParse(right);
      if (leftNum != null && rightNum != null) {
        return leftNum.compareTo(rightNum);
      }
      if (leftNum != null) return -1;
      if (rightNum != null) return 1;
      return left.compareTo(right);
    }
    return a.length.compareTo(b.length);
  }
}

class _ParsedVersion {
  const _ParsedVersion(this.core, this.prerelease);

  final List<int> core;
  final List<String> prerelease;

  factory _ParsedVersion.parse(String value) {
    var clean = value
        .trim()
        .replaceFirst(RegExp(r'^v', caseSensitive: false), '');
    // Build-метаданные («+31») не влияют на порядок версий.
    final plus = clean.indexOf('+');
    if (plus >= 0) clean = clean.substring(0, plus);
    // Отделяем prerelease-часть («-beta.2») от основной версии.
    var prerelease = const <String>[];
    final dash = clean.indexOf('-');
    if (dash >= 0) {
      final tail = clean.substring(dash + 1).trim();
      if (tail.isNotEmpty) prerelease = tail.split('.');
      clean = clean.substring(0, dash);
    }
    final parts = clean.split('.');
    return _ParsedVersion(
      List<int>.generate(
        3,
        (index) => index < parts.length ? int.tryParse(parts[index]) ?? 0 : 0,
      ),
      prerelease,
    );
  }
}
