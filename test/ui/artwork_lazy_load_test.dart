// ART-LAZY-01: Artwork без url сам подгружает обложку по artist/title,
// когда плитка появляется на экране, — не дожидаясь воспроизведения трека.
//
// Поиск подменяется через LazyArtworkLoader.resolverOverride (без SQLite
// и сети); найденный «URL» — локальный путь, чтобы Artwork рендерил
// Image.file без CachedNetworkImage.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:player/ui/widgets/artwork.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  final loader = LazyArtworkLoader.instance;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    loader.enabled = true;
    loader.resolverOverride = (artist, title) async {
      calls.add('$artist|$title');
      return '/lazy/$artist-$title.jpg';
    };
  });

  tearDown(() {
    loader.resolverOverride = null;
    loader.enabled = false;
  });

  testWidgets('без url обложка ищется по artist/title сразу при показе',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const Artwork(url: null, artist: 'Artist', title: 'Song', size: 48),
    ));
    expect(find.byType(Image), findsNothing);

    await tester.pump();

    expect(calls, ['Artist|Song']);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('есть свой url — ленивый поиск не выполняется', (tester) async {
    await tester.pumpWidget(_wrap(
      const Artwork(
        url: '/own/cover.jpg',
        artist: 'Artist',
        title: 'Song',
        size: 48,
      ),
    ));
    await tester.pump();

    expect(calls, isEmpty);
  });

  testWidgets('без artist/title — прежний плейсхолдер, поиска нет',
      (tester) async {
    await tester.pumpWidget(_wrap(const Artwork(url: null, size: 48)));
    await tester.pump();

    expect(calls, isEmpty);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('переиспользованный под другой трек элемент ищет заново',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const Artwork(url: null, artist: 'A', title: 'One', size: 48),
    ));
    await tester.pump();
    await tester.pumpWidget(_wrap(
      const Artwork(url: null, artist: 'B', title: 'Two', size: 48),
    ));
    await tester.pump();

    expect(calls, ['A|One', 'B|Two']);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as FileImage).file.path, '/lazy/B-Two.jpg');
  });

  testWidgets('в длинном списке ищутся только построенные (видимые) плитки',
      (tester) async {
    await tester.pumpWidget(_wrap(
      ListView.builder(
        itemCount: 500,
        itemExtent: 56,
        itemBuilder: (_, i) => Artwork(
          url: null,
          artist: 'Artist',
          title: 'Song $i',
          size: 48,
        ),
      ),
    ));
    await tester.pump();

    expect(calls, isNotEmpty);
    expect(calls.length, lessThan(50));
    expect(calls, isNot(contains('Artist|Song 499')));
  });
}
