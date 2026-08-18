import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_text.dart';
import '../../../../backend/models/onboarding_models.dart';
import '../../../../backend/services/profile_service.dart';
import '../auth_widgets.dart' show PhotoPicker, BioField, AuthField;
import '../../../widgets/avatar_crop_sheet.dart';
import 'onboarding_widgets.dart';

/// Mandatory profile-completion flow. Shown by [AuthGate] when a signed-in user
/// is missing any onboarding field.
///
/// Steps: Date of Birth → Gender → Hand + Court Side → Phone → Photo + Bio.
///
/// The last step is where a Google/Apple signup gets asked for a picture and a
/// bio at all. [SignUpFlow] asks on its own final step, but a social signup
/// never passes through it — it lands straight here — so without this step
/// those accounts had no way to add either during setup.
///
/// Photo and bio are both OPTIONAL: the step is always valid and the button
/// says Finish. They are also saved AFTER the onboarding upsert, so a failed
/// upload can never cost someone the answers they just gave.
class OnboardingFlow extends StatefulWidget {
  final String userId;
  final String displayName;
  final ProfileService profileService;
  final OnboardingProfile initial;
  final VoidCallback onCompleted;
  final Future<void> Function()? onSignOut;

  const OnboardingFlow({
    super.key,
    required this.userId,
    required this.profileService,
    required this.onCompleted,
    this.displayName = '',
    this.initial = const OnboardingProfile(),
    this.onSignOut,
  });

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

/// The steps this flow can show, in order. Which ones actually appear is
/// decided once in [_OnboardingFlowState._steps].
enum _Step { name, username, dob, gender, style, phone, extras }

class _OnboardingFlowState extends State<OnboardingFlow> {
  /// The steps THIS player sees.
  ///
  /// Built once, and indexed into everywhere, because the alternative — fixed
  /// indices with conditionals sprinkled through three separate switches — is
  /// how you get an off-by-one that shows the phone step's title above the
  /// gender step's body.
  ///
  /// name/username are asked only when they are missing or auto-generated, so
  /// an email or Google signup sees exactly the five steps it saw before and
  /// an Apple one is finally asked for both.
  late final List<_Step> _steps = [
    if (!OnboardingProfile.isUsableName(widget.initial.name)) _Step.name,
    if (OnboardingProfile.isGeneratedUsername(widget.initial.username) ||
        (widget.initial.username ?? '').trim().isEmpty)
      _Step.username,
    _Step.dob,
    _Step.gender,
    _Step.style,
    _Step.phone,
    _Step.extras,
  ];

  int get _total => _steps.length;
  _Step get _cur => _steps[_step];

  late OnboardingProfile _draft = widget.initial;
  late int _step = _firstIncompleteStep();
  bool _forward = true;
  bool _checkingHandle = false;
  bool _saving = false;
  String? _error;

  // Step 4. Kept out of OnboardingProfile on purpose — that model's isComplete
  // mirrors the server's generated onboarding_completed column, and neither of
  // these is required to finish.
  Uint8List? _avatarBytes;
  String _avatarExt = 'jpg';
  String _bio = '';

  static const _kickers = <_Step, String>{
    _Step.name: 'About you',
    _Step.username: 'About you',
    _Step.dob: 'About you',
    _Step.gender: 'About you',
    _Step.style: 'Your game',
    _Step.phone: 'Contact',
    _Step.extras: 'Your profile',
  };
  static const _titles = <_Step, String>{
    _Step.name: 'What should we call you?',
    _Step.username: 'Pick your username',
    _Step.dob: 'When were you born?',
    _Step.gender: 'How do you identify?',
    _Step.style: 'Your playing style',
    _Step.phone: 'What\'s your phone number?',
    _Step.extras: 'Put a face to your name',
  };
  static const _subs = <_Step, String>{
    _Step.name: 'This is the name other players see on matches and rankings.',
    _Step.username: 'Your unique handle. Letters, numbers and _ only.',
    _Step.dob: 'We use this to match you with players in your age group.',
    _Step.gender: 'Helps us place you in the right leagues and events.',
    _Step.style: 'Tell us your dominant hand and preferred court side.',
    _Step.phone: 'So other players can reach you to arrange matches.',
    _Step.extras: 'Both are optional — you can add or change them later in Edit Profile.',
  };

