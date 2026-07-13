import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../theme/app_spacing.dart';
import '../../../backend/services/auth_service.dart';

/// ── Labelled text field with leading icon + password reveal ──────
class AuthField extends StatefulWidget {
  final String label;
  final String? hint;
  final String? helper;
  final IconData? icon;
  final bool obscure;
  final TextInputType keyboard;
  final TextCapitalization capitalization;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final bool readOnly;
  final bool locked; // non-editable AND visually greyed with a lock icon
  final VoidCallback? onTap;
  final Widget? trailing;
  const AuthField({
    super.key,
    required this.label,
    this.hint,
    this.helper,
    this.icon,
    this.obscure = false,
    this.keyboard = TextInputType.text,
    this.capitalization = TextCapitalization.none,
    this.controller,
    this.onChanged,
    this.readOnly = false,
    this.locked = false,
    this.onTap,
    this.trailing,
  });

  @override
  State<AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<AuthField> {
  late final FocusNode _node = FocusNode()..addListener(() => setState(() {}));
  bool _show = false;

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.locked;
    final focused = _node.hasFocus && !locked;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 7, left: 1),
        child: Text(widget.label,
            style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 12.5)),
      ),
      AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: locked ? AppColors.field.withValues(alpha: 0.5) : AppColors.field,
          borderRadius: AppRadius.btnR,
          border: Border.all(
              color: focused ? AppColors.primary : AppColors.line, width: 1.5),
          boxShadow: focused
              ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.16), blurRadius: 0, spreadRadius: 3)]
              : null,
        ),
        child: Row(children: [
          if (widget.icon != null) ...[
            Icon(widget.icon,
                size: 18,
                color: locked
                    ? AppColors.inkFaint
                    : (focused ? AppColors.primary : AppColors.inkFaint)),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: TextField(
              focusNode: _node,
              controller: widget.controller,
              onChanged: widget.onChanged,
              readOnly: widget.readOnly || locked,
              enableInteractiveSelection: !locked,
              onTap: widget.onTap,
              obscureText: widget.obscure && !_show,
              keyboardType: widget.keyboard,
              textCapitalization: widget.capitalization,
              cursorColor: AppColors.primary,
              style: AppText.bodyStrong(locked ? AppColors.inkFaint : AppColors.ink)
                  .copyWith(fontSize: 15),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 15),
              ),
            ),
          ),
          if (locked)
            const Icon(Icons.lock_outline_rounded, size: 17, color: AppColors.inkFaint),
          if (widget.trailing != null) widget.trailing!,
          if (widget.obscure)
            GestureDetector(
              onTap: () => setState(() => _show = !_show),
              child: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 19, color: AppColors.inkFaint),
            ),
        ]),
      ),
      if (widget.helper != null)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2),
          child: Text(widget.helper!,
              style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 11, letterSpacing: 0)),
        ),
    ]);
  }
}

/// ── Phone field: country chip + number ───────────────────────────
class PhoneField extends StatefulWidget {
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  const PhoneField({super.key, this.controller, this.onChanged});
  @override
  State<PhoneField> createState() => _PhoneFieldState();
}

class _PhoneFieldState extends State<PhoneField> {
  late final FocusNode _node = FocusNode()..addListener(() => setState(() {}));
  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _node.hasFocus;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 7, left: 1),
        child: Text('Phone Number',
            style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 12.5)),
      ),
      AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 50,
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: AppRadius.btnR,
          border: Border.all(color: focused ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
            margin: const EdgeInsets.symmetric(vertical: 13),
            decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: AppColors.line))),
            child: Row(children: [
              const Text('🇪🇬', style: TextStyle(fontSize: 17)),
              const SizedBox(width: 6),
              Text('+20', style: AppText.bodyStrong().copyWith(fontSize: 15)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              focusNode: _node,
              controller: widget.controller,
              keyboardType: TextInputType.phone,
              onChanged: widget.onChanged,
              cursorColor: AppColors.primary,
              style: AppText.bodyStrong().copyWith(fontSize: 15, letterSpacing: 0.3),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '100 123 4567',
                hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 15),
              ),
            ),
          ),
          const SizedBox(width: 14),
        ]),
      ),
    ]);
  }
}

/// ── Multiline bio field with counter ─────────────────────────────
class BioField extends StatefulWidget {
  final int max;
  final ValueChanged<String>? onChanged;
  const BioField({super.key, this.max = 140, this.onChanged});
  @override
  State<BioField> createState() => _BioFieldState();
}

