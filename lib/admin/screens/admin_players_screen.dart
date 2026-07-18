import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPicker;
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

// Super-Admin PLAYERS console (mobile-first, rating engine v2).
// KPIs · division-distribution insight (bar + tappable filter tiles) · search
// · filter chips + sort · card directory · profile sheet (edit ranking / ban).
// All data is real (admin_players_console RPC) — no mock/legacy ELO.

enum _Sort { rank, recent, name, winRate }

extension on _Sort {
  String get label => switch (this) {
        _Sort.rank => 'Rank',
        _Sort.recent => 'Recently active',
        _Sort.name => 'Name',
        _Sort.winRate => 'Win rate',
      };
}

class AdminPlayersScreen extends StatefulWidget {
  const AdminPlayersScreen({super.key});
  @override
  State<AdminPlayersScreen> createState() => _AdminPlayersScreenState();
}

class _AdminPlayersScreenState extends State<AdminPlayersScreen> {
  List<Map<String, dynamic>> _all = [];
  bool _loading = true;
  String? _error;
  String _filter = 'all';
  _Sort _sort = _Sort.rank;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AdminService.playersConsole();
      data.sort((a, b) => _ratingOf(b).compareTo(_ratingOf(a)));
      if (mounted) setState(() { _all = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── rating engine v2 helpers ────────────────────────────────────────────
  // The live skill number is the 0..7 `rating` (mirrored by `level`).
  static double _ratingOf(Map<String, dynamic> p) =>
      (p['rating'] as num?)?.toDouble() ??
      (p['level'] as num?)?.toDouble() ??
      0.0;

  static bool _isProvisional(Map<String, dynamic> p) {
    if (p['is_provisional'] is bool) return p['is_provisional'] as bool;
    return ((p['competitive_matches'] as num?)?.toInt() ??
            (p['played'] as num?)?.toInt() ??
            0) <
        5;
  }

  // Unranked = still in placement (< 5 competitive matches). Mirrors the player
  // app's Unranked/placement gate. Falls back to competitive/played count when
  // placement_played isn't in the payload (pre-migration RPC).
  static bool _isUnranked(Map<String, dynamic> p) {
    final placement = (p['placement_played'] as num?)?.toInt();
    if (placement != null) return placement < 5;
    return ((p['competitive_matches'] as num?)?.toInt() ??
            (p['played'] as num?)?.toInt() ??
            0) <
        5;
  }

  static String _tierForRating(double lv) {
    if (lv >= 5.0) return 'elite';
    if (lv >= 3.5) return 'gold';
    if (lv >= 2.0) return 'silver';
    return 'bronze';
  }

  static String _divLetter(String tier) {
    switch (tier) {
      case 'elite': return 'A';
      case 'gold': return 'B';
      case 'silver': return 'C';
      default: return 'D';
    }
  }

  static String _metalName(String tier) {
    switch (tier) {
      case 'elite': return 'Elite';
      case 'gold': return 'Gold';
      case 'silver': return 'Silver';
      default: return 'Bronze';
    }
  }

  static int? _winRate(Map<String, dynamic> p) {
    final played = (p['played'] as num?)?.toInt() ?? 0;
    if (played == 0) return null;
    final wins = (p['wins'] as num?)?.toInt() ?? 0;
    return (wins / played * 100).round();
  }

  static String _handle(Map<String, dynamic> p) {
    final u = (p['username'] as String?)?.trim();
    if (u != null && u.isNotEmpty) return u.startsWith('@') ? u : '@$u';
    final id = p['id'] as String? ?? '';
    return 'PL-${id.length >= 4 ? id.substring(0, 4).toUpperCase() : id}';
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  // Account moderation state wins; otherwise show ranking state.
  static String _statusKey(Map<String, dynamic> p) {
    final s = p['status'] as String? ?? 'active';
    if (s == 'banned' || s == 'flagged') return s;
    if (_isUnranked(p)) return 'unranked';
    return _isProvisional(p) ? 'provisional' : 'ranked';
  }

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  static DateTime? _at(Map<String, dynamic> p, String key) {
    final v = p[key];
    if (v is String) return DateTime.tryParse(v)?.toLocal();
    return null;
  }

  static String _rel(DateTime? t) {
    if (t == null) return '—';
    final d = DateTime.now().difference(t);
    if (d.isNegative) return 'now';
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays == 1) return '1d';
    if (d.inDays < 7) return '${d.inDays}d';
    if (d.inDays < 30) return '${(d.inDays / 7).floor()}w';
    if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo';
    return '${(d.inDays / 365).floor()}y';
  }

  static String _monthYear(DateTime? t) =>
      t == null ? '—' : '${_months[t.month - 1]} ${t.year}';

  // ── filtered + sorted rows ──────────────────────────────────────────────
  List<Map<String, dynamic>> get _rows {
    final q = _search.text.trim().toLowerCase();
    final rows = _all.where((p) {
      if (_filter == 'unranked' && !_isUnranked(p)) return false;
      if (_filter == 'banned' && (p['status'] as String?) != 'banned') return false;
      if (['A', 'B', 'C', 'D'].contains(_filter) &&
          (_isUnranked(p) || _divLetter(_tierForRating(_ratingOf(p))) != _filter)) {
        return false;
      }
      if (q.isNotEmpty) {
        final hay = [
          p['name'], p['username'], p['email'], p['id'],
        ].whereType<String>().join(' ').toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
    rows.sort((a, b) {
      switch (_sort) {
        case _Sort.rank:
          return _ratingOf(b).compareTo(_ratingOf(a));
        case _Sort.name:
          return (a['name'] as String? ?? '')
              .toLowerCase()
              .compareTo((b['name'] as String? ?? '').toLowerCase());
        case _Sort.winRate:
          return (_winRate(b) ?? -1).compareTo(_winRate(a) ?? -1);
        case _Sort.recent:
          final ta = _at(a, 'last_sign_in_at')?.millisecondsSinceEpoch ?? 0;
          final tb = _at(b, 'last_sign_in_at')?.millisecondsSinceEpoch ?? 0;
          return tb.compareTo(ta);
      }
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.wifi_off_rounded, size: 36, color: AdminColors.inkFaint),
          const SizedBox(height: 12),
          Text('Could not load players', style: AdminText.strong()),
          const SizedBox(height: 8),
          AdminButton('Retry', onPressed: _load),
        ]),
      );
    }

    final now24 = DateTime.now().subtract(const Duration(hours: 24));
    final activeToday = _all
        .where((p) => (_at(p, 'last_sign_in_at') ?? DateTime(2000)).isAfter(now24))
        .length;
    final unranked = _all.where(_isUnranked).length;
    final banned = _all.where((p) => (p['status'] as String?) == 'banned').length;
    final rows = _rows;

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(icon: Icons.groups_outlined, tone: AdminColors.green, label: 'Total players', value: '${_all.length}'),
            StatCard(icon: Icons.bolt_rounded, tone: AdminColors.primary, label: 'Active today', value: '$activeToday'),
            StatCard(icon: Icons.hourglass_bottom_rounded, tone: unranked > 0 ? AdminColors.warn : AdminColors.inkFaint, label: 'Unranked', value: '$unranked', foot: 'In placement'),
            StatCard(icon: Icons.lock_outline_rounded, tone: AdminColors.danger, label: 'Banned', value: '$banned'),
          ]),
          const SizedBox(height: 16),
          _distribution(),
          const SizedBox(height: 14),
          _searchField(),
          const SizedBox(height: 12),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final f in const [
                  ['all', 'All'],
                  ['A', 'Div A'],
                  ['B', 'Div B'],
                  ['C', 'Div C'],
                  ['D', 'Div D'],
                  ['unranked', 'Unranked'],
                  ['banned', 'Banned'],
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _chip(f[1], _filter == f[0], () => setState(() => _filter = f[0])),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Text('SORT', style: AdminText.kicker()),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final s in _Sort.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _seg(s.label, _sort == s, () => setState(() => _sort = s)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text('${rows.length}', style: AdminText.mono(12, FontWeight.w600, AdminColors.inkFaint)),
          ]),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Center(child: Text('No players match this filter', style: AdminText.small())),
            )
          else
            for (final p in rows) _PlayerCard(p, onTap: () => _openPlayer(p)),
        ],
      ),
    );
  }

  Widget _searchField() => Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: AdminUI.fieldR,
          border: Border.all(color: AdminColors.line),
        ),
        child: Row(children: [
          const Icon(Icons.search_rounded, size: 18, color: AdminColors.inkFaint),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              style: AdminText.body(),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search name, @username, email…',
                hintStyle: AdminText.small(AdminColors.inkFaint),
              ),
            ),
          ),
          if (_search.text.isNotEmpty)
            GestureDetector(
              onTap: () => _search.clear(),
              child: const Icon(Icons.close_rounded, size: 17, color: AdminColors.inkFaint),
            ),
        ]),
      );

  // ── division distribution ───────────────────────────────────────────────
  Widget _distribution() {
    const tiers = ['elite', 'gold', 'silver', 'bronze'];
    final counts = {for (final t in tiers) t: 0};
    for (final p in _all) {
      if (_isUnranked(p)) continue; // unranked players have no division yet
      counts[_tierForRating(_ratingOf(p))] = counts[_tierForRating(_ratingOf(p))]! + 1;
    }
    final ranked = counts.values.fold<int>(0, (a, b) => a + b);
    final unranked = _all.length - ranked;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AdminColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AdminColors.lineSoft),
        boxShadow: AdminColors.cardShadow,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Division distribution', style: AdminText.sans(13.5, FontWeight.w800, AdminColors.ink)),
        Text(
            '$ranked ranked across 4 divisions'
            '${unranked > 0 ? ' · $unranked unranked' : ''}',
            style: AdminText.small(AdminColors.inkFaint)),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (final t in tiers)
                if (counts[t]! > 0)
                  Expanded(
                    flex: counts[t]!,
                    child: Container(
                      margin: const EdgeInsets.only(right: 2),
                      color: AdminColors.tier(t),
                    ),
                  ),
              if (ranked == 0) Expanded(child: Container(color: AdminColors.surface3)),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final t in tiers)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _divTile(t, counts[t]!),
                ),
              ),
          ],
        ),
      ]),
    );
  }

  Widget _divTile(String tier, int count) {
    final letter = _divLetter(tier);
    final on = _filter == letter;
    final c = AdminColors.tier(tier);
    return GestureDetector(
      onTap: () => setState(() => _filter = on ? 'all' : letter),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: on ? AdminColors.wash(c, 0.10) : AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? c : AdminColors.lineSoft, width: on ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text('DIV $letter', style: AdminText.sans(10, FontWeight.w800, AdminColors.inkFaint)),
          ]),
          const SizedBox(height: 3),
          Text('$count', style: AdminText.mono(16, FontWeight.w800, AdminColors.ink)),
          Text(_metalName(tier), style: AdminText.sans(10.5, FontWeight.w600, AdminColors.inkFaint)),
        ]),
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
            border: Border.all(color: on ? AdminColors.ink : AdminColors.line),
          ),
          child: Text(label,
              style: AdminText.sans(12.5, on ? FontWeight.w700 : FontWeight.w600,
                  on ? AdminColors.surface : AdminColors.inkSoft)),
        ),
      );

  Widget _seg(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: on ? AdminColors.surface : AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: on ? AdminColors.line : Colors.transparent),
          ),
          child: Text(label,
              style: AdminText.sans(12, on ? FontWeight.w800 : FontWeight.w600,
                  on ? AdminColors.ink : AdminColors.inkSoft)),
        ),
      );

  // ── profile sheet ───────────────────────────────────────────────────────
  void _openPlayer(Map<String, dynamic> p) {
    final name = p['name'] as String? ?? 'Unknown';
    final rating = _ratingOf(p);
    final unranked = _isUnranked(p);
    final tier = _tierForRating(rating);
    final tierColor = unranked ? AdminColors.inkFaint : AdminColors.tier(tier);
    final statusKey = _statusKey(p);
    final phone = p['phone'] as String?;
    final email = p['email'] as String?;
    final city = p['city'] as String?;
    final id = p['id'] as String;
    final rank = (p['rank'] as num?)?.toInt();
    final played = (p['played'] as num?)?.toInt() ?? 0;
    final wr = _winRate(p);
    final reliability = (p['reliability'] as num?)?.round() ??
        (p['sigma'] is num ? ((1 - (p['sigma'] as num)) * 100).round() : null);

    adminSheet(
      context,
      title: name,
      sub: '${_handle(p)} · joined ${_monthYear(_at(p, 'joined'))}',
      heightFactor: 0.74,
      footer: Row(children: [
        Expanded(
          child: AdminButton('Edit ranking',
              icon: Icons.edit_outlined,
              height: 48,
              onPressed: () {
                Navigator.pop(context);
                _editRanking(p);
              }),
        ),
        const SizedBox(width: 10),
        if (statusKey == 'banned')
          Expanded(
            child: AdminButton('Unban',
                height: 48,
                variant: AdminBtn.ghost,
                onPressed: () async {
                  Navigator.pop(context);
                  await _setStatus(id, 'active');
                  if (mounted) adminToast(context, '$name reinstated');
                }),
          )
        else
          Expanded(
            child: AdminButton('Ban',
                icon: Icons.lock_outline_rounded,
                height: 48,
                variant: AdminBtn.danger,
                onPressed: () async {
                  Navigator.pop(context);
                  await _setStatus(id, 'banned');
                  if (mounted) adminToast(context, '$name banned');
                }),
          ),
      ]),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AdminAvatar(_initials(name), size: 60, color: tierColor,
              imageUrl: p['avatar_url'] as String?),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              StatusBadge(statusKey, dot: true),
              const SizedBox(height: 6),
              if (email != null) _contactRow(Icons.mail_outline_rounded, email),
              if (phone != null) _contactRow(Icons.phone_outlined, phone),
              if (city != null) _contactRow(Icons.place_outlined, city),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          _statBox('Rank', unranked || rank == null ? '—' : '#$rank'),
          const SizedBox(width: 10),
          _statBox('Level', unranked ? '—' : rating.toStringAsFixed(2)),
          const SizedBox(width: 10),
          _statBox('Win rate', wr == null ? '—' : '$wr%'),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _statBox('Division', unranked ? '—' : 'Div ${_divLetter(tier)}'),
          const SizedBox(width: 10),
          _statBox('Reliability', reliability == null ? '—' : '$reliability%'),
          const SizedBox(width: 10),
          _statBox('Played', '$played'),
        ]),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Container(width: 11, height: 11,
                decoration: BoxDecoration(color: tierColor, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Current division', style: AdminText.kicker()),
                const SizedBox(height: 4),
                Text(
                    unranked
                        ? 'Unranked · no division yet'
                        : '${_metalName(tier)} · Division ${_divLetter(tier)}',
                    style: AdminText.sans(15, FontWeight.w800, AdminColors.ink)),
              ]),
            ),
            Text(
                unranked
                    ? 'Unranked'
                    : (_isProvisional(p) ? 'Provisional' : 'Ranked'),
                style: AdminText.sans(12.5, FontWeight.w800,
                    unranked
                        ? AdminColors.inkFaint
                        : (_isProvisional(p) ? AdminColors.warn : AdminColors.success))),
          ]),
        ),
      ]),
    );
  }

  Widget _contactRow(IconData ic, String text) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(children: [
          Icon(ic, size: 14, color: AdminColors.inkFaint),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                style: AdminText.small(), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ]),
      );

  Widget _statBox(String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(11)),
          child: Column(children: [
            Text(label.toUpperCase(), style: AdminText.kicker()),
            const SizedBox(height: 5),
            Text(value,
                style: AdminText.sans(15, FontWeight.w800, AdminColors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ]),
        ),
      );

  // ── edit ranking (rating engine v2 — server-side write) ─────────────────
  void _editRanking(Map<String, dynamic> p) {
    final id = p['id'] as String;
    final name = p['name'] as String? ?? 'Player';
    final curRating = _ratingOf(p);
    double rating = ((curRating / 0.25).round() * 0.25).clamp(0.0, 7.0).toDouble();
    bool anchor = p['is_anchor'] == true;

    final levels = [for (var i = 0; i <= 28; i++) i * 0.25];
    final wheelCtrl = FixedExtentScrollController(
        initialItem: (rating / 0.25).round().clamp(0, levels.length - 1));

    adminSheet(
      context,
      title: 'Set player rating',
      sub: name,
      heightFactor: 0.72,
      footer: AdminButton(
        'Apply',
        full: true,
        height: 50,
        icon: Icons.check_rounded,
        onPressed: () async {
          final sigma = anchor ? 0.30 : 0.50;
          Navigator.pop(context);
          final err = await AdminService.setRating(id,
              rating: rating, sigma: sigma, isAnchor: anchor);
          if (!mounted) return;
          if (err != null) {
            adminToast(context, err, ok: false);
            return;
          }
          final tier = _tierForRating(rating);
          final idx = _all.indexWhere((x) => x['id'] == id);
          if (idx != -1) {
            setState(() {
              _all[idx] = {
                ..._all[idx],
                'rating': rating,
                'level': rating,
                'tier': tier,
                'sigma': sigma,
                'reliability': ((1 - sigma) * 100).round(),
                'is_anchor': anchor,
                'is_provisional': false,
                'competitive_matches': 10,
              };
              _all.sort((a, b) => _ratingOf(b).compareTo(_ratingOf(a)));
            });
          }
          adminToast(context,
              '$name set to Lv ${rating.toStringAsFixed(2)}${anchor ? ' · Anchor' : ''}');
        },
      ),
      body: StatefulBuilder(builder: (c, setSheet) {
        final tier = _tierForRating(rating);
        final sigma = anchor ? 0.30 : 0.50;
        final reliability = ((1 - sigma) * 100).round();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Rating', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 7),
          // Inline scroll wheel — fits inside the sheet (no full-screen dropdown
          // overlay that overflowed the screen).
          Container(
            height: 150,
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: AdminUI.fieldR,
                border: Border.all(color: AdminColors.line)),
            clipBehavior: Clip.antiAlias,
            child: CupertinoPicker(
              scrollController: wheelCtrl,
              itemExtent: 36,
              squeeze: 1.15,
              diameterRatio: 1.5,
              selectionOverlay: Container(
                decoration: const BoxDecoration(
                  border: Border.symmetric(
                      horizontal: BorderSide(color: AdminColors.line)),
                ),
              ),
              onSelectedItemChanged: (i) => setSheet(() => rating = levels[i]),
              children: [
                for (final l in levels)
                  Center(
                    child: Text(
                        'Lv ${l.toStringAsFixed(2)}  ·  Division ${_divLetter(_tierForRating(l))}',
                        style: AdminText.body()),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Container(width: 9, height: 9,
                  decoration: BoxDecoration(color: AdminColors.tier(tier), shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    'Lv ${rating.toStringAsFixed(2)} · Division ${_divLetter(tier)} · σ ${sigma.toStringAsFixed(2)} ($reliability% reliable)',
                    style: AdminText.sans(13.5, FontWeight.w800, AdminColors.ink)),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Anchor player',
                    style: AdminText.sans(14, FontWeight.w800, AdminColors.ink)),
                const SizedBox(height: 2),
                Text(
                    'Hand-calibrated reference — barely moves in matches (σ 0.30). '
                    'Off = leveling session (σ 0.50), self-tunes from play.',
                    style: AdminText.small(AdminColors.inkFaint)),
              ]),
            ),
            const SizedBox(width: 10),
            Switch.adaptive(value: anchor, onChanged: (v) => setSheet(() => anchor = v)),
          ]),
          const SizedBox(height: 12),
          Text(
              'Sets the rating server-side and marks the player established '
              '(non-provisional). Logged to the audit trail.',
              style: AdminText.small(AdminColors.inkFaint)),
        ]);
      }),
    );
  }

  Future<void> _setStatus(String id, String status) async {
    try {
      await AdminService.setPlayerStatus(id, status);
      final idx = _all.indexWhere((x) => x['id'] == id);
      if (idx != -1 && mounted) {
        setState(() => _all[idx] = {..._all[idx], 'status': status});
      }
    } catch (e) {
      if (mounted) adminToast(context, 'Update failed', ok: false);
    }
  }
}

