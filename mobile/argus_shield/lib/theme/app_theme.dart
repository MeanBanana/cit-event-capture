// app_theme.dart — the one place for Argus Shield's colours, fonts, text
// styles and spacing. Values come from the Figma designs for the login and
// register pages.
//
// Pages should use these instead of hard-coding values:
//   color: AppColors.accent     not  Colors.orangeAccent
//   style: AppText.fieldLabel   not  TextStyle(fontFamily: ..., fontSize: ...)
// Change a value here and every screen follows.
//
// buildArgusTheme() turns the same values into the app-wide ThemeData, so
// plain widgets (TextFormField, ElevatedButton, TextButton, TabBar, SnackBar,
// Checkbox, progress spinners) pick up the Argus look without extra styling.

import 'package:flutter/material.dart';

/// Colours.
class AppColors {
  AppColors._();

  /// Page background.
  static const Color background = Color(0xFF192536);

  /// App bar / header background.
  static const Color header = Color(0xFF11192A);

  /// Buttons, links, focused fields, active tab, icons (Colors.orangeAccent).
  static const Color accent = Color(0xFFFFAB40);

  /// Errors, failed actions and urgent actions such as recording live.
  static const Color danger = Color(0xFFF35C68);

  /// Successful actions (Colors.green).
  static const Color success = Color(0xFF4CAF50);

  /// Outline of text fields and boxes when not focused.
  static const Color fieldBorder = Color(0xFF79747E);

  static const Color textPrimary = Colors.white;
  static const Color textMuted = Colors.white70;
  static const Color textHint = Colors.white54;

  /// The small "Secure Access" line under the login button.
  static const Color footer = Colors.black;
}

/// Font families (declared in pubspec.yaml).
class AppFonts {
  AppFonts._();

  /// Titles and field labels.
  static const String heading = 'CourierPrime';

  /// Everything else: body text, buttons, links.
  static const String body = 'Inter';
}

/// Text styles.
class AppText {
  AppText._();

  /// "Argus Shield" in the app bar.
  static const TextStyle appTitle = TextStyle(
    fontFamily: AppFonts.heading,
    fontSize: 30,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
  );

  /// "CIT Intelligence System" under the app bar title.
  static const TextStyle appSubtitle = TextStyle(
    fontFamily: AppFonts.heading,
    fontSize: 10,
    color: AppColors.textPrimary,
  );

  /// Big page heading on full-screen pages ("Login", "Register as citizen").
  static const TextStyle pageTitle = TextStyle(
    fontFamily: AppFonts.heading,
    fontSize: 50,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
  );

  /// Heading of a section or tab ("Submit footage", "My profile").
  static const TextStyle sectionTitle = TextStyle(
    fontFamily: AppFonts.heading,
    fontSize: 28,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
  );

  /// Label above a text field ("Username", "Password").
  static const TextStyle fieldLabel = TextStyle(
    fontFamily: AppFonts.heading,
    fontSize: 20,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
  );

  /// Label next to a checkbox ("Terms and conditions").
  static const TextStyle checkboxLabel = TextStyle(
    fontFamily: AppFonts.heading,
    fontSize: 20,
    color: AppColors.textPrimary,
  );

  /// Heading inside a card (a submission's reference number).
  static const TextStyle cardTitle = TextStyle(
    fontFamily: AppFonts.heading,
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 16,
    height: 1.3,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodyMuted = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 15,
    height: 1.3,
    color: AppColors.textMuted,
  );

  /// Small bold tag: role badge, submission status.
  static const TextStyle caption = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 12,
    fontWeight: FontWeight.bold,
    letterSpacing: 0.8,
    color: AppColors.accent,
  );

  /// Text buttons ("Forgot password?", "Register as citizen").
  static const TextStyle link = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 20,
    color: AppColors.accent,
  );

  /// Main action button ("Access System", "Register Account").
  static const TextStyle button = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 30,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
  );

  /// Smaller buttons that sit inside a page ("Record Live Footage").
  static const TextStyle buttonSmall = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 16,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
  );

  static const TextStyle footer = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 13,
    color: AppColors.footer,
  );
}

/// Spacing and sizes.
class AppSpacing {
  AppSpacing._();

  /// Padding around the content of every page.
  static const EdgeInsets page = EdgeInsets.all(30);

  static const double small = 10;
  static const double medium = 20;
  static const double large = 30;

  /// Main action button size.
  static const double buttonHeight = 70;
  static const double buttonMaxWidth = 400;
}

/// The app-wide theme. Pass it to every MaterialApp: `theme: buildArgusTheme()`.
ThemeData buildArgusTheme() {
  const colorScheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: AppColors.textPrimary,
    secondary: AppColors.accent,
    onSecondary: AppColors.textPrimary,
    surface: AppColors.background,
    onSurface: AppColors.textPrimary,
    error: AppColors.danger,
    onError: AppColors.textPrimary,
  );

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: AppFonts.body,

    // Text fields: outlined, orange when focused, coral when invalid.
    inputDecorationTheme: const InputDecorationThemeData(
      border: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.fieldBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.fieldBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.danger, width: 2),
      ),
      hintStyle: TextStyle(color: AppColors.textHint),
      prefixStyle: TextStyle(color: AppColors.textPrimary, fontSize: 16),
      errorStyle: TextStyle(color: AppColors.danger),
      errorMaxLines: 3,
    ),

    // Main buttons: square orange block with white bold text.
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.textPrimary,
        disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.5),
        disabledForegroundColor: AppColors.textMuted,
        shape: const RoundedRectangleBorder(),
        elevation: 4,
        textStyle: AppText.button,
      ),
    ),

    // Links.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        textStyle: AppText.link,
      ),
    ),

    tabBarTheme: const TabBarThemeData(
      labelColor: AppColors.accent,
      unselectedLabelColor: AppColors.textMuted,
      indicatorColor: AppColors.accent,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
      labelStyle: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 14,
        fontWeight: FontWeight.bold,
      ),
      unselectedLabelStyle: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 14,
        fontWeight: FontWeight.bold,
      ),
    ),

    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.header,
      contentTextStyle: AppText.body,
      actionTextColor: AppColors.accent,
    ),

    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.background,
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
    ),
  );
}
