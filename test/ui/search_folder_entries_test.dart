import 'package:flutter_test/flutter_test.dart';
import 'package:player/models/track.dart';
import 'package:player/ui/pages/search/search_folder_tiles.dart';
import 'package:player/ui/widgets/soulseek_folder_sheet.dart';

Track _t(String id, {String? folder, String remote = r'u\Artist\Album\x.flac'}) =>
    Track(
      id: id,
      sourceId: 'soulseek',
      title: id,
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
}
