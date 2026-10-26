import 'package:flutter_test/flutter_test.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/pages/search/search_folder_tiles.dart';
import 'package:player/ui/widgets/soulseek_folder_sheet.dart';

Track _t(
  String id, {
  String? folder,
  String remote = r'u\Artist\Album\x.flac',
  String? title,
}) =>
    Track(
      id: id,
      sourceId: 'soulseek',
      title: title ?? id,
      artist: 'Artist',
      extra: {
        'peerUsername': 'u',
        'remoteFilename': remote,
        'folderKey': ?folder,
      },
    );

void main() {
  test('groupSearchEntries folds folder tracks at the first track position',
      () {
    final entries = groupSearchEntries([
      _t('a', folder: 'f1'),
      _t('s1'),
      _t('b', folder: 'f1'),
      _t('c', folder: 'f2'),
      _t('s2'),
    ]);
    expect(entries.map((e) => e.isFolder), [true, false, true, false]);
    expect(entries[0].tracks.map((t) => t.id), ['a', 'b']);
    expect(entries[1].tracks.single.id, 's1');
    expect(entries[2].tracks.single.id, 'c');
  });

  test('SoulseekFolderInfo: folder name, disc folders get the parent', () {
    expect(SoulseekFolderInfo.of([_t('a')]).name, 'Album');
    expect(
      SoulseekFolderInfo.of([_t('a', remote: r'u\Album (2010)\CD1\01.flac')])
          .name,
      'Album (2010) · CD1',
    );
  });

  group('folderFocusIndex', () {
    List<Track> album(List<String> titles) => [
          for (final (i, t) in titles.indexed) _t('$i', folder: 'f', title: t),
        ];

    test('title track of an album is found, not the first track', () {
      final tracks = album([
        'Battery',
        'Master of Puppets',
        'The Thing That Should Not Be',
      ]);
      expect(folderFocusIndex(tracks, 'Metallica - Master of Puppets'), 1);
    });

    test('album search without a matching title → null', () {
      final tracks = album(['Speak to Me', 'Breathe', 'Time']);
      expect(
          folderFocusIndex(tracks, 'Pink Floyd Dark Side of the Moon'), isNull);
      expect(folderFocusIndex(tracks, ''), isNull);
    });

    test('longest fully matched title wins over a shorter one', () {
      final tracks = album(['Love', 'Whole Lotta Love', 'Ramble On']);
      expect(folderFocusIndex(tracks, 'Led Zeppelin Whole Lotta Love'), 1);
    });

    test('brackets, track numbers and case are ignored; extras break ties',
        () {
      final tracks = album([
        '01 Intro',
        'Paranoid (Live)',
        'PARANOID [2009 Remaster]',
        'Paranoid',
      ]);
      expect(folderFocusIndex(tracks, 'black sabbath paranoid'), 3);
      expect(folderFocusIndex(tracks, 'black sabbath paranoid live'), 1);
      expect(folderFocusIndex(tracks, 'sabbath intro'), 0);
    });

    test('ё and е match', () {
      final tracks = album(['Всё идёт по плану', 'Моя оборона']);
      expect(
          folderFocusIndex(tracks, 'Гражданская оборона все идет по плану'), 0);
    });
  });

  test('groupSearchEntries sets focus of folders from the query', () {
    final entries = groupSearchEntries(
      [
        _t('a', folder: 'f1', title: 'Battery'),
        _t('b', folder: 'f1', title: 'Master of Puppets'),
        _t('s', title: 'Master of Puppets'),
      ],
      query: 'metallica master of puppets',
    );
    expect(entries[0].focus, 1);
    expect(entries[0].focusTrack!.id, 'b');
    expect(entries[1].focus, isNull);
  });
}
