import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/auth_service.dart';
import 'auth_widgets.dart';

/// Last step of sign-up when Supabase has "Confirm email" on: the player types
/// the 6-digit code from the signup email.
///
/// There is no success callback on purpose. Verifying creates the session,
/// which fires `signedIn` on the auth stream, and [AuthGate] moves the whole
/// app off the sign-up flow on its own.
class CheckEmailScreen extends StatefulWidget {
  final String email;
  final VoidCallback onBack;

  /// Photo picked during sign-up. There was no session to upload it with at
  /// that point, so it rides along and lands once the code is accepted.
  final Uint8List? avatarBytes;
  final String avatarExt;

  const CheckEmailScreen({
    super.key,
    required this.email,
    required this.onBack,
    this.avatarBytes,
    this.avatarExt = 'jpg',
  });

  @override
  State<CheckEmailScreen> createState() => _CheckEmailScreenState();
}

class _CheckEmailScreenState extends State<CheckEmailScreen> {
  static const _len = 6;

  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _tick;
  int _wait = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startCooldown();
    // _CodeField paints the caret box from hasFocus, which changes without any
    // text change — so it needs its own repaint trigger.
    _focus.addListener(_onFocus);
    // Straight into the keyboard — this screen has exactly one thing to do.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    _focus.removeListener(_onFocus);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Mirrors the service's clock rather than keeping its own count, so backing
  /// out and returning can't hand the player a fresh 60 seconds.
  void _startCooldown() {
    _tick?.cancel();
    _wait = AuthService.signupCodeCooldownRemaining(widget.email);
    if (_wait == 0) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = AuthService.signupCodeCooldownRemaining(widget.email);
      if (!mounted) return t.cancel();
      setState(() => _wait = left);
      if (left == 0) t.cancel();
    });
  }

  Future<void> _verify() async {
    final code = _ctrl.text.trim();
    if (code.length < _len || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AuthService.verifySignupCode(
      widget.email,
      code,
      avatarBytes: widget.avatarBytes,
      avatarExt: widget.avatarExt,
    );
    // On success the auth stream has already moved AuthGate on and this widget
    // is being torn down — touching state here would throw.
    if (!mounted || err == null) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    _ctrl.clear();
    _focus.requestFocus();
  }

  Future<void> _resend() async {
    if (_wait > 0 || _busy) return;
    setState(() => _busy = true);
    final err = await AuthService.resendSignupCode(widget.email);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    _startCooldown();
    if (err == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('New code sent to ${widget.email}.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    final filled = _ctrl.text.length == _len;

    return Container(
      color: AppColors.bg,
      padding: EdgeInsets.fromLTRB(20, top + 14, 20, bottom + 24),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          BackSquare(onTap: widget.onBack),
          const SizedBox(height: 32),
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mark_email_unread_outlined,
                  size: 40, color: AppColors.primary),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text('Enter your code',
                textAlign: TextAlign.center,
                style: AppText.stat(29, AppColors.ink)
                    .copyWith(letterSpacing: -0.6, height: 1.0)),
          ),
          const SizedBox(height: 12),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text.rich(
                TextSpan(
                  style: AppText.body(AppColors.inkSoft)
                      .copyWith(fontSize: 15, height: 1.55),
                  children: [
                    const TextSpan(text: 'We sent a 6-digit code to\n'),
                    TextSpan(
                      text: widget.email,
                      style:
                          AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 15),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 28),
          _CodeField(
            controller: _ctrl,
            focusNode: _focus,
            length: _len,
            error: _error != null,
            enabled: !_busy,
            onChanged: (v) {
              setState(() => _error = null);
              if (v.length == _len) _verify(); // saves a tap on the last digit
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Row(children: [
              const Icon(Icons.error_outline_rounded,
                  size: 17, color: AppColors.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_error!,
                    style: AppText.small(AppColors.danger)
                        .copyWith(fontSize: 13, height: 1.4)),
              ),
            ]),
          ],
          const SizedBox(height: 24),
          AppButton(
            _busy ? 'Verifying…' : 'Verify email',
            full: true,
            height: 54,
            onPressed: (filled && !_busy) ? _verify : null,
          ),
          const SizedBox(height: 18),
          Center(
            child: TextButton(
              onPressed: (_wait == 0 && !_busy) ? _resend : null,
              child: Text(
                _wait > 0 ? 'Resend code in ${_wait}s' : 'Resend code',
                style: AppText.bodyStrong(
                        _wait > 0 ? AppColors.inkFaint : AppColors.primary)
                    .copyWith(fontSize: 14),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.cardR,
              border: Border.all(color: AppColors.line),
              boxShadow: kCardShadow,
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline_rounded,
                  size: 19, color: AppColors.primary),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  "Can't find it? Check your spam folder. The code expires in "
                  '1 hour.',
                  style: AppText.body(AppColors.inkSoft)
                      .copyWith(fontSize: 13, height: 1.5),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Six boxes over one real field.
///
/// Per-box TextFields are the obvious build and the wrong one — they each own a
/// fragment of the code, so paste drops five digits and backspace at the start
/// of a box has nowhere to go. This is a single value rendered six times: paste,
/// autofill and backspace all behave because there is only ever one field.
class _CodeField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final int length;
  final bool error;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _CodeField({
    required this.controller,
    required this.focusNode,
    required this.length,
    required this.error,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final text = controller.text;
    return GestureDetector(
      onTap: () => focusNode.requestFocus(),
      behavior: HitTestBehavior.opaque,
      child: Stack(children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(length, (i) {
            final filled = i < text.length;
            final active = focusNode.hasFocus && i == text.length;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == length - 1 ? 0 : 8),
                child: Container(
                  height: 60,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.field,
                    borderRadius: AppRadius.btnR,
                    border: Border.all(
                      color: error
                          ? AppColors.danger
                          : active
                              ? AppColors.primary
                              : filled
                                  ? AppColors.line
                                  : AppColors.lineSoft,
                      width: (active || error) ? 2 : 1,
                    ),
                  ),
                  child: Text(filled ? text[i] : '',
                      style: AppText.stat(24, AppColors.ink)),
                ),
              ),
            );
          }),
        ),
        // The real field, invisible and stretched over the boxes so a tap
        // anywhere on the row focuses it and the system keyboard/autofill
        // target something real.
        Positioned.fill(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            onChanged: onChanged,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(length),
            ],
            showCursor: false,
            enableInteractiveSelection: false,
            style: const TextStyle(color: Colors.transparent, height: 0.01),
            decoration: const InputDecoration(
              border: InputBorder.none,
              counterText: '',
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ]),
    );
  }
}
