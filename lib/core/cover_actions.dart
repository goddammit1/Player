// lib/core/cover_actions.dart
//
// Смена / сброс обложки трека пользователем. Общие для мобильного
// PlayerPage (PlayerInteractiveArtwork) и десктопной вкладки «Track».

import 'artwork_helper.dart';
import 'player_service_interface.dart';

abstract final class CoverActions {
  /// Есть ли у трека кастомная обложка (тогда доступен [reset]).
  static bool hasCustom(String trackId) =>
      ArtworkHelper.getCustomArtworkSync(trackId) != null;

  /// Выбор картинки → сохранение на диск → обновление очереди, MediaItem
  /// (перерасчёт палитры) и репозиториев. `false` — пользователь отменил
  /// выбор или сохранить не удалось.
  static Future<bool> change(
    PlayerServiceInterface player,
    String trackId,
  ) async {
    final newPath = await ArtworkHelper.pickAndSaveArtwork(trackId);
    if (newPath == null) return false;
    await player.updateCustomArtwork(trackId, newPath);
    return true;
  }

  /// Возвращает оригинальную обложку источника.
  static Future<void> reset(PlayerServiceInterface player, String trackId) =>
      player.resetCustomArtwork(trackId);
}
