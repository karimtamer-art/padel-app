import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';

final ImagePicker _imagePicker = ImagePicker();

Future<({Uint8List bytes, String ext})?> _pickBannerImage() async {
  final f = await _imagePicker.pickImage(source: ImageSource.gallery);
  if (f == null) return null;
  final bytes = await f.readAsBytes();
  final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'jpg';
  return (bytes: bytes, ext: ext);
}

class AdminPromotionsScreen extends StatefulWidget {
  const AdminPromotionsScreen({super.key});
  @override
  State<AdminPromotionsScreen> createState() => _AdminPromotionsScreenState();
}

class _AdminPromotionsScreenState extends State<AdminPromotionsScreen> {
  List<Map<String, dynamic>> _banners = [];
  List<Map<String, dynamic>> _products = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    final banners = await AdminService.fetchBanners();
    final products = await AdminService.fetchProducts();
    if (!mounted) return;
    setState(() {
      _banners = banners;
      _products = products;
      _loading = false;
    });
  }

  int _itemCount(String bannerId) =>
      _products.where((p) => p['banner_id'] == bannerId).length;

  static String _egp(dynamic n) =>
      n == null ? '—' : 'EGP ${(n as num).toInt()}';

  // Preset background colors for image-less banners (hero, clay, pine, gold,
  // blue, ink). Stored as hex on banners.bg_color.
  static const _bannerColors = [
    '#21372F', '#C2502A', '#2F6B57', '#B07E22', '#3F7896', '#2A2218',
  ];

  static Color _hexColor(String? hex, [Color fallback = const Color(0xFF21372F)]) {
    if (hex == null || hex.isEmpty) return fallback;
    final h = hex.replaceAll('#', '');
    final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
    return v == null ? fallback : Color(v);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          AdminSection(
            'Store banners',
            sub: 'Promotional banners + sales shown at the top of the store',
            action: AdminButton('Create',
                icon: Icons.add_rounded, height: 34, onPressed: () => _editBanner(null)),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AdminColors.primary),
              ),
            )
          else if (_banners.isEmpty)
            _emptyState()
          else
            for (final b in _banners) _bannerRow(b),
        ],
      ),
    );
  }

  Widget _emptyState() => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: AdminCard(
          child: Column(children: [
            Container(
              width: 48, height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AdminColors.wash(AdminColors.primary, 0.12),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.image_outlined,
                  size: 24, color: AdminColors.primary),
            ),
            const SizedBox(height: 12),
            Text('No banners yet', style: AdminText.cardTitle()),
            const SizedBox(height: 3),
            Text('Create a banner to run a sale on selected products.',
                textAlign: TextAlign.center, style: AdminText.small()),
          ]),
        ),
      );

  Widget _bannerRow(Map<String, dynamic> b) {
    final active = (b['is_active'] as bool?) ?? true;
    final pct = (b['discount_pct'] as num?)?.toInt();
    final count = _itemCount(b['id'] as String);
    final image = b['image_url'] as String?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        onTap: () => _editBanner(b),
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: (image != null && image.isNotEmpty)
                ? Image.network(image,
                    width: 64, height: 48, fit: BoxFit.cover,
                    cacheWidth: 200,
                    errorBuilder: (_, __, ___) => _thumbFallback(b))
                : _thumbFallback(b),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  (b['title'] as String?)?.trim().isNotEmpty == true
                      ? b['title'] as String
                      : 'Untitled banner',
                  style: AdminText.strong(),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Row(children: [
                _pill(pct != null ? '$pct% off' : 'Custom prices',
                    AdminColors.primary),
                const SizedBox(width: 6),
                Text('$count item${count == 1 ? '' : 's'}',
                    style: AdminText.small(AdminColors.inkFaint)),
              ]),
            ]),
          ),
          const SizedBox(width: 10),
          _pill(active ? 'Active' : 'Hidden',
              active ? AdminColors.green : AdminColors.inkFaint),
        ]),
      ),
    );
  }

  Widget _thumbFallback(Map<String, dynamic> b) {
    final color = b['bg_color'] as String?;
    if (color != null && color.isNotEmpty) {
      return Container(width: 64, height: 48, color: _hexColor(color));
    }
    return Container(
      width: 64, height: 48,
      alignment: Alignment.center,
      color: AdminColors.surfaceAlt,
      child: const Icon(Icons.image_outlined, size: 20, color: AdminColors.inkFaint),
    );
  }

  Widget _pill(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: AdminColors.wash(c, 0.14),
            borderRadius: BorderRadius.circular(999)),
        child: Text(t, style: AdminText.sans(10.5, FontWeight.w800, c)),
      );

  // ── Editor ─────────────────────────────────────────────────────────────────

  Future<void> _editBanner(Map<String, dynamic>? b) async {
    final editing = b != null;
    final titleC = TextEditingController(text: b?['title'] as String? ?? '');
    final subC = TextEditingController(text: b?['subtitle'] as String? ?? '');
    final pctC =
        TextEditingController(text: (b?['discount_pct'])?.toString() ?? '');
    final searchC = TextEditingController();
    var imageUrl = b?['image_url'] as String?;
    ({Uint8List bytes, String ext})? pending;
    var bgColor = b?['bg_color'] as String? ?? _bannerColors.first;
    var isActive = (b?['is_active'] as bool?) ?? true;
    // percent unless an existing banner was saved with custom prices
    var mode = (b == null || b['discount_pct'] != null) ? 'percent' : 'custom';
    var query = '';
    final selected = <String>{};
    final priceCtrls = <String, TextEditingController>{};

    if (editing) {
      final items = await AdminService.fetchBannerProducts(b['id'] as String);
      for (final it in items) {
        final id = it['id'] as String;
        selected.add(id);
        priceCtrls[id] = TextEditingController(
            text: (it['sale_price'] as num?)?.toInt().toString() ?? '');
      }
    }
    for (final p in _products) {
      priceCtrls.putIfAbsent(p['id'] as String, () => TextEditingController());
    }

    if (!mounted) return;
    await adminSheet(
      context,
      title: editing ? 'Edit banner' : 'New banner',
      sub: 'Runs a sale on the selected products',
      heightFactor: 0.94,
      footer: Row(children: [
        if (editing) ...[
          AdminButton('Delete',
              variant: AdminBtn.danger,
              height: 50,
              icon: Icons.delete_outline_rounded,
              onPressed: () => _confirmDelete(b)),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: AdminButton(editing ? 'Save' : 'Create', full: true, height: 50,
              onPressed: () async {
            final pct = int.tryParse(pctC.text);
            if (mode == 'percent' && selected.isNotEmpty && pct == null) {
              adminToast(context, 'Enter a discount %', ok: false);
              return;
            }
            Navigator.pop(context);
            try {
              var url = imageUrl;
              if (pending != null) {
                url = await AdminService.uploadBannerImage(
                    pending!.bytes, pending!.ext);
              }
              final items = [
                for (final id in selected)
                  {
                    'product_id': id,
                    'sale_price': mode == 'custom'
                        ? int.tryParse(priceCtrls[id]!.text)
                        : null,
                  }
              ];
              await AdminService.saveBanner(
                id: b?['id'] as String?,
                title: titleC.text.trim().isEmpty ? null : titleC.text.trim(),
                subtitle: subC.text.trim().isEmpty ? null : subC.text.trim(),
                imageUrl: url,
                bgColor: bgColor,
                isActive: isActive,
                discountPct: mode == 'percent' ? pct : null,
                items: items,
              );
              await _load();
              if (mounted) {
                adminToast(context, editing ? 'Banner updated' : 'Banner created');
              }
            } catch (e) {
              if (mounted) adminToast(context, "Couldn't save: $e", ok: false);
            }
          }),
        ),
      ]),
      body: StatefulBuilder(
        builder: (context, setSheet) {
          final list = query.trim().isEmpty
              ? _products
              : _products
                  .where((p) => (p['name'] as String? ?? '')
                      .toLowerCase()
                      .contains(query.trim().toLowerCase()))
                  .toList();
          return Column(children: [
            // image
            GestureDetector(
              onTap: () async {
                final f = await _pickBannerImage();
                if (f != null) setSheet(() => pending = f);
              },
              child: Container(
                height: 120,
                width: double.infinity,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                    color: AdminColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AdminColors.line)),
                child: pending != null
                    ? Image.memory(pending!.bytes, fit: BoxFit.cover)
                    : (imageUrl != null && imageUrl!.isNotEmpty)
                        ? Image.network(imageUrl!, fit: BoxFit.cover)
                        : Container(
                            color: _hexColor(bgColor),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.add_photo_alternate_outlined,
                                    size: 28, color: Colors.white70),
                                const SizedBox(height: 6),
                                Text('Tap to add image (optional)',
                                    style: AdminText.sans(
                                        12, FontWeight.w600, Colors.white70)),
                              ],
                            ),
                          ),
              ),
            ),
            // Color is used as the background when no image is set.
            if (pending == null && (imageUrl == null || imageUrl!.isEmpty)) ...[
              const SizedBox(height: 12),
              Row(children: [
                Text('BACKGROUND COLOR', style: AdminText.kicker()),
                const Spacer(),
                if (imageUrl != null && imageUrl!.isNotEmpty)
                  GestureDetector(
                    onTap: () => setSheet(() => imageUrl = null),
                    child: Text('Remove image',
                        style: AdminText.small(AdminColors.primary)),
                  ),
              ]),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final c in _bannerColors)
                    GestureDetector(
                      onTap: () => setSheet(() => bgColor = c),
                      child: Container(
                        width: 36, height: 36,
                        margin: const EdgeInsets.only(right: 10),
                        decoration: BoxDecoration(
                          color: _hexColor(c),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                              color: bgColor == c
                                  ? AdminColors.ink
                                  : AdminColors.line,
                              width: bgColor == c ? 2.4 : 1),
                        ),
                        child: bgColor == c
                            ? const Icon(Icons.check_rounded,
                                size: 18, color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
            ] else if (imageUrl != null && imageUrl!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () => setSheet(() => imageUrl = null),
                  child: Text('Remove image',
                      style: AdminText.small(AdminColors.primary)),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _field('Title', titleC, hint: 'e.g. Summer Sale'),
            const SizedBox(height: 14),
            _field('Subtitle', subC, hint: 'e.g. Up to 20% off rackets'),
            const SizedBox(height: 14),
            _toggleRow('Active', 'Show in store & apply the sale', isActive,
                (v) => setSheet(() => isActive = v)),
            const SizedBox(height: 14),
            _modeToggle(mode, (v) => setSheet(() => mode = v)),
            if (mode == 'percent') ...[
              const SizedBox(height: 12),
              _field('Discount %', pctC, prefix: '%',
                  hint: 'Applied to every selected product'),
            ],
            const SizedBox(height: 16),
            Row(children: [
              Text('PRODUCTS ON SALE', style: AdminText.kicker()),
              const Spacer(),
              Text('${selected.length} selected',
                  style: AdminText.small(AdminColors.inkFaint)),
            ]),
            const SizedBox(height: 8),
            _searchField(searchC, (v) => setSheet(() => query = v)),
            const SizedBox(height: 8),
            for (final p in list)
              _productPickRow(p, mode, selected, priceCtrls, setSheet),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('No products match.',
                    style: AdminText.small(AdminColors.inkFaint)),
              ),
          ]);
        },
      ),
    );
  }

  Widget _productPickRow(
      Map<String, dynamic> p,
      String mode,
      Set<String> selected,
      Map<String, TextEditingController> priceCtrls,
      void Function(void Function()) setSheet) {
    final id = p['id'] as String;
    final on = selected.contains(id);
    final price = (p['price'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: on
              ? AdminColors.wash(AdminColors.primary, 0.08)
              : AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: on ? AdminColors.primary : AdminColors.line,
              width: on ? 1.5 : 1),
        ),
        child: Row(children: [
          GestureDetector(
            onTap: () => setSheet(() =>
                on ? selected.remove(id) : selected.add(id)),
            child: Icon(
                on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                color: on ? AdminColors.primary : AdminColors.inkFaint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p['name'] as String? ?? '—',
                  style: AdminText.strong(),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(_egp(price), style: AdminText.small(AdminColors.inkFaint)),
            ]),
          ),
          if (on && mode == 'custom')
            SizedBox(
              width: 96,
              child: TextField(
                controller: priceCtrls[id],
                keyboardType: TextInputType.number,
                style: AdminText.body(),
                decoration: InputDecoration(
                  isDense: true,
                  prefixText: 'EGP ',
                  prefixStyle:
                      AdminText.mono(11, FontWeight.w700, AdminColors.inkFaint),
                  hintText: 'sale',
                  filled: true,
                  fillColor: AdminColors.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: AdminUI.fieldR,
                      borderSide: const BorderSide(color: AdminColors.line)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: AdminUI.fieldR,
                      borderSide: const BorderSide(
                          color: AdminColors.primary, width: 1.6)),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(Map<String, dynamic> b) async {
    Navigator.pop(context); // close editor first
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Delete banner?', style: AdminText.cardTitle()),
        content: Text(
            'Remove this banner and take its products off sale (back to full '
            'price)? This cannot be undone.',
            style: AdminText.body(AdminColors.inkSoft)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text('Delete', style: AdminText.strong(AdminColors.danger))),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await AdminService.deleteBanner(b['id'] as String);
      await _load();
      if (mounted) adminToast(context, 'Banner deleted');
    } catch (e) {
      if (mounted) adminToast(context, "Couldn't delete: $e", ok: false);
    }
  }

  // ── Field helpers ────────────────────────────────────────────────────────

  Widget _modeToggle(String mode, ValueChanged<String> onChanged) => Row(
        children: [
          for (final m in const [
            ['percent', 'Percentage'],
            ['custom', 'Custom price'],
          ])
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(m[0]),
                child: Container(
                  margin: EdgeInsets.only(right: m[0] == 'percent' ? 8 : 0),
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: mode == m[0]
                        ? AdminColors.primary
                        : AdminColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: mode == m[0]
                            ? AdminColors.primary
                            : AdminColors.line),
                  ),
                  child: Text(m[1],
                      style: AdminText.sans(
                          13,
                          FontWeight.w700,
                          mode == m[0]
                              ? AdminColors.primaryInk
                              : AdminColors.inkSoft)),
                ),
              ),
            ),
        ],
      );

  Widget _searchField(TextEditingController c, ValueChanged<String> onChanged) =>
      TextField(
        controller: c,
        onChanged: onChanged,
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon:
              const Icon(Icons.search_rounded, size: 18, color: AdminColors.inkFaint),
          hintText: 'Search products…',
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.primary, width: 1.6)),
        ),
      );

  Widget _toggleRow(
          String label, String sub, bool value, ValueChanged<bool> onChanged) =>
      Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AdminColors.line)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AdminText.strong()),
              const SizedBox(height: 1),
              Text(sub, style: AdminText.small(AdminColors.inkFaint)),
            ]),
          ),
          Switch(
            value: value,
            activeThumbColor: AdminColors.primary,
            onChanged: onChanged,
          ),
        ]),
      );

  Widget _field(String label, TextEditingController c,
      {String? hint, String? prefix, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType:
            prefix != null ? TextInputType.number : TextInputType.text,
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          prefixText: prefix != null ? '$prefix ' : null,
          prefixStyle: AdminText.mono(12, FontWeight.w700, AdminColors.inkFaint),
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.primary, width: 1.6)),
        ),
      ),
      if (hint != null) ...[
        const SizedBox(height: 5),
        Text(hint, style: AdminText.small(AdminColors.inkFaint)),
      ],
    ]);
  }

}