  static final _usernameRe = RegExp(r'^[a-z0-9_]{3,20}$');

  /// Where to open. Anything we still have to ASK for comes first — landing an
  /// Apple signup on the birthday step while its name is blank is how the
  /// missing answer stays missing.
  int _firstIncompleteStep() {
    if (_steps.contains(_Step.name)) return _steps.indexOf(_Step.name);
    if (_steps.contains(_Step.username)) return _steps.indexOf(_Step.username);
    if (widget.initial.dateOfBirth == null) return _steps.indexOf(_Step.dob);
    if (widget.initial.gender == null) return _steps.indexOf(_Step.gender);
    if (widget.initial.hand == null || widget.initial.side == null) {
      return _steps.indexOf(_Step.style);
    }
    if (OnboardingValidation.phone(widget.initial.phone) != null) {
      return _steps.indexOf(_Step.phone);
    }
    return 0;
  }

  bool get _stepValid {
    switch (_cur) {
      case _Step.name:
        return OnboardingProfile.isUsableName(_draft.name) &&
            _draft.name!.trim().length >= 2;
      case _Step.username:
        return _usernameRe.hasMatch((_draft.username ?? '').trim().toLowerCase());
      case _Step.dob:
        return OnboardingValidation.dateOfBirth(_draft.dateOfBirth) == null;
      case _Step.gender:
        return _draft.gender != null;
      case _Step.style:
        return _draft.hand != null && _draft.side != null;
      case _Step.phone:
        return OnboardingValidation.phone(_draft.phone) == null;
      case _Step.extras:
        return true; // photo and bio are both optional
    }
  }

  void _back() {
    if (_step == 0) return;
    setState(() {
      _forward = false;
      _error = null;
      _step--;
    });
  }

  Future<void> _next() async {
    if (!_stepValid || _saving || _checkingHandle) return;
    // Check the handle before moving on, not at Finish — the unique index would
    // otherwise reject it five steps later, on the screen that can't fix it.
    if (_cur == _Step.username) {
      final handle = _draft.username!.trim().toLowerCase();
      setState(() { _checkingHandle = true; _error = null; });
      final free = await ProfileService.isUsernameAvailable(handle);
      if (!mounted) return;
      setState(() => _checkingHandle = false);
      if (!free) {
        setState(() => _error = 'That username is already taken. Try another.');
        return;
      }
    }
    if (_step < _total - 1) {
      setState(() {
        _forward = true;
        _error = null;
        _step++;
      });
      return;
    }
    await _submit();
  }

  Future<void> _submit() async {
    // isValid mirrors the server's onboarding_completed, which doesn't include
    // name/username — so the steps we added need checking separately or they
    // could be walked past.
    if (!OnboardingValidation.isValid(_draft) ||
        (_steps.contains(_Step.name) &&
            !OnboardingProfile.isUsableName(_draft.name)) ||
        (_steps.contains(_Step.username) &&
            !_usernameRe.hasMatch((_draft.username ?? '').trim().toLowerCase()))) {
      setState(() => _error = 'Please complete every step before finishing.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      await widget.profileService.saveOnboarding(widget.userId, _draft, name: widget.displayName);

      // Read it back before declaring victory. onCompleted() sends AuthGate to
      // _resolve(), which re-reads the profile and returns straight here if it
      // still looks incomplete — that is the onboarding loop, and from the
      // player's side it is indistinguishable from the app being broken.
      //
      // An upsert can "succeed" and change nothing: PostgREST reports no error
      // when RLS matches zero rows, and a column the client has no grant on is
      // simply refused. One extra round trip, once per account, turns an
      // infinite loop into a message that says what happened.
      final saved = await widget.profileService.fetch(widget.userId);
      if (!mounted) return;
      if (saved == null || !saved.isComplete) {
        setState(() {
          _saving = false;
          _error = "Your answers were sent but the profile didn't save. "
              'Please try Finish again — if it keeps happening, contact '
              'help@padel-rivals.com.';
        });
        return;
      }
      // Optional extras, deliberately after the answers are safely stored and
      // deliberately not awaited into the same try/catch outcome: a photo that
      // fails to upload must not throw away a completed onboarding and drop
      // someone back at step one. Worst case they add it in Edit Profile.
      await _saveExtras();
      if (!mounted) return;
      widget.onCompleted();
    } catch (e) {
      if (!mounted) return;
      setState(() { _saving = false; _error = _friendly(e); });
    }
  }

  /// Photo + bio. Swallows its own failures — see the call site.
  Future<void> _saveExtras() async {
    try {
      final bio = _bio.trim();
      if (bio.isNotEmpty) {
        await ProfileService.updateProfile(widget.userId, {'bio': bio});
      }
      final bytes = _avatarBytes;
      if (bytes != null) {
        // Writes profiles.avatar_url itself on success.
        await ProfileService.uploadAvatar(bytes, _avatarExt);
      }
    } catch (_) {/* onboarding is already saved; not worth blocking on */}
  }

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
        _avatarBytes = bytes;
        _avatarExt = 'png'; // the crop always encodes PNG
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not open your photos. You can add one later.');
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.toLowerCase().contains('failed host')) {
      return 'No connection. Check your network and try again.';
    }
    return 'Couldn\'t save your details. Please try again.';
  }

