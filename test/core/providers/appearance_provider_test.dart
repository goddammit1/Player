import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/providers/appearance_provider.dart';

void main() {
  group('AppThemeMode', () {
    test('fixed не берёт цвета из обложки и рисует градиент', () {
      expect(AppThemeMode.fixed.paletteAlgorithm, isNull);
      expect(
        AppThemeMode.fixed.playerBackground,
        PlayerBackgroundStyle.gradient,
      );
    });

    test('dynamic — это Classic: прежний алгоритм и градиент', () {
      expect(AppThemeMode.dynamic.paletteAlgorithm, PaletteAlgorithm.classic);
      expect(
        AppThemeMode.dynamic.playerBackground,
        PlayerBackgroundStyle.gradient,
      );
    });

    test('perceptual использует перцептивную палитру и градиент', () {
      expect(
        AppThemeMode.perceptual.paletteAlgorithm,
        PaletteAlgorithm.perceptual,
      );
      expect(
        AppThemeMode.perceptual.playerBackground,
        PlayerBackgroundStyle.gradient,
      );
    });

    test('mesh и blur берут цвета из perceptual, меняют только фон плеера', () {
      expect(AppThemeMode.mesh.paletteAlgorithm, PaletteAlgorithm.perceptual);
      expect(AppThemeMode.mesh.playerBackground, PlayerBackgroundStyle.mesh);
      expect(AppThemeMode.blur.paletteAlgorithm, PaletteAlgorithm.perceptual);
      expect(AppThemeMode.blur.playerBackground, PlayerBackgroundStyle.blur);
    });

    test('имена fixed и dynamic не меняются: так они хранятся в БД', () {
      expect(AppThemeMode.fixed.name, 'fixed');
      expect(AppThemeMode.dynamic.name, 'dynamic');
    });
  });
}
