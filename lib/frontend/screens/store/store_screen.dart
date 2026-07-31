import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/frontend/widgets/padel_refresh.dart';
import 'package:padel_clay/frontend/widgets/skeleton.dart';
import 'package:padel_clay/frontend/widgets/micro.dart';
import 'package:padel_clay/backend/models/mock_data.dart';
import 'package:padel_clay/backend/services/store_service.dart';
import 'product_detail_screen.dart';

class StoreScreen extends StatefulWidget {
  final int cart;
  final ValueChanged<Product> onAdd;
  final VoidCallback onOpenCart;
  const StoreScreen({super.key, this.cart = 0, required this.onAdd, required this.onOpenCart});
  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  String _cat = 'All';
  final _searchCtrl = TextEditingController();
  String _query = '';
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _banners = [];
  String? _saleBannerId; // when set, grid shows only this banner's items
  bool _loading = true;
  bool _hideLowStock = false; // admin app_settings 'hide_low_stock'

  // fly-to-cart anchors
  final GlobalKey _cartKey = GlobalKey();
  final Map<String, GlobalKey> _addKeys = {};

  static const _cats = ['All', 'Rackets', 'Shoes', 'Apparel', 'Accessories', 'Balls'];

  static const _catIcons = <String, IconData>{
    'Rackets': Icons.sports_tennis_rounded,
    'Shoes': Icons.directions_run_rounded,
    'Apparel': Icons.checkroom_rounded,
    'Balls': Icons.sports_baseball_rounded,
    'Accessories': Icons.backpack_rounded,
  };

