// lib/ui/pages/player/player_title_scroller.dart
//
// Бегущая строка заголовка трека (marquee), если текст шире доступной ширины.
// Вынесена из player_page.dart (декомпозиция монолита, план §1.3).

import 'package:marquee/marquee.dart';
import 'package:flutter/material.dart';

import '../../../core/global_theme_provider.dart';

class PlayerTitleScroller extends StatelessWidget {
  const PlayerTitleScroller({super.key, required this.text, required this.colors});
  final String text;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: colors.textPrimary,
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    );

    return SizedBox(
      height: 30,
      child: LayoutBuilder(
        builder: (_, c) {
          final tp = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          if (tp.width <= c.maxWidth) {
            return Center(child: Text(text, maxLines: 1, style: style));
          }
          return Marquee(
            text: text,
            style: style,
            scrollAxis: Axis.horizontal,
            blankSpace: 60,
            velocity: 30,
            pauseAfterRound: const Duration(seconds: 2),
            startPadding: 0,
            accelerationDuration: const Duration(milliseconds: 400),
            accelerationCurve: Curves.easeOut,
            decelerationDuration: const Duration(milliseconds: 400),
            decelerationCurve: Curves.easeIn,
            fadingEdgeStartFraction: 0.06,
            fadingEdgeEndFraction: 0.06,
          );
        },
      ),
    );
  }
}