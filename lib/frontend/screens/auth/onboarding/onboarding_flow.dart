import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_text.dart';
import '../../../../backend/models/onboarding_models.dart';
import '../../../../backend/services/profile_service.dart';
import 'onboarding_widgets.dart';

/// Mandatory profile-completion flow. Shown by [AuthGate] when a signed-in user
/// is missing any onboarding field.
///
/// Steps: Date of Birth → Gender → Hand + Court Side → Phone.
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

class _OnboardingFlowState extends State<OnboardingFlow> {
  static const _total = 4;

  late OnboardingProfile _draft = widget.initial;
  late int _step = _firstIncompleteStep();
  bool _forward = true;
  bool _saving = false;
  String? _error;

  static const _kickers = [
    'About you', 'About you', 'Your game', 'Contact',
  ];
  static const _titles = [
    'When were you born?',
    'How do you identify?',
    'Your playing style',
    'What\'s your phone number?',
  ];
  static const _subs = [
    'We use this to match you with players in your age group.',
    'Helps us place you in the right leagues and events.',
    'Tell us your dominant hand and preferred court side.',
    'So other players can reach you to arrange matches.',
  ];

  int _firstIncompleteStep() {
    if (widget.initial.dateOfBirth == null) return 0;
    if (widget.initial.gender == null) return 1;
    if (widget.initial.hand == null || widget.initial.side == null) return 2;
    if (OnboardingValidation.phone(widget.initial.phone) != null) return 3;
    return 0;
  }

  bool get _stepValid {
    switch (_step) {
      case 0:
        return OnboardingValidation.dateOfBirth(_draft.dateOfBirth) == null;
      case 1:
        return _draft.gender != null;
      case 2:
        return _draft.hand != null && _draft.side != null;
      case 3:
        return OnboardingValidation.phone(_draft.phone) == null;
      default:
        return false;
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
    if (!_stepValid || _saving) return;
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
    if (!OnboardingValidation.isValid(_draft)) {
      setState(() => _error = 'Please complete every step before finishing.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      await widget.profileService.saveOnboarding(widget.userId, _draft, name: widget.displayName);
      if (!mounted) return;
      widget.onCompleted();
    } catch (e) {
      if (!mounted) return;
      setState(() { _saving = false; _error = _friendly(e); });
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
              loading: _saving,
              onTap: _next,
            ),
          ]),
        ),
      ]),
    ),   // Container
    );   // GestureDetector
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _DobStep(
          value: _draft.dateOfBirth,
          onChanged: (d) => setState(() {
            _draft = _draft.copyWith(dateOfBirth: d);
            _error = null;
          }),
        );
      case 1:
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
      case 2:
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
      case 3:
        return _PhoneStep(
          value: _draft.phone,
          onChanged: (p) => setState(() {
            _draft = _draft.copyWith(phone: p);
            _error = null;
          }),
        );
      default:
        return const SizedBox.shrink();
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
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: ChoiceCard(
                label: CourtSidePref.values[i].label,
                glyph: CourtSideGlyph(
                  leftActive: CourtSidePref.values[i] == CourtSidePref.left,
                  selected: side == CourtSidePref.values[i],
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
