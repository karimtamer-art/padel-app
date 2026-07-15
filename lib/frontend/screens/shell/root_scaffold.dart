import 'package:flutter/material.dart';
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
import '../create/create_match_sheet.dart';
import '../detail/match_detail_screen.dart';

/// Root scaffold: 4 tabs + a raised center "Create" action.
/// Nav order: Home · Tournaments · (Create) · Store · You
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

  // page index per visual slot (slot 2 is the FAB, not a page)
  static const _slotToPage = {0: 0, 1: 1, 3: 2, 4: 3};

  Future<void> _openCreate() async {
    final matchId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CreateMatchSheet(
        myName: widget.displayName,
        myInitials: widget.initials,
      ),
    );
    if (!mounted) return;
    // A match may have been created even when the sheet closes without "View"
    // (Done / Create-another) — refresh Home either way so it shows up.
    setState(() => _homeRefresh++);
    if (matchId == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MatchDetailScreen(matchId: matchId)));
    if (mounted) setState(() => _homeRefresh++);
  }

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
            onSeeTournaments: () => setState(() => _tab = 1),
            onAddToCart: _addToCart,
            profile: widget.profile,
            displayName: widget.displayName,
            initials: widget.initials,
          ),
          const TournamentsScreen(),
          StoreScreen(cart: _cartCount, onAdd: _addToCart, onOpenCart: _openCart),
          ProfileScreen(
            profile: widget.profile,
            refreshTick: _profileRefresh,
            onFindMatch: _openCreate,
            onSignOut: widget.onSignOut,
            onReorder: _reorder,
            displayName: widget.displayName,
            initials: widget.initials,
            memberSince: widget.memberSince,
          ),
        ],
      ),
      bottomNavigationBar: _NavBar(
        current: _tab,
        onTap: (i) => setState(() {
          // Returning to Home refetches it (it's kept alive in the IndexedStack,
          // so an action on another tab — e.g. withdrawing — wouldn't show
          // otherwise).
          if (i == 0 && _tab != 0) _homeRefresh++;
          if (i == 4 && _tab != 4) _profileRefresh++;
          _tab = i;
        }),
        onCreate: _openCreate,
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  final int current;
  final ValueChanged<int> onTap;
  final VoidCallback onCreate;
  const _NavBar({required this.current, required this.onTap, required this.onCreate});

  // The create button floats above the bar by this much; the Stack reserves
  // the space so the whole circle stays tappable (OverflowBox would clip hits).
  static const double _fabSize = 64;
  static const double _fabOverlap = 18;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: _fabOverlap),
          child: Container(
            decoration: const BoxDecoration(
              color: AppColors.bg,
              border: Border(top: BorderSide(color: AppColors.lineSoft)),
            ),
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 26),
            child: LayoutBuilder(
              builder: (context, c) {
                final slotW = c.maxWidth / 5; // 5 slots incl. Create (skipped)
                const pillW = 48.0, pillH = 36.0;
                final pillLeft = slotW * current + (slotW - pillW) / 2;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // gliding active-tab pill (behind the icons); skips Create
                    if (current != 2)
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
                        _createSlot(),
                        _item(3, Icons.shopping_bag_outlined, 'Store', reduce),
                        _item(4, Icons.account_circle_outlined, 'You', reduce),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              onTap: onCreate,
              child: Container(
                width: _fabSize,
                height: _fabSize,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.4),
                        blurRadius: 18,
                        offset: const Offset(0, 8)),
                  ],
                ),
                child: const Icon(Icons.add_rounded,
                    color: AppColors.primaryInk, size: 32),
              ),
            ),
          ),
        ),
      ],
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

  Widget _createSlot() {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // reserved space under the floating create button
          const SizedBox(height: 38),
          Text('Create',
              style: AppText.tag(AppColors.primary)
                  .copyWith(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.1)),
        ],
      ),
    );
  }
}