  static const _catColors = <String, Color>{
    'Rackets': AppColors.primary,
    'Shoes': AppColors.accent,
    'Apparel': AppColors.diamond,
    'Balls': AppColors.success,
    'Accessories': AppColors.platinum,
  };

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('products')
          .select('id, name, brand, category, description, image_url, price, sale_price, on_sale, stock_status, rating, is_visible, banner_id')
          .eq('is_visible', true)
          .order('created_at', ascending: false);
      final banners = await StoreService.fetchActiveBanners();
      // Store-wide admin setting: suppress the LOW badge when on.
      bool hideLow = false;
      try {
        final s = await Supabase.instance.client
            .from('app_settings')
            .select('value')
            .eq('key', 'hide_low_stock')
            .maybeSingle();
        hideLow = (s?['value'] as String?) == 'true';
      } catch (_) {}
      if (mounted) {
        setState(() {
          _products = List<Map<String, dynamic>>.from(rows as List);
          _banners = banners;
          _hideLowStock = hideLow;
          // drop a stale sale filter if its banner is no longer active
          if (_saleBannerId != null &&
              !_banners.any((b) => b['id'] == _saleBannerId)) {
            _saleBannerId = null;
          }
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Parse a banner's hex bg_color (e.g. '#21372F'); falls back to the hero green.
  static Color _hexColor(String? hex) {
    if (hex == null || hex.isEmpty) return AppColors.hero;
    final h = hex.replaceAll('#', '');
    final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
    return v == null ? AppColors.hero : Color(v);
  }

  // Normalise DB lowercase category → display title case
  static String _normCat(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'rackets': return 'Rackets';
      case 'shoes': return 'Shoes';
      case 'apparel': return 'Apparel';
      case 'balls': return 'Balls';
      default: return 'Accessories';
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.trim().toLowerCase();
    return _products.where((p) {
      // Sale mode: only this banner's items (category filter ignored).
      if (_saleBannerId != null) {
        if (p['banner_id'] != _saleBannerId) return false;
      } else if (_cat != 'All' && _normCat(p['category'] as String?) != _cat) {
        return false;
      }
      if (q.isNotEmpty) {
        final name = (p['name'] as String? ?? '').toLowerCase();
        final brand = (p['brand'] as String? ?? '').toLowerCase();
        if (!name.contains(q) && !brand.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  // Convert a Supabase row to the mock Product model used by the cart
  Product _toProduct(Map<String, dynamic> row) {
    final price = (row['price'] as num?)?.toInt() ?? 0;
    final salePrice = (row['sale_price'] as num?)?.toInt();
    final onSale = (row['on_sale'] as bool?) ?? false;
    final discount = (onSale && salePrice != null && price > 0)
        ? ((price - salePrice) / price * 100).round().clamp(1, 99)
        : 0;
    return Product(
      row['brand'] as String? ?? '',
      row['name'] as String? ?? 'Product',
      _normCat(row['category'] as String?),
      price,
      (row['rating'] as num?)?.toDouble() ?? 0.0,
      0,
      discount: discount,
      id: row['id'] as String? ?? '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Column(
      children: [
        ScreenBar(
          title: 'Store',
          actions: [
            KeyedSubtree(
                key: _cartKey,
                child: IconChip(Icons.shopping_cart_outlined,
                    badge: widget.cart, onTap: widget.onOpenCart))
          ],
        ),
        Expanded(
          child: PadelRefresh(
            onRefresh: _loadProducts,
            slivers: [
              SliverToBoxAdapter(child: _searchBar()),
                SliverToBoxAdapter(child: _bannersCarousel()),
                SliverToBoxAdapter(child: _tradeIn()),
                SliverToBoxAdapter(
                    child: _saleBannerId == null ? _catChips() : _saleHeader()),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 4, AppSpacing.screen, 10),
                    child: Row(children: [
                      Text(
                          _saleBannerId != null
                              ? 'ON SALE'
                              : (_cat == 'All' ? 'ALL PRODUCTS' : _cat.toUpperCase()),
                          style: AppText.kicker()),
                      const SizedBox(width: 8),
                      if (_loading)
                        const SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                        )
                      else
                        Text('${list.length} items',
                            style: AppText.tag(AppColors.inkFaint)),
                    ]),
                  ),
                ),
                if (!_loading && list.isEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 20, AppSpacing.screen, 40),
                    sliver: SliverToBoxAdapter(child: _emptyState()),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 0, AppSpacing.screen, 120),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.62,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (_, i) => _loading
                            ? const _SkeletonCard()
                            : _productCard(list[i]),
                        childCount: _loading ? 6 : list.length,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
  }

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 8, AppSpacing.screen, 12),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.btnR,
              border: Border.all(color: AppColors.line)),
          child: Row(children: [
            const Icon(Icons.search_rounded, size: 18, color: AppColors.inkFaint),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                textInputAction: TextInputAction.search,
                style: AppText.body().copyWith(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  // Fill the bar height so the whole thing is tappable.
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  hintText: 'Search equipment, brands…',
                  hintStyle: AppText.body(AppColors.inkFaint),
                ),
              ),
            ),
            if (_query.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                  FocusScope.of(context).unfocus();
                },
                child: const Icon(Icons.close_rounded,
                    size: 18, color: AppColors.inkFaint),
              ),
          ]),
        ),
      );

  // Admin-managed promotional banners. Hidden when there are none.
  Widget _bannersCarousel() {
    if (_loading || _banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 122,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: AppSpacing.screenH,
          itemCount: _banners.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) => _bannerCard(_banners[i]),
        ),
      ),
    );
  }

  Widget _bannerCard(Map<String, dynamic> b) {
    final w = MediaQuery.of(context).size.width - AppSpacing.screen * 2;
    final image = b['image_url'] as String?;
    final hasImage = image != null && image.isNotEmpty;
    final accent = _hexColor(b['bg_color'] as String?);
    final title = (b['title'] as String?)?.trim() ?? '';
    final subtitle = (b['subtitle'] as String?)?.trim() ?? '';
    final pct = (b['discount_pct'] as num?)?.toInt();
    final width = _banners.length == 1 ? w : w * 0.86;

    void open() => setState(() {
          _saleBannerId = b['id'] as String?;
          _cat = 'All';
        });

    // Image banners: full-bleed art with a legibility scrim and white text.
    if (hasImage) {
      return GestureDetector(
        onTap: open,
        child: Container(
          width: width,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
          ),
          child: Stack(fit: StackFit.expand, children: [
            Image.network(image,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.10),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (pct != null)
                    AppTag('$pct% OFF', color: AppColors.primary, solid: true),
                  if (title.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.stat(20, Colors.white)
                            .copyWith(letterSpacing: -0.3)),
                  ],
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.small(Colors.white70)
                            .copyWith(fontSize: 12.5, height: 1.3)),
                  ],
                ],
              ),
            ),
          ]),
        ),
      );
    }

    // Color banners: classic light promo card — accent tag + headline + icon tile.
    final pill = (title.isNotEmpty ? title : 'Sale').toUpperCase();
    final headline = subtitle.isNotEmpty
        ? subtitle
        : (pct != null ? 'Up to $pct% off' : 'Shop the sale');
    return GestureDetector(
      onTap: open,
      child: Container(
        width: width,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.cardR,
          border: Border.all(color: accent.withValues(alpha: 0.30)),
        ),
        child: Stack(children: [
          Positioned(
            right: -24, top: -24,
            child: Container(
              width: 150, height: 150,
              decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.10), shape: BoxShape.circle),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppTag(pill, color: accent, solid: true),
                    const SizedBox(height: 8),
                    Text(headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.stat(18)
                            .copyWith(height: 1.15, letterSpacing: -0.3)),
                    if (subtitle.isNotEmpty && pct != null) ...[
                      const SizedBox(height: 5),
                      Text('$pct% off',
                          style: AppText.small().copyWith(fontSize: 12)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 84, height: 84,
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14)),
                child: Icon(Icons.sports_tennis_rounded, size: 46, color: accent),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  // Shown in place of the category chips while a banner's sale is active.
  Widget _saleHeader() {
    final b = _banners.firstWhere((x) => x['id'] == _saleBannerId,
        orElse: () => const <String, dynamic>{});
    final title = (b['title'] as String?)?.trim();
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(AppSpacing.screen, 0, AppSpacing.screen, 12),
      child: GestureDetector(
        onTap: () => setState(() => _saleBannerId = null),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.08),
            borderRadius: AppRadius.btnR,
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            const Icon(Icons.local_offer_rounded,
                size: 16, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  title != null && title.isNotEmpty ? 'Sale: $title' : 'On sale',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyStrong(AppColors.primary)
                      .copyWith(fontSize: 13)),
            ),
            const Icon(Icons.close_rounded, size: 16, color: AppColors.primary),
            const SizedBox(width: 2),
            Text('Clear',
                style: AppText.tag(AppColors.primary).copyWith(fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  Widget _tradeIn() => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 0, AppSpacing.screen, 12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardR,
            gradient: const LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [AppColors.hero, AppColors.hero2]),
            boxShadow: kCardShadow,
          ),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const AppTag('Trade-In Program', color: AppColors.primary, solid: true),
            const SizedBox(height: 10),
            Text('Upgrade Your Game', style: AppText.cardTitle(AppColors.heroInk).copyWith(fontSize: 20)),
            const SizedBox(height: 3),
            Text('Trade in your old racket for store credit.',
                style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 13)),
            const SizedBox(height: 14),
            Row(children: [
              AppButton('Start Trade-In', icon: Icons.arrow_forward_rounded, height: 32, onPressed: () => _openTradeIn()),
              const Spacer(),
              const Icon(Icons.swap_horiz_rounded, size: 40, color: AppColors.primary),
            ]),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _openRepair,
              behavior: HitTestBehavior.opaque,
              child: Row(children: [
                const Icon(Icons.build_outlined, size: 15, color: AppColors.heroFaint),
                const SizedBox(width: 7),
                Text('Racket needs fixing? Request a repair →',
                    style: AppText.small(AppColors.heroFaint)
                        .copyWith(fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),
      );

  Widget _catChips() => SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 0, AppSpacing.screen, 12),
          itemCount: _cats.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final c = _cats[i];
            final on = c == _cat;
            return GestureDetector(
              onTap: () => setState(() => _cat = c),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: on ? AppColors.primary : AppColors.surface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: on ? AppColors.primary : AppColors.line),
                ),
                child: Text(c,
                    style: AppText.bodyStrong(on ? AppColors.primaryInk : AppColors.inkSoft)
                        .copyWith(fontSize: 13, fontWeight: on ? FontWeight.w800 : FontWeight.w600)),
              ),
            );
          },
        ),
      );

  Widget _productCard(Map<String, dynamic> row) {
    final cat = _normCat(row['category'] as String?);
    final color = _catColors[cat] ?? AppColors.primary;
    final icon = _catIcons[cat] ?? Icons.sports_tennis_rounded;
    final brand = row['brand'] as String? ?? '';
    final name = row['name'] as String? ?? 'Product';
    final price = (row['price'] as num?)?.toInt() ?? 0;
    final salePrice = (row['sale_price'] as num?)?.toInt();
    final onSale = (row['on_sale'] as bool?) ?? false;
    final displayPrice = (onSale && salePrice != null) ? salePrice : price;
    final rating = (row['rating'] as num?)?.toDouble();
    final stockStatus = row['stock_status'] as String? ?? 'in';
    final outOfStock = stockStatus == 'out';
    final lowStock = stockStatus == 'low' && !_hideLowStock;
    final imageUrl = row['image_url'] as String?;
    final addKey =
        _addKeys.putIfAbsent((row['id'] as String?) ?? name, () => GlobalKey());

    const topRadius = BorderRadius.vertical(top: Radius.circular(AppRadius.card));

    return AppCard(
      padding: EdgeInsets.zero,
      onTap: () => _openProduct(row),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: topRadius,
                child: Image.network(
                  imageUrl,
                  height: 108,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  // decode small to keep the grid light
                  cacheWidth: 320,
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : Container(height: 108, color: AppColors.field),
                  errorBuilder: (_, __, ___) => StripedPlaceholder(
                    height: 108,
                    icon: icon,
                    color: outOfStock ? AppColors.inkFaint : color,
                    radius: topRadius,
                  ),
                ),
              )
            else
              StripedPlaceholder(
                height: 108,
                icon: icon,
                color: outOfStock ? AppColors.inkFaint : color,
                radius: topRadius,
              ),
            if (onSale && salePrice != null && price > 0)
              Positioned(
                top: 8, right: 8,
                child: _flag('-${((price - salePrice) / price * 100).round()}%', AppColors.danger),
              ),
            if (outOfStock)
              Positioned(top: 8, left: 8, child: _flag('OUT', AppColors.inkSoft))
            else if (lowStock)
              Positioned(top: 8, left: 8, child: _flag('LOW', AppColors.warn)),
          ]),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (brand.isNotEmpty)
                    Text(brand.toUpperCase(),
                        style: AppText.tag().copyWith(fontSize: 9, letterSpacing: 1)),
                  const SizedBox(height: 2),
                  Text(name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong().copyWith(fontSize: 13, height: 1.2)),
                  if (rating != null && rating > 0) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.star_rounded, size: 12, color: AppColors.gold),
                      const SizedBox(width: 3),
                      Text(rating.toStringAsFixed(1),
                          style: AppText.bodyStrong().copyWith(fontSize: 11)),
                    ]),
                  ],
                  const Spacer(),
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (onSale && salePrice != null)
                          Text(MockData.egp(price),
                              style: AppText.tag(AppColors.inkFaint).copyWith(
                                  fontSize: 10, decoration: TextDecoration.lineThrough)),
                        Text(MockData.egp(displayPrice),
                            style: AppText.stat(14,
                                onSale ? AppColors.primary : AppColors.ink)),
                      ]),
                    ),
                    GestureDetector(
                      onTap: outOfStock
                          ? null
                          : () {
                              final p = _toProduct(row);
                              FlyToCart.run(
                                context: context,
                                fromKey: addKey,
                                toKey: _cartKey,
                                onArrive: () => widget.onAdd(p),
                              );
                            },
                      child: Container(
                        key: addKey,
                        width: 32, height: 32,
                        decoration: BoxDecoration(
                          color: outOfStock ? AppColors.line : AppColors.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          outOfStock ? Icons.block_rounded : Icons.add_rounded,
                          size: 18,
                          color: outOfStock ? AppColors.inkFaint : AppColors.primaryInk,
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _flag(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4)),
        child: Text(t,
            style: AppText.tag(Colors.white)
                .copyWith(fontSize: 9, fontWeight: FontWeight.w800)),
      );

  Widget _emptyState() => AppCard(
        child: Column(children: [
          Container(
            width: 52, height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.field, borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.shopping_bag_outlined,
                size: 26, color: AppColors.inkFaint),
          ),
          const SizedBox(height: 14),
          Text(
            _cat == 'All' ? 'No products yet' : 'No $_cat products',
            style: AppText.bodyStrong().copyWith(fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text('Check back soon — new gear is added regularly.',
              textAlign: TextAlign.center,
              style: AppText.small().copyWith(fontSize: 12.5, height: 1.5)),
        ]),
      );

  void _openProduct(Map<String, dynamic> row) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProductDetailScreen(
        product: row,
        onAddToCart: () => widget.onAdd(_toProduct(row)),
        hideLowStock: _hideLowStock,
      ),
    ));
  }

  void _openTradeIn() {
    // Categories come back lowercase from the DB ('rackets') — normalise first.
    final rackets = _products
        .where((p) => _normCat(p['category'] as String?) == 'Rackets')
        .toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TradeInSheet(rackets: rackets),
    );
  }

  void _openRepair() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _RepairSheet(),
    );
  }
}

