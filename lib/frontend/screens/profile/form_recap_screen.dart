import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/models/mock_data.dart';

/// Full-screen recent-form recap: last 6 matches with partner, opponents,
/// ranks, scores and ELO deltas. Push with [Navigator.push].
class FormRecapScreen extends StatelessWidget {
  const FormRecapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final h = MockData.formHistory;
    final wins = h.where((m) => m.won).length;
    final losses = h.length - wins;
    final net = h.fold(0, (s, m) => s + m.eloDelta);
    final rate = (wins / h.length * 100).round();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        // hero
        Container(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 8, 16, 16),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [AppColors.hero, AppColors.hero2]),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 34, height: 34, alignment: Alignment.center,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: AppColors.heroInk),
                ),
              ),
              const SizedBox(width: 12),
              Text('RECENT FORM', style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11, letterSpacing: 1.5)),
            ]),
            const SizedBox(height: 10),
            Text('Last 6 Matches', style: AppText.stat(23, AppColors.heroInk)),
            const SizedBox(height: 12),
            Row(children: [
              for (final m in h)
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: Container(
                    width: 28, height: 28, alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: (m.won ? AppColors.success : AppColors.danger).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(m.won ? 'W' : 'L',
                        style: AppText.tag(m.won ? AppColors.success : AppColors.danger).copyWith(fontSize: 12, fontWeight: FontWeight.w900)),
                  ),
                ),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              _stat('$wins–$losses', 'Record', AppColors.heroInk),
              const SizedBox(width: 22),
              _stat('$rate%', 'Win rate', AppColors.heroInk),
              const SizedBox(width: 22),
              _stat('${net >= 0 ? '+' : ''}$net', 'Net ELO', net >= 0 ? AppColors.success : AppColors.danger),
            ]),
          ]),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 28),
            itemCount: h.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _MatchEntry(h[i]),
          ),
        ),
      ]),
    );
  }

  Widget _stat(String v, String l, Color c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(v, style: AppText.stat(20, c)),
        Text(l, style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 10.5)),
      ]);
}

class _MatchEntry extends StatelessWidget {
  final FormMatch m;
  const _MatchEntry(this.m);
  @override
  Widget build(BuildContext context) {
    final c = m.won ? AppColors.success : AppColors.danger;
    final you = FormPlayer('You', 'KH', MockData.me.tier, MockData.elo);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30, height: 30, alignment: Alignment.center,
            decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(9)),
            child: Text(m.won ? 'W' : 'L', style: AppText.stat(13, c)),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m.won ? 'Win' : 'Loss'} · ${m.score}', style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
              Text('${m.date} · ${m.when}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small().copyWith(fontSize: 11)),
            ]),
          ),
          Row(children: [
            Icon(m.eloDelta >= 0 ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 13, color: m.eloDelta >= 0 ? AppColors.success : AppColors.danger),
            Text('${m.eloDelta.abs()}',
                style: AppText.bodyStrong(m.eloDelta >= 0 ? AppColors.success : AppColors.danger).copyWith(fontSize: 12.5)),
          ]),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          AppTag(m.type, color: m.type == 'Competitive' ? AppColors.accent : AppColors.inkSoft),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.place_outlined, size: 12, color: AppColors.inkSoft),
            const SizedBox(width: 4),
            Text(m.court, style: AppText.small().copyWith(fontSize: 11.5)),
          ]),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.field, borderRadius: BorderRadius.circular(12)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('YOUR TEAM', style: AppText.tag(AppColors.primary).copyWith(fontSize: 9.5, letterSpacing: 0.8)),
                const SizedBox(height: 9),
                _player(you, me: true),
                const SizedBox(height: 9),
                _player(m.partner),
              ]),
            ),
            Column(children: [
              Container(width: 1, height: 18, color: AppColors.line),
              Padding(padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('VS', style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1))),
              Container(width: 1, height: 18, color: AppColors.line),
            ]),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('OPPONENTS', style: AppText.tag().copyWith(fontSize: 9.5, letterSpacing: 0.8)),
                const SizedBox(height: 9),
                _player(m.opp[0], right: true),
                const SizedBox(height: 9),
                _player(m.opp[1], right: true),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _player(FormPlayer p, {bool me = false, bool right = false}) {
    final avatar = AppAvatar(me ? 'KH' : p.bi, size: 34, ring: 1.5, color: me ? AppColors.primary : AppColors.tier(p.tier));
    final info = Column(
      crossAxisAlignment: right ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(me ? 'You' : p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong().copyWith(fontSize: 12.5)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          TierBadge(p.tier),
          Text(' ${p.elo}', style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10)),
        ]),
      ],
    );
    final children = right ? [Flexible(child: info), const SizedBox(width: 8), avatar] : [avatar, const SizedBox(width: 8), Flexible(child: info)];
    return Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start, children: children);
  }
}
