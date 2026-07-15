import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

class AdminMatchesScreen extends StatefulWidget {
  const AdminMatchesScreen({super.key});
  @override
  State<AdminMatchesScreen> createState() => _AdminMatchesScreenState();
}

class _AdminMatchesScreenState extends State<AdminMatchesScreen> {
  List<Map<String, dynamic>> _matches = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AdminService.fetchMatches();
      if (mounted) setState(() { _matches = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  static Color _statusColor(String? s) {
    switch (s) {
      case 'open': return AdminColors.success;
      case 'full': return AdminColors.warn;
      case 'completed': return AdminColors.inkSoft;
      case 'cancelled': return AdminColors.danger;
      default: return AdminColors.inkSoft;
    }
  }

  static String _statusLabel(String? s) {
    switch (s) {
      case 'open': return 'Open';
      case 'full': return 'Full';
      case 'completed': return 'Completed';
      case 'cancelled': return 'Cancelled';
      default: return s ?? 'Unknown';
    }
  }

  static String _fmtDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.day}  ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }
    if (_error != null) {
      return RefreshIndicator(
        color: AdminColors.primary,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
          children: [
            _emptyState('No matches yet',
                'Pull down to refresh or tap retry.'),
            const SizedBox(height: 16),
            Center(child: AdminButton('Retry', onPressed: _load)),
          ],
        ),
      );
    }

    final open = _matches.where((m) => m['status'] == 'open').length;
    final completed = _matches.where((m) => m['status'] == 'completed').length;
    final faulty = _matches.where(_isFaulty).length;

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(icon: Icons.sports_tennis_rounded, tone: AdminColors.primary, label: 'Total matches', value: '${_matches.length}'),
            StatCard(icon: Icons.lock_open_outlined, tone: AdminColors.success, label: 'Open', value: '$open'),
            StatCard(icon: Icons.check_circle_outline_rounded, tone: AdminColors.inkSoft, label: 'Completed', value: '$completed'),
            StatCard(icon: Icons.report_gmailerrorred_outlined, tone: AdminColors.danger, label: 'Faulty', value: '$faulty'),
          ]),
          const SizedBox(height: 16),
          AdminSection('Match history', sub: '${_matches.length} matches'),
          if (_matches.isEmpty)
            _emptyState('No matches yet', 'Matches will appear here once players start booking courts.')
          else
            for (final m in _matches) _card(m),
        ],
      ),
    );
  }

  static bool _isFaulty(Map<String, dynamic> m) =>
      ((m['players'] as num?)?.toInt() ?? 0) == 0;

  Widget _card(Map<String, dynamic> m) {
    final status = m['status'] as String?;
    final format = m['match_type'] as String? ?? 'casual';
    final scheduled = _fmtDate(m['scheduled_at'] as String?);
    final creator = m['creator_name'] as String?;
    final players = (m['players'] as num?)?.toInt() ?? 0;
    final faulty = players == 0;
    final statusColor = _statusColor(status);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AdminColors.wash(faulty ? AdminColors.danger : statusColor, 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(faulty ? Icons.report_gmailerrorred_outlined : Icons.sports_tennis_rounded,
                size: 20, color: faulty ? AdminColors.danger : statusColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(
                    format[0].toUpperCase() + format.substring(1),
                    style: AdminText.strong(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (faulty)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AdminColors.wash(AdminColors.danger, 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('Faulty · no players',
                        style: AdminText.sans(10.5, FontWeight.w800, AdminColors.danger)),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AdminColors.wash(statusColor, 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(_statusLabel(status),
                      style: AdminText.sans(11, FontWeight.w700, statusColor)),
                ),
              ]),
              const SizedBox(height: 3),
              Text(scheduled, style: AdminText.small()),
              const SizedBox(height: 2),
              Row(children: [
                Text('$players/4 players',
                    style: AdminText.mono(10.5, FontWeight.w500, AdminColors.inkFaint)),
                if (creator != null) ...[
                  Text('  ·  ', style: AdminText.small()),
                  Flexible(
                    child: Text(creator,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AdminText.small()),
                  ),
                ],
              ]),
            ]),
          ),
          if (status != 'cancelled') ...[
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, color: AdminColors.danger),
              tooltip: 'Remove match',
              onPressed: () => _remove(m),
            ),
          ],
        ]),
      ),
    );
  }

  Future<void> _remove(Map<String, dynamic> m) async {
    final id = m['id'] as String?;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Remove match?', style: AdminText.h2()),
        content: Text(
            'This hides it from players and marks it cancelled. The record is kept '
            'in the database — nothing is permanently deleted.',
            style: AdminText.small()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: AdminText.strong())),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Remove',
                  style: AdminText.sans(13.5, FontWeight.w800, AdminColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    final err = await AdminService.removeMatch(id);
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err);
      return;
    }
    // Keep it in the list, now shown as cancelled.
    setState(() => m['status'] = 'cancelled');
  }

  Widget _emptyState(String title, String sub) => Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56, height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.sports_tennis_rounded, size: 26, color: AdminColors.inkFaint),
          ),
          const SizedBox(height: 14),
          Text(title, style: AdminText.h2()),
          const SizedBox(height: 6),
          Text(sub, textAlign: TextAlign.center, style: AdminText.small()),
        ]),
      );
}
