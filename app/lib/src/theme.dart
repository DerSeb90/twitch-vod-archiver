import 'package:flutter/material.dart';

/// Design tokens. Dark-first, violet → pink accent, rounded, lots of depth.
abstract final class C {
  static const bg = Color(0xFF09090B);
  static const surface = Color(0xFF111116);
  static const surface2 = Color(0xFF18181F);
  static const surface3 = Color(0xFF22222B);
  static const border = Color(0xFF26262F);
  static const text = Color(0xFFFAFAFA);
  static const muted = Color(0xFFA1A1AA);
  static const faint = Color(0xFF71717A);
  static const primary = Color(0xFF8B5CF6);
  static const primarySoft = Color(0xFFA78BFA);
  static const pink = Color(0xFFEC4899);
  static const orange = Color(0xFFF97316);
  static const live = Color(0xFFF43F5E);
  static const success = Color(0xFF22C55E);

  static const brandGradient = LinearGradient(
    colors: [primary, pink, orange],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

const kRadius = 14.0;
const kMaxContentWidth = 1680.0;

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: C.primary,
    secondary: C.pink,
    surface: C.surface,
    onSurface: C.text,
    error: C.live,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.bg,
    fontFamily: 'Inter',
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text).copyWith(
          headlineLarge: const TextStyle(color: C.text, fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 40, height: 1.05, letterSpacing: -1),
          headlineMedium: const TextStyle(color: C.text, fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 28, letterSpacing: -0.5),
          titleLarge: const TextStyle(color: C.text, fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w700, fontSize: 20, letterSpacing: -0.2),
          titleMedium: const TextStyle(color: C.text, fontWeight: FontWeight.w600, fontSize: 15),
          bodyMedium: const TextStyle(fontSize: 14, color: C.text),
          bodySmall: const TextStyle(fontSize: 12.5, color: C.muted),
          labelSmall: const TextStyle(color: C.text, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4),
        ),
    dividerTheme: const DividerThemeData(color: C.border, thickness: 1, space: 1),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: C.surface3, borderRadius: BorderRadius.circular(8), border: Border.all(color: C.border)),
      textStyle: const TextStyle(color: C.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.surface2,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: const TextStyle(color: C.faint),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.primary, width: 1.5)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'Inter'),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.text,
        side: const BorderSide(color: C.border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.surface3,
      contentTextStyle: const TextStyle(color: C.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : C.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.primary : C.surface3),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: C.primary,
      inactiveTrackColor: C.surface3,
      thumbColor: Colors.white,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      trackHeight: 3,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: C.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: C.border)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: C.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: C.border)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(C.surface3),
      radius: const Radius.circular(8),
      thickness: WidgetStateProperty.all(6),
    ),
  );
}
