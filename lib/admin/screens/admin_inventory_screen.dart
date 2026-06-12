import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';

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
    final priceC =
        TextEditingController(text: p['price']?.toString() ?? '');
    final costC =
        TextEditingController(text: _cost(p).toString());
    final stockC =
        TextEditingController(text: p['stock']?.toString() ?? '');

    adminSheet(
      context,
      title: p['name'] as String? ?? '—',
      sub: '${p['brand'] ?? '—'} · ${_normCat(p['category'] as String?)}',
      heightFactor: 0.62,
      footer: AdminButton('Save changes', full: true, height: 50,
          onPressed: () async {
        Navigator.pop(context);
        await Supabase.instance.client.from('products').update({
          'price': int.tryParse(priceC.text) ?? p['price'],
          'stock': int.tryParse(stockC.text) ?? p['stock'],
        }).eq('id', p['id'] as String);
        final newCost = int.tryParse(costC.text);
        if (newCost != null) {
          await Supabase.instance.client.from('product_costs').upsert({
            'product_id': p['id'] as String,
            'cost': newCost,
          }, onConflict: 'product_id');
        }
        await _load();
        if (mounted) adminToast(context, 'Product updated');
      }),
      body: Column(children: [
        Row(children: [
          Expanded(child: _field('Cost (wholesale)', costC, prefix: 'EGP')),
          const SizedBox(width: 12),
          Expanded(child: _field('Selling price', priceC, prefix: 'EGP')),
        ]),
        const SizedBox(height: 14),
        _field('Stock on hand', stockC),
      ]),
    );
  }

  void _addProduct() {
    final nameC = TextEditingController();
    final brandC = TextEditingController();
    final priceC = TextEditingController();
    final costC = TextEditingController();
    final stockC = TextEditingController();
    final catNotifier = ValueNotifier<String>('rackets');

    adminSheet(
      context,
      title: 'Add product',
      sub: 'New items publish straight to the app store',
      heightFactor: 0.88,
      footer: AdminButton(
        'Publish to app',
        full: true,
        height: 50,
        icon: Icons.check_rounded,
        onPressed: () async {
          if (nameC.text.trim().isEmpty || priceC.text.trim().isEmpty) return;
          Navigator.pop(context);
          await AdminService.upsertProduct({
            'name': nameC.text.trim(),
            'brand': brandC.text.trim().isEmpty ? 'Generic' : brandC.text.trim(),
            'category': catNotifier.value,
            'price': int.tryParse(priceC.text) ?? 0,
            'cost': int.tryParse(costC.text) ?? 0,
            'stock': int.tryParse(stockC.text) ?? 0,
            'is_visible': true,
            'on_sale': false,
          });
          await _load();
          if (mounted) {
            adminToast(context, '"${nameC.text.trim()}" added to store');
          }
        },
      ),
      body: ValueListenableBuilder<String>(
        valueListenable: catNotifier,
        builder: (_, cat, __) => Column(children: [
          DottedDropZone(icon: _catIcon(cat)),
          const SizedBox(height: 14),
          _field('Product name', nameC, hint: 'e.g. Nox AT10 Genius 18K'),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _field('Brand', brandC, hint: 'Nox')),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Category',
                    style: AdminText.strong(AdminColors.inkSoft)),
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
                      value: cat,
                      isExpanded: true,
                      style: AdminText.body(),
                      items: [
                        for (final c in _dbCats)
                          DropdownMenuItem(
                              value: c, child: Text(_normCat(c)))
                      ],
                      onChanged: (v) => catNotifier.value = v ?? cat,
                    ),
                  ),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _field('Cost', costC, prefix: 'EGP')),
            const SizedBox(width: 12),
            Expanded(child: _field('Price', priceC, prefix: 'EGP')),
          ]),
          const SizedBox(height: 14),
          _field('Opening stock', stockC, hint: '≤6 flags as low stock'),
        ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController c,
      {String? hint, String? prefix}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      TextField(
        controller: c,
        keyboardType:
            prefix != null ? TextInputType.number : TextInputType.text,
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

class DottedDropZone extends StatelessWidget {
  final IconData icon;
  const DottedDropZone({super.key, this.icon = Icons.image_outlined});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AdminColors.surfaceAlt,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AdminColors.line, width: 2),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AdminColors.surface3,
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 20, color: AdminColors.inkFaint),
        ),
        const SizedBox(height: 8),
        Text('Add product image',
            style: AdminText.strong(AdminColors.inkSoft)),
        const SizedBox(height: 2),
        Text('PNG or JPG', style: AdminText.small(AdminColors.inkFaint)),
      ]),
    );
  }
}
