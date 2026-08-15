import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'common.dart';

/// Drag and pinch a photo into the circle before it becomes your avatar.
///
/// Every profile picture used to be centre-cropped by whatever the camera
/// framed, which put people's chins in the circle and their heads outside it.
///
/// No new dependency: `image_cropper` would want its own Android activity and
/// an iOS pod for the same job. The pan/zoom is a single scale gesture, and
/// the same transform is replayed onto a [ui.Canvas] so what gets saved is
/// exactly what was framed.
///
/// This used to use [InteractiveViewer] and was fiddly for two reasons worth
/// remembering:
///
///  * InteractiveViewer only accepts gestures within its CHILD's bounds. Once
///    the photo was panned, the child moved out from under the finger, so
///    touching where the image visibly was did nothing — you had to find the
///    spot the child had moved to.
///  * With `minScale: 1`, a pinch that would take the scale below 1.0 was
///    clamped while the focal-point translation still applied, so the photo
///    slid sideways instead of zooming.
///
/// Handling the gesture directly fixes both: one detector covers the whole
/// square (opaque hit test, so it never depends on where the content is), and
/// `onScaleUpdate` carries pan and pinch together — a plain drag is simply a
/// scale gesture whose `scale` is 1.0.
class AvatarCropSheet extends StatefulWidget {
  final Uint8List bytes;
  const AvatarCropSheet._(this.bytes);

  /// Returns the cropped square PNG, or null if cancelled.
  static Future<Uint8List?> show(BuildContext context, Uint8List bytes) {
    return showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      // The sheet's own drag-to-dismiss competes with dragging the PHOTO, and
      // wins: swiping up or down inside the circle pulled the whole sheet
      // instead of moving the picture. (Horizontal drags were unaffected,
      // which is what made it look like the crop was half-broken rather than
      // being taken by the parent.) Nothing is lost by turning it off — the
      // sheet is already isDismissible: false and has an explicit Cancel.
      enableDrag: false,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => AvatarCropSheet._(bytes),
    );
  }

  @override
  State<AvatarCropSheet> createState() => _AvatarCropSheetState();
}

class _AvatarCropSheetState extends State<AvatarCropSheet> {
  ui.Image? _image;
  bool _busy = false;
  double _viewport = 0; // square side of the crop area, set at layout

  /// The transform, as `screen = content * _scale + _offset`.
  double _scale = 1;
  Offset _offset = Offset.zero;

  // Gesture anchors, captured once per gesture so pinch and drag compose
  // without drifting.
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  static const double _minScale = 1;
  static const double _maxScale = 5;

  /// The photo at "cover" scale — its shorter side exactly fills the crop
  /// square, so the longer side overflows and is what you pan through.
  ///
  /// This is the content, NOT a pre-cropped square. Using BoxFit.cover baked a
  /// CENTRED crop in before the gesture ever ran, so at 1x a portrait photo was
  /// stuck showing its middle band and dragging did nothing — you had to zoom
  /// in first just to be allowed to move. Now 1x already has slack in the long
  /// dimension, which is what people reach for first.
  Size get _content {
    final img = _image;
    if (img == null || _viewport <= 0) return Size(_viewport, _viewport);
    final w = img.width.toDouble(), h = img.height.toDouble();
    final k = _viewport / (w < h ? w : h);
    return Size(w * k, h * k);
  }

  /// Keeps the photo covering the crop square, so it can never be dragged off
  /// leaving a blank wedge inside the circle.
  Offset _clampOffset(Offset o, double scale) {
    final c = _content;
    // Content always covers — its shorter side equals the viewport at scale 1
    // and only grows — so both bounds are <= 0. min() is belt and braces.
    final minX = _viewport - c.width * scale;
    final minY = _viewport - c.height * scale;
    return Offset(
      o.dx.clamp(minX < 0 ? minX : 0.0, 0.0),
      o.dy.clamp(minY < 0 ? minY : 0.0, 0.0),
    );
  }

