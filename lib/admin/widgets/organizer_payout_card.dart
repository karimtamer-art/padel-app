// ============================================================================
// organizer_payout_card.dart — reusable "InstaPay payout" card.
// Self-loads and self-edits the signed-in organizer's InstaPay username + link
// (payout_accounts, provider 'instapay') via AdminService. Embedded on the
// Overview and Community screens so it can be seen/edited from either place —
// one source of truth, no drift. Players registering for the organizer's PAID
// tournaments transfer to these details (see tournament_pay_info).
// ============================================================================
import 'package:flutter/material.dart';
import '../data/admin_service.dart';
import '../theme/admin_colors.dart';
import 'admin_kit.dart';

class OrganizerPayoutCard extends StatefulWidget {
  const OrganizerPayoutCard({super.key});
  @override
  State<OrganizerPayoutCard> createState() => _OrganizerPayoutCardState();
}

class _OrganizerPayoutCardState extends State<OrganizerPayoutCard> {
  String? _handle;
  String? _link;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await AdminService.fetchMyInstapay();
    if (!mounted) return;
    setState(() {
      _handle = v.handle;
      _link = v.link;
      _loading = false;
    });
  }

  bool get _set => (_handle ?? '').isNotEmpty || (_link ?? '').isNotEmpty;

  Future<void> _edit() async {
    // The field holds only the name — "@instapay" is fixed on the right.
    final handleC =
        TextEditingController(text: AdminService.instapayName(_handle));
    final linkC = TextEditingController(text: _link ?? '');
    adminSheet(
      context,
      title: 'InstaPay payout',
      sub: 'Players transfer your entry fees to these details',
      heightFactor: 0.6,
      footer: AdminButton(
        'Save',
        full: true,
        height: 50,
        icon: Icons.check_rounded,
        color: AdminColors.gold,
        onPressed: () async {
          Navigator.pop(context);
          final handle = AdminService.normalizeInstapay(handleC.text);
          final err = await AdminService.setMyInstapay(
              handle: handle ?? '', link: linkC.text.trim());
          if (!mounted) return;
          if (err != null) {
            adminToast(context, err, ok: false);
            return;
          }
          setState(() {
            _handle = handle;
            _link = linkC.text.trim().isEmpty ? null : linkC.text.trim();
          });
          adminToast(context, 'Payout details saved');
        },
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
              color: AdminColors.wash(AdminColors.gold, 0.12),
              borderRadius: AdminUI.fieldR),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded, size: 17, color: AdminColors.gold),
            const SizedBox(width: 9),
            Expanded(
                child: Text(
                    'Add your InstaPay username, a payment link, or both. Players '
                    'see these when they pay to enter your tournaments.',
                    style: AdminText.small(AdminColors.ink))),
          ]),
        ),
        const SizedBox(height: 14),
        Text('INSTAPAY USERNAME', style: AdminText.kicker()),
        const SizedBox(height: 7),
        _field(handleC, 'yourname', suffix: AdminService.instapaySuffix),
        const SizedBox(height: 14),
        Text('PAYMENT LINK (OPTIONAL)', style: AdminText.kicker()),
        const SizedBox(height: 7),
        _field(linkC, 'https://ipn.eg/... or your InstaPay link',
            keyboard: TextInputType.url),
      ]),
    );
  }

  static Widget _field(TextEditingController c, String hint,
          {TextInputType? keyboard, String? suffix}) =>
      TextField(
        controller: c,
        keyboardType: keyboard,
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: AdminText.body(AdminColors.inkFaint),
          // Fixed, non-editable — InstaPay always completes the address.
          suffixText: suffix,
          suffixStyle: AdminText.sans(13.5, FontWeight.w700, AdminColors.inkSoft),
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.primary, width: 1.6)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AdminCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AdminColors.wash(AdminColors.gold, 0.14),
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.account_balance_wallet_outlined,
                  size: 19, color: AdminColors.gold),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('InstaPay payout', style: AdminText.cardTitle()),
                Text('Where players send your entry fees', style: AdminText.small()),
              ]),
            ),
            if (!_loading)
              AdminButton(_set ? 'Edit' : 'Set up',
                  icon: _set ? Icons.edit_outlined : Icons.add,
                  height: 34,
                  variant: AdminBtn.ghost,
                  onPressed: _edit),
          ]),
          const SizedBox(height: 12),
          if (_loading)
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                  color: AdminColors.surfaceAlt, borderRadius: AdminUI.fieldR),
              child: Text('Loading…', style: AdminText.small()),
            )
          else if (_set) ...[
            if ((_handle ?? '').isNotEmpty)
              _detailRow(Icons.alternate_email_rounded, _handle!),
            if ((_link ?? '').isNotEmpty) ...[
              if ((_handle ?? '').isNotEmpty) const SizedBox(height: 8),
              _detailRow(Icons.link_rounded, _link!),
            ],
          ] else
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                  color: AdminColors.wash(AdminColors.warn, 0.12),
                  borderRadius: AdminUI.fieldR),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, size: 17, color: AdminColors.warn),
                const SizedBox(width: 9),
                Expanded(
                    child: Text(
                        'Not set — paid-entry players pay the platform account until you add yours.',
                        style: AdminText.small(AdminColors.ink))),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _detailRow(IconData icon, String value) => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt, borderRadius: AdminUI.fieldR),
        child: Row(children: [
          Icon(icon, size: 17, color: AdminColors.inkSoft),
          const SizedBox(width: 9),
          Expanded(
            child: Text(value,
                style: AdminText.sans(13.5, FontWeight.w700, AdminColors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      );
}
