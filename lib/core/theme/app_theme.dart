import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  AppTheme._();

  // ── Colors ────────────────────────────────────────────────────────
  static const Color background     = Color(0xFF0A0C14);
  static const Color surface        = Color(0xFF141824);
  static const Color surfaceVariant = Color(0xFF1C2130);
  static const Color card           = Color(0xFF1A1F2E);
  static const Color cardHover      = Color(0xFF222840);

  static const Color primary        = Color(0xFF4F8EF7);
  static const Color primaryDark    = Color(0xFF2C6CE4);
  static const Color accent         = Color(0xFF7B61FF);

  static const Color success        = Color(0xFF22C55E);
  static const Color warning        = Color(0xFFF59E0B);
  static const Color error          = Color(0xFFEF4444);

  static const Color textPrimary    = Color(0xFFE8EAF2);
  static const Color textSecondary  = Color(0xFF8B90A7);
  static const Color textMuted      = Color(0xFF4A5068);
  static const Color divider        = Color(0xFF1E2338);

  static const Color sidebarBg     = Color(0xFF0E1120);
  static const Color selectedItem  = Color(0xFF1E2D54);

  // ── EPG Colors ────────────────────────────────────────────────────
  static const Color epgPast     = Color(0xFF111420);
  static const Color epgCurrent  = Color(0xFF1A2340);
  static const Color epgFuture   = Color(0xFF161B2C);
  static const Color epgBorder   = Color(0xFF232840);
  static const Color timelineLine = Color(0xFF4F8EF7);

  // ── Gradients ─────────────────────────────────────────────────────
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF4F8EF7), Color(0xFF7B61FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFF1A1F2E), Color(0xFF141824)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient darkOverlay = LinearGradient(
    colors: [Colors.transparent, Color(0xCC0A0C14)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ── Shadows — getters, NOT const (withValues is not const) ────────
  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.4),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> get primaryShadow => [
    BoxShadow(
      color: primary.withValues(alpha: 0.3),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> get elevatedShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.6),
      blurRadius: 30,
      offset: const Offset(0, 12),
    ),
  ];

  // ── Theme ─────────────────────────────────────────────────────────
  static ThemeData get darkTheme {
    final base = ThemeData.dark(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: background,
      textTheme: _buildTextTheme(base.textTheme),

      colorScheme: const ColorScheme.dark(
        brightness: Brightness.dark,
        primary: primary,
        onPrimary: Colors.white,
        secondary: accent,
        onSecondary: Colors.white,
        surface: surface,
        onSurface: textPrimary,
        surfaceContainerHighest: surfaceVariant,
        error: error,
        onError: Colors.white,
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        iconTheme: const IconThemeData(color: textPrimary, size: 22),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: error, width: 2),
        ),
        hintStyle: const TextStyle(color: textMuted, fontSize: 14),
        labelStyle: const TextStyle(color: primary, fontSize: 14),
        contentPadding:
        const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        isDense: true,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding:
          const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          textStyle:
          GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: primary),
          padding:
          const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          textStyle:
          GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      // ── FIXED: CardTheme → CardThemeData ──────────────────────────
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.all(4),
      ),

      // ── FIXED: DialogTheme → DialogThemeData ──────────────────────
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 24,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        contentTextStyle: GoogleFonts.inter(
          fontSize: 14,
          color: textSecondary,
        ),
      ),

      dividerTheme: const DividerThemeData(
        color: divider,
        space: 1,
        thickness: 1,
      ),

      iconTheme: const IconThemeData(color: textSecondary, size: 22),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceVariant,
        contentTextStyle:
        GoogleFonts.inter(color: textPrimary, fontSize: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
        elevation: 8,
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius:
          BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
      ),

      listTileTheme: ListTileThemeData(
        tileColor: Colors.transparent,
        iconColor: textSecondary,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        subtitleTextStyle:
        GoogleFonts.inter(fontSize: 12, color: textSecondary),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
        contentPadding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(Colors.white),
        side: const BorderSide(color: textMuted, width: 1.5),
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.selected)
            ? Colors.white
            : textMuted),
        trackColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.selected)
            ? primary
            : surfaceVariant),
      ),

      sliderTheme: const SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: surfaceVariant,
        thumbColor: Colors.white,
        overlayColor: Color(0x334F8EF7),
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: surfaceVariant,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceVariant,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: divider),
        ),
        textStyle: const TextStyle(color: textPrimary, fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(
            textMuted.withValues(alpha: 0.5)),
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(4),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: divider),
        ),
        elevation: 16,
        textStyle: GoogleFonts.inter(fontSize: 13, color: textPrimary),
      ),
    );
  }

  // ── Text Theme Builder ────────────────────────────────────────────
  static TextTheme _buildTextTheme(TextTheme base) {
    return GoogleFonts.interTextTheme(base).copyWith(
      displayLarge:  _ts(57, FontWeight.w700, letterSpacing: -1),
      displayMedium: _ts(45, FontWeight.w700, letterSpacing: -0.5),
      headlineLarge: _ts(32, FontWeight.w700, letterSpacing: -0.5),
      headlineMedium:_ts(24, FontWeight.w600),
      headlineSmall: _ts(20, FontWeight.w600),
      titleLarge:    _ts(18, FontWeight.w600),
      titleMedium:   _ts(16, FontWeight.w500),
      titleSmall:    _ts(14, FontWeight.w500, color: textSecondary),
      bodyLarge:     _ts(16, FontWeight.w400),
      bodyMedium:    _ts(14, FontWeight.w400, color: textSecondary),
      bodySmall:     _ts(12, FontWeight.w400, color: textMuted),
      labelLarge:    _ts(14, FontWeight.w600, letterSpacing: 0.5),
      labelMedium:   _ts(12, FontWeight.w500),
      labelSmall:    _ts(11, FontWeight.w500, color: textMuted),
    );
  }

  static TextStyle _ts(
      double size,
      FontWeight weight, {
        Color color = textPrimary,
        double letterSpacing = 0,
      }) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
      );
}