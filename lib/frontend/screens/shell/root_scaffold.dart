import 'package:flutter/material.dart';
import '../../../backend/services/region_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/app_toast.dart';
import '../../../backend/models/mock_data.dart';
import '../../../backend/models/ranking_scale.dart';
import '../home/home_screen.dart';
import '../tournaments/tournaments_screen.dart';
import '../store/store_screen.dart';
import '../store/cart_screen.dart';
import '../profile/profile_screen.dart';

/// Root scaffold: Home · Tournaments · Store (commerce regions only) · You.
///
/// [profile] selects the account state shown across Home + Profile — pass
/// [PlayerProfile.fresh] for a player who just signed up (unranked + empty
/// states) or [PlayerProfile.established] (default) for a returning player.
class RootScaffold extends StatefulWidget {
  final PlayerProfile profile;
  final String displayName;
  final String initials;
  final String memberSince;
  final Future<void> Function()? onSignOut;
  const RootScaffold({
    super.key,
    this.profile = PlayerProfile.fresh,
    this.displayName = '',
    this.initials = 'P',
    this.memberSince = '',
    this.onSignOut,
  });
  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  int _tab = 0;
  int _homeRefresh = 0; // bumping this rebuilds HomeScreen (refetches data)
  int _profileRefresh = 0; // same idea for the kept-alive ProfileScreen
  final List<CartLine> _cart = [];

  int get _cartCount => _cart.fold(0, (n, l) => n + l.qty);

  void _addToCart(Product p) {
    setState(() {
      final existing = _cart.where((l) => l.product.name == p.name && l.product.brand == p.brand);
      if (existing.isNotEmpty) {
        existing.first.qty++;
      } else {
        _cart.add(CartLine(p));
      }
    });
    AppToast.show(
      context,
      'Added — $_cartCount item${_cartCount == 1 ? '' : 's'} in cart',
      actionLabel: 'View',
      onAction: _openCart,
    );
  }

