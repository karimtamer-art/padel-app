import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/avatar_crop_sheet.dart';
import 'package:padel_clay/backend/services/auth_service.dart';
import 'package:padel_clay/backend/services/profile_service.dart';
import 'package:padel_clay/backend/models/onboarding_models.dart';
import 'auth_widgets.dart';
import 'onboarding/onboarding_widgets.dart';

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

  // Kicker / title / subtitle per step. Deliberately the same three-line
  // header OnboardingFlow uses - a Google or Apple signup lands there instead
  // of here, and the two must not read as different apps.
  static const _kickers = ['About you', 'Your game', 'Your profile'];
  static const _titles = [
    "Let's set up your account",
    'Your playing style',
    'Put a face to your name',
  ];
  static const _subs = [
    'A few details so other players know who they are matching with.',
    'Tell us your dominant hand and preferred court side.',
    'Both are optional — you can add or change them later in Edit Profile.',
  ];

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
    // Re-check the handle. It was checked on step 1, which is two steps and an
    // unbounded amount of time ago, and handle_new_user does not fail on a
    // taken username — it quietly generates a near-miss instead. Better to send
    // them back one screen than to create the account under a name they never
    // chose.
    if (!await ProfileService.isUsernameAvailable(_data.username)) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _step = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('That username was taken while you were signing up. '
                'Please pick another.'),
            backgroundColor: Color(0xFFB00020)),
      );
      return;
    }
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Container(
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
              Expanded(child: OnbProgress(step: _step, total: 3)),
              const SizedBox(width: 14),
              Text('${_step + 1} / 3',
                  style: AppText.bodyStrong(AppColors.inkFaint).copyWith(fontSize: 12)),
            ]),
            const SizedBox(height: 18),
            Text(_kickers[_step].toUpperCase(),
                style: AppText.kicker(AppColors.primary).copyWith(fontSize: 11, letterSpacing: 1.5)),
            const SizedBox(height: 5),
            Text(_titles[_step],
                style: AppText.stat(25, AppColors.ink).copyWith(letterSpacing: -0.6, height: 1.05)),
            const SizedBox(height: 7),
            Text(_subs[_step],
                style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13.5, height: 1.45)),
          ]),
        ),

        // ── body ──
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
            physics: const BouncingScrollPhysics(),
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
    ),   // Container
    );   // GestureDetector
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
        const SizedBox(height: 22),
        const _SectionLabel(icon: Icons.wc_rounded, label: 'How do you identify?'),
        const SizedBox(height: 12),
        _cardRow([
          for (final g in Gender.values)
            ChoiceCard(
              label: g.label,
              icon: g.icon,
              selected: _data.gender == g.id,
              onTap: () => setState(() => _data.gender = g.id),
            ),
        ]),
      ]);

  // ── Step 2 — Player Profile ─────────────────────────────────────────
  Widget _playerStep() => Column(key: const ValueKey(1), children: [
        const _SectionLabel(
          icon: Icons.back_hand_outlined,
          label: 'Which hand do you play with?',
        ),
        const SizedBox(height: 12),
        _cardRow([
          for (final h in Hand.values)
            ChoiceCard(
              label: h.label,
              icon: h.icon,
              flipIcon: h.flipIcon,
              selected: _data.hand == h.id,
              onTap: () => setState(() => _data.hand = h.id),
            ),
        ]),
        const SizedBox(height: 22),
        const _SectionLabel(
          icon: Icons.sports_tennis_rounded,
          label: 'Your preferred court side?',
        ),
        const SizedBox(height: 12),
        _cardRow(
          [
            for (final s in CourtSidePref.values)
              ChoiceCard(
                label: s.label,
                glyph: CourtSideGlyph(
                  // "Both" lights up the whole court.
                  leftFill: s != CourtSidePref.right,
                  rightFill: s != CourtSidePref.left,
                  selected: _data.side == s.id,
                  // Three across instead of two - a 70pt court would overflow
                  // the row on a narrow phone.
                  width: 52,
                ),
                selected: _data.side == s.id,
                onTap: () => setState(() => _data.side = s.id),
              ),
          ],
          gap: 10,
        ),
      ]);

  /// Equal-width row of [ChoiceCard]s - the same grid OnboardingFlow lays its
  /// answer cards out on.
  Widget _cardRow(List<Widget> cards, {double gap = 12}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < cards.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(child: cards[i]),
          ],
        ],
      );

  Future<void> _pickPhoto() async {
    try {
      final f = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 90,
      );
      if (f == null) return;
      final raw = await f.readAsBytes();
      if (!mounted) return;
      final bytes = await AvatarCropSheet.show(context, raw);
      if (bytes == null || !mounted) return; // cancelled
      setState(() {
        _data.avatarBytes = bytes;
        _data.avatarExt = 'png'; // the crop always encodes PNG
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
        Text('A photo helps opponents recognise you on court.',
            textAlign: TextAlign.center,
            style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 12.5)),
        const SizedBox(height: 22),
        BioField(onChanged: (v) => _data.bio = v),
      ]);

  static String _fmtDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }
}

/// Small icon + caption above a group of [ChoiceCard]s. Mirrors the private
/// `_SectionLabel` in `onboarding/onboarding_flow.dart` so the two flows label
/// their answer grids identically; change one, change the other.
class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 15, color: AppColors.inkSoft),
      const SizedBox(width: 7),
      Text(label,
          style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 13)),
    ]);
  }
}
