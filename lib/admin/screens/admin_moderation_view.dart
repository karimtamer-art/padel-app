import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';

/// The moderation queue — player reports on messages, comments and people
/// (App Store Guideline 1.2). Lifted out of the Requests console so it lives
/// under Reports with the rest of the reporting; the server guard is unchanged
/// (`_can_edit('requests')`), so whoever could action a report before still can.
///
/// Self-contained: it loads its own queue and refreshes after every decision.
class AdminModerationView extends StatefulWidget {
  const AdminModerationView({super.key});
  @override
  State<AdminModerationView> createState() => _AdminModerationViewState();
}

class _AdminModerationViewState extends State<AdminModerationView> {
  List<Map<String, dynamic>> _reports = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    List<Map<String, dynamic>> rows = const [];
    try {
      rows = await AdminService.fetchReports();
    } catch (e) {
      // A database without the block-and-report delta must not take the tab
      // down — an empty queue reads the same as "nothing reported yet".
      debugPrint('[AdminModeration] load: $e');
    }
    if (!mounted) return;
    setState(() {
      _reports = rows;
      _loading = false;
    });
  }

  static const _reasonLabels = {
    'harassment': 'Harassment or bullying',
    'hate': 'Hate speech',
    'sexual': 'Sexual or explicit content',
    'violence': 'Violence or threats',
    'spam': 'Spam or a scam',
    'impersonation': 'Impersonation',
    'other': 'Something else',
  };

  static const _targetLabels = {
    'dm_message': 'Direct message',
    'ticket_message': 'Match ticket message',
    'community_message': 'Community chat',
    'announcement_comment': 'Comment',
    'user': 'Player',
  };

  static String _priorLine(int n) =>
      '$n other report${n == 1 ? '' : 's'} against this player';

  static String _fmtDate(String? iso) {
    if (iso == null) return '';
    try {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      final dt = DateTime.parse(iso).toLocal();
      return '${months[dt.month - 1]} ${dt.day}';
    } catch (_) {
      return '';
    }
  }

  static String _shortId(String? id) {
    if (id == null) return '—';
    return id.length > 8 ? id.substring(0, 8).toUpperCase() : id.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AdminColors.primary));
    }
    final open = _reports.where((r) => r['status'] == 'open').toList();
    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          const AdminSection('Moderation',
              sub: 'What players reported — messages, comments and people'),
          KpiGrid([
            StatCard(
                icon: Icons.flag_outlined,
                tone: AdminColors.danger,
                label: 'Open reports',
                value: '${open.length}'),
            StatCard(
                icon: Icons.gavel_rounded,
                tone: AdminColors.green,
                label: 'Actioned',
                value:
                    '${_reports.where((r) => r['status'] == 'actioned').length}'),
            StatCard(
                icon: Icons.do_not_disturb_on_outlined,
                tone: AdminColors.inkFaint,
                label: 'Dismissed',
                value:
                    '${_reports.where((r) => r['status'] == 'dismissed').length}'),
          ]),
          const SizedBox(height: 10),
          // Apple expects reports to be dealt with promptly; say so where the
          // work actually happens.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(11)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.schedule_rounded,
                  size: 15, color: AdminColors.inkFaint),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                    'Review reports within 24 hours. Acting on one can delete '
                    'the message; banning a player is done from Players.',
                    style: AdminText.small(AdminColors.inkFaint)),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          if (_reports.isEmpty)
            Container(
              padding: const EdgeInsets.all(28),
              alignment: Alignment.center,
              child: Text('Nothing reported yet',
                  style: AdminText.small(AdminColors.inkFaint)),
            )
          else
            for (final r in _reports)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AdminCard(
                  onTap: () => _openReport(r),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(
                                _reasonLabels[r['reason']] ??
                                    (r['reason'] as String? ?? '—'),
                                style: AdminText.strong(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                          StatusBadge(r['status'] as String? ?? 'open',
                              dot: true),
                        ]),
                        const SizedBox(height: 3),
                        Text(
                            '${_targetLabels[r['target_type']] ?? r['target_type']}'
                            ' · ${(r['target_user_name'] as String?) ?? 'Player'}'
                            ' · ${_fmtDate(r['created_at'] as String?)}',
                            style: AdminText.small()),
                        if ((r['content_excerpt'] as String?)?.isNotEmpty ??
                            false) ...[
                          const SizedBox(height: 7),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                                color: AdminColors.surfaceAlt,
                                borderRadius: BorderRadius.circular(9)),
                            child: Text('"${r['content_excerpt']}"',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AdminText.small(AdminColors.inkSoft)),
                          ),
                        ],
                        // Repeat offenders are the ones worth banning.
                        if (((r['prior_reports'] as int?) ?? 0) > 0) ...[
                          const SizedBox(height: 7),
                          Row(children: [
                            const Icon(Icons.warning_amber_rounded,
                                size: 13, color: AdminColors.warn),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(_priorLine(r['prior_reports'] as int),
                                  style: AdminText.small(AdminColors.warn)),
                            ),
                          ]),
                        ],
                      ]),
                ),
              ),
        ],
      ),
    );
  }

  void _openReport(Map<String, dynamic> r) {
    final id = r['id'] as String;
    final status = r['status'] as String? ?? 'open';
    final noteC = TextEditingController();
    final canDelete = r['target_id'] != null && r['target_type'] != 'user';

    Future<void> resolve(String newStatus, {bool delete = false}) async {
      Navigator.pop(context);
      final err = await AdminService.resolveReport(id,
          status: newStatus, note: noteC.text, delete: delete);
      await _load();
      if (mounted) {
        adminToast(
            context,
            err ??
                (newStatus == 'actioned'
                    ? (delete
                        ? 'Content removed — report closed'
                        : 'Report actioned')
                    : 'Report dismissed'),
            ok: err == null);
      }
    }

    adminSheet(
      context,
      title: _reasonLabels[r['reason']] ?? 'Report',
      sub: '${_targetLabels[r['target_type']] ?? r['target_type']}'
          ' · ${_shortId(id)}',
      heightFactor: 0.8,
      footer: status != 'open'
          ? null
          : Column(mainAxisSize: MainAxisSize.min, children: [
              if (canDelete) ...[
                AdminButton('Remove content',
                    full: true,
                    height: 50,
                    variant: AdminBtn.danger,
                    icon: Icons.delete_outline_rounded,
                    onPressed: () => resolve('actioned', delete: true)),
                const SizedBox(height: 8),
              ],
              AdminButton('Mark actioned',
                  full: true,
                  height: 46,
                  variant: AdminBtn.success,
                  onPressed: () => resolve('actioned')),
              const SizedBox(height: 8),
              AdminButton('Dismiss',
                  full: true,
                  height: 44,
                  variant: AdminBtn.ghost,
                  onPressed: () => resolve('dismissed')),
            ]),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _kv('Reported by', (r['reporter_name'] as String?) ?? 'Player'),
          const SizedBox(width: 10),
          _kv('About', (r['target_user_name'] as String?) ?? 'Player'),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _kv('Account', (r['target_user_status'] as String?) ?? '—'),
          const SizedBox(width: 10),
          _kv('Prior reports', '${(r['prior_reports'] as int?) ?? 0}'),
        ]),
        const SizedBox(height: 14),
        Text('REPORTED CONTENT', style: AdminText.kicker()),
        const SizedBox(height: 7),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11)),
          child: Text(
              ((r['content_excerpt'] as String?)?.isNotEmpty ?? false)
                  ? '"${r['content_excerpt']}"'
                  : 'No message attached — this is a report about the player.',
              style: AdminText.body().copyWith(height: 1.5)),
        ),
        if ((r['note'] as String?)?.isNotEmpty ?? false) ...[
          const SizedBox(height: 14),
          Text('WHAT THE REPORTER SAID', style: AdminText.kicker()),
          const SizedBox(height: 7),
          Text(r['note'] as String,
              style: AdminText.body().copyWith(height: 1.5)),
        ],
        if (status == 'open') ...[
          const SizedBox(height: 14),
          Text('INTERNAL NOTE (OPTIONAL)', style: AdminText.kicker()),
          const SizedBox(height: 7),
          TextField(
            controller: noteC,
            maxLines: 2,
            style: AdminText.body(),
            decoration: InputDecoration(
              hintText: 'What did you decide, and why?',
              hintStyle: AdminText.small(AdminColors.inkFaint),
              isDense: true,
              filled: true,
              fillColor: AdminColors.surfaceAlt,
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
        ],
      ]),
    );
  }

  Widget _kv(String k, String v) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k.toUpperCase(), style: AdminText.kicker()),
            const SizedBox(height: 4),
            Text(v,
                style: AdminText.sans(13.5, FontWeight.w800, AdminColors.ink)),
          ]),
        ),
      );
}
