import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/auth_service.dart';
import 'package:padel_clay/backend/services/profile_service.dart';
import 'auth_widgets.dart';

/// Collected onboarding answers.
class SignUpData {
  String name = '', username = '', email = '', phone = '', password = '', confirm = '', bio = '';
  DateTime? dob;
  String gender = '';
  String hand = 'right';
  String side = 'both';
  // Profile photo picked on the last step; uploaded after sign-up when a
  // session exists. Null when the user skips it (photo is optional).
  Uint8List? avatarBytes;
  String avatarExt = 'jpg';
}

class SignUpFlow extends StatefulWidget {
  final VoidCallback onExit;
  /// [sessionCreated] is true when email confirmation is disabled and a session
  /// exists immediately — caller should skip the check-email screen.
  final void Function(SignUpData data, bool sessionCreated) onComplete;
  const SignUpFlow({super.key, required this.onExit, required this.onComplete});

  @override
  State<SignUpFlow> createState() => _SignUpFlowState();
}

class _SignUpFlowState extends State<SignUpFlow> {
  int _step = 0;
  bool _loading = false;
  final _data = SignUpData();

  // Controllers keep field text when the user navigates between steps.
  late final TextEditingController _nameCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _passCtrl;
  late final TextEditingController _confirmCtrl;
  late final TextEditingController _dobCtrl;

  static const _kickers = ['Basic Information', 'Player Profile', 'Complete Profile'];
  static const _titles = ["Let's set up your account", 'How do you play?', 'Make it yours'];

  @override
  void initState() {
    super.initState();
    _nameCtrl    = TextEditingController(text: _data.name);
    _usernameCtrl = TextEditingController(text: _data.username);
    _emailCtrl   = TextEditingController(text: _data.email);
    _phoneCtrl   = TextEditingController(text: _data.phone);
    _passCtrl    = TextEditingController(text: _data.password);
    _confirmCtrl = TextEditingController(text: _data.confirm);
    _dobCtrl     = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    _dobCtrl.dispose();
    super.dispose();
  }

  void _back() => _step == 0 ? widget.onExit() : setState(() => _step--);

  static final _usernameRe = RegExp(r'^[a-z0-9_]{3,20}$');

