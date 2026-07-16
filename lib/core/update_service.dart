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

  static Future<void> downloadAndInstall(
    AppRelease release, {
    required void Function(double progress) onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'In-app installation is available only on Android.',
      );
    }

    final tempDirectory = await getTemporaryDirectory();
    final apk = File(
      '${tempDirectory.path}${Platform.pathSeparator}player-update.apk',
    );
    if (await apk.exists()) await apk.delete();

    await _dio.download(
      release.apkUrl,
      apk.path,
      deleteOnError: true,
      options: Options(
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 10),
      ),
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );

    if (!await apk.exists() || await apk.length() == 0) {
      throw StateError('The downloaded APK is empty.');
    }

    await _installChannel.invokeMethod<void>('installApk', {'path': apk.path});
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
