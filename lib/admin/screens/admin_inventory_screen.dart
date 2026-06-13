import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';

final ImagePicker _imagePicker = ImagePicker();

/// Picks one or more images and reads their bytes + extension. Works on web
/// (bytes) and device, so the same upload path serves chrome dev and iOS.
Future<List<({Uint8List bytes, String ext})>> _pickProductImages() async {
  final files = await _imagePicker.pickMultiImage();
  final out = <({Uint8List bytes, String ext})>[];
  for (final f in files) {
    final bytes = await f.readAsBytes();
    final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'jpg';
    out.add((bytes: bytes, ext: ext));
  }
  return out;
}

class AdminInventoryScreen extends StatefulWidget {
  const AdminInventoryScreen({super.key});
  @override
  State<AdminInventoryScreen> createState() => _AdminInventoryScreenState();
}

class _AdminInventoryScreenState extends State<AdminInventoryScreen> {
  List<Map<String, dynamic>> _products = [];
  bool _loading = true;
  String _stockFilter = 'all';

  static const _dbCats = ['rackets', 'shoes', 'apparel', 'balls', 'accessories'];

  static IconData _catIcon(String? c) =>
      <String, IconData>{
        'rackets': Icons.sports_tennis_rounded,
        'shoes': Icons.directions_run_rounded,
        'apparel': Icons.checkroom_rounded,
        'balls': Icons.sports_baseball_rounded,
        'accessories': Icons.backpack_rounded,
      }[(c ?? '').toLowerCase()] ??
      Icons.inventory_2_outlined;

  static String _normCat(String? c) {
    switch ((c ?? '').toLowerCase()) {
      case 'rackets': return 'Rackets';
      case 'shoes': return 'Shoes';
      case 'apparel': return 'Apparel';
      case 'balls': return 'Balls';
      case 'accessories': return 'Accessories';
      default: return c ?? 'Other';
    }
  }

  static int _cost(Map<String, dynamic> p) =>
      ((p['product_costs'] as Map?)?['cost'] as num?)?.toInt() ?? 0;

  static String _egp(dynamic n) =>
      n == null ? '—' : 'EGP ${(n as num).toInt()}';

