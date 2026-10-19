// new_investigator_form.dart — the form inside the "New investigator" popup
// (opened by "+ New investigator" on the Investigators tab).
//
// Same look as NewCaseForm (pickers.dart): Courier labels, themed fields, a
// red error line and one big orange button. The checks here match the
// create-investigator Edge Function, so most mistakes are caught before
// anything is sent.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';

/// What the admin filled in. Optional fields are '' when left empty.
class NewInvestigatorDetails {
  final String firstName;
  final String surname;
  final String username;
  final String email;
  final String phone; // the 9 digits after +27, or ''
  final String rank;
  final String badgeNumber;
  final String station;
  final String unit;

  const NewInvestigatorDetails({
    required this.firstName,
    required this.surname,
    required this.username,
    required this.email,
    required this.phone,
    required this.rank,
    required this.badgeNumber,
    required this.station,
    required this.unit,
  });
}

class NewInvestigatorForm extends StatefulWidget {
  /// Saves the account. Throw to show the error in the form (the popup
  /// stays open so nothing typed is lost).
  final Future<void> Function(NewInvestigatorDetails details) onCreate;

  const NewInvestigatorForm({super.key, required this.onCreate});

  @override
  State<NewInvestigatorForm> createState() => _NewInvestigatorFormState();
}

class _NewInvestigatorFormState extends State<NewInvestigatorForm> {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _surname = TextEditingController();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _rank = TextEditingController();
  final _badge = TextEditingController();
  final _station = TextEditingController();
  final _unit = TextEditingController();

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _firstName, _surname, _username, _email, _phone,
      _rank, _badge, _station, _unit,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onCreate(NewInvestigatorDetails(
        firstName: _firstName.text.trim(),
        surname: _surname.text.trim(),
        username: _username.text.trim(),
        email: _email.text.trim(),
        phone: _phone.text.trim(),
        rank: _rank.text.trim(),
        badgeNumber: _badge.text.trim().toUpperCase(),
        station: _station.text.trim(),
        unit: _unit.text.trim(),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---- validators (same rules as the Edge Function) ----------------------

  static String? _required(String? value, String message) =>
      (value == null || value.trim().isEmpty) ? message : null;

  static String? _validateUsername(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Enter a username';
    if (!RegExp(r'^[A-Za-z0-9_.]{3,30}$').hasMatch(text)) {
      return 'Use 3-30 letters, numbers, _ or .';
    }
    return null;
  }

  static String? _validateEmail(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Enter an email address';
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  static String? _validatePhone(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null; // optional
    if (text.length != 9) return 'Phone number must be 9 digits, no initial 0';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        children: [
          const Text(
            'The investigator sets their own password: once the account '
            'exists, we email them a link to choose one.',
            style: AppText.bodyMuted,
          ),
          const SizedBox(height: AppSpacing.medium),

          const _SectionLabel('PERSONAL DETAILS'),
          _field('First name', _firstName,
              capitalization: TextCapitalization.words,
              validator: (v) => _required(v, 'Enter the first name')),
          _field('Surname', _surname,
              capitalization: TextCapitalization.words,
              validator: (v) => _required(v, 'Enter the surname')),
          _field('Username', _username,
              hint: 'Used to log in, e.g. tmokoena',
              autocorrect: false,
              validator: _validateUsername),
          _field('Email address', _email,
              keyboard: TextInputType.emailAddress,
              autocorrect: false,
              validator: _validateEmail),
          _field('Phone number (optional)', _phone,
              keyboard: TextInputType.phone,
              prefix: '+27 ',
              formatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(9),
              ],
              validator: _validatePhone),

          const SizedBox(height: AppSpacing.small),
          const _SectionLabel('POLICE DETAILS'),
          _field('Rank (optional)', _rank,
              hint: 'e.g. Sgt.', maxLength: 50),
          _field('Badge number', _badge,
              hint: 'e.g. JHB-4471',
              capitalization: TextCapitalization.characters,
              maxLength: 50,
              validator: (v) => _required(v, 'Enter the badge number')),
          _field('Station', _station,
              hint: 'e.g. Kempton Park SAPS',
              capitalization: TextCapitalization.words,
              maxLength: 150,
              validator: (v) => _required(v, 'Enter the station')),
          _field('Unit (optional)', _unit,
              hint: 'e.g. CIT Task Force',
              capitalization: TextCapitalization.words,
              maxLength: 100),

          if (_error != null) ...[
            const SizedBox(height: AppSpacing.small),
            Text(_error!,
                style: AppText.bodyMuted.copyWith(color: AppColors.danger)),
          ],
          const SizedBox(height: AppSpacing.medium),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _saving ? null : _submit,
              // the theme's button text is 30px; this label is longer
              style: ElevatedButton.styleFrom(
                textStyle: AppText.buttonSmall.copyWith(fontSize: 17),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _saving ? 'Creating...' : 'Create investigator account',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A label + text field pair, spaced like NewCaseForm.
  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    String? prefix,
    TextInputType? keyboard,
    TextCapitalization capitalization = TextCapitalization.none,
    bool autocorrect = true,
    int? maxLength,
    List<TextInputFormatter>? formatters,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.small),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.fieldLabel.copyWith(fontSize: 17)),
          const SizedBox(height: 6),
          TextFormField(
            controller: controller,
            style: AppText.body,
            keyboardType: keyboard,
            textCapitalization: capitalization,
            autocorrect: autocorrect,
            maxLength: maxLength,
            inputFormatters: formatters,
            textInputAction: TextInputAction.next,
            enabled: !_saving,
            decoration: InputDecoration(
              hintText: hint,
              prefixText: prefix,
              counterText: '', // hide the "0/50" counter
            ),
            validator: validator,
          ),
        ],
      ),
    );
  }
}

/// Small orange heading between groups of fields.
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.small),
      child: Text(text, style: AppText.caption),
    );
  }
}