  void _openCart() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CartScreen(cart: _cart, onChanged: () => setState(() {})),
    ));
  }

  /// Reorder from "My orders": merge the order's lines into the cart (summing
  /// quantities for items already present) and open the cart.
  void _reorder(List<CartLine> lines) {
    setState(() {
      for (final line in lines) {
        final existing = _cart.where(
            (l) => l.product.name == line.product.name && l.product.brand == line.product.brand);
        if (existing.isNotEmpty) {
          existing.first.qty += line.qty;
        } else {
          _cart.add(line);
        }
      }
    });
    _openCart();
  }

  /// Does this player's region have a store?
  ///
  /// Cash-on-delivery and the Egyptian `addresses` shape (governorate / city /
  /// area) don't export, so the Store is Egypt-only — decided by
  /// `regions.commerce_enabled`, i.e. by DATA rather than by a build flag.
  bool get _commerce => RegionService.now.commerceEnabled;

  /// Nav slot id → IndexedStack page. Slot 2 was the retired Create FAB.
  ///
  /// The slot ids are STABLE (Store is always 3, You is always 4) so that
  /// `onSeeStore` and the refresh conditions below keep meaning one thing; only
  /// which slots are *visible* and which page each maps to changes.
  Map<int, int> get _slotToPage =>
      _commerce ? const {0: 0, 1: 1, 3: 2, 4: 3} : const {0: 0, 1: 1, 4: 2};

  void _seeTournaments() => setState(() => _tab = 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      extendBody: true,
      body: IndexedStack(
        index: _slotToPage[_tab] ?? 0,
        children: [
          HomeScreen(
            key: const ValueKey('home'),
            refreshTick: _homeRefresh,
            onSeeStore: () => setState(() => _tab = 3),
            onSeeTournaments: _seeTournaments,
            onAddToCart: _addToCart,
            profile: widget.profile,
            displayName: widget.displayName,
            initials: widget.initials,
          ),
          const TournamentsScreen(),
          // Left out of the tree entirely where there is no store, rather than
          // built and never shown — StoreScreen fetches products on init.
          if (_commerce)
            StoreScreen(cart: _cartCount, onAdd: _addToCart, onOpenCart: _openCart),
          ProfileScreen(
            profile: widget.profile,
            refreshTick: _profileRefresh,
            // Placement is earned in tournaments now that pickup is retired.
            onBrowseTournaments: _seeTournaments,
            onSignOut: widget.onSignOut,
            onReorder: _reorder,
            displayName: widget.displayName,
            initials: widget.initials,
            memberSince: widget.memberSince,
          ),
        ],
      ),
      bottomNavigationBar: _NavBar(
        commerce: _commerce,
        current: _tab,
        onTap: (i) => setState(() {
          // Returning to Home refetches it (it's kept alive in the IndexedStack,
          // so an action on another tab — e.g. withdrawing — wouldn't show
          // otherwise).
          if (i == 0 && _tab != 0) _homeRefresh++;
          if (i == 4 && _tab != 4) _profileRefresh++;
          _tab = i;
        }),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  final int current;
  final ValueChanged<int> onTap;

  /// Whether the Store slot appears. See `RootScaffold._commerce`.
  final bool commerce;

  const _NavBar({
    required this.current,
    required this.onTap,
    this.commerce = true,
  });

  /// Slot ids in visual order.
  ///
  /// Slot **2 was the raised "Create" FAB and is gone** (2026-09-26): in a
  /// tournament-first app a player has nothing to create — tournaments are made
  /// in the admin console, and `AuthGate` sends staff there rather than here, so
  /// nobody who sees this bar could ever have used it for that. Pickup itself
  /// was retired in Phase 4, so there is no create-match path anywhere.
  ///
  /// Slot ids stay STABLE (Store is still 3, You is still 4) so `onSeeStore` and
  /// the refresh conditions keep meaning one thing. The pill divides by
  /// `_slots.length`, so dropping a slot moves the geometry with it.
  List<int> get _slots => [0, 1, if (commerce) 3, 4];

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.lineSoft)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 26),
      child: LayoutBuilder(
        builder: (context, c) {
          final slotW = c.maxWidth / _slots.length;
          const pillW = 48.0, pillH = 36.0;
          // Position by VISUAL index, not slot id — with Store hidden, slot 4
          // ("You") is the third icon, not the fourth.
          final visualIndex = _slots.indexOf(current);
          final pillLeft =
              slotW * (visualIndex < 0 ? 0 : visualIndex) + (slotW - pillW) / 2;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // gliding active-tab pill, behind the icons
              AnimatedPositioned(
                duration: Duration(milliseconds: reduce ? 0 : 280),
                curve: Curves.easeOutCubic,
                left: pillLeft,
                top: 0,
                width: pillW,
                height: pillH,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _item(0, Icons.home_outlined, 'Home', reduce),
                  _item(1, Icons.emoji_events_outlined, 'Tournaments', reduce),
                  if (commerce)
                    _item(3, Icons.shopping_bag_outlined, 'Store', reduce),
                  _item(4, Icons.account_circle_outlined, 'You', reduce),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _item(int slot, IconData icon, String label, bool reduce) {
    final on = current == slot;
    final c = on ? AppColors.primary : AppColors.inkFaint;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(slot),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // active icon lifts ~2px above the gliding pill (drawn behind by
            // the Stack); the per-item background is gone — the pill replaces it
            AnimatedSlide(
              duration: Duration(milliseconds: reduce ? 0 : 300),
              curve: Curves.easeOutBack,
              offset: Offset(0, on && !reduce ? -0.06 : 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                child: Icon(icon, size: 22, color: c),
              ),
            ),
            const SizedBox(height: 4),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tag(c).copyWith(
                    fontSize: 9.5,
                    letterSpacing: 0.1,
                    fontWeight: on ? FontWeight.w800 : FontWeight.w600)),
          ],
        ),
      ),
    );
  }

}