  static String _egpShort(int n) {
    if (n >= 1000000) return 'EGP ${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return 'EGP ${(n / 1000).toStringAsFixed(0)}K';
    return 'EGP $n';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    final data = await AdminService.fetchProducts();
    if (!mounted) return;
    setState(() {
      _products = data;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _rows => _products.where((p) {
        if (_stockFilter != 'all' && p['stock_status'] != _stockFilter) {
          return false;
        }
        return true;
      }).toList();

  @override
  Widget build(BuildContext context) {
    final lowOut =
        _products.where((p) => p['stock_status'] != 'in').toList();
    final stockVal = _products.fold<int>(
        0,
        (s, p) =>
            s +
            _cost(p) *
                ((p['stock'] as num?)?.toInt() ?? 0));
    final unitsOnHand = _products.fold<int>(
        0, (s, p) => s + ((p['stock'] as num?)?.toInt() ?? 0));
    final activeSku =
        _products.where((p) => p['is_visible'] == true).length;

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(
                icon: Icons.inventory_2_outlined,
                tone: AdminColors.primary,
                label: 'Active SKUs',
                value: '$activeSku',
                foot: '$unitsOnHand on hand'),
            StatCard(
                icon: Icons.layers_outlined,
                tone: AdminColors.green,
                label: 'Stock value',
                value: _egpShort(stockVal)),
            StatCard(
                icon: Icons.warning_amber_rounded,
                tone: AdminColors.warn,
                label: 'Need reorder',
                value: '${lowOut.length}',
                foot: '${_products.where((p) => p['stock_status'] == 'out').length} out of stock'),
            StatCard(
                icon: Icons.format_list_numbered_rounded,
                tone: AdminColors.info,
                label: 'Total SKUs',
                value: '${_products.length}'),
          ]),
          const SizedBox(height: 16),

          if (lowOut.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AdminColors.wash(AdminColors.warn, 0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: AdminColors.wash(AdminColors.warn, 0.3)),
              ),
              child: Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                      color: AdminColors.warn, shape: BoxShape.circle),
                  child: const Icon(Icons.priority_high_rounded,
                      size: 18, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(
                        '${lowOut.length} product${lowOut.length > 1 ? 's' : ''} at or below reorder level',
                        style: AdminText.strong())),
              ]),
            ),

          AdminSection(
            'Inventory',
            sub: '${_rows.length} SKUs · tap to edit',
            action: AdminButton('Add',
                icon: Icons.add_rounded,
                height: 34,
                onPressed: _addProduct),
          ),

          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final f in const [
                  ['all', 'All stock'],
                  ['in', 'In stock'],
                  ['low', 'Low'],
                  ['out', 'Out']
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _chip(f[1], _stockFilter == f[0],
                        () => setState(() => _stockFilter = f[0])),
                  ),
              ],
            ),
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
          else
            for (final p in _rows) _row(p),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: on ? AdminColors.ink : AdminColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: on ? AdminColors.ink : AdminColors.line),
          ),
          child: Text(label,
              style: AdminText.sans(12.5,
                  on ? FontWeight.w700 : FontWeight.w600,
                  on ? AdminColors.surface : AdminColors.inkSoft)),
        ),
      );

  Widget _row(Map<String, dynamic> p) {
    final stock = (p['stock'] as num?)?.toInt() ?? 0;
    final price = (p['price'] as num?)?.toInt() ?? 0;
    final cost = _cost(p);
    final margin = price - cost;
    final stockStatus = p['stock_status'] as String? ?? 'in';
    final stockColor = stock == 0
        ? AdminColors.danger
        : stockStatus == 'low'
            ? AdminColors.warn
            : AdminColors.ink;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        onTap: () => _editProduct(p),
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(10)),
            child: Icon(_catIcon(p['category'] as String?),
                size: 21, color: AdminColors.inkSoft),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p['name'] as String? ?? '—',
                  style: AdminText.strong(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                  '${p['brand'] ?? '—'} · ${_normCat(p['category'] as String?)}',
                  style: AdminText.small()),
              const SizedBox(height: 7),
              Row(children: [
                Text(_egp(price), style: AdminText.strong()),
                const SizedBox(width: 8),
                Text('+${_egp(margin)}',
                    style: AdminText.sans(
                        11.5, FontWeight.w700, AdminColors.success)),
              ]),
            ]),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('$stock',
                style: AdminText.sans(18, FontWeight.w800, stockColor)),
            const SizedBox(height: 4),
            stockStatus == 'in'
                ? const StatusBadge('in', dot: true)
                : GestureDetector(
                    onTap: () => _restock(p),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                          color: AdminColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.add_rounded,
                            size: 14, color: AdminColors.ink),
                        const SizedBox(width: 3),
                        Text('Restock',
                            style: AdminText.sans(
                                12, FontWeight.w700, AdminColors.ink)),
                      ]),
                    ),
                  ),
          ]),
        ]),
      ),
    );
  }

  void _restock(Map<String, dynamic> p) {
    final add = ValueNotifier<int>(24);
    final current = (p['stock'] as num?)?.toInt() ?? 0;
    adminSheet(
      context,
      title: 'Restock — ${p['name']}',
      sub: '$current on hand',
      heightFactor: 0.55,
      footer: ValueListenableBuilder<int>(
        valueListenable: add,
        builder: (_, v, __) => AdminButton(
          'Add $v units',
          full: true,
          height: 50,
          variant: AdminBtn.success,
          onPressed: () async {
            Navigator.pop(context);
            await Supabase.instance.client
                .from('products')
                .update({'stock': current + v})
                .eq('id', p['id'] as String);
            await _load();
            if (mounted) adminToast(context, '+$v units restocked');
          },
        ),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: add,
        builder: (_, v, __) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: AdminColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('CURRENT', style: AdminText.kicker()),
                    const SizedBox(height: 4),
                    Text('$current units',
                        style: AdminText.sans(
                            17,
                            FontWeight.w800,
                            current == 0
                                ? AdminColors.danger
                                : AdminColors.warn)),
                  ]),
                  const Spacer(),
                  const Icon(Icons.arrow_forward_rounded,
                      color: AdminColors.inkFaint),
                  const Spacer(),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('AFTER', style: AdminText.kicker()),
                    const SizedBox(height: 4),
                    Text('${current + v} units',
                        style: AdminText.sans(
                            17, FontWeight.w800, AdminColors.success)),
                  ]),
                ]),
              ),
              const SizedBox(height: 16),
              Text('Units to add',
                  style: AdminText.strong(AdminColors.inkSoft)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final q in const [12, 24, 48, 100])
                    GestureDetector(
                      onTap: () => add.value = q,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 9),
                        decoration: BoxDecoration(
                          color: v == q
                              ? AdminColors.primary
                              : AdminColors.surface,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color: v == q
                                  ? AdminColors.primary
                                  : AdminColors.line),
                        ),
                        child: Text('+$q',
                            style: AdminText.sans(
                                13,
                                FontWeight.w700,
                                v == q
                                    ? AdminColors.primaryInk
                                    : AdminColors.inkSoft)),
                      ),
                    ),
                ],
              ),
            ]),
      ),
    );
  }

  void _editProduct(Map<String, dynamic> p) {
    final nameC  = TextEditingController(text: p['name'] as String? ?? '');
    final brandC = TextEditingController(text: p['brand'] as String? ?? '');
    final descC  = TextEditingController(text: p['description'] as String? ?? '');
    final priceC = TextEditingController(text: p['price']?.toString() ?? '');
    final saleC  = TextEditingController(text: p['sale_price']?.toString() ?? '');
    final costC  = TextEditingController(text: _cost(p).toString());
    final stockC = TextEditingController(text: p['stock']?.toString() ?? '');
    var cat     = (p['category'] as String?)?.toLowerCase() ?? 'accessories';
    var onSale  = (p['on_sale'] as bool?) ?? false;
    var visible = (p['is_visible'] as bool?) ?? true;

    adminSheet(
      context,
      title: p['name'] as String? ?? '—',
      sub: 'Edit product · changes publish to the app store',
      heightFactor: 0.92,
      footer: Row(children: [
        AdminButton('Delete',
            variant: AdminBtn.danger,
            height: 50,
            icon: Icons.delete_outline_rounded,
            onPressed: () => _confirmDelete(p)),
        const SizedBox(width: 10),
        Expanded(
          child: AdminButton('Save changes', full: true, height: 50,
              onPressed: () async {
            if (nameC.text.trim().isEmpty) return;
            Navigator.pop(context);
            await AdminService.upsertProduct({
              'id': p['id'],
              'name': nameC.text.trim(),
              'brand': brandC.text.trim().isEmpty ? null : brandC.text.trim(),
              'category': cat,
              'description':
                  descC.text.trim().isEmpty ? null : descC.text.trim(),
              'price': int.tryParse(priceC.text) ?? p['price'],
              'cost': int.tryParse(costC.text),
              'stock': int.tryParse(stockC.text) ?? p['stock'],
              'on_sale': onSale,
              'sale_price': onSale ? int.tryParse(saleC.text) : null,
              'is_visible': visible,
            });
            await _load();
            if (mounted) adminToast(context, 'Product updated');
          }),
        ),
      ]),
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(children: [
          _ProductImages(
              productId: p['id'] as String,
              initialPrimary: p['image_url'] as String?,
              onChanged: _load),
          const SizedBox(height: 14),
          _field('Product name', nameC),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _field('Brand', brandC)),
            const SizedBox(width: 12),
            Expanded(child: _catField(cat, (v) => setSheet(() => cat = v))),
          ]),
          const SizedBox(height: 14),
          _field('Description', descC,
              hint: 'Short info shown on the product page', maxLines: 3),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _field('Cost', costC, prefix: 'EGP')),
            const SizedBox(width: 12),
            Expanded(child: _field('Price', priceC, prefix: 'EGP')),
          ]),
          const SizedBox(height: 14),
          _field('Stock on hand', stockC),
          const SizedBox(height: 14),
          _toggleRow('On sale', 'Show a discounted price', onSale,
              (v) => setSheet(() => onSale = v)),
          if (onSale) ...[
            const SizedBox(height: 12),
            _field('Sale price', saleC, prefix: 'EGP'),
          ],
          const SizedBox(height: 12),
          _toggleRow('Visible in store', 'Players can see and buy it', visible,
              (v) => setSheet(() => visible = v)),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(Map<String, dynamic> p) async {
    Navigator.pop(context); // close the edit sheet first
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Delete product?', style: AdminText.cardTitle()),
        content: Text(
            'Remove "${p['name'] ?? 'this product'}" from the store? This also '
            'deletes its images and cannot be undone.',
            style: AdminText.body(AdminColors.inkSoft)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Delete', style: AdminText.strong(AdminColors.danger)),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await AdminService.deleteProduct(p['id'] as String);
    await _load();
    if (mounted) adminToast(context, 'Product deleted');
  }

  void _addProduct() {
    final nameC  = TextEditingController();
    final brandC = TextEditingController();
    final descC  = TextEditingController();
    final priceC = TextEditingController();
    final saleC  = TextEditingController();
    final costC  = TextEditingController();
    final stockC = TextEditingController();
    var cat     = 'rackets';
    var onSale  = false;
    var visible = true;
    // Picked in the sheet, uploaded after the product row is created (needs id).
    final pendingImages = <({Uint8List bytes, String ext})>[];

    adminSheet(
      context,
      title: 'Add product',
      sub: 'New items publish straight to the app store',
      heightFactor: 0.92,
      footer: AdminButton(
        'Publish to app',
        full: true,
        height: 50,
        icon: Icons.check_rounded,
        onPressed: () async {
          if (nameC.text.trim().isEmpty || priceC.text.trim().isEmpty) return;
          Navigator.pop(context);
          final id = await AdminService.upsertProduct({
            'name': nameC.text.trim(),
            'brand': brandC.text.trim().isEmpty ? 'Generic' : brandC.text.trim(),
            'category': cat,
            'description': descC.text.trim().isEmpty ? null : descC.text.trim(),
            'price': int.tryParse(priceC.text) ?? 0,
            'cost': int.tryParse(costC.text) ?? 0,
            'stock': int.tryParse(stockC.text) ?? 0,
            'on_sale': onSale,
            'sale_price': onSale ? int.tryParse(saleC.text) : null,
            'is_visible': visible,
          });
          for (final f in pendingImages) {
            await AdminService.uploadProductImage(id, f.bytes, f.ext);
          }
          await _load();
          if (mounted) {
            adminToast(context, '"${nameC.text.trim()}" added to store');
          }
        },
      ),
      body: StatefulBuilder(
        builder: (context, setSheet) => Column(children: [
          _ProductImages(pending: pendingImages),
          const SizedBox(height: 14),
          _field('Product name', nameC, hint: 'e.g. Nox AT10 Genius 18K'),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _field('Brand', brandC, hint: 'Nox')),
            const SizedBox(width: 12),
            Expanded(child: _catField(cat, (v) => setSheet(() => cat = v))),
          ]),
          const SizedBox(height: 14),
          _field('Description', descC,
              hint: 'Short info shown on the product page', maxLines: 3),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _field('Cost', costC, prefix: 'EGP')),
            const SizedBox(width: 12),
            Expanded(child: _field('Price', priceC, prefix: 'EGP')),
          ]),
          const SizedBox(height: 14),
          _field('Opening stock', stockC, hint: '≤5 flags as low stock'),
          const SizedBox(height: 14),
          _toggleRow('On sale', 'Show a discounted price', onSale,
              (v) => setSheet(() => onSale = v)),
          if (onSale) ...[
            const SizedBox(height: 12),
            _field('Sale price', saleC, prefix: 'EGP'),
          ],
          const SizedBox(height: 12),
          _toggleRow('Visible in store', 'Players can see and buy it', visible,
              (v) => setSheet(() => visible = v)),
        ]),
      ),
    );
  }

  Widget _catField(String value, ValueChanged<String> onChanged) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Category', style: AdminText.strong(AdminColors.inkSoft)),
        const SizedBox(height: 7),
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: AdminUI.fieldR,
              border: Border.all(color: AdminColors.line)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              style: AdminText.body(),
              items: [
                for (final c in _dbCats)
                  DropdownMenuItem(value: c, child: Text(_normCat(c))),
              ],
              onChanged: (v) => onChanged(v ?? value),
            ),
          ),
        ),
      ]);

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
        keyboardType: prefix != null
            ? TextInputType.number
            : maxLines > 1
                ? TextInputType.multiline
                : TextInputType.text,
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          prefixText: prefix != null ? '$prefix ' : null,
          prefixStyle:
              AdminText.mono(12, FontWeight.w700, AdminColors.inkFaint),
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide:
                  const BorderSide(color: AdminColors.primary, width: 1.6)),
        ),
      ),
      if (hint != null) ...[
        const SizedBox(height: 5),
        Text(hint, style: AdminText.small(AdminColors.inkFaint))
      ],
    ]);
  }
}