// ── player row card ─────────────────────────────────────────────────────────
class _PlayerCard extends StatelessWidget {
  final Map<String, dynamic> p;
  final VoidCallback onTap;
  const _PlayerCard(this.p, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = p['name'] as String? ?? 'Unknown';
    final rating = _AdminPlayersScreenState._ratingOf(p);
    final unranked = _AdminPlayersScreenState._isUnranked(p);
    final tier = _AdminPlayersScreenState._tierForRating(rating);
    final statusKey = _AdminPlayersScreenState._statusKey(p);
    final c = unranked ? AdminColors.inkFaint : AdminColors.tier(tier);
    final rank = (p['rank'] as num?)?.toInt();
    final played = (p['played'] as num?)?.toInt() ?? 0;
    final wins = (p['wins'] as num?)?.toInt() ?? 0;
    final losses = (p['losses'] as num?)?.toInt() ?? (played - wins);
    final wr = _AdminPlayersScreenState._winRate(p);
    final accent = statusKey == 'banned'
        ? AdminColors.danger
        : (statusKey == 'provisional' || statusKey == 'flagged' ? AdminColors.warn : null);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AdminColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AdminColors.lineSoft),
              boxShadow: AdminColors.cardShadow,
            ),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (accent != null)
                  Container(width: 3,
                      decoration: BoxDecoration(
                          color: accent,
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)))),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(13),
                    child: Column(children: [
                      Row(children: [
                        SizedBox(
                          width: 22,
                          child: Text(rank == null ? '' : '$rank',
                              textAlign: TextAlign.right,
                              style: AdminText.mono(12, FontWeight.w500, AdminColors.inkFaint)),
                        ),
                        const SizedBox(width: 12),
                        AdminAvatar(_AdminPlayersScreenState._initials(name), size: 40, color: c,
                            imageUrl: p['avatar_url'] as String?),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AdminText.sans(14, FontWeight.w800, AdminColors.ink)),
                            const SizedBox(height: 3),
                            Row(children: [
                              Flexible(
                                child: Text(_AdminPlayersScreenState._handle(p),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AdminText.mono(11.5, FontWeight.w500, AdminColors.inkSoft)),
                              ),
                              const SizedBox(width: 8),
                              Text('·', style: AdminText.small(AdminColors.inkFaint)),
                              const SizedBox(width: 8),
                              Container(width: 7, height: 7,
                                  decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                              const SizedBox(width: 5),
                              Text(
                                  unranked
                                      ? 'Unranked'
                                      : 'Div ${_AdminPlayersScreenState._divLetter(tier)}',
                                  style: AdminText.sans(11.5, FontWeight.w700, AdminColors.inkSoft)),
                            ]),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          if (unranked)
                            Text('—',
                                style: AdminText.mono(14, FontWeight.w800, AdminColors.inkFaint))
                          else
                            Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic, children: [
                              Text('Lv ', style: AdminText.sans(9.5, FontWeight.w700, AdminColors.inkFaint)),
                              Text(rating.toStringAsFixed(2),
                                  style: AdminText.mono(14, FontWeight.w800, AdminColors.ink)),
                            ]),
                          const SizedBox(height: 4),
                          StatusBadge(statusKey, dot: true),
                          const SizedBox(height: 3),
                          Text(_AdminPlayersScreenState._rel(
                                  _AdminPlayersScreenState._at(p, 'last_sign_in_at')),
                              style: AdminText.mono(10.5, FontWeight.w500, AdminColors.inkFaint)),
                        ]),
                      ]),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 11),
                        child: Divider(height: 1, color: AdminColors.lineSoft),
                      ),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text('$played played', style: AdminText.small()),
                        Text('$wins W · $losses L', style: AdminText.small()),
                        Text('Win ${wr == null ? '—' : '$wr%'}',
                            style: AdminText.sans(12, FontWeight.w800, AdminColors.ink)),
                      ]),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