// Player submits a racket repair — lands in the admin repair queue (which had
// no way to be populated before). RLS scopes the insert to the caller.
class _RepairSheet extends StatefulWidget {
  const _RepairSheet();
  @override
  State<_RepairSheet> createState() => _RepairSheetState();
}

class _RepairSheetState extends State<_RepairSheet> {
  final _racket = TextEditingController();
  final _issue = TextEditingController();
  bool _busy = false, _done = false;
  String _ref = '';

  @override
  void dispose() {
    _racket.dispose();
    _issue.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    final issue = _issue.text.trim();
    if (uid == null || issue.isEmpty || _busy) {
      if (issue.isEmpty) AppToast.show(context, 'Describe the issue first', kind: ToastKind.error);
      return;
    }
    setState(() => _busy = true);
    try {
      final row = await Supabase.instance.client
          .from('repair_requests')
          .insert({
            'player_id': uid,
            'racket_desc': _racket.text.trim().isEmpty ? 'Racket' : _racket.text.trim(),
            'issue': issue,
            'status': 'pending',
          })
          .select('id')
          .single();
      if (!mounted) return;
      final id = (row['id'] as String?) ?? '';
      setState(() {
        _busy = false;
        _done = true;
        _ref = id.isNotEmpty ? 'RP-${id.substring(0, 6).toUpperCase()}' : 'RP-PENDING';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.show(context, 'Could not submit — try again', kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(4))),
          const SizedBox(height: 16),
          if (_done) ...[
            const Icon(Icons.check_circle_rounded, size: 44, color: AppColors.success),
            const SizedBox(height: 12),
            Text('Repair requested', style: AppText.cardTitle().copyWith(fontSize: 18)),
            const SizedBox(height: 6),
            Text('Reference $_ref — our team will reach out with a quote.',
                textAlign: TextAlign.center, style: AppText.small().copyWith(fontSize: 12.5, height: 1.4)),
            const SizedBox(height: 18),
            AppButton('Done', full: true, height: 50, onPressed: () => Navigator.pop(context)),
          ] else ...[
            Align(alignment: Alignment.centerLeft,
                child: Text('Racket repair', style: AppText.cardTitle().copyWith(fontSize: 18))),
            const SizedBox(height: 4),
            Align(alignment: Alignment.centerLeft,
                child: Text('Tell us what needs fixing — we\'ll quote you.',
                    style: AppText.small().copyWith(fontSize: 12.5))),
            const SizedBox(height: 16),
            _field(_racket, 'Racket (brand / model) — optional'),
            const SizedBox(height: 10),
            _field(_issue, 'What\'s wrong? e.g. cracked frame, grommet, grip', lines: 3),
            const SizedBox(height: 16),
            AppButton(_busy ? 'Submitting…' : 'Request repair',
                full: true, height: 52, icon: Icons.build_rounded,
                onPressed: _busy ? null : _submit),
          ],
        ]),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, {int lines = 1}) => TextField(
        controller: c,
        maxLines: lines,
        style: AppText.body().copyWith(fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppText.small(AppColors.inkFaint),
          filled: true,
          fillColor: AppColors.field,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      );
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();
  @override
  Widget build(BuildContext context) {
    return const AppCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Skeleton(height: 108, width: double.infinity, radius: AppRadius.card),
        Padding(
          padding: EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Skeleton(width: 40, height: 8, radius: 4),
            SizedBox(height: 6),
            Skeleton(width: double.infinity, height: 10, radius: 4),
            SizedBox(height: 4),
            Skeleton(width: 80, height: 10, radius: 4),
            SizedBox(height: 14),
            Skeleton(width: 60, height: 14, radius: 4),
          ]),
        ),
      ]),
    );
  }
}

