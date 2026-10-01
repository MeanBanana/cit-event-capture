// app_styles.dart — shared colours and reusable field presentation.

import 'package:flutter/material.dart';

// Colours based on the citizen dashboard mock-up.
const Color argusNavy = Color(0xFF1B293C);
const Color argusHeader = Color(0xFF111A2D);
const Color argusField = Color(0xFF162335);
const Color argusGold = Color(0xFFAA8942);
const Color argusCoral = Color(0xFFF35C68);
const Color argusBorder = Color(0xFF536276);

/// Consistent uppercase-style label used above the incident and profile fields.
class FormLabel extends StatelessWidget {
  final String text;

  const FormLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.8,
      ),
    );
  }
}

/// Applies the same navy fill and border colours to all form fields.
InputDecoration fieldDecoration(String hint) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white54),
    filled: true,
    fillColor: argusField,
    contentPadding: const EdgeInsets.all(13),
    enabledBorder: const OutlineInputBorder(
      borderSide: BorderSide(color: argusBorder, width: 2),
    ),
    // Gold indicates the field currently being edited.
    focusedBorder: const OutlineInputBorder(
      borderSide: BorderSide(color: argusGold, width: 2),
    ),
    // Coral indicates an input that failed validation.
    errorBorder: const OutlineInputBorder(
      borderSide: BorderSide(color: argusCoral, width: 2),
    ),
    focusedErrorBorder: const OutlineInputBorder(
      borderSide: BorderSide(color: argusCoral, width: 2),
    ),
  );
}
