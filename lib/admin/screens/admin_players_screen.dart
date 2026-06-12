import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AdminService.fetchPlayers();
      if (mounted) setState(() { _all = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<Map<String, dynamic>> get _rows {
    return _all.where((p) {
      final s = p['status'] as String? ?? 'active';
      final v = p['verified'] as bool? ?? false;
      if (_filter == 'flagged') return s == 'flagged';
      if (_filter == 'banned') return s == 'banned';
      if (_filter == 'unverified') return !v && s == 'active';
      if (['A', 'B', 'C', 'D'].contains(_filter)) {
        return _divLetter(p['tier'] as String? ?? 'bronze') == _filter;
      }
      return true;
    }).toList();
  }

  static String _divLetter(String tier) {
    switch (tier) {
      case 'elite': return 'A';
      case 'gold': return 'B';
      case 'silver': return 'C';
      default: return 'D';
    }
  }

  static String _divLabel(String tier) => 'Division ${_divLetter(tier)}';

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  static String _statusKey(Map<String, dynamic> p) {
    final s = p['status'] as String? ?? 'active';
    if (s != 'active') return s;
    final v = p['verified'] as bool? ?? false;
    return v ? 'active' : 'unverified';
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

    final flagged = _all.where((p) => (p['status'] as String?) == 'flagged').length;
    final banned = _all.where((p) => (p['status'] as String?) == 'banned').length;

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(icon: Icons.groups_outlined, tone: AdminColors.green, label: 'Total players', value: '${_all.length}'),
            StatCard(icon: Icons.how_to_reg_outlined, tone: AdminColors.primary, label: 'Verified', value: '${_all.where((p) => (p['verified'] as bool?) ?? false).length}'),
            StatCard(icon: Icons.flag_outlined, tone: AdminColors.info, label: 'Flagged', value: '$flagged'),
            StatCard(icon: Icons.lock_outline_rounded, tone: AdminColors.danger, label: 'Banned', value: '$banned'),
          ]),
          const SizedBox(height: 16),
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
                  ['flagged', 'Flagged'],
                  ['unverified', 'Unverified'],
                  ['banned', 'Banned'],
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _chip(f[1], _filter == f[0], () => setState(() => _filter = f[0])),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Center(
                child: Text('No players match this filter', style: AdminText.small()),
              ),
            )
          else
            for (int i = 0; i < _rows.length; i++) _row(i + 1, _rows[i]),
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
            border: Border.all(color: on ? AdminColors.ink : AdminColors.line),
          ),
          child: Text(label,
              style: AdminText.sans(12.5, on ? FontWeight.w700 : FontWeight.w600,
                  on ? AdminColors.surface : AdminColors.inkSoft)),
        ),
      );

  Widget _row(int rank, Map<String, dynamic> p) {
    final name = p['name'] as String? ?? 'Unknown';
    final tier = p['tier'] as String? ?? 'bronze';
    final elo = (p['elo'] as num?)?.toInt() ?? 1000;
    final statusKey = _statusKey(p);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        onTap: () => _openPlayer(p),
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Text('$rank',
              style: AdminText.mono(12, FontWeight.w500, AdminColors.inkFaint)),
          const SizedBox(width: 12),
          AdminAvatar(_initials(name),
              size: 38, color: AdminColors.tier(tier)),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  style: AdminText.strong(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Row(children: [
                Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: AdminColors.tier(tier),
                        shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Text(_divLabel(tier), style: AdminText.small()),
                if (p['city'] != null) ...[
                  Text('  ·  ', style: AdminText.small()),
                  Text(p['city'] as String,
                      style: AdminText.small(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ]),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('$elo',
                style: AdminText.sans(16, FontWeight.w800, AdminColors.ink)),
            const SizedBox(height: 4),
            StatusBadge(statusKey, dot: true),
          ]),
        ]),
      ),
    );
  }

  void _openPlayer(Map<String, dynamic> p) {
    final name = p['name'] as String? ?? 'Unknown';
    final tier = p['tier'] as String? ?? 'bronze';
    final elo = (p['elo'] as num?)?.toInt() ?? 1000;
    final statusKey = _statusKey(p);
    final phone = p['phone'] as String?;
    final city = p['city'] as String?;
    final id = p['id'] as String;

    adminSheet(
      context,
      title: name,
      sub: id.substring(0, 8),
      heightFactor: 0.7,
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
          AdminAvatar(_initials(name), size: 60, color: AdminColors.tier(tier)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              StatusBadge(statusKey, dot: true),
              const SizedBox(height: 6),
              if (phone != null)
                Text(phone, style: AdminText.small()),
              if (city != null)
                Text(city, style: AdminText.small()),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          _statBox('ELO', '$elo'),
          const SizedBox(width: 10),
          _statBox('Division', _divLabel(tier)),
          const SizedBox(width: 10),
          _statBox('Verified', (p['verified'] as bool? ?? false) ? 'Yes' : 'No'),
        ]),
      ]),
    );
  }

  Widget _statBox(String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11)),
          child: Column(children: [
            Text(label.toUpperCase(), style: AdminText.kicker()),
            const SizedBox(height: 5),
            Text(value,
                style: AdminText.sans(14, FontWeight.w800, AdminColors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ]),
        ),
      );

  void _editRanking(Map<String, dynamic> p) {
    final id = p['id'] as String;
    final name = p['name'] as String? ?? 'Player';
    final eloC = TextEditingController(
        text: '${(p['elo'] as num?)?.toInt() ?? 1000}');
    String tier = p['tier'] as String? ?? 'bronze';

    const tiers = ['bronze', 'silver', 'gold', 'elite'];
    const tierLabels = {
      'bronze': 'Division D',
      'silver': 'Division C',
      'gold': 'Division B',
      'elite': 'Division A',
    };

    adminSheet(
      context,
      title: 'Adjust ranking',
      sub: name,
      heightFactor: 0.58,
      footer: AdminButton(
        'Apply',
        full: true,
        height: 50,
        icon: Icons.check_rounded,
        onPressed: () async {
          final newElo = int.tryParse(eloC.text) ?? (p['elo'] as num?)?.toInt() ?? 1000;
          Navigator.pop(context);
          try {
            await AdminService.setPlayerEloTier(id, newElo, tier);
            final idx = _all.indexWhere((x) => x['id'] == id);
            if (idx != -1 && mounted) {
              setState(() {
                _all[idx] = {..._all[idx], 'elo': newElo, 'tier': tier};
                _all.sort((a, b) => ((b['elo'] as num?)?.toInt() ?? 0)
                    .compareTo((a['elo'] as num?)?.toInt() ?? 0));
              });
            }
            if (mounted) adminToast(context, '$name ranking updated');
          } catch (e) {
            if (mounted) adminToast(context, 'Save failed — check connection', ok: false);
          }
        },
      ),
      body: StatefulBuilder(builder: (c, setSheet) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ELO rating', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 7),
          TextField(
            controller: eloC,
            keyboardType: TextInputType.number,
            style: AdminText.body(),
            decoration: InputDecoration(
              filled: true,
              fillColor: AdminColors.surfaceAlt,
              isDense: true,
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
          const SizedBox(height: 16),
          Text('Division / tier', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in tiers)
                GestureDetector(
                  onTap: () => setSheet(() => tier = t),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 9),
                    decoration: BoxDecoration(
                      color: tier == t
                          ? AdminColors.ink
                          : AdminColors.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: tier == t
                              ? AdminColors.ink
                              : AdminColors.line),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: AdminColors.tier(t),
                              shape: BoxShape.circle)),
                      const SizedBox(width: 7),
                      Text(tierLabels[t]!,
                          style: AdminText.sans(
                              12.5,
                              FontWeight.w700,
                              tier == t
                                  ? AdminColors.surface
                                  : AdminColors.inkSoft)),
                    ]),
                  ),
                ),
            ],
          ),
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
