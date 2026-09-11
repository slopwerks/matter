import 'package:flutter/material.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';

/// 为绕过真实 app 根的测试提供 neu 主题：迁移后的页面通过
/// `context.neu`（ThemeExtension）取色，测试内联的 `MaterialApp`
/// 若不带扩展会直接崩溃。
ThemeData neuTestTheme({bool dark = true}) => buildNeuTheme(
  dark ? NeuColors.dark : NeuColors.light,
  dark ? Brightness.dark : Brightness.light,
);
