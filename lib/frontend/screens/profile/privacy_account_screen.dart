import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/backend/services/profile_service.dart';
import 'settings_common.dart';

class PrivacyAccountScreen extends StatefulWidget {
  const PrivacyAccountScreen({super.key});
  @override
  State<PrivacyAccountScreen> createState() => _PrivacyAccountScreenState();
}

class _PrivacyAccountScreenState extends State<PrivacyAccountScreen> {
  User? get _user => Supabase.instance.client.auth.currentUser;

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(msg)));

  Future<void> _changePassword() async {
    final email = _user?.email;
    if (email == null || email.isEmpty) {
      _snack('No email on this account — password sign-in isn\'t set up.');
      return;
    }
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(email);
      if (mounted) _snack('Password reset link sent to $email.');
    } on AuthException catch (e) {
      if (mounted) _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Privacy & Account',
      children: [
        const SectionLabel('Account'),
        TileGroup(children: [
          NavTile(icon: Icons.mail_outline_rounded, title: 'Email',
              subtitle: _user?.email ?? 'Not set',
              onTap: () => _snack('To change your email, contact support.')),
          NavTile(icon: Icons.phone_outlined, title: 'Phone Number',
              subtitle: (_user?.phone?.isNotEmpty ?? false) ? '+${_user!.phone}' : 'Not set',
              onTap: () => _snack('Update your phone from Edit Profile.')),
          NavTile(icon: Icons.lock_outline_rounded, title: 'Change Password',
              subtitle: 'Sends a reset link to your email', onTap: _changePassword),
        ]),
        const SizedBox(height: 22),

        const SectionLabel('Data'),
        TileGroup(children: [
          NavTile(icon: Icons.download_outlined, title: 'Download My Data',
              onTap: () => _snack('Email help@padel.eg and we\'ll send your data export.')),
          NavTile(icon: Icons.block_rounded, title: 'Blocked Players', subtitle: 'None',
              onTap: () => _snack('You haven\'t blocked anyone.')),
        ]),
        const SizedBox(height: 22),

        const SectionLabel('Danger Zone'),
        TileGroup(children: [
          NavTile(
            icon: Icons.delete_outline_rounded,
            title: 'Delete Account',
            tint: AppColors.danger,
            onTap: () => _confirmDelete(context),
          ),
        ]),
      ],
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete account?', style: AppText.cardTitle()),
        content: Text(
          'This permanently removes your profile, matches, and ranking right now. '
          'This cannot be undone.',
          style: AppText.body(AppColors.inkSoft).copyWith(height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: AppText.bodyStrong(AppColors.inkSoft)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteAccount();
            },
            child: Text('Delete', style: AppText.bodyStrong(AppColors.danger)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAccount() async {
    // Blocking spinner while the RPC removes the account.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final err = await ProfileService.deleteAccount();
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss the spinner
    if (err != null) {
      _snack('Could not delete your account: $err');
      return;
    }
    // Account is gone — sign out (invalidates the now-orphaned session) and
    // unwind to the auth gate, which routes to sign-in on sign-out.
    await Supabase.instance.client.auth.signOut();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Your account has been deleted.')));
  }
}
