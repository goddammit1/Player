import 'dart:async';

import 'package:player/ui/widgets/artwork.dart';

/// Глобальная настройка всех тестов в test/.
///
/// ART-LAZY-01: Artwork с artist/title лениво ищет обложку через
/// ArtworkProvider (SQLite + Genius/iTunes). В fake-async виджет-тестах это
/// вешает тест или оставляет pending timers, поэтому по умолчанию поиск
/// выключен; тесты ленивой загрузки включают его сами через
/// LazyArtworkLoader.instance.resolverOverride / enabled.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  LazyArtworkLoader.instance.enabled = false;
  await testMain();
}
