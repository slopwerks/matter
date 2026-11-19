import 'package:flutter/material.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_theme.dart';

/// Shared test theme. The define also runs existing behavioral tests against
/// Material without duplicating their Rust mocks or changing their scenarios.
ThemeData neuTestTheme({
  bool dark = true,
  bool material = const bool.fromEnvironment('MATTER_TEST_MATERIAL'),
}) => material
    ? buildMaterialTheme(dark ? Brightness.dark : Brightness.light)
    : buildNeuTheme(
        dark ? NeuColors.dark : NeuColors.light,
        dark ? Brightness.dark : Brightness.light,
      );