  void _handleBack() {
    if (_step == 0) {
      widget.onSignOut?.call();
    } else {
      _back();
    }
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
              _IconSquare(
                icon: Icons.arrow_back_rounded,
                enabled: !_saving,
                onTap: _handleBack,
              ),
              const SizedBox(width: 14),
              Expanded(child: OnbProgress(step: _step, total: _total)),
              const SizedBox(width: 14),
              Text('${_step + 1} / $_total',
                  style: AppText.bodyStrong(AppColors.inkFaint).copyWith(fontSize: 12)),
            ]),
            const SizedBox(height: 18),
            Text(_kickers[_cur]!.toUpperCase(),
                style: AppText.kicker(AppColors.primary).copyWith(fontSize: 11, letterSpacing: 1.5)),
            const SizedBox(height: 5),
            Text(_titles[_cur]!,
                style: AppText.stat(25, AppColors.ink).copyWith(letterSpacing: -0.6, height: 1.05)),
            const SizedBox(height: 7),
            Text(_subs[_cur]!,
                style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13.5, height: 1.45)),
          ]),
        ),

        // ── body ──
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) {
              final dx = _forward ? 0.06 : -0.06;
              return FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(begin: Offset(dx, 0), end: Offset.zero).animate(anim),
                  child: child,
                ),
              );
            },
            child: SingleChildScrollView(
              key: ValueKey(_step),
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
              physics: const BouncingScrollPhysics(),
              child: _stepBody(),
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_error != null) ...[
              OnbErrorBar(_error!),
              const SizedBox(height: 12),
            ],
            _PrimaryButton(
              label: _step == _total - 1 ? 'Finish' : 'Continue',
              enabled: _stepValid,
              loading: _saving || _checkingHandle,
              onTap: _next,
            ),
          ]),
        ),
      ]),
    ),   // Container
    );   // GestureDetector
  }

  Widget _stepBody() {
    switch (_cur) {
      case _Step.name:
        return _TextStep(
          key: const ValueKey('name'),
          label: 'Full name',
          hint: 'e.g. Karim Tamer',
          icon: Icons.person_outline_rounded,
          initial: _draft.name ?? '',
          capitalization: TextCapitalization.words,
          onChanged: (v) => setState(() {
            _draft = _draft.copyWith(name: v);
            _error = null;
          }),
        );
      case _Step.username:
        return _TextStep(
          key: const ValueKey('username'),
          label: 'Username',
          hint: 'e.g. karim_t',
          helper: '3–20 characters: letters, numbers or _',
          icon: Icons.alternate_email_rounded,
          initial: _draft.username ?? '',
          onChanged: (v) => setState(() {
            _draft = _draft.copyWith(username: v.trim().toLowerCase());
            _error = null;
          }),
        );
      case _Step.dob:
        return _DobStep(
          value: _draft.dateOfBirth,
          onChanged: (d) => setState(() {
            _draft = _draft.copyWith(dateOfBirth: d);
            _error = null;
          }),
        );
      case _Step.gender:
        return _grid([
          for (final g in Gender.values)
            ChoiceCard(
              label: g.label,
              icon: g.icon,
              selected: _draft.gender == g,
              onTap: () => setState(() {
                _draft = _draft.copyWith(gender: g);
                _error = null;
              }),
            ),
        ]);
      case _Step.style:
        return _HandSideStep(
          hand: _draft.hand,
          side: _draft.side,
          onHandChanged: (h) => setState(() {
            _draft = _draft.copyWith(hand: h);
            _error = null;
          }),
          onSideChanged: (s) => setState(() {
            _draft = _draft.copyWith(side: s);
            _error = null;
          }),
        );
      case _Step.phone:
        return _PhoneStep(
          value: _draft.phone,
          onChanged: (p) => setState(() {
            _draft = _draft.copyWith(phone: p);
            _error = null;
          }),
        );
      case _Step.extras:
        return Column(key: const ValueKey('photo_bio'), children: [
          const SizedBox(height: 6),
          Center(child: PhotoPicker(onTap: _pickPhoto, imageBytes: _avatarBytes)),
          const SizedBox(height: 14),
          Text('A photo helps opponents recognise you on court.',
              textAlign: TextAlign.center,
              style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 12.5)),
          const SizedBox(height: 22),
          BioField(onChanged: (v) => _bio = v),
        ]);
    }
  }

  Widget _grid(List<Widget> cards) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: cards[i]),
          ],
        ],
      );
}

