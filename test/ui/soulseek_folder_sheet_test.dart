// Шторка папки Soulseek: искомые треки — разделом над остальной папкой.
//
// Источник Soulseek не зарегистрирован — шторка не догружает папку и
// показывает переданные треки.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

import 'package:player/core/artwork_helper.dart';
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/widgets/soulseek_folder_sheet.dart';

class _FakePlayer extends Fake implements PlayerServiceInterface {
  List<String>? queue;
  int? startIndex;

  @override
  Stream<MediaItem?> get mediaItem => BehaviorSubject<MediaItem?>.seeded(null);

  @override
  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    queue = [for (final t in tracks) t.title];
    this.startIndex = startIndex;
  }
}

Track _t(String title) => Track(
  id: title,
  sourceId: 'soulseek',
  title: title,
  artist: 'Black Sabbath',
  extra: {
    'peerUsername': 'u',
    'remoteFilename': 'u\\Black Sabbath\\Best Of\\$title.flac',
  },
);

void main() {
  final tracks = [
    _t('War Pigs'),
    _t('Paranoid'),
    _t('Iron Man'),
    _t('Paranoid (Live)'),
  ];
  late _FakePlayer player;

  setUp(() {
    ArtworkHelper.disableDbReadsForTesting = true;
    player = _FakePlayer();
  });

  tearDown(() => ArtworkHelper.disableDbReadsForTesting = false);

  Future<void> pumpSheet(WidgetTester tester, List<Track> targets) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerServiceProvider.overrideWithValue(player)],
        child: MaterialApp(
          home: Scaffold(
            body: SoulseekFolderSheet(tracks: tracks, targets: targets),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  double y(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  testWidgets('targets come first, then the rest of the folder in order', (
    tester,
  ) async {
    await pumpSheet(tester, [tracks[1], tracks[3]]);

    final order = [
      'MATCHES',
      'Paranoid',
      'Paranoid (Live)',
      'REST OF FOLDER',
      'War Pigs',
      'Iron Man',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        y(tester, order[i]),
        greaterThan(y(tester, order[i - 1])),
        reason: '${order[i]} below ${order[i - 1]}',
      );
    }
    // Каждый трек — один раз.
    expect(find.text('Paranoid'), findsOneWidget);
  });

  testWidgets('tap on a target plays the folder from that track', (
    tester,
  ) async {
    await pumpSheet(tester, [tracks[1]]);
    await tester.tap(find.text('Paranoid'));
    await tester.pump();

    expect(player.queue, [
      'War Pigs',
      'Paranoid',
      'Iron Man',
      'Paranoid (Live)',
    ]);
    expect(player.startIndex, 1);
  });

  testWidgets('no targets — plain folder without section labels', (
    tester,
  ) async {
    await pumpSheet(tester, const []);

    expect(find.text('MATCHES'), findsNothing);
    expect(find.text('REST OF FOLDER'), findsNothing);
    expect(y(tester, 'Iron Man'), greaterThan(y(tester, 'Paranoid')));
    expect(y(tester, 'Paranoid'), greaterThan(y(tester, 'War Pigs')));
  });
}