class _BioFieldState extends State<BioField> {
  late final FocusNode _node = FocusNode()..addListener(() => setState(() {}));
  int _len = 0;
  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _node.hasFocus;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 7, left: 1),
        child: Text('Short Bio (optional)',
            style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 12.5)),
      ),
      AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: AppRadius.btnR,
          border: Border.all(color: focused ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Column(children: [
          TextField(
            focusNode: _node,
            maxLines: 3,
            maxLength: widget.max,
            cursorColor: AppColors.primary,
            onChanged: (v) {
              setState(() => _len = v.length);
              widget.onChanged?.call(v);
            },
            style: AppText.body().copyWith(fontSize: 15, height: 1.5),
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              counterText: '',
              hintText: 'Competitive padel player looking for evening matches.',
              hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 15, height: 1.5),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text('$_len/${widget.max}',
                style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 11, letterSpacing: 0)),
          ),
        ]),
      ),
    ]);
  }
}

/// ── Segmented option group ───────────────────────────────────────
class SegOption {
  final String value, label;
  final String? sub;
  final IconData? icon;
  final bool flipIcon;
  final CourtSide? side; // renders a mini court diagram instead of an icon
  const SegOption(this.value, this.label, {this.sub, this.icon, this.flipIcon = false, this.side});
}

enum CourtSide { left, right, both }

class SegmentedField extends StatelessWidget {
  final String label;
  final List<SegOption> options;
  final String value;
  final ValueChanged<String> onChanged;
  final int columns;
  const SegmentedField({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.columns = 0,
  });

  @override
  Widget build(BuildContext context) {
    final cols = columns == 0 ? options.length : columns;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 7, left: 1),
        child: Text(label,
            style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 12.5)),
      ),
      LayoutBuilder(builder: (context, c) {
        const gap = 8.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final o in options)
              SizedBox(width: w, child: _cell(o)),
          ],
        );
      }),
    ]);
  }

  Widget _cell(SegOption o) {
    final on = value == o.value;
    final hasGlyph = o.icon != null || o.side != null;
    return GestureDetector(
      onTap: () => onChanged(o.value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: hasGlyph ? 13 : 12),
        decoration: BoxDecoration(
          color: on ? AppColors.primary.withValues(alpha: 0.12) : AppColors.field,
          borderRadius: AppRadius.btnR,
          border: Border.all(color: on ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (o.side != null) ...[
            _CourtGlyph(side: o.side!, on: on),
            const SizedBox(height: 6),
          ] else if (o.icon != null) ...[
            Transform.flip(
              flipX: o.flipIcon,
              child: Icon(o.icon, size: 22, color: on ? AppColors.primary : AppColors.inkSoft),
            ),
            const SizedBox(height: 6),
          ],
          Text(o.label,
              textAlign: TextAlign.center,
              style: AppText.bodyStrong(on ? AppColors.primary : AppColors.ink)
                  .copyWith(fontSize: 13, fontWeight: on ? FontWeight.w800 : FontWeight.w600)),
          if (o.sub != null) ...[
            const SizedBox(height: 1),
            Text(o.sub!,
                style: AppText.tag(on ? AppColors.primary : AppColors.inkFaint)
                    .copyWith(fontSize: 10.5, letterSpacing: 0)),
          ],
        ]),
      ),
    );
  }
}

/// small padel-court diagram highlighting the active side(s)
class _CourtGlyph extends StatelessWidget {
  final CourtSide side;
  final bool on;
  const _CourtGlyph({required this.side, required this.on});
  @override
  Widget build(BuildContext context) {
    final c = on ? AppColors.primary : AppColors.inkFaint;
    final wash = on ? AppColors.primary.withValues(alpha: 0.12) : Colors.transparent;
    Color l = (side == CourtSide.left || side == CourtSide.both) ? wash : Colors.transparent;
    Color r = (side == CourtSide.right || side == CourtSide.both) ? wash : Colors.transparent;
    return Container(
      width: 38,
      height: 26,
      decoration: BoxDecoration(border: Border.all(color: c, width: 1.6), borderRadius: BorderRadius.circular(4)),
      child: Stack(children: [
        Row(children: [
          Expanded(child: Container(decoration: BoxDecoration(color: l, border: Border(right: BorderSide(color: c))))),
          Expanded(child: Container(color: r)),
        ]),
        Center(child: Container(width: 5, height: 5, decoration: BoxDecoration(color: c, shape: BoxShape.circle))),
      ]),
    );
  }
}

/// ── "or" divider ─────────────────────────────────────────────────
class OrDivider extends StatelessWidget {
  final String label;
  const OrDivider(this.label, {super.key});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      const Expanded(child: Divider(color: AppColors.line, height: 1)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(label.toUpperCase(),
            style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 11, letterSpacing: 1)),
      ),
      const Expanded(child: Divider(color: AppColors.line, height: 1)),
    ]);
  }
}