// ── Step 0: Date of Birth ─────────────────────────────────────────────────────
/// Single-field step (name, username).
///
/// Stateful only to own the controller: the parent rebuilds on every keystroke
/// to re-evaluate the Continue button, and a controller created in build would
/// reset the cursor to the start each time.
class _TextStep extends StatefulWidget {
  final String label;
  final String? hint;
  final String? helper;
  final IconData icon;
  final String initial;
  final TextCapitalization capitalization;
  final ValueChanged<String> onChanged;

  const _TextStep({
    super.key,
    required this.label,
    required this.icon,
    required this.initial,
    required this.onChanged,
    this.hint,
    this.helper,
    this.capitalization = TextCapitalization.none,
  });

  @override
  State<_TextStep> createState() => _TextStepState();
}

class _TextStepState extends State<_TextStep> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: AuthField(
        label: widget.label,
        hint: widget.hint,
        helper: widget.helper,
        icon: widget.icon,
        controller: _ctrl,
        capitalization: widget.capitalization,
        autocorrect: false,
        onChanged: widget.onChanged,
      ),
    );
  }
}

class _DobStep extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  const _DobStep({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final initial = value ?? DateTime(now.year - 24, now.month, now.day);
    final err = value == null ? null : OnboardingValidation.dateOfBirth(value);
    final age = value == null ? null : OnboardingValidation.ageOn(value!);

    return Column(key: const ValueKey('dob'), children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.line, width: 1.5),
          boxShadow: kCardShadow,
        ),
        child: Column(children: [
          Text(value == null ? 'Scroll to set' : _fmt(value!),
              style: AppText.stat(26, value == null ? AppColors.inkFaint : AppColors.ink)
                  .copyWith(letterSpacing: -0.5)),
          const SizedBox(height: 6),
          Text(age == null ? 'Date of birth' : '$age years old',
              style: AppText.bodyStrong(age == null ? AppColors.inkFaint : AppColors.primary)
                  .copyWith(fontSize: 13)),
        ]),
      ),
      const SizedBox(height: 16),
      Container(
        height: 196,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.line, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: CupertinoTheme(
          data: const CupertinoThemeData(
            textTheme: CupertinoTextThemeData(
              dateTimePickerTextStyle: TextStyle(
                  fontSize: 20, color: AppColors.ink, fontWeight: FontWeight.w700),
            ),
          ),
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.date,
            initialDateTime: initial,
            minimumDate: DateTime(now.year - OnboardingValidation.maxAge),
            maximumDate: now,
            onDateTimeChanged: onChanged,
          ),
        ),
      ),
      if (err != null) ...[
        const SizedBox(height: 14),
        OnbErrorBar(err),
      ],
    ]);
  }

  static String _fmt(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }
}

// ── Step 2: Hand + Court Side (combined) ─────────────────────────────────────
class _HandSideStep extends StatelessWidget {
  final Hand? hand;
  final CourtSidePref? side;
  final ValueChanged<Hand> onHandChanged;
  final ValueChanged<CourtSidePref> onSideChanged;

