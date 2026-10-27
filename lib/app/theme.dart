import 'package:flutter/material.dart';

/// Visual direction from DESIGN-notion.md, adapted for a mobile writing tool.
abstract final class PaperTheme {
  static const blue = Color(0xff0075de);
  static const paper = Color(0xfff6f5f4);
  static const ink = Color(0xff31302e);
  static const muted = Color(0xff615d59);
  static const hairline = Color(0xffe6e6e6);

  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xff232323) : Colors.white;
    final canvas = dark ? const Color(0xff191919) : paper;
    final foreground = dark ? const Color(0xffeeeeec) : ink;
    final secondary = dark ? const Color(0xffb3b0ac) : muted;
    final line = dark ? const Color(0xff3a3a3a) : hairline;
    final primary = dark ? const Color(0xff62aef0) : blue;
    final scheme = ColorScheme.fromSeed(seedColor: blue, brightness: brightness)
        .copyWith(
          primary: primary,
          onPrimary: dark ? const Color(0xff102a40) : Colors.white,
          surface: surface,
          onSurface: foreground,
          onSurfaceVariant: secondary,
          outline: line,
          outlineVariant: line,
          surfaceTint: Colors.transparent,
          primaryContainer: dark
              ? const Color(0xff19374f)
              : const Color(0xffeaf3fc),
          onPrimaryContainer: primary,
        );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final text = base.textTheme
        .apply(bodyColor: foreground, displayColor: foreground)
        .copyWith(
          headlineLarge: TextStyle(
            fontSize: 32,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -.8,
            color: foreground,
          ),
          headlineMedium: TextStyle(
            fontSize: 26,
            height: 1.25,
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
            color: foreground,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            height: 1.4,
            fontWeight: FontWeight.w600,
            letterSpacing: -.2,
            color: foreground,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            height: 1.4,
            fontWeight: FontWeight.w600,
            color: foreground,
          ),
          bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: foreground),
          bodyMedium: TextStyle(fontSize: 15, height: 1.45, color: foreground),
          bodySmall: TextStyle(fontSize: 12, height: 1.4, color: secondary),
        );
    final utilityShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );
    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: canvas,
      dividerColor: line,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleMedium,
        shape: Border(bottom: BorderSide(color: line)),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        hintStyle: TextStyle(color: secondary),
        labelStyle: TextStyle(color: secondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: utilityShape,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground,
          minimumSize: const Size(44, 48),
          side: BorderSide(color: line),
          shape: utilityShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size(44, 44),
          shape: utilityShape,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: scheme.onPrimary,
        elevation: 1,
        highlightElevation: 2,
        shape: utilityShape,
        extendedTextStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surface,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        labelStyle: TextStyle(fontSize: 13, color: foreground),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        shape: Border(right: BorderSide(color: line)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: secondary,
        textColor: foreground,
        selectedColor: primary,
        selectedTileColor: scheme.primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: line),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: line),
        ),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 24),
      iconTheme: IconThemeData(color: secondary, size: 22),
    );
  }
}

class PageWidth extends StatelessWidget {
  final Widget child;
  const PageWidth({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1080),
      child: child,
    ),
  );
}