class _Condition {
  final String label, desc;
  const _Condition(this.label, this.desc);
}

/// Trade-In — multi-step submission:
///   0. Condition  1. Details  2. Trade toward
///   3. Review     4. Submitted (confirmation + reference number)
/// No asking price — the credit is set by our team after inspection.
class _TradeInSheet extends StatefulWidget {
  final List<Map<String, dynamic>> rackets;
  const _TradeInSheet({required this.rackets});
  @override
  State<_TradeInSheet> createState() => _TradeInSheetState();
}

class _TradeInSheetState extends State<_TradeInSheet> {
  static const _conditions = <_Condition>[
    _Condition('Like New', 'Barely used, no marks'),
    _Condition('Good', 'Light wear, plays great'),
    _Condition('Fair', 'Visible scuffs or scratches'),
    _Condition('Worn', 'Heavy use, still functional'),
  ];

  static const _steps = ['Condition', 'Details', 'Trade for', 'Review'];
  static const _last = 3; // Review; step 4 = submitted

  List<Map<String, dynamic>> get _rackets => widget.rackets;

  int _step = 0;
  int _cond = -1;
  bool _busy = false;
  final _nameC = TextEditingController();
  final _brandC = TextEditingController();
  final _notesC = TextEditingController();
  int _target = -1;
  String _ref = '';

