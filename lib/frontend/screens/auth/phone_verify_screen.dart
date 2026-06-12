import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/auth_service.dart';

class PhoneVerifyScreen extends StatefulWidget {
  final String phone;
  final VoidCallback onVerified;
  final VoidCallback onSkip;
  const PhoneVerifyScreen({
    super.key,
    required this.phone,
    required this.onVerified,
    required this.onSkip,
  });

  @override
  State<PhoneVerifyScreen> createState() => _PhoneVerifyScreenState();
}

class _PhoneVerifyScreenState extends State<PhoneVerifyScreen> {
  bool _codeSent = false;
  bool _sending = false;
  bool _verifying = false;
  String _otp = '';

  String get _formatted => AuthService.formatPhone(widget.phone);

  Future<void> _sendCode() async {
    setState(() => _sending = true);
    final err = await AuthService.sendPhoneOtp(widget.phone);
    if (!mounted) return;
    setState(() { _sending = false; _codeSent = true; });
    if (err != null) {
      _err(err);
      setState(() => _codeSent = false);
    }
  }

  Future<void> _verify() async {
    if (_otp.length < 6) {
      _err('Please enter the full 6-digit code.');
      return;
    }
    setState(() => _verifying = true);
    final err = await AuthService.verifyPhoneOtp(widget.phone, _otp);
    if (!mounted) return;
    setState(() => _verifying = false);
    if (err != null) {
      _err(err);
    } else {
      widget.onVerified();
    }
  }

  void _err(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFFB00020)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      color: AppColors.bg,
      padding: EdgeInsets.fromLTRB(20, top + 20, 20, bottom + 30),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Spacer(),
        Center(
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.phone_android_rounded, size: 40, color: AppColors.primary),
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text('Verify your number',
              style: AppText.stat(26, AppColors.ink).copyWith(letterSpacing: -0.6)),
        ),
        const SizedBox(height: 12),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text.rich(
              TextSpan(
                style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 14.5, height: 1.55),
                children: [
                  const TextSpan(text: 'Players contact each other directly. We\'ll send a code to\n'),
                  TextSpan(
                    text: _formatted,
                    style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 14.5),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 32),

        if (!_codeSent) ...[
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _sending
                ? const SizedBox(
                    key: ValueKey('l'),
                    height: 54,
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.primary),
                    ),
                  )
                : AppButton(
                    key: const ValueKey('b'),
                    'Send verification code',
                    full: true,
                    height: 54,
                    onPressed: _sendCode,
                  ),
          ),
        ] else ...[
          Text('Enter the 6-digit code',
              style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 12.5)),
          const SizedBox(height: 12),
          _OtpInput(onChanged: (v) => _otp = v),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _verifying
                ? const SizedBox(
                    key: ValueKey('l'),
                    height: 54,
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.primary),
                    ),
                  )
                : AppButton(
                    key: const ValueKey('b'),
                    'Verify',
                    full: true,
                    height: 54,
                    onPressed: _verify,
                  ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: _sendCode,
              child: Text('Resend code',
                  style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 13.5)),
            ),
          ),
        ],

        const Spacer(),
        Center(
          child: TextButton(
            onPressed: widget.onSkip,
            child: Text('Skip for now',
                style: AppText.body(AppColors.inkFaint).copyWith(fontSize: 13.5)),
          ),
        ),
      ]),
    );
  }
}

// ── 6-box OTP input ──────────────────────────────────────────────────────
class _OtpInput extends StatefulWidget {
  final ValueChanged<String> onChanged;
  const _OtpInput({required this.onChanged});

  @override
  State<_OtpInput> createState() => _OtpInputState();
}

class _OtpInputState extends State<_OtpInput> {
  final _ctrls = List.generate(6, (_) => TextEditingController());
  final _nodes = List.generate(6, (_) => FocusNode());

  @override
  void initState() {
    super.initState();
    for (final n in _nodes) { n.addListener(() => setState(() {})); }
    WidgetsBinding.instance.addPostFrameCallback((_) => _nodes[0].requestFocus());
  }

  @override
  void dispose() {
    for (final c in _ctrls) { c.dispose(); }
    for (final n in _nodes) { n.dispose(); }
    super.dispose();
  }

  String get _otp => _ctrls.map((c) => c.text).join();

  void _onChanged(int i, String v) {
    // Handle paste of full code
    if (v.length > 1) {
      final digits = v.replaceAll(RegExp(r'\D'), '');
      for (int j = 0; j < 6 && j < digits.length; j++) {
        _ctrls[j].text = digits[j];
      }
      setState(() {});
      widget.onChanged(_otp);
      _nodes.last.requestFocus();
      return;
    }
    setState(() {});
    widget.onChanged(_otp);
    if (v.isNotEmpty && i < 5) _nodes[i + 1].requestFocus();
  }

  void _onKey(int i, KeyEvent e) {
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.backspace &&
        _ctrls[i].text.isEmpty &&
        i > 0) {
      _ctrls[i - 1].clear();
      _nodes[i - 1].requestFocus();
      setState(() {});
      widget.onChanged(_otp);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(6, (i) {
        final focused = _nodes[i].hasFocus;
        final filled = _ctrls[i].text.isNotEmpty;
        return KeyboardListener(
          focusNode: FocusNode(skipTraversal: true),
          onKeyEvent: (e) => _onKey(i, e),
          child: Container(
            width: 48,
            height: 58,
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: focused
                    ? AppColors.primary
                    : filled
                        ? AppColors.primary.withValues(alpha: 0.45)
                        : AppColors.line,
                width: focused ? 2 : 1.5,
              ),
              boxShadow: focused
                  ? [BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.14),
                      blurRadius: 0,
                      spreadRadius: 3,
                    )]
                  : null,
            ),
            child: TextField(
              controller: _ctrls[i],
              focusNode: _nodes[i],
              textAlign: TextAlign.center,
              maxLength: 1,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              cursorColor: AppColors.primary,
              style: AppText.stat(22, AppColors.ink),
              onChanged: (v) => _onChanged(i, v),
              decoration: const InputDecoration(
                counterText: '',
                border: InputBorder.none,
              ),
            ),
          ),
        );
      }),
    );
  }
}
