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
/// an iOS pod for the same job. [InteractiveViewer] already provides the pan
/// and pinch, and its transform matrix is replayed onto a [ui.Canvas] here so
/// what gets saved is exactly what was framed.
class AvatarCropSheet extends StatefulWidget {
  final Uint8List bytes;
  const AvatarCropSheet._(this.bytes);

  /// Returns the cropped square PNG, or null if cancelled.
  static Future<Uint8List?> show(BuildContext context, Uint8List bytes) {
    return showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
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
  final _controller = TransformationController();
  ui.Image? _image;
  bool _busy = false;
  double _viewport = 0; // square side of the crop area, set at layout

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
      setState(() => _image = frame.image);
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context); // unreadable file — caller keeps the old photo
    }
  }

  @override
  void dispose() {
    _controller.dispose();
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
    canvas.transform(_controller.value.storage);

    final srcSize = Size(img.width.toDouble(), img.height.toDouble());
    final box = Size(_viewport, _viewport);
    final fitted = applyBoxFit(BoxFit.cover, srcSize, box);
    final src = Alignment.center.inscribe(fitted.source, Offset.zero & srcSize);
    final dst = Alignment.center.inscribe(fitted.destination, Offset.zero & box);
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
    _viewport = side;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: AppColors.line, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 16),
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
                    ClipRect(
                      child: InteractiveViewer(
                        transformationController: _controller,
                        minScale: 1,
                        maxScale: 5,
                        // Lets them drag a zoomed photo right to the edge of
                        // the circle instead of stopping at the square.
                        boundaryMargin: EdgeInsets.all(side),
                        child: SizedBox(
                          width: side,
                          height: side,
                          child: RawImage(image: img, fit: BoxFit.cover),
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