/// Product image gallery manager. Two modes:
/// - **edit** (`productId` set): loads existing images, uploads/removes/sets
///   primary immediately via [AdminService].
/// - **add** (`pending` set): holds picked images in memory; the parent uploads
///   them after the product row is created (it has no id yet).
class _ProductImages extends StatefulWidget {
  final String? productId;
  final String? initialPrimary;
  final VoidCallback? onChanged;
  final List<({Uint8List bytes, String ext})>? pending;
  const _ProductImages(
      {this.productId, this.initialPrimary, this.onChanged, this.pending});
  @override
  State<_ProductImages> createState() => _ProductImagesState();
}

class _ProductImagesState extends State<_ProductImages> {
  List<Map<String, dynamic>> _images = [];
  String? _primary;
  bool _loading = false;
  bool _busy = false;

  bool get _isEdit => widget.productId != null;

  @override
  void initState() {
    super.initState();
    _primary = widget.initialPrimary;
    if (_isEdit) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final imgs = await AdminService.fetchProductImages(widget.productId!);
    if (!mounted) return;
    setState(() {
      _images = imgs;
      _loading = false;
      if (_primary == null && imgs.isNotEmpty) _primary = imgs.first['url'] as String?;
    });
  }

  Future<void> _add() async {
    final picked = await _pickProductImages();
    if (picked.isEmpty || !mounted) return;
    if (!_isEdit) {
      setState(() => widget.pending!.addAll(picked));
      return;
    }
    setState(() => _busy = true);
    for (final f in picked) {
      await AdminService.uploadProductImage(widget.productId!, f.bytes, f.ext);
    }
    await _load();
    widget.onChanged?.call();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _removeUploaded(Map<String, dynamic> img) async {
    setState(() => _busy = true);
    final url = img['url'] as String;
    await AdminService.removeProductImage(
        widget.productId!, img['id'] as String, url);
    if (_primary == url) _primary = null;
    await _load();
    widget.onChanged?.call();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _setPrimary(String url) async {
    await AdminService.setPrimaryImage(widget.productId!, url);
    if (!mounted) return;
    setState(() => _primary = url);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('Images', style: AdminText.strong(AdminColors.inkSoft)),
        const SizedBox(width: 8),
        if (_busy || _loading)
          const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AdminColors.primary)),
      ]),
      const SizedBox(height: 7),
      SizedBox(
        height: 84,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          _addTile(),
          if (_isEdit)
            for (final img in _images) _netThumb(img)
          else
            for (int i = 0; i < pending.length; i++) _memThumb(i),
        ]),
      ),
      if (_isEdit && _images.isNotEmpty) ...[
        const SizedBox(height: 5),
        Text('Tap a photo to make it the main image.',
            style: AdminText.small(AdminColors.inkFaint)),
      ],
    ]);
  }

  Widget _addTile() => GestureDetector(
        onTap: _busy ? null : _add,
        child: Container(
          width: 76, height: 76,
          margin: const EdgeInsets.only(right: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AdminColors.line, width: 2),
          ),
          child: const Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add_a_photo_outlined, size: 20, color: AdminColors.inkFaint),
            SizedBox(height: 4),
            Text('Add', style: TextStyle(fontSize: 11, color: AdminColors.inkFaint)),
          ]),
        ),
      );

  Widget _frame({required Widget image, required VoidCallback onRemove,
      bool primary = false, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 76, height: 76,
        margin: const EdgeInsets.only(right: 8),
        child: Stack(clipBehavior: Clip.none, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 76, height: 76,
              child: image,
            ),
          ),
          if (primary)
            Positioned(
              left: 4, bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                    color: AdminColors.primary,
                    borderRadius: BorderRadius.circular(6)),
                child: const Text('MAIN',
                    style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
            ),
          Positioned(
            top: -6, right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22, height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AdminColors.danger, shape: BoxShape.circle,
                    border: Border.all(color: AdminColors.surface, width: 2)),
                child: const Icon(Icons.close_rounded, size: 12, color: Colors.white),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _netThumb(Map<String, dynamic> img) {
    final url = img['url'] as String;
    return _frame(
      image: Image.network(url, fit: BoxFit.cover, cacheWidth: 200,
          errorBuilder: (_, __, ___) => Container(
              color: AdminColors.surfaceAlt,
              child: const Icon(Icons.broken_image_outlined,
                  size: 18, color: AdminColors.inkFaint))),
      primary: url == _primary,
      onTap: _busy ? null : () => _setPrimary(url),
      onRemove: _busy ? () {} : () => _removeUploaded(img),
    );
  }

  Widget _memThumb(int i) => _frame(
        image: Image.memory(widget.pending![i].bytes, fit: BoxFit.cover),
        primary: i == 0,
        onRemove: () => setState(() => widget.pending!.removeAt(i)),
      );
}
