import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/backend/services/auth_service.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/backend/services/profile_service.dart';
import 'package:padel_clay/backend/services/moderation_service.dart';
import 'settings_common.dart';
import 'blocked_players_screen.dart';
import 'shared_numbers_screen.dart';
import 'help_support_screen.dart' show kSupportEmail;

class PrivacyAccountScreen extends StatefulWidget {
  const PrivacyAccountScreen({super.key});
  @override
  State<PrivacyAccountScreen> createState() => _PrivacyAccountScreenState();
}

class _PrivacyAccountScreenState extends State<PrivacyAccountScreen> {
  User? get _user => Supabase.instance.client.auth.currentUser;
  String? _phone; // from profiles.phone (the auth user's phone is empty here)
  int? _blocked; // null until loaded, so the tile doesn't flash "None"
  bool _phonePublic = false; // profiles.phone_public — private by default
  int? _shares; // people I've swapped numbers with
  // Same spam guard as the sign-in screen: the tap used to do nothing visible
  // until the email landed, so people tapped it until Supabase rate-limited
  // them and nothing arrived at all.
  bool _resetBusy = false;
  int _resetCooldown = 0;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadPhone();
    _loadBlocked();
    _loadShares();
    // A cooldown from an earlier visit still applies.
    _syncResetCooldown();
  }

  Future<void> _loadShares() async {
    final rows = await ProfileService.myContactShares();
    if (mounted) setState(() => _shares = rows.length);
  }

  Future<void> _loadBlocked() async {
    final rows = await ModerationService.blockedUsers();
    if (mounted) setState(() => _blocked = rows.length);
  }

  Future<void> _loadPhone() async {
    final uid = _user?.id;
    if (uid == null) return;
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('phone, phone_public')
          .eq('id', uid)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _phone = (row?['phone'] as String?)?.trim();
          _phonePublic = row?['phone_public'] == true;
        });
      }
    } catch (_) {
      // Pre-migration DB has no phone_public column; the whole select fails.
      // Leaving it false is the safe reading.
    }
  }

  Future<void> _setPhonePublic(bool on) async {
    setState(() => _phonePublic = on); // optimistic: the switch must feel instant
    final err = await ProfileService.setPhonePublic(on);
    if (!mounted) return;
    if (err != null) {
      setState(() => _phonePublic = !on);
      _snack(err);
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(msg)));

  /// Re-reads the countdown from AuthService, which is where it actually lives
  /// — leaving this screen and coming back resumes the same clock rather than
  /// handing out a fresh one.
  void _syncResetCooldown() {
    final email = _user?.email;
    if (email == null) return;
    final left = AuthService.resetCooldownRemaining(email);
    if (left == _resetCooldown) return;
    setState(() => _resetCooldown = left);
    if (left > 0) {
      _resetTimer ??= Timer.periodic(
          const Duration(seconds: 1), (_) => _syncResetCooldown());
    } else {
      _resetTimer?.cancel();
      _resetTimer = null;
    }
  }

  Future<void> _changePassword() async {
    final email = _user?.email;
    if (email == null || email.isEmpty) {
      _snack('No email on this account — password sign-in isn\'t set up.');
      return;
    }
    setState(() => _resetBusy = true);
    final err = await AuthService.sendPasswordReset(email);
    if (!mounted) return;
    setState(() => _resetBusy = false);
    // The service stamps the clock on success AND on a server-side rate-limit,
    // so resync either way before reporting.
    _syncResetCooldown();
    _snack(err ?? 'Reset link sent to $email. Check your inbox and spam.');
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
              subtitle: (_phone?.isNotEmpty ?? false) ? _phone! : 'Not set',
              onTap: () => _snack('Update your phone from Edit Profile.')),
          // A Google/Apple account has no password here to change — the tile
          // would mail a link that sets one they'd never use. Say which button
          // signs them in instead.
          if (AuthService.hasPasswordLogin)
            NavTile(
                icon: Icons.lock_outline_rounded,
                title: 'Change Password',
                subtitle: _resetBusy
                    ? 'Sending…'
                    : (_resetCooldown > 0
                        ? 'Link sent — you can resend in ${_resetCooldown}s'
                        : 'Sends a reset link to your email'),
                onTap: (_resetBusy || _resetCooldown > 0)
                    ? null
                    : _changePassword)
          else
            NavTile(
                icon: Icons.lock_outline_rounded,
                title: 'Password',
                chevron: false,
                subtitle:
                    'You sign in with ${AuthService.socialProviderLabel ?? 'a social account'} — there\'s no password to change',
                onTap: null),
        ]),
        const SizedBox(height: 22),

        const SectionLabel('Your phone number'),
        TileGroup(children: [
          SwitchTile(
            icon: Icons.visibility_outlined,
            title: 'Show my number to players in my matches',
            subtitle: _phonePublic
                ? 'Anyone you\'re booked to play with can see it'
                : 'Hidden — players have to ask you first',
            value: _phonePublic,
            onChanged: _setPhonePublic,
          ),
          NavTile(
              icon: Icons.people_alt_outlined,
              title: 'Shared with',
              subtitle: _shares == null
                  ? 'People who can see your number'
                  : (_shares == 0
                      ? 'Nobody yet'
                      : '$_shares ${_shares == 1 ? 'person' : 'people'}'),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SharedNumbersScreen()));
                _loadShares(); // they may have revoked someone
              }),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
              'Turning this off never stops people asking — a request still '
              'reaches you and you decide each time. Accepting shares both ways.',
              style: AppText.small().copyWith(fontSize: 12, height: 1.45)),
        ),
        const SizedBox(height: 22),

        const SectionLabel('Data'),
        TileGroup(children: [
          NavTile(icon: Icons.download_outlined, title: 'Download My Data',
              onTap: () => _snack('Email $kSupportEmail and we\'ll send your data export.')),
          NavTile(
              icon: Icons.block_rounded,
              title: 'Blocked Players',
              subtitle: _blocked == null
                  ? 'Manage who you\'ve blocked'
                  : (_blocked == 0 ? 'None' : '$_blocked blocked'),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const BlockedPlayersScreen()));
                _loadBlocked(); // the count may have changed
              }),
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