/// ── Social provider button ───────────────────────────────────────
class SocialButton extends StatelessWidget {
  final String provider; // 'google' | 'apple'
  final VoidCallback? onPressed;
  const SocialButton({super.key, required this.provider, this.onPressed});
  @override
  Widget build(BuildContext context) {
    final isGoogle = provider == 'google';
    return SizedBox(
      height: 50,
      child: Material(
        color: AppColors.surface,
        borderRadius: AppRadius.btnR,
        child: InkWell(
          borderRadius: AppRadius.btnR,
          onTap: onPressed,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
                borderRadius: AppRadius.btnR,
                border: Border.all(color: AppColors.line, width: 1.5)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              isGoogle ? const _GoogleG() : const Icon(Icons.apple, size: 22, color: AppColors.ink),
              const SizedBox(width: 10),
              Text('Continue with ${isGoogle ? 'Google' : 'Apple'}',
                  style: AppText.bodyStrong().copyWith(fontSize: 14.5, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// ── Google provider button with loading + error handling ─────────
class GoogleSignInButton extends StatefulWidget {
  final Future<void> Function()? onPressed;
  final String label;
  const GoogleSignInButton({super.key, this.onPressed, this.label = 'Continue with Google'});
  @override
  State<GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<GoogleSignInButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy || widget.onPressed == null) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed!.call();
    } on AuthCancelled {
      // User dismissed the picker — silent.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.ink,
            content: Text('Google sign-in failed. Please try again.',
                style: AppText.bodyStrong(AppColors.bg).copyWith(fontSize: 13)),
          ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Material(
        color: AppColors.surface,
        borderRadius: AppRadius.btnR,
        child: InkWell(
          borderRadius: AppRadius.btnR,
          onTap: _busy ? null : _run,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
                borderRadius: AppRadius.btnR,
                border: Border.all(color: AppColors.line, width: 1.5)),
            child: _busy
                ? const SizedBox(
                    width: 21, height: 21,
                    child: CircularProgressIndicator(strokeWidth: 2.3, color: AppColors.primary),
                  )
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    const _GoogleG(),
                    const SizedBox(width: 10),
                    Text(widget.label,
                        style: AppText.bodyStrong().copyWith(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  ]),
          ),
        ),
      ),
    );
  }
}

class _GoogleG extends StatelessWidget {
  const _GoogleG();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: CustomPaint(painter: _GPainter()),
    );
  }
}

class _GPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    final stroke = size.width * 0.22;
    final rect = Rect.fromCircle(center: c, radius: r - stroke / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    p.color = const Color(0xFF4285F4);
    canvas.drawArc(rect, -0.35, 1.7, false, p);
    p.color = const Color(0xFF34A853);
    canvas.drawArc(rect, 1.4, 1.4, false, p);
    p.color = const Color(0xFFFBBC05);
    canvas.drawArc(rect, 2.7, 1.4, false, p);
    p.color = const Color(0xFFEA4335);
    canvas.drawArc(rect, 4.0, 1.55, false, p);
    final bar = Paint()..color = const Color(0xFF4285F4);
    canvas.drawRect(Rect.fromLTWH(r, r - stroke / 2, r - stroke / 2, stroke), bar);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// ── Step progress bar (segments) ─────────────────────────────────
class StepBar extends StatelessWidget {
  final int step, total;
  const StepBar({super.key, required this.step, required this.total});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (int i = 0; i < total; i++) ...[
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: 5,
            decoration: BoxDecoration(
              color: i <= step ? AppColors.primary : AppColors.line,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        if (i < total - 1) const SizedBox(width: 6),
      ],
    ]);
  }
}

/// ── Square back button ───────────────────────────────────────────
class BackSquare extends StatelessWidget {
  final VoidCallback onTap;
  const BackSquare({super.key, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: AppColors.field, borderRadius: BorderRadius.circular(12)),
        child: const Icon(Icons.arrow_back_rounded, size: 19, color: AppColors.ink),
      ),
    );
  }
}

/// ── Profile photo picker (tappable circle) ───────────────────────
class PhotoPicker extends StatelessWidget {
  final VoidCallback? onTap;
  const PhotoPicker({super.key, this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap ?? () {},
      child: SizedBox(
        width: 124,
        height: 124,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 124,
            height: 124,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.field,
              border: Border.all(
                  color: AppColors.line, width: 2.5, style: BorderStyle.solid),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.photo_camera_outlined, size: 30, color: AppColors.primary),
              const SizedBox(height: 7),
              Text('Add photo',
                  style: AppText.tag(AppColors.inkSoft).copyWith(fontSize: 11, letterSpacing: 0)),
            ]),
          ),
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.surface, width: 3),
              ),
              child: const Icon(Icons.add_rounded, size: 16, color: AppColors.primaryInk),
            ),
          ),
        ]),
      ),
    );
  }
}
