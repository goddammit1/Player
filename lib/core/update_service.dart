import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppRelease {
  const AppRelease({
    required this.version,
    required this.name,
    required this.notes,
    required this.apkUrl,
    required this.pageUrl,
  });

  final String version;
  final String name;
  final String notes;
  final String apkUrl;
  final String pageUrl;
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

enum InstallOutcome { started, permissionRequired }

class UpdateService {
  UpdateService._();

  static const repository = 'goddammit1/Player';
  static const _installChannel = MethodChannel('player/app_update');

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Player-Android-Updater',
      },
    ),
  );

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
          apkUrl: '',
          pageUrl: '',
        ),
        updateAvailable: false,
      );
    }

    final response = await _dio.get<Map<String, dynamic>>(
      'https://api.github.com/repos/$repository/releases/latest',
    );
    final data = response.data;
    if (response.statusCode != 200 || data == null) {
      throw StateError('GitHub returned HTTP ${response.statusCode}.');
    }

    final assets = data['assets'];
    String? apkUrl;
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name']?.toString() ?? '';
        final url = asset['browser_download_url']?.toString() ?? '';
        if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) {
          apkUrl = url;
          break;
        }
      }
    }

    if (apkUrl == null) {
      throw StateError('The latest GitHub release does not contain an APK.');
    }

    final tag = data['tag_name']?.toString().trim() ?? '';
    if (tag.isEmpty) {
      throw StateError('The latest GitHub release has no version tag.');
    }

    final release = AppRelease(
      version: tag.replaceFirst(RegExp(r'^v', caseSensitive: false), ''),
      name: data['name']?.toString().trim() ?? '',
      notes: data['body']?.toString().trim() ?? '',
      apkUrl: apkUrl,
      pageUrl: data['html_url']?.toString() ?? '',
    );

    return UpdateCheckResult(
      currentVersion: packageInfo.version,
      release: release,
      updateAvailable:
          _compareVersions(release.version, packageInfo.version) > 0,
    );
  }

  /// Скачивает APK один раз и кэширует его во временной папке.
  /// Если файл этого же релиза уже загружен — переиспользуем его,
  /// чтобы возврат из системных настроек не запускал скачивание заново.
  static Future<String> download(
    AppRelease release, {
    required void Function(double progress) onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'In-app installation is available only on Android.',
      );
    }

    final tempDirectory = await getTemporaryDirectory();
    final sep = Platform.pathSeparator;
    final apk = File(
      '${tempDirectory.path}${sep}player-update-${release.version}.apk',
    );

    // Уже скачан валидный APK этого релиза — не качаем повторно.
    if (await apk.exists() && await apk.length() > 0) {
      onProgress(1);
      return apk.path;
    }

    // Чистим устаревшие/битые файлы.
    final legacy = File('${tempDirectory.path}${sep}player-update.apk');
    if (await legacy.exists()) await legacy.delete();
    final partial = File('${apk.path}.part');
    if (await partial.exists()) await partial.delete();

    await _dio.download(
      release.apkUrl,
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
      throw StateError('The downloaded APK is empty.');
    }

    // Переименовываем только полностью скачанный файл — так в кэше
    // никогда не окажется обрезанный APK, пригодный для переиспользования.
    await partial.rename(apk.path);
    return apk.path;
  }

  /// Запускает установку уже скачанного APK. Возвращает [InstallOutcome]:
  /// либо установщик открыт, либо система увела за разрешением
  /// «Установка неизвестных приложений» (файл при этом сохранён).
  static Future<InstallOutcome> install(String apkPath) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'In-app installation is available only on Android.',
      );
    }

    final status = await _installChannel.invokeMethod<String>(
      'installApk',
      {'path': apkPath},
    );
    return status == 'permissionRequired'
        ? InstallOutcome.permissionRequired
        : InstallOutcome.started;
  }

  static int _compareVersions(String left, String right) {
    List<int> parse(String value) {
      final clean = value
          .replaceFirst(RegExp(r'^v', caseSensitive: false), '')
          .split(RegExp(r'[-+]'))
          .first;
      final parts = clean.split('.');
      return List<int>.generate(
        3,
        (index) => index < parts.length ? int.tryParse(parts[index]) ?? 0 : 0,
      );
    }

    final a = parse(left);
    final b = parse(right);
    for (var index = 0; index < 3; index++) {
      if (a[index] != b[index]) return a[index].compareTo(b[index]);
    }
    return 0;
  }
}