  String? _validateStep0() {
    if (_data.name.trim().isEmpty)        return 'Please enter your full name.';
    final username = _data.username.trim().toLowerCase();
    if (username.isEmpty)                 return 'Please choose a username.';
    if (!_usernameRe.hasMatch(username)) {
      return 'Username must be 3–20 characters: letters, numbers, or _.';
    }
    final email = _data.email.trim();
    if (email.isEmpty)                    return 'Please enter your email.';
    if (!email.contains('@') || !email.contains('.')) return 'Please enter a valid email address.';
    if (_data.password.length < 8)        return 'Password must be at least 8 characters.';
    if (_data.password != _data.confirm)  return 'Passwords do not match.';
    if (_data.dob == null)                return 'Please select your date of birth.';
    if (_data.gender.isEmpty)             return 'Please select your gender.';
    // require a usable phone here, or the auth gate re-asks it in onboarding
    final digits = _data.phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 10 || digits.length > 12) {
      return 'Please enter a valid mobile number (e.g. 01001234567).';
    }
    return null;
  }

  Future<void> _next() async {
    if (_step == 0) {
      final err = _validateStep0();
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err), backgroundColor: const Color(0xFFB00020)),
        );
        return;
      }
      // username is unique — check before advancing so the user fixes it here,
      // not after submitting the whole form.
      setState(() => _loading = true);
      final free = await ProfileService.isUsernameAvailable(_data.username);
      if (!mounted) return;
      setState(() => _loading = false);
      if (!free) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('That username is already taken. Try another.'),
              backgroundColor: Color(0xFFB00020)),
        );
        return;
      }
    }
    if (_step < 2) {
      setState(() => _step++);
      return;
    }
    setState(() => _loading = true);
    final (error, sessionCreated) = await AuthService.signUp(_data);
    if (!mounted) return;
    setState(() => _loading = false);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: const Color(0xFFB00020)),
      );
    } else {
      widget.onComplete(_data, sessionCreated);
    }
  }

  Future<void> _pickDob() async {
    // players must be at least 13 — mirrors the DB's profiles_dob_chk backstop
    final now = DateTime.now();
    final latestDob = DateTime(now.year - 13, now.month, now.day);
    DateTime tempDate = _data.dob ?? DateTime(now.year - 24);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => Container(
        height: 300,
        decoration: const BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.lineSoft)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Date of Birth',
                      style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 14)),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      setState(() {
                        _data.dob = tempDate;
                        _dobCtrl.text = _fmtDate(tempDate);
                      });
                      Navigator.pop(context);
                    },
                    child: Text('Done',
                        style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 14)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _data.dob ?? DateTime(now.year - 24),
                maximumDate: latestDob,
                minimumDate: DateTime(now.year - 100, now.month, now.day),
                onDateTimeChanged: (date) => tempDate = date,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      color: AppColors.bg,
      child: Column(children: [
        // ── header ──
        Container(
          padding: EdgeInsets.fromLTRB(20, top + 14, 20, 16),
          decoration: const BoxDecoration(
            color: AppColors.bg,
            border: Border(bottom: BorderSide(color: AppColors.lineSoft)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              BackSquare(onTap: _back),
              const SizedBox(width: 14),
              Expanded(child: StepBar(step: _step, total: 3)),
              const SizedBox(width: 14),
              Text('${_step + 1} / 3',
                  style: AppText.bodyStrong(AppColors.inkFaint).copyWith(fontSize: 12)),
            ]),
            const SizedBox(height: 16),
            Text(_kickers[_step].toUpperCase(),
                style: AppText.kicker(AppColors.primary).copyWith(fontSize: 11, letterSpacing: 1.5)),
            const SizedBox(height: 4),
            Text(_titles[_step],
                style: AppText.stat(24, AppColors.ink).copyWith(letterSpacing: -0.5, height: 1.0)),
          ]),
        ),

        // ── body ──
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _step == 0
                  ? _basicStep()
                  : _step == 1
                      ? _playerStep()
                      : _completeStep(),
            ),
          ),
        ),

        // ── footer ──
        Container(
          padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(context).padding.bottom + 16),
          decoration: const BoxDecoration(
            color: AppColors.bg,
            border: Border(top: BorderSide(color: AppColors.lineSoft)),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _loading
                ? const SizedBox(
                    key: ValueKey('loading'),
                    height: 54,
                    child: Center(
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: AppColors.primary),
                    ),
                  )
                : AppButton(
                    key: const ValueKey('btn'),
                    _step == 2 ? 'Create Account' : 'Continue',
                    full: true,
                    height: 54,
                    onPressed: _next,
                  ),
          ),
        ),
      ]),
    );
  }

  // ── Step 1 — Basic Information ──────────────────────────────────────
  Widget _basicStep() => Column(key: const ValueKey(0), children: [
        AuthField(
          label: 'Full Name',
          icon: Icons.person_outline_rounded,
          hint: 'Karim Hassan',
          capitalization: TextCapitalization.words,
          controller: _nameCtrl,
          onChanged: (v) => _data.name = v,
        ),
        const SizedBox(height: 16),
        AuthField(
          label: 'Username',
          icon: Icons.alternate_email_rounded,
          hint: 'karim_h',
          helper: 'How teammates find you. 3–20 chars: letters, numbers, _',
          controller: _usernameCtrl,
          onChanged: (v) => _data.username = v,
        ),
        const SizedBox(height: 16),
        AuthField(
          label: 'Email',
          icon: Icons.mail_outline_rounded,
          hint: 'you@email.com',
          keyboard: TextInputType.emailAddress,
          controller: _emailCtrl,
          onChanged: (v) => _data.email = v,
        ),
        const SizedBox(height: 16),
        PhoneField(
          controller: _phoneCtrl,
          onChanged: (v) => _data.phone = v,
        ),
        const SizedBox(height: 16),
        AuthField(
          label: 'Password',
          icon: Icons.lock_outline_rounded,
          hint: 'At least 8 characters',
          helper: 'Use 8+ characters with a number.',
          obscure: true,
          controller: _passCtrl,
          onChanged: (v) => _data.password = v,
        ),
        const SizedBox(height: 16),
        AuthField(
          label: 'Confirm Password',
          icon: Icons.lock_outline_rounded,
          hint: 'Re-enter password',
          obscure: true,
          controller: _confirmCtrl,
          onChanged: (v) => _data.confirm = v,
        ),
        const SizedBox(height: 16),
        AuthField(
          label: 'Date of Birth',
          icon: Icons.calendar_today_outlined,
          hint: 'Select date',
          readOnly: true,
          onTap: _pickDob,
          controller: _dobCtrl,
          trailing: const Icon(Icons.expand_more_rounded, size: 20, color: AppColors.inkFaint),
        ),
        const SizedBox(height: 20),
        SegmentedField(
          label: 'Gender',
          columns: 2,
          value: _data.gender,
          onChanged: (v) => setState(() => _data.gender = v),
          options: const [
            SegOption('male', 'Male'),
            SegOption('female', 'Female'),
          ],
        ),
      ]);

  // ── Step 2 — Player Profile ─────────────────────────────────────────
  Widget _playerStep() => Column(key: const ValueKey(1), children: [
        SegmentedField(
          label: 'Preferred Playing Hand',
          columns: 2,
          value: _data.hand,
          onChanged: (v) => setState(() => _data.hand = v),
          options: const [
            SegOption('right', 'Right Handed', icon: Icons.back_hand_outlined, flipIcon: true),
            SegOption('left', 'Left Handed', icon: Icons.back_hand_outlined),
          ],
        ),
        const SizedBox(height: 22),
        SegmentedField(
          label: 'Preferred Court Side',
          columns: 3,
          value: _data.side,
          onChanged: (v) => setState(() => _data.side = v),
          options: const [
            SegOption('left', 'Left', side: CourtSide.left),
            SegOption('right', 'Right', side: CourtSide.right),
            SegOption('both', 'Both', side: CourtSide.both),
          ],
        ),
      ]);

  Future<void> _pickPhoto() async {
    try {
      final f = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 82,
      );
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final dot = f.name.lastIndexOf('.');
      final ext = dot >= 0 ? f.name.substring(dot + 1).toLowerCase() : 'jpg';
      if (!mounted) return;
      setState(() {
        _data.avatarBytes = bytes;
        _data.avatarExt = ext.isEmpty ? 'jpg' : ext;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        // Was interpolating the raw exception into the signup screen.
        const SnackBar(
            content: Text('Could not open your photos. If access is turned off, '
                'you can enable it in Settings.'),
            backgroundColor: Color(0xFFB00020)),
      );
    }
  }

  // ── Step 3 — Complete Profile ───────────────────────────────────────
  Widget _completeStep() => Column(key: const ValueKey(2), children: [
        const SizedBox(height: 6),
        Center(child: PhotoPicker(onTap: _pickPhoto, imageBytes: _data.avatarBytes)),
        const SizedBox(height: 14),
        Text('Add a profile photo so opponents recognise you on court.',
            textAlign: TextAlign.center,
            style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 12.5)),
        const SizedBox(height: 22),
        BioField(onChanged: (v) => _data.bio = v),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.22)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.primary),
            const SizedBox(width: 11),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 12.5, height: 1.5),
                  children: [
                    const TextSpan(text: 'You can refine your profile, ELO and tier anytime from '),
                    TextSpan(text: 'Settings', style: AppText.bodyStrong().copyWith(fontSize: 12.5)),
                    const TextSpan(text: '.'),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ]);

  static String _fmtDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }
}