  const _HandSideStep({
    required this.hand,
    required this.side,
    required this.onHandChanged,
    required this.onSideChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(key: const ValueKey('hand_side'), children: [
      // ── Hand ──
      const _SectionLabel(
        icon: Icons.back_hand_outlined,
        label: 'Which hand do you play with?',
      ),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < Hand.values.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: ChoiceCard(
                label: Hand.values[i].label,
                icon: Hand.values[i].icon,
                flipIcon: Hand.values[i].flipIcon,
                selected: hand == Hand.values[i],
                onTap: () => onHandChanged(Hand.values[i]),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 22),
      // ── Court Side ──
      const _SectionLabel(
        icon: Icons.sports_tennis_rounded,
        label: 'Your preferred court side?',
      ),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < CourtSidePref.values.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: ChoiceCard(
                label: CourtSidePref.values[i].label,
                glyph: CourtSideGlyph(
                  // "Both" lights up the whole court.
                  leftFill: CourtSidePref.values[i] != CourtSidePref.right,
                  rightFill: CourtSidePref.values[i] != CourtSidePref.left,
                  selected: side == CourtSidePref.values[i],
                  // Three across instead of two — a 70pt court would overflow
                  // the row on a narrow phone.
                  width: 52,
                ),
                selected: side == CourtSidePref.values[i],
                onTap: () => onSideChanged(CourtSidePref.values[i]),
              ),
            ),
          ],
        ],
      ),
    ]);
  }
}

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

// ── Step 3: Phone Number ──────────────────────────────────────────────────────
class _PhoneStep extends StatefulWidget {
  final String? value;
  final ValueChanged<String> onChanged;
  const _PhoneStep({required this.value, required this.onChanged});

  @override
  State<_PhoneStep> createState() => _PhoneStepState();
}

class _PhoneStepState extends State<_PhoneStep> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value ?? '');
  bool _touched = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final err = _touched ? OnboardingValidation.phone(_ctrl.text) : null;

    // Wrapped in a (transparent) Material so the TextField has a Material
    // ancestor — the onboarding shell is a plain Container, not a Scaffold.
    return Material(
      type: MaterialType.transparency,
      child: Column(key: const ValueKey('phone'), children: [
      Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: err != null ? AppColors.danger : AppColors.line,
            width: 1.5,
          ),
          boxShadow: kCardShadow,
        ),
        child: Row(children: [
          // +20 prefix badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: AppColors.line, width: 1.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('🇪🇬', style: TextStyle(fontSize: 20, decoration: TextDecoration.none)),
              const SizedBox(width: 8),
              Text('+20',
                  style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 16)),
            ]),
          ),
          // number field
          Expanded(
            child: TextField(
              controller: _ctrl,
              keyboardType: TextInputType.phone,
              style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 17),
              decoration: InputDecoration(
                hintText: '1001234567',
                hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 17),
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              ),
              onChanged: (v) {
                setState(() => _touched = true);
                widget.onChanged(v);
              },
              onTap: () => setState(() => _touched = false),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      // hint
      Row(children: [
        const Icon(Icons.info_outline_rounded, size: 14, color: AppColors.inkFaint),
        const SizedBox(width: 6),
        Text('Used so other players can contact you for matches.',
            style: AppText.body(AppColors.inkFaint).copyWith(fontSize: 12.5)),
      ]),
      if (err != null) ...[
        const SizedBox(height: 14),
        OnbErrorBar(err),
      ],
    ]),
    );
  }
}

// ── Footer primary button ─────────────────────────────────────────────────────
class _PrimaryButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;
  const _PrimaryButton({
    required this.label,
    required this.enabled,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = enabled && !loading;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: Material(
        color: active ? AppColors.primary : AppColors.line,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: active ? onTap : null,
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: AppColors.primaryInk),
                  )
                : Text(label,
                    style: AppText.bodyStrong(
                            active ? AppColors.primaryInk : AppColors.inkFaint)
                        .copyWith(fontSize: 15, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    );
  }
}

class _IconSquare extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  const _IconSquare({required this.icon, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AppColors.field, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, size: 19, color: AppColors.ink),
        ),
      ),
    );
  }
}
