import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

class AdminDashboardScreen extends StatefulWidget {
  final void Function(String navId)? onNavigate;
  const AdminDashboardScreen({super.key, this.onNavigate});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  Map<String, int> _counts = {};
  Map<String, int> _divisions = {};
  List<int> _weeklyMatches = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    try {
      Map<String, int> counts = {};
      Map<String, int> divisions = {};
      List<int> weekly = [];
      await Future.wait([
        AdminService.fetchDashboardCounts().then((v) => counts = v),
        AdminService.fetchDivisionCounts().then((v) => divisions = v),
        AdminService.fetchWeeklyMatchCounts().then((v) => weekly = v),
      ]);
      if (!mounted) return;
      setState(() {
        _counts = counts;
        _divisions = divisions;
        _weeklyMatches = weekly;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(String key) => _loading ? '—' : '${_counts[key] ?? 0}';

  @override
  Widget build(BuildContext context) {
    const tierOrder = ['elite', 'gold', 'silver', 'bronze'];
    const tierLabels = {
      'elite': 'A · Elite',
      'gold': 'B · Gold',
      'silver': 'C · Silver',
      'bronze': 'D · Bronze',
    };
    const dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final hasMatchData = _weeklyMatches.any((n) => n > 0);
    final hasDivData = _divisions.values.any((n) => n > 0);

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(
                icon: Icons.groups_outlined,
                tone: AdminColors.green,
                label: 'Total players',
                value: _fmt('players')),
            StatCard(
                icon: Icons.sports_tennis_rounded,
                tone: AdminColors.primary,
                label: 'Total matches',
                value: _fmt('matches')),
            StatCard(
                icon: Icons.place_outlined,
                tone: AdminColors.info,
                label: 'Courts',
                value: _fmt('courts')),
            StatCard(
                icon: Icons.emoji_events_outlined,
                tone: AdminColors.warn,
                label: 'Tournaments',
                value: _fmt('tournaments')),
          ]),
          const SizedBox(height: 16),

          // Revenue — pending Paymob (Phase 6)
          AdminCard(
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AdminColors.wash(AdminColors.info, 0.12),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.payments_outlined,
                    size: 19, color: AdminColors.info),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Revenue', style: AdminText.cardTitle()),
                      const SizedBox(height: 2),
                      Text('Available once Paymob is wired',
                          style: AdminText.small()),
                    ]),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: AdminColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(999)),
                child: Text('Phase 6',
                    style: AdminText.sans(
                        11, FontWeight.w700, AdminColors.inkFaint)),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          // Matches by day — real data
          AdminCard(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Matches by day', style: AdminText.cardTitle()),
                  const SizedBox(height: 2),
                  Text('This week', style: AdminText.small()),
                  const SizedBox(height: 16),
                  if (!hasMatchData)
                    _noDataRow('No matches scheduled this week')
                  else
                    SizedBox(
                        height: 90,
                        child: _Bars(_weeklyMatches, dayLabels)),
                ]),
          ),
          const SizedBox(height: 16),

          // Division split — real data
          AdminCard(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Division split', style: AdminText.cardTitle()),
                  const SizedBox(height: 14),
                  if (!hasDivData)
                    _noDataRow('No players registered yet')
                  else
                    for (final tier in tierOrder)
                      if ((_divisions[tier] ?? 0) > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(children: [
                            Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                    color: AdminColors.tier(tier),
                                    shape: BoxShape.circle)),
                            const SizedBox(width: 9),
                            Text(tierLabels[tier]!,
                                style: AdminText.strong()),
                            const Spacer(),
                            Text('${_divisions[tier]}',
                                style: AdminText.mono(
                                    12,
                                    FontWeight.w700,
                                    AdminColors.inkSoft)),
                          ]),
                        ),
                ]),
          ),
          const SizedBox(height: 16),

          // Quick navigation
          AdminCard(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quick navigation', style: AdminText.cardTitle()),
                  const SizedBox(height: 12),
                  _attn(
                      context,
                      Icons.groups_outlined,
                      AdminColors.green,
                      '${_fmt('players')} players registered',
                      'View & manage profiles',
                      'players'),
                  _attn(
                      context,
                      Icons.sports_tennis_rounded,
                      AdminColors.primary,
                      '${_fmt('matches')} matches recorded',
                      'View match history',
                      'matches'),
                  _attn(
                      context,
                      Icons.emoji_events_outlined,
                      AdminColors.warn,
                      '${_fmt('tournaments')} tournaments',
                      'Manage brackets & entries',
                      'tournaments'),
                ]),
          ),
          const SizedBox(height: 16),

          // Activity feed — no log table yet
          AdminCard(
            padding: EdgeInsets.zero,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                    child: Text('Recent activity',
                        style: AdminText.cardTitle()),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 4, 16, 20),
                    child: _noDataRow(
                        'Activity log coming in a future update'),
                  ),
                ]),
          ),
        ],
      ),
    );
  }

  Widget _noDataRow(String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.inbox_outlined,
              size: 17, color: AdminColors.inkFaint),
          const SizedBox(width: 8),
          Text(label, style: AdminText.small(AdminColors.inkFaint)),
        ]),
      );

  Widget _attn(BuildContext context, IconData icon, Color tone, String title,
      String sub, String nav) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AdminColors.lineSoft)),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.wash(tone, 0.14),
                borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 17, color: tone),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AdminText.strong()),
                  Text(sub, style: AdminText.small()),
                ]),
          ),
          GestureDetector(
            onTap: () => widget.onNavigate?.call(nav),
            child: const Icon(Icons.chevron_right_rounded,
                color: AdminColors.inkFaint),
          ),
        ]),
      ),
    );
  }
}

class _Bars extends StatelessWidget {
  final List<int> data;
  final List<String> labels;
  const _Bars(this.data, this.labels);
  @override
  Widget build(BuildContext context) {
    final maxV = data.reduce((a, b) => a > b ? a : b);
    if (maxV == 0) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (int i = 0; i < data.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: (data[i] / maxV) * 64,
                      decoration: BoxDecoration(
                        color: data[i] == maxV
                            ? AdminColors.primary
                            : AdminColors.wash(AdminColors.green, 0.18),
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(4)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(labels[i],
                        style: AdminText.mono(
                            9, FontWeight.w500, AdminColors.inkFaint)),
                  ]),
            ),
          ),
      ],
    );
  }
}
