import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/models/mock_data.dart';

/// Full product page: swipeable image gallery, info/description, price, and
/// add-to-cart. The gallery (all images) loads only here so the store grid
/// stays light.
class ProductDetailScreen extends StatefulWidget {
  final Map<String, dynamic> product;
  /// Adds this product to the cart (one unit) — wired to the same handler the
  /// store grid uses.
  final VoidCallback onAddToCart;
  /// Store-wide admin setting: when true the "Low stock" tag is suppressed.
  final bool hideLowStock;
  const ProductDetailScreen(
      {super.key,
      required this.product,
      required this.onAddToCart,
      this.hideLowStock = false});
  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  final _pageCtrl = PageController();
  List<String> _images = [];
  bool _loading = true;
  int _page = 0;

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

  static String _normCat(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'rackets': return 'Rackets';
      case 'shoes': return 'Shoes';
      case 'apparel': return 'Apparel';
      case 'balls': return 'Balls';
      default: return 'Accessories';
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.product['id'] as String?;
    final primary = widget.product['image_url'] as String?;
    var urls = <String>[];
    if (id != null && id.isNotEmpty) {
      try {
        final rows = await Supabase.instance.client
            .from('product_images')
            .select('url, sort_order')
            .eq('product_id', id)
            .order('sort_order');
        urls = [for (final r in rows as List) r['url'] as String];
      } catch (_) {}
    }
    if (urls.isEmpty && primary != null && primary.isNotEmpty) urls = [primary];
    if (mounted) setState(() { _images = urls; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final cat = _normCat(p['category'] as String?);
    final brand = (p['brand'] as String? ?? '').trim();
    final name = p['name'] as String? ?? 'Product';
    final price = (p['price'] as num?)?.toInt() ?? 0;
    final salePrice = (p['sale_price'] as num?)?.toInt();
    final onSale = (p['on_sale'] as bool?) ?? false;
    final hasSale = onSale && salePrice != null && price > 0;
    final displayPrice = hasSale ? salePrice : price;
    final rating = (p['rating'] as num?)?.toDouble();
    final desc = (p['description'] as String? ?? '').trim();
    final stockStatus = p['stock_status'] as String? ?? 'in';
    final outOfStock = stockStatus == 'out';
    final lowStock = stockStatus == 'low' && !widget.hideLowStock;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: ScreenBar(title: 'Details', onBack: () => Navigator.pop(context)),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _gallery(cat),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.screen, 18, AppSpacing.screen, 28),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (brand.isNotEmpty)
                Text(brand.toUpperCase(),
                    style: AppText.kicker().copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 6),
              Text(name,
                  style: AppText.stat(24, AppColors.ink)
                      .copyWith(height: 1.15, letterSpacing: -0.4)),
              const SizedBox(height: 10),
              Row(children: [
                AppTag(cat, color: _catColors[cat] ?? AppColors.primary),
                if (rating != null && rating > 0) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.star_rounded, size: 16, color: AppColors.gold),
                  const SizedBox(width: 3),
                  Text(rating.toStringAsFixed(1),
                      style: AppText.bodyStrong().copyWith(fontSize: 13)),
                ],
                const Spacer(),
                if (outOfStock)
                  const AppTag('Out of stock', color: AppColors.inkSoft)
                else if (lowStock)
                  const AppTag('Low stock', color: AppColors.warn),
              ]),
              const SizedBox(height: 18),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(MockData.egp(displayPrice),
                    style: AppText.stat(28,
                        hasSale ? AppColors.primary : AppColors.ink)),
                if (hasSale) ...[
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(MockData.egp(price),
                        style: AppText.body(AppColors.inkFaint).copyWith(
                            fontSize: 15,
                            decoration: TextDecoration.lineThrough)),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: _saleFlag(
                        '-${((price - salePrice) / price * 100).round()}%'),
                  ),
                ],
              ]),
              if (desc.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text('ABOUT', style: AppText.kicker()),
                const SizedBox(height: 8),
                Text(desc,
                    style: AppText.body(AppColors.inkSoft)
                        .copyWith(fontSize: 14.5, height: 1.6)),
              ],
            ]),
          ),
        ],
      ),
      bottomNavigationBar: _bottomBar(outOfStock, displayPrice),
    );
  }

  Widget _gallery(String cat) {
    final color = _catColors[cat] ?? AppColors.primary;
    final icon = _catIcons[cat] ?? Icons.sports_tennis_rounded;
    if (_loading) {
      return Container(height: 300, color: AppColors.field);
    }
    if (_images.isEmpty) {
      return StripedPlaceholder(height: 300, icon: icon, color: color);
    }
    return SizedBox(
      height: 300,
      child: Stack(children: [
        PageView.builder(
          controller: _pageCtrl,
          itemCount: _images.length,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (_, i) => Image.network(
            _images[i],
            fit: BoxFit.cover,
            width: double.infinity,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : Container(color: AppColors.field),
            errorBuilder: (_, __, ___) =>
                StripedPlaceholder(height: 300, icon: icon, color: color),
          ),
        ),
        if (_images.length > 1)
          Positioned(
            bottom: 14,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < _images.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? AppColors.primary
                          : Colors.white.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _saleFlag(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
            color: AppColors.danger, borderRadius: BorderRadius.circular(6)),
        child: Text(t,
            style: AppText.tag(Colors.white)
                .copyWith(fontSize: 11, fontWeight: FontWeight.w800)),
      );

  Widget _bottomBar(bool outOfStock, int displayPrice) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.screen, 12, AppSpacing.screen,
          MediaQuery.of(context).padding.bottom + 14),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.lineSoft)),
      ),
      child: AppButton(
        outOfStock ? 'Out of Stock' : 'Add to Cart · ${MockData.egp(displayPrice)}',
        full: true,
        height: 54,
        icon: outOfStock ? Icons.block_rounded : Icons.add_shopping_cart_rounded,
        onPressed: outOfStock
            ? null
            : () {
                widget.onAddToCart();
                Navigator.pop(context);
              },
      ),
    );
  }
}
