import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/common.dart';
import '../../../backend/services/auth_service.dart';
import '../../../admin/data/admin_service.dart';
import 'auth_widgets.dart';

/// Choose a new password. Two callers, same form:
///
///  * Forced first login for a provisioned organizer — they signed in with a
///    temporary password and must set their own before reaching the console.
///  * Password recovery — they tapped the link in the reset email, which opens
///    the app with a short-lived session (`AuthChangeEvent.passwordRecovery`).
///
/// [recovery] only swaps the copy and skips `clearMustChangePassword()`, which
/// is a staff-only flag; the actual work is identical, so this stays one screen.
class SetPasswordScreen extends StatefulWidget {
  final String displayName;
  final Future<void> Function() onDone; // re-resolve the gate once set
  final Future<void> Function() onSignOut;
  final bool recovery;
  const SetPasswordScreen({
    super.key,
    required this.displayName,
    required this.onDone,
    required this.onSignOut,
    this.recovery = false,
  });

  @override
  State<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<SetPasswordScreen> {
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pw = _pw.text;
    final confirm = _confirm.text;
    if (pw.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }
    if (pw != confirm) {
      setState(() => _error = 'The two passwords don\'t match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AuthService.setPassword(pw);
    if (err != null) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    // Staff-only flag; a player arriving from a reset email has no business
    // writing it (and no row that wants it cleared).
    if (!widget.recovery) await AdminService.clearMustChangePassword();
    if (!mounted) return;
    await widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.displayName.trim();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          children: [
            Container(
              width: 60,
              height: 60,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(alpha: 0.12)),
              child: const Icon(Icons.lock_reset_rounded,
                  size: 30, color: AppColors.primary),
            ),
            const SizedBox(height: 20),
            Text(widget.recovery ? 'Choose a new password' : 'Set your password',
                style: AppText.bigTitle()),
            const SizedBox(height: 8),
            Text(
                widget.recovery
                    ? 'Almost done — pick a new password and you\'ll be signed straight in.'
                    : (name.isEmpty
                        ? 'Choose a new password to finish setting up your organizer account.'
                        : 'Welcome, $name. Choose a new password to finish setting up your organizer account.'),
                style: AppText.body(AppColors.inkSoft)
                    .copyWith(fontSize: 14, height: 1.5)),
            const SizedBox(height: 24),
            AuthField(
              label: 'New password',
              hint: 'At least 8 characters',
              icon: Icons.lock_outline_rounded,
              obscure: true,
              controller: _pw,
            ),
            const SizedBox(height: 14),
            AuthField(
              label: 'Confirm password',
              hint: 'Re-enter your new password',
              icon: Icons.lock_outline_rounded,
              obscure: true,
              controller: _confirm,
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Row(children: [
                const Icon(Icons.error_outline_rounded,
                    size: 16, color: AppColors.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_error!,
                      style: AppText.small(AppColors.danger)),
                ),
              ]),
            ],
            const SizedBox(height: 24),
            AppButton(
                _busy
                    ? 'Saving…'
                    : (widget.recovery ? 'Save new password' : 'Save & continue'),
                full: true,
                height: 52,
                icon: Icons.check_rounded,
                onPressed: _busy ? null : _submit),
            const SizedBox(height: 11),
            AppButton(widget.recovery ? 'Cancel' : 'Sign out',
                full: true,
                height: 52,
                variant: AppBtnVariant.ghost,
                onPressed: _busy ? null : () => widget.onSignOut()),
          ],
        ),
      ),
    );
  }
}
