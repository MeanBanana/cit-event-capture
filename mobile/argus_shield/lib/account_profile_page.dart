import 'package:flutter/material.dart';
import 'package:argus_shield/login.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';

/// Account details for signed-in users whose profile is not managed by the
/// citizen profile form.
class AccountProfilePage extends StatefulWidget {
  final SupabaseService? service;

  const AccountProfilePage({super.key, this.service});

  @override
  State<AccountProfilePage> createState() => _AccountProfilePageState();
}

class _AccountProfilePageState extends State<AccountProfilePage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _signingOut = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await _service.getMyAccountProfile();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Your account details could not be loaded. Check your '
            'connection and try again.';
        _loading = false;
      });
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      await _service.logout();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (_) => false,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _signingOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not sign out: $error'),
          backgroundColor: AppColors.danger,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final role = _roleLabel(profile?['role'] as String?);
    return Scaffold(
      appBar: RoleAppBar(
        roleLabel: role,
        marker: role == 'System Administrator'
            ? RoleMarker.diamond
            : RoleMarker.circle,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _buildProfile(profile!, role),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: AppSpacing.page,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.account_circle_outlined,
                size: 52, color: AppColors.textHint),
            const SizedBox(height: AppSpacing.medium),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: AppText.bodyMuted,
            ),
            const SizedBox(height: AppSpacing.small),
            TextButton.icon(
              onPressed: _loadProfile,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfile(Map<String, dynamic> profile, String role) {
    final firstName = profile['firstname'] as String? ?? '';
    final surname = profile['surname'] as String? ?? '';
    final username = profile['username'] as String? ?? '';
    final fullName = '$firstName $surname'.trim();
    final displayName =
        fullName.isNotEmpty ? fullName : username.isNotEmpty ? username : 'Account holder';
    final userId = profile['userid'];
    final phone = profile['phonenumber'] as String? ?? '';
    final roleTitle = switch (role) {
      'System Administrator' => 'Administrator account',
      'Investigator' => 'Investigator account',
      'Citizen' => 'Citizen account',
      _ => 'Argus Shield account',
    };
    final roleDescription = switch (role) {
      'System Administrator' =>
        'This account has administrative access to the Argus Shield system.',
      'Investigator' =>
        'This account has access to assigned investigations and case tools.',
      'Citizen' =>
        'This account can submit incident reports and manage personal details.',
      _ => 'Your access is managed by Argus Shield administrators.',
    };

    return ListView(
      padding: AppSpacing.page,
      children: [
        const Text('My profile', style: AppText.sectionTitle),
        const SizedBox(height: AppSpacing.small),
        const Text(
          'Account details and access information for your signed-in account.',
          style: AppText.bodyMuted,
        ),
        const SizedBox(height: AppSpacing.large),
        Container(
          padding: const EdgeInsets.all(AppSpacing.medium),
          decoration: BoxDecoration(
            color: AppColors.header,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.fieldBorder),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: AppColors.background,
                foregroundColor: AppColors.accent,
                child: Text(
                  _initials(displayName),
                  style: AppText.cardTitle.copyWith(fontSize: 20),
                ),
              ),
              const SizedBox(width: AppSpacing.medium),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayName, style: AppText.cardTitle),
                    if (username.isNotEmpty)
                      Text('@$username', style: AppText.bodyMuted),
                    const SizedBox(height: 6),
                    Text(role.toUpperCase(), style: AppText.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.large),
        const Text('ACCOUNT INFORMATION', style: AppText.cardTitle),
        const SizedBox(height: AppSpacing.small),
        _ProfileDetail(
          icon: Icons.alternate_email,
          label: 'Email address',
          value: profile['email'] as String? ?? 'Not provided',
        ),
        _ProfileDetail(
          icon: Icons.phone_outlined,
          label: 'Phone number',
          value: phone.isEmpty ? 'Not provided' : phone,
        ),
        _ProfileDetail(
          icon: Icons.badge_outlined,
          label: 'Account ID',
          value: userId?.toString() ?? 'Not available',
        ),
        const SizedBox(height: AppSpacing.medium),
        Container(
          padding: const EdgeInsets.all(AppSpacing.medium),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.accent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.verified_user_outlined,
                  color: AppColors.accent),
              const SizedBox(width: AppSpacing.small),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(roleTitle, style: AppText.cardTitle),
                    const SizedBox(height: 4),
                    Text(roleDescription, style: AppText.bodyMuted),
                    const SizedBox(height: 8),
                    const Text(
                      'Your role cannot be changed from this page.',
                      style: AppText.bodyMuted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.large),
        OutlinedButton.icon(
          onPressed: _signingOut ? null : _signOut,
          icon: const Icon(Icons.logout),
          label: Text(_signingOut ? 'Signing out...' : 'Sign out'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.danger,
            side: const BorderSide(color: AppColors.danger),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ],
    );
  }

  String _roleLabel(String? role) {
    switch (role) {
      case 'admin':
        return 'System Administrator';
      case 'investigator':
        return 'Investigator';
      case 'citizen':
        return 'Citizen';
      default:
        return 'Account';
    }
  }

  String _initials(String name) {
    final parts = name.split(RegExp(r'\s+')).where((part) => part.isNotEmpty);
    final initials = parts.take(2).map((part) => part[0]).join();
    return initials.isEmpty ? '?' : initials.toUpperCase();
  }
}

class _ProfileDetail extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ProfileDetail({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.accent),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(), style: AppText.caption),
                const SizedBox(height: 3),
                Text(value, style: AppText.body),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