  /// Centres the content in the square — the sensible opening frame.
  void _centre() {
    final c = _content;
    _scale = 1;
    _offset = Offset((_viewport - c.width) / 2, (_viewport - c.height) / 2);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final next = (_startScale * d.scale).clamp(_minScale, _maxScale);
    // Hold the content point that was under the focal point in place:
    //   c = (f0 - o0) / s0   and we want   f1 = c * s1 + o1
    final o = d.localFocalPoint - (_startFocal - _startOffset) * (next / _startScale);
    setState(() {
      _scale = next;
      _offset = _clampOffset(o, next);
    });
  }

  /// Saved edge length. 512 is plenty for a 124px picker at 3x and keeps the
  /// upload small — these go straight into a public bucket.
  static const int _out = 512;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _image = frame.image;
        _centre();
      });
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context); // unreadable file — caller keeps the old photo
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final img = _image;
    if (img == null || _busy || _viewport <= 0) return;
    setState(() => _busy = true);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
        recorder, Rect.fromLTWH(0, 0, _out.toDouble(), _out.toDouble()));

    // Replay exactly what the viewport shows: scale the logical crop area up to
    // the output size, then apply the user's pan/zoom matrix, then draw the
    // image the same way BoxFit.cover laid it out underneath.
    canvas.scale(_out / _viewport);
    // Same transform the preview applies: screen = content * scale + offset.
    canvas.translate(_offset.dx, _offset.dy);
    canvas.scale(_scale);

    // The whole image, drawn at cover scale. The transform above decides which
    // part of it lands inside the square, so no cropping happens here — that is
    // what keeps the preview and the saved file identical.
    final src = Offset.zero & Size(img.width.toDouble(), img.height.toDouble());
    final dst = Offset.zero & _content;
    canvas.drawImageRect(
        img, src, dst, Paint()..filterQuality = FilterQuality.high);

    final picture = recorder.endRecording();
    final out = await picture.toImage(_out, _out);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    out.dispose();

    if (!mounted) return;
    Navigator.pop(context, data?.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final side = MediaQuery.of(context).size.width - 40;
    // Re-frame if the square changed size (first layout, rotation, resize).
    // Mutating here rather than setState — we are already mid-build and the
    // transform below reads the new values immediately.
    if (side != _viewport) {
      _viewport = side;
      if (img != null) _centre();
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // No grab handle: the sheet is not draggable (enableDrag: false, so
          // a vertical drag reaches the photo instead), and a handle invites
          // exactly the gesture that now does nothing.
          Text('Position your photo', style: AppText.cardTitle()),
          const SizedBox(height: 4),
          Text('Drag to move · pinch to zoom',
              style: AppText.small(AppColors.inkFaint)),
          const SizedBox(height: 16),
          SizedBox(
            width: side,
            height: side,
            child: img == null
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                : Stack(children: [
                    // opaque so the WHOLE square takes the gesture, wherever
                    // the photo has been panned to
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      child: ClipRect(
                        child: Transform(
                          transform: Matrix4.identity()
                            ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                            ..scaleByDouble(_scale, _scale, 1, 1),
                          child: SizedBox(
                            width: _content.width,
                            height: _content.height,
                            child: RawImage(image: img, fit: BoxFit.fill),
                          ),
                        ),
                      ),
                    ),
                    // Shows what will actually be kept. Not interactive, so it
                    // never swallows a drag meant for the photo.
                    IgnorePointer(
                      child: CustomPaint(
                          size: Size(side, side), painter: _CircleMask()),
                    ),
                  ]),
          ),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: AppButton('Cancel',
                  height: 48,
                  variant: AppBtnVariant.ghost,
                  onPressed: _busy ? null : () => Navigator.pop(context)),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: AppButton(_busy ? 'Saving…' : 'Use photo',
                  height: 48,
                  onPressed: (_busy || img == null) ? null : _save),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Dims everything outside the circle so the crop is obvious.
class _CircleMask extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Path()
      ..addOval(Rect.fromCircle(
          center: rect.center, radius: size.shortestSide / 2));
    final outside =
        Path.combine(PathOperation.difference, Path()..addRect(rect), circle);
    canvas.drawPath(outside, Paint()..color = AppColors.bg.withValues(alpha: 0.82));
    canvas.drawPath(
        circle,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = AppColors.primary);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
