import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/muzmo_source.dart';

void main() {
  late MuzmoSource s;
  setUp(() => s = MuzmoSource());
  tearDown(() => s.dispose());

  // Реальная структура HTML со страницы rmr.muzmo.cc/search:
  // tr.item-song > td.play[data-file][data-title]
  String row(String file, String title,
      {String? b, String? br, String? t, String? getNew}) {
    return '<tr class="item-song">'
        '<td class="play" data-file="$file" data-title="$title"></td>'
        '${b!=null||br!=null?'<td class="artist-title"><a class="block">${b!=null?'<b>$b</b>':''}${br!=null?'<br>$br':''}</a></td>':''}'
        '${t!=null?'<td class="song-time"><small>$t</small></td>':''}'
        '${getNew!=null?'<td><a class="block" href="$getNew"></a></td>':''}'
        '</tr>';
  }

  /// Оборачивает row в минимально-валидный фрагмент с <table>.
  String html(String body) => '<table><tbody>$body</tbody></table>';

  group('parseTracks', () {
    test('dash separator + duration', () {
      final r = s.parseTracks(html(row('https://x.com/m.mp3', 'Rick - Song', t: '3:33')));
      expect(r.length, 1);
      expect(r.first.artist, 'Rick');
      expect(r.first.title, 'Song');
      expect(r.first.duration, const Duration(minutes: 3, seconds: 33));
      expect(r.first.extra['streamUrl'], 'https://x.com/m.mp3');
    });

    test('em-dash', () =>
        expect(s.parseTracks(html(row('https://x.com/m.mp3', 'Р — Б'))).first.artist, 'Р'));

    test('en-dash', () =>
        expect(s.parseTracks(html(row('https://x.com/m.mp3', 'C – D'))).first.artist, 'C'));

    test('<b> overrides data-title', () =>
        expect(s.parseTracks(html(row('https://x.com/m.mp3', 'W', b: 'Real', br: 'RT'))).first.artist, 'Real'));

    test('hh:mm:ss', () =>
        expect(s.parseTracks(html(row('https://x.com/m.mp3', 'DJ - M', t: '1:02:33'))).first.duration,
            const Duration(hours: 1, minutes: 2, seconds: 33)));

    test('empty title skip', () =>
        expect(s.parseTracks(html(row('https://x.com/m.mp3', '- '))), isEmpty));

    test('empty stream skip', () =>
        expect(s.parseTracks(html('<tr class="item-song"><td class="play"></td></tr>')), isEmpty));

    test('multiple', () =>
        expect(s.parseTracks(html(row('https://a.mp3','A1 - T1')+row('https://b.mp3','A2 - T2'))).length, 2));
  });

  group('normalizeUrl', () {
    test('absolute', () => expect(s.normalizeUrl('https://x.com/f.mp3'), 'https://x.com/f.mp3'));
    test('protocol-relative', () => expect(s.normalizeUrl('//x.com/f.mp3'), 'https://x.com/f.mp3'));
    test('relative', () => expect(s.normalizeUrl('/a'), contains('rmr.muzmo.cc')));
  });

  group('parseDuration', () {
    test('mm:ss', () => expect(s.parseDuration('4:20'), const Duration(minutes: 4, seconds: 20)));
    test('hh:mm:ss', () => expect(s.parseDuration('1:15:30'),
        const Duration(hours: 1, minutes: 15, seconds: 30)));
    test('invalid', () {expect(s.parseDuration(''), isNull); expect(s.parseDuration('bad'), isNull);});
  });
}

