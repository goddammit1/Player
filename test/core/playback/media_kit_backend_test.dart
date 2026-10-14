// Формула boost десктопного бэкенда: гейн mpv = (v/100)³.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/media_kit_backend.dart';

double _gainDb(double mpvVolume) => 60 * math.log(mpvVolume / 100) / math.ln10;

void main() {
  test('no boost keeps the user volume', () {
    expect(mpvVolumeFor(1.0, 0), 100);
    expect(mpvVolumeFor(0.5, 0), 50);
    expect(mpvVolumeFor(0, 12), 0);
  });

  test('boost adds exactly N dB on top of the user volume', () {
    expect(_gainDb(mpvVolumeFor(1.0, 12)), closeTo(12, 1e-9));
    expect(_gainDb(mpvVolumeFor(1.0, 6)), closeTo(6, 1e-9));
    expect(_gainDb(mpvVolumeFor(0.5, 6)) - _gainDb(mpvVolumeFor(0.5, 0)),
        closeTo(6, 1e-9));
  });

  test('max boost fits under volume-max', () {
    expect(mpvVolumeFor(1.0, 12), lessThanOrEqualTo(mpvVolumeMax));
    expect(mpvVolumeFor(1.0, 30), mpvVolumeMax);
  });
}
