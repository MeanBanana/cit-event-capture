// The form in the "New investigator" popup (from "+ New investigator" on the
// Investigators tab). The same form pre-filled is the "Update investigator"
// popup, where the password becomes optional.
//
// Styled like NewCaseForm in pickers.dart. The checks match the
// create-investigator Edge Function, so most mistakes get caught before we
// send anything.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/temp_password.dart';

/// What the admin typed. Optional fields come through as '' when empty.
class NewInvestigatorDetails {
  final String firstName;
  final String surname;
  final String username;
  final String email;
  final String phone; // 9 digits after +27, or ''
  final String rank;
  final String badgeNumber;
  final String station;
  final String unit;
  final String password; // temporary, they change it on first login

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
    required this.password,
  });
}

class NewInvestigatorForm extends StatefulWidget {
  /// Saves the account. Throw to show the error in the form; the popup stays
  /// open so nothing they typed is lost.
  final Future<void> Function(NewInvestigatorDetails details) onCreate;

  /// Update mode: the investigator's current details, with password ''. The
  /// password is optional then, leaving it empty keeps their current one.
  final NewInvestigatorDetails? initial;

  const NewInvestigatorForm({super.key, required this.onCreate, this.initial});

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
  final _password = TextEditingController();

  bool _saving = false;
  bool _showPassword = false;
  String? _error;

  bool get _isUpdate => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    if (d != null) {
      _firstName.text = d.firstName;
      _surname.text = d.surname;
      _username.text = d.username;
      _email.text = d.email;
      _phone.text = d.phone;
      _rank.text = d.rank;
      _badge.text = d.badgeNumber;
      _station.text = d.station;
      _unit.text = d.unit;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _firstName, _surname, _username, _email, _phone,
      _rank, _badge, _station, _unit, _password,
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
        password: _password.text,
      ));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --- validators, same rules as the Edge Function

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

  /// Fill in a random temporary password and show it so the admin can write
  /// it down.
  void _generatePassword() {
    setState(() {
      _password.text = generateTempPassword();
      _showPassword = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        children: [
          Text(
            _isUpdate
                ? 'Change their details or log-in. Leave the password empty to '
                    'keep their current one; a new password is temporary and '
                    'they must choose their own at their next log-in.'
                : 'Give the investigator their username and a temporary password. '
                    'They must choose their own password the first time they log in.',
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

          const SizedBox(height: AppSpacing.small),
          const _SectionLabel('LOG-IN'),
          _passwordField(),

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
              // the theme's button text is 30px and this label is longer
              style: ElevatedButton.styleFrom(
                textStyle: AppText.buttonSmall.copyWith(fontSize: 17),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _isUpdate
                      ? (_saving ? 'Saving...' : 'Save changes')
                      : (_saving ? 'Creating...' : 'Create investigator account'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The temporary password field, with Show/Hide and Generate.
  Widget _passwordField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.small),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_isUpdate ? 'New temporary password (optional)' : 'Temporary password',
              style: AppText.fieldLabel.copyWith(fontSize: 17)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  key: const Key('temp-password'),
                  controller: _password,
                  style: AppText.body,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 72,
                  enabled: !_saving,
                  decoration: InputDecoration(
                    hintText: _isUpdate ? 'Leave empty to keep it' : 'Tap Generate',
                    counterText: '',
                    suffixIcon: IconButton(
                      tooltip: _showPassword ? 'Hide password' : 'Show password',
                      icon: Icon(
                        _showPassword ? Icons.visibility_off : Icons.visibility,
                        color: AppColors.textMuted,
                      ),
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                  validator: (value) => _isUpdate && (value ?? '').isEmpty
                      ? null
                      : validateTempPassword(value),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: _saving ? null : _generatePassword,
                  child: const Text('Generate'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// A label and text field, spaced like NewCaseForm.
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
