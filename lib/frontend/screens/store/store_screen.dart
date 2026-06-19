import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
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
                  isCollapsed: true,
                  border: InputBorder.none,
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _TradeInSheet(),
    );
  }
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

class _TradeInSheet extends StatefulWidget {
  const _TradeInSheet();
  @override
  State<_TradeInSheet> createState() => _TradeInSheetState();
}

class _TradeInSheetState extends State<_TradeInSheet> {
  int _step = 0;
  int _cond = -1;
  bool _busy = false;
  final _conditions = ['Like New', 'Good', 'Fair', 'Worn'];
  final _quotes = [2200, 1500, 850, 400];

  Future<void> _submit() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.from('trade_requests').insert({
        'player_id': uid,
        'racket_desc': 'Racket trade-in (${_conditions[_cond]})',
        'condition': _conditions[_cond].toLowerCase(),
        'asking_credit': _quotes[_cond],
        'status': 'pending',
      });
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
              'Trade-in requested — bring your racket to any partner club for inspection.')));
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
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(children: [
        Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(children: [
            Text('Trade-In', style: AppText.cardTitle().copyWith(fontSize: 19)),
            const Spacer(),
            IconChip(Icons.close_rounded, onTap: () => Navigator.pop(context)),
          ]),
        ),
        const Divider(height: 20, color: AppColors.lineSoft),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: _step == 0 ? _condition() : _quote(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
          child: AppButton(
            _step == 0 ? 'Get Quote' : (_busy ? 'Submitting…' : 'Request Trade-In'),
            full: true, height: 52,
            onPressed: (_step == 0 && _cond < 0) || _busy
                ? null
                : () => _step == 0 ? setState(() => _step = 1) : _submit(),
          ),
        ),
      ]),
    );
  }

  Widget _condition() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("What's the condition?", style: AppText.cardTitle().copyWith(fontSize: 16)),
        const SizedBox(height: 3),
        Text('Be honest — it helps us quote accurately.', style: AppText.small()),
        const SizedBox(height: 16),
        for (int i = 0; i < _conditions.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GestureDetector(
              onTap: () => setState(() => _cond = i),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _cond == i ? AppColors.primary.withValues(alpha: 0.1) : AppColors.field,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _cond == i ? AppColors.primary : AppColors.line, width: 1.5),
                ),
                child: Row(children: [
                  Icon(Icons.sports_tennis_rounded, size: 22, color: _cond == i ? AppColors.primary : AppColors.inkFaint),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_conditions[i], style: AppText.bodyStrong())),
                  Text('~${MockData.egp(_quotes[i])}', style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 13)),
                ]),
              ),
            ),
          ),
      ]);

  Widget _quote() => Column(children: [
        const SizedBox(height: 10),
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: const Icon(Icons.check_circle_outline_rounded, size: 34, color: AppColors.primary),
        ),
        const SizedBox(height: 14),
        Text('Estimated store credit', style: AppText.small()),
        const SizedBox(height: 4),
        Text(MockData.egp(_cond >= 0 ? _quotes[_cond] : 0), style: AppText.stat(40, AppColors.primary)),
        const SizedBox(height: 8),
        Text('Final value confirmed after inspection at any partner club.',
            textAlign: TextAlign.center, style: AppText.small(AppColors.inkFaint)),
      ]);
}