  @override
  void dispose() {
    _nameC.dispose();
    _brandC.dispose();
    _notesC.dispose();
    super.dispose();
  }

  Map<String, dynamic>? get _targetP =>
      _target >= 0 && _target < _rackets.length ? _rackets[_target] : null;
  int get _targetPrice => _targetP == null ? 0 : _price(_targetP!);

  static String _brand(Map r) => (r['brand'] as String?)?.trim() ?? '';
  static String _name(Map r) => (r['name'] as String?)?.trim() ?? '';
  static int _price(Map r) {
    final onSale = r['on_sale'] == true;
    final sale = (r['sale_price'] as num?)?.toInt();
    final price = (r['price'] as num?)?.toInt() ?? 0;
    return onSale && sale != null ? sale : price;
  }

  bool get _canNext {
    switch (_step) {
      case 0:
        return _cond >= 0;
      case 1:
        return _nameC.text.trim().isNotEmpty &&
            _brandC.text.trim().isNotEmpty;
      case 2:
        return _target >= 0;
      default:
        return true;
    }
  }

  String get _ctaLabel {
    if (_step < 2) return 'Continue';
    if (_step == 2) return 'Review Request';
    if (_step == _last) return _busy ? 'Submitting…' : 'Submit Request';
    return 'Done';
  }

