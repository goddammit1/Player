// lib/ui/widgets/back_button.dart
//
// Круглая кнопка «Назад» (chevron_left в тёмно-сером контейнере), как в
// шапке страницы настроек: Material-подложка цвета elevated + CircleBorder,
// поверх InkWell с тем же круглым бордером, внутри квадрат 52x52 с иконкой.
//
// Вызывает Navigator.maybePop() (или Navigator.pop, если maybePop недоступен).
// Используется на страницах-разделах настроек (Appearance / Backup / About)
// и на самой странице настроек — единый внешний вид без дублирования кода.

import 'package:flutter/material.dart';

import '../../core/providers.dart';

class CircleBackButton extends StatelessWidget {
  const CircleBackButton({super.key, required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => Navigator.of(context).maybePop(),
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(
            Icons.chevron_left_rounded,
            color: colors.textPrimary,
            size: 26,
          ),
        ),
      ),
    );
  }
}