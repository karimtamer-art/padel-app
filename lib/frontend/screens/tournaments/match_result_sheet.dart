import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';

// Player-driven tournament match result: submit a winner (+ score), or confirm/
// dispute the other team's submission. The organizer never has to referee.

Future<void> showTournamentMatchResult(
  BuildContext context, {
  required Map<String, dynamic> match,
  required String? uid,
  VoidCallback? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _MatchResultSheet(match: match, uid: uid, onChanged: onChanged),
  );
}

class _MatchResultSheet extends StatefulWidget {
  final Map<String, dynamic> match;
  final String? uid;
  final VoidCallback? onChanged;
  const _MatchResultSheet({required this.match, required this.uid, this.onChanged});

  @override
  State<_MatchResultSheet> createState() => _MatchResultSheetState();
}

class _MatchResultSheetState extends State<_MatchResultSheet> {
  final _scoreCtrl = TextEditingController();
  String? _pick; // chosen winner entry id
  bool _busy = false;

  Map<String, dynamic>? get _e1 => widget.match['e1'] as Map<String, dynamic>?;
  Map<String, dynamic>? get _e2 => widget.match['e2'] as Map<String, dynamic>?;
  String get _matchId => widget.match['id'] as String;
  String? get _winner => widget.match['winner_entry'] as String?;
  String get _status => (widget.match['result_status'] as String?) ?? 'open';

  @override
  void initState() {
    super.initState();
    _scoreCtrl.text = (widget.match['submitted_score'] as String?) ??
        (widget.match['score'] as String?) ?? '';
  }

  @override
  void dispose() {
    _scoreCtrl.dispose();
    super.dispose();
  }

  bool _inEntry(Map<String, dynamic>? e, String? uid) =>
      e != null && uid != null && (e['player_id'] == uid || e['partner_id'] == uid);

  String? get _myTeam => _inEntry(_e1, widget.uid)
      ? 'a'
      : _inEntry(_e2, widget.uid)
          ? 'b'
          : null;

  String? get _subTeam {
    final by = widget.match['submitted_by'] as String?;
    return _inEntry(_e1, by) ? 'a' : (_inEntry(_e2, by) ? 'b' : null);
  }

  Map<String, dynamic>? _entryById(String? id) {
    if (id == null) return null;
    if (_e1?['id'] == id) return _e1;
    if (_e2?['id'] == id) return _e2;
    return null;
  }

  Future<void> _submit() async {
    if (_pick == null) {
      AppToast.show(context, 'Tap the winning pair first', kind: ToastKind.error);
      return;
    }
    setState(() => _busy = true);
    final err = await TournamentService.submitResult(_matchId, _pick!,
        score: _scoreCtrl.text.trim().isEmpty ? null : _scoreCtrl.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      AppToast.show(context, err, kind: ToastKind.error);
      return;
    }
    widget.onChanged?.call();
    Navigator.pop(context);
    AppToast.show(context, 'Result submitted — the other team confirms it.');
  }

  Future<void> _confirm(bool ok) async {
    setState(() => _busy = true);
    final err = await TournamentService.confirmResult(_matchId, ok);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      AppToast.show(context, err, kind: ToastKind.error);
      return;
    }
    widget.onChanged?.call();
    Navigator.pop(context);
    AppToast.show(context, ok ? 'Result confirmed' : 'Result disputed — please re-submit together.');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(4))),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Match result', style: AppText.cardTitle().copyWith(fontSize: 18)),
          ),
          const SizedBox(height: 14),
          ..._body(),
        ]),
      ),
    );
  }

  List<Widget> _body() {
    // Already decided (confirmed or organizer-set).
    if (_winner != null) {
      final w = _entryById(_winner);
      return [
        _resultBanner(AppColors.success, Icons.emoji_events_rounded, 'Final result',
            '${TournamentService.pairLabel(w)} won'
            '${(widget.match['score'] as String?)?.isNotEmpty == true ? ' · ${widget.match['score']}' : ''}'),
      ];
    }

    // Pending someone's confirmation.
    if (_status == 'pending') {
      final sub = _entryById(widget.match['submitted_winner'] as String?);
      final line = '${TournamentService.pairLabel(sub)} won'
          '${(widget.match['submitted_score'] as String?)?.isNotEmpty == true ? ' · ${widget.match['submitted_score']}' : ''}';
      if (_myTeam == null) {
        return [_resultBanner(AppColors.gold, Icons.schedule_rounded, 'Awaiting confirmation', line)];
      }
      if (_subTeam == _myTeam) {
        return [
          _resultBanner(AppColors.gold, Icons.schedule_rounded, 'Waiting on the other team',
              'You submitted: $line'),
        ];
      }
      // I'm the other team — confirm or dispute.
      return [
        _resultBanner(AppColors.gold, Icons.help_outline_rounded, 'Confirm this result?', line),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: AppButton('Dispute', full: true, height: 50, variant: AppBtnVariant.ghost,
                onPressed: _busy ? null : () => _confirm(false)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AppButton(_busy ? '…' : 'Confirm', full: true, height: 50,
                icon: Icons.check_rounded, onPressed: _busy ? null : () => _confirm(true)),
          ),
        ]),
      ];
    }

    // Open or disputed — a participant enters the result.
    if (_myTeam == null) {
      return [
        _resultBanner(AppColors.inkFaint, Icons.info_outline_rounded, 'Result pending',
            'Only players in this match can enter the result.'),
      ];
    }
    return [
      if (_status == 'disputed')
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _resultBanner(AppColors.danger, Icons.info_outline_rounded, 'Result disputed',
              'The last result was rejected. Agree on the score and submit again.'),
        ),
      Align(alignment: Alignment.centerLeft, child: Text('Who won?', style: AppText.small(AppColors.inkSoft))),
      const SizedBox(height: 8),
      _pickRow(_e1),
      const SizedBox(height: 8),
      _pickRow(_e2),
      const SizedBox(height: 14),
      TextField(
        controller: _scoreCtrl,
        style: AppText.body().copyWith(fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Score (optional) — e.g. 6-4, 6-3',
          hintStyle: AppText.small(AppColors.inkFaint),
          filled: true,
          fillColor: AppColors.field,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
      const SizedBox(height: 14),
      AppButton(_busy ? 'Submitting…' : 'Submit result',
          full: true, height: 52, icon: Icons.check_rounded,
          onPressed: _busy ? null : _submit),
    ];
  }

  Widget _pickRow(Map<String, dynamic>? e) {
    if (e == null) return const SizedBox.shrink();
    final id = e['id'] as String?;
    final on = _pick == id;
    return GestureDetector(
      onTap: () => setState(() => _pick = id),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: on ? AppColors.primary.withValues(alpha: 0.08) : AppColors.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          Expanded(
            child: Text(TournamentService.pairLabel(e),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppText.bodyStrong().copyWith(fontSize: 14)),
          ),
          Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              size: 20, color: on ? AppColors.primary : AppColors.line),
        ]),
      ),
    );
  }

  Widget _resultBanner(Color c, IconData ic, String title, String body) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ic, size: 18, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
              const SizedBox(height: 2),
              Text(body, style: AppText.small().copyWith(fontSize: 12.5, height: 1.4)),
            ]),
          ),
        ]),
      );
}