  Future<void> _advance() async {
    if (_step < _last) {
      setState(() => _step++);
    } else if (_step == _last) {
      await _submit();
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> _submit() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    setState(() => _busy = true);
    final brand = _brandC.text.trim();
    final name = _nameC.text.trim();
    final desc = [brand, name].where((s) => s.isNotEmpty).join(' ');
    final tp = _targetP;
    final note = <String>[
      if (_notesC.text.trim().isNotEmpty) _notesC.text.trim(),
      if (tp != null)
        'Wants to trade toward: ${_name(tp)} (${MockData.egp(_targetPrice)}).',
    ].join('\n');
    try {
      final row = await Supabase.instance.client
          .from('trade_requests')
          .insert({
            'player_id': uid,
            'racket_desc': desc.isEmpty ? 'Racket trade-in' : desc,
            'condition': _conditions[_cond].label,
            // no asking price — our team sets the credit after inspection
            'note': note,
            'status': 'pending',
          })
          .select('id')
          .single();
      if (!mounted) return;
      final id = (row['id'] as String?) ?? '';
      setState(() {
        _ref = id.isNotEmpty ? 'TD-${id.substring(0, 6).toUpperCase()}' : 'TD-PENDING';
        _busy = false;
        _step = _last + 1; // submitted
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          content: Text("Couldn't submit the trade-in. Try again.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitted = _step > _last;
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: kPopShadow,
      ),
      // Reserve the keyboard's height so the pinned Continue button and the
      // fields stay above it (a fixed-height sheet doesn't do this on its own).
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(children: [
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(top: 12, bottom: 4),
          decoration: BoxDecoration(
              color: AppColors.line, borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
          child: Row(children: [
            if (_step > 0 && !submitted) ...[
              IconChip(Icons.arrow_back_rounded,
                  onTap: () => setState(() => _step--)),
              const SizedBox(width: 6),
            ],
            Text(submitted ? 'Request Sent' : 'Trade-In',
                style: AppText.cardTitle().copyWith(fontSize: 18)),
            const Spacer(),
            IconChip(Icons.close_rounded, onTap: () => Navigator.pop(context)),
          ]),
        ),
        if (!submitted) _progress(),
        const Divider(height: 1, color: AppColors.lineSoft),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: _body(),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.lineSoft))),
          child: AppButton(
            _ctaLabel,
            full: true,
            height: 52,
            onPressed: (_canNext && !_busy) ? _advance : null,
          ),
        ),
        ]),
      ),
    );
  }

  // ── progress dots + labels ──
  Widget _progress() => Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
        child: Row(
          children: [
            for (int i = 0; i < _steps.length; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i == _steps.length - 1 ? 0 : 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 3,
                        decoration: BoxDecoration(
                          color: i <= _step ? AppColors.primary : AppColors.line,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(_steps[i],
                          style: AppText.tag(i == _step
                                  ? AppColors.primary
                                  : AppColors.inkFaint)
                              .copyWith(fontSize: 9, letterSpacing: 0.3)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _body() {
    switch (_step) {
      case 0:
        return _conditionStep();
      case 1:
        return _detailsStep();
      case 2:
        return _tradeForStep();
      case 3:
        return _reviewStep();
      default:
        return _submittedStep();
    }
  }

  Widget _heading(String title, String sub) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.cardTitle().copyWith(fontSize: 16)),
          const SizedBox(height: 3),
          Text(sub, style: AppText.small()),
          const SizedBox(height: 16),
        ],
      );

  Widget _field(String label, Widget child, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(label,
                  style: AppText.bodyStrong(AppColors.inkSoft).copyWith(
                      fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
              if (hint != null) ...[
                const Spacer(),
                Text(hint, style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11)),
              ],
            ]),
            const SizedBox(height: 6),
            child,
          ],
        ),
      );

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: AppText.body(AppColors.inkFaint),
        isDense: true,
        filled: true,
        fillColor: AppColors.field,
        contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: AppColors.line, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      );

  // ── STEP 0 — condition ──
  Widget _conditionStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading("What's the condition?",
              'Be honest — it helps us value it accurately.'),
          for (int i = 0; i < _conditions.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () => setState(() => _cond = i),
                child: Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: _cond == i
                        ? AppColors.wash(AppColors.primary)
                        : AppColors.field,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _cond == i ? AppColors.primary : AppColors.line,
                        width: 1.5),
                  ),
                  child: Row(children: [
                    Icon(Icons.sports_tennis_rounded,
                        size: 22,
                        color: _cond == i ? AppColors.primary : AppColors.inkFaint),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_conditions[i].label,
                              style: AppText.bodyStrong().copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: _cond == i
                                      ? AppColors.ink
                                      : AppColors.inkSoft)),
                          const SizedBox(height: 1),
                          Text(_conditions[i].desc,
                              style: AppText.small(AppColors.inkFaint)
                                  .copyWith(fontSize: 11.5)),
                        ],
                      ),
                    ),
                  ]),
                ),
              ),
            ),
        ],
      );

  // ── STEP 1 — details ──
  Widget _detailsStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading('Tell us about your racket',
              'Details help us assess it and speed up approval.'),
          _field(
              'RACKET NAME',
              TextField(
                  controller: _nameC,
                  style: AppText.body(),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  decoration: _inputDeco('e.g. Adipower Ctrl 3.2'),
                  onChanged: (_) => setState(() {}))),
          _field(
              'BRAND',
              TextField(
                  controller: _brandC,
                  style: AppText.body(),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  decoration: _inputDeco('e.g. Adidas'),
                  onChanged: (_) => setState(() {}))),
          _field(
            'DESCRIPTION & DETAILS',
            TextField(
              controller: _notesC,
              maxLines: 3,
              style: AppText.body(),
              decoration:
                  _inputDeco('Year, weight, shape, grip, any defects or upgrades…'),
            ),
            hint: 'optional',
          ),
        ],
      );

  // ── STEP 2 — trade toward ──
  Widget _tradeForStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading('Trade toward which racket?',
              'Pick the racket from our store you want to upgrade to.'),
          if (_rackets.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              alignment: Alignment.center,
              child: Text('No rackets available right now.',
                  style: AppText.small(AppColors.inkFaint)),
            )
          else
            for (int i = 0; i < _rackets.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _targetRow(i),
              ),
        ],
      );

  /// Square product thumbnail — same `image_url` the store grid uses, with the
  /// striped placeholder as the fallback (no image, or a broken/blocked URL).
  /// `contain` on a field-coloured tile so a tall racket shot isn't cropped.
  Widget _thumb(Map<String, dynamic>? p, double size) {
    final url = (p?['image_url'] as String?)?.trim() ?? '';
    const radius = BorderRadius.all(Radius.circular(10));
    Widget placeholder() => SizedBox(
          width: size,
          height: size,
          child: StripedPlaceholder(
              height: size, icon: Icons.sports_tennis_rounded, radius: radius),
        );
    if (url.isEmpty) return placeholder();
    return ClipRRect(
      borderRadius: radius,
      child: Container(
        width: size,
        height: size,
        color: AppColors.field,
        child: Image.network(
          url,
          fit: BoxFit.contain,
          cacheWidth: (size * 3).round(),
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : const SizedBox.shrink(),
          errorBuilder: (_, __, ___) => placeholder(),
        ),
      ),
    );
  }

  Widget _targetRow(int i) {
    final p = _rackets[i];
    final on = _target == i;
    return GestureDetector(
      onTap: () => setState(() => _target = i),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: on ? AppColors.wash(AppColors.primary) : AppColors.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: on ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          _thumb(p, 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_brand(p).toUpperCase(),
                    style: AppText.kicker(AppColors.inkSoft).copyWith(fontSize: 9)),
                Text(_name(p),
                    style: AppText.bodyStrong().copyWith(
                        fontSize: 13.5, fontWeight: FontWeight.w800, height: 1.2)),
                const SizedBox(height: 2),
                Text(MockData.egp(_price(p)),
                    style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? AppColors.primary : Colors.transparent,
              border: Border.all(
                  color: on ? AppColors.primary : AppColors.line, width: 2),
            ),
            child: on
                ? const Icon(Icons.check_rounded, size: 13, color: AppColors.primaryInk)
                : null,
          ),
        ]),
      ),
    );
  }

  // ── STEP 3 — review ──
  Widget _reviewStep() {
    final tp = _targetP;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading('Review your request',
            'Check the details before sending to our team.'),
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: AppColors.field,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // the player's own racket — always the placeholder, they don't
                // upload a photo
                _thumb(null, 60),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((_brandC.text.isEmpty ? '—' : _brandC.text).toUpperCase(),
                          style: AppText.kicker(AppColors.inkSoft).copyWith(fontSize: 9)),
                      Text(_nameC.text.isEmpty ? 'Your racket' : _nameC.text,
                          style: AppText.cardTitle().copyWith(fontSize: 15)),
                      const SizedBox(height: 4),
                      AppTag(_cond >= 0 ? _conditions[_cond].label : '—',
                          color: AppColors.primary),
                    ],
                  ),
                ),
              ]),
              if (_notesC.text.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_notesC.text,
                    style: AppText.small(AppColors.inkSoft).copyWith(fontSize: 12, height: 1.4)),
              ],
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppColors.field,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(children: [
            _reviewRow('Trading toward', tp == null ? '—' : _name(tp)),
            _reviewRow('New racket price', MockData.egp(_targetPrice)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(children: [
                Text('Trade-in credit',
                    style: AppText.bodyStrong().copyWith(fontWeight: FontWeight.w800)),
                const Spacer(),
                Text('After inspection',
                    style: AppText.bodyStrong(AppColors.primary)
                        .copyWith(fontSize: 13.5)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Text(
          'Final value is confirmed after a free inspection at any partner club. No commitment until you accept the offer.',
          textAlign: TextAlign.center,
          style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11.5, height: 1.45),
        ),
      ],
    );
  }

  Widget _reviewRow(String k, String v) => Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.lineSoft))),
        child: Row(children: [
          Text(k, style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13)),
          const Spacer(),
          Text(v,
              style: AppText.bodyStrong()
                  .copyWith(fontSize: 13.5, fontWeight: FontWeight.w800)),
        ]),
      );

  // ── STEP 4 — submitted ──
  Widget _submittedStep() => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
                color: AppColors.wash(AppColors.primary), shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_outline_rounded,
                size: 42, color: AppColors.primary),
          ),
          const SizedBox(height: 18),
          Text('Request submitted', style: AppText.bigTitle().copyWith(fontSize: 20)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 270),
            child: Text.rich(
              TextSpan(
                style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13.5, height: 1.5),
                children: [
                  const TextSpan(text: 'Our team will review your '),
                  TextSpan(
                      text: _nameC.text.isEmpty ? 'racket' : _nameC.text,
                      style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
                  const TextSpan(
                      text:
                          " and send an offer soon. You'll get a notification when it's ready."),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('REF', style: AppText.kicker(AppColors.inkSoft).copyWith(fontSize: 11)),
              const SizedBox(width: 8),
              Text(_ref,
                  style: AppText.bodyStrong().copyWith(fontSize: 12.5, letterSpacing: 0.5)),
            ]),
          ),
        ]),
      );
}
