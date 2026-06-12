import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        duration: const Duration(milliseconds: 2200),
        content: Row(children: [
          const Icon(Icons.check_circle_rounded, size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
              child: Text(
                  'Added — $_cartCount item${_cartCount == 1 ? '' : 's'} in cart',
                  style: AppText.bodyStrong(AppColors.bg).copyWith(fontSize: 13))),
          GestureDetector(
            onTap: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              _openCart();
            },
            child: Text('VIEW', style: AppText.tag(AppColors.primary).copyWith(fontSize: 12)),
          ),
        ]),
      ));
  }

  void _openCart() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CartScreen(cart: _cart, onChanged: () => setState(() {})),
    ));
  }

  // page index per visual slot (slot 2 is the FAB, not a page)
  static const _slotToPage = {0: 0, 1: 1, 3: 2, 4: 3};

  Future<void> _openCreate() async {
    final matchId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CreateMatchSheet(),
    );
    if (matchId == null || !mounted) return;
    setState(() => _homeRefresh++);
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
            key: ValueKey('home-$_homeRefresh'),
            onSeeStore: () => setState(() => _tab = 3),
            onSeeTournaments: () => setState(() => _tab = 1),
            profile: widget.profile,
            displayName: widget.displayName,
            initials: widget.initials,
          ),
          const TournamentsScreen(),
          StoreScreen(cart: _cartCount, onAdd: _addToCart, onOpenCart: _openCart),
          ProfileScreen(
            profile: widget.profile,
            onFindMatch: _openCreate,
            onSignOut: widget.onSignOut,
            displayName: widget.displayName,
            initials: widget.initials,
            memberSince: widget.memberSince,
          ),
        ],
      ),
      bottomNavigationBar: _NavBar(
        current: _tab,
        onTap: (i) => setState(() => _tab = i),
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
  static const double _fabOverlap = 30;

  @override
  Widget build(BuildContext context) {
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _item(0, Icons.home_outlined, 'Home'),
                _item(1, Icons.emoji_events_outlined, 'Tournaments'),
                _createSlot(),
                _item(3, Icons.shopping_bag_outlined, 'Store'),
                _item(4, Icons.account_circle_outlined, 'You'),
              ],
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

  Widget _item(int slot, IconData icon, String label) {
    final on = current == slot;
    final c = on ? AppColors.primary : AppColors.inkFaint;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(slot),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              decoration: BoxDecoration(
                color: on ? AppColors.primary.withValues(alpha: 0.12) : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 22, color: c),
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
