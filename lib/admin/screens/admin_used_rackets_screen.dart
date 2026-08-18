import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../data/finance_model.dart' show egp, prettyDate, prettyYmd;
import '../widgets/admin_kit.dart';

/// Used rackets — second-hand stock bought to sell on.
///
/// One card per RACKET, not per transaction, so both halves of its life sit on
/// the same line: what you paid, what you sold it for, and the profit between.
/// A racket with no sale date is still on the shelf.
///
/// The money here is the SAME money Reports counts — `_finance_core` reads
/// these rows directly (`out.used_buy` on the purchase date, `in.used_sales` on
/// the sale date). Nothing on this screen computes a total the server doesn't;
/// it only re-states per racket what Reports totals per period.
///
/// The one trap is the overlap with trade-ins: a racket taken in on a trade-in
/// has ALREADY had its acquisition booked as trade-in credit, so its purchase
/// must not be charged again. That is what [kUsedSources] is for.
class AdminUsedRacketsScreen extends StatefulWidget {
  const AdminUsedRacketsScreen({super.key});
  @override
  State<AdminUsedRacketsScreen> createState() => _AdminUsedRacketsScreenState();
}

/// Where a racket came from. Mirrors `used_rackets_source_chk` in the SQL —
/// change both. The second entry is the double-count guard, not a label.
const kUsedSources = <(String, String, String)>[
  (
    'bought',
    'Bought it',
    'Paid cash for it. The price counts as money out in Reports.',
  ),
  (
    'trade_in',
    'Came from a trade-in',
    'Already paid for as trade-in credit. Reports will NOT charge you for it '
        'again — the sale still counts.',
  ),
];

class _AdminUsedRacketsScreenState extends State<AdminUsedRacketsScreen> {
  List<Map<String, dynamic>> _rackets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    final rows = await AdminService.fetchUsedRackets();
    if (!mounted) return;
    setState(() {
      _rackets = rows;
      _loading = false;
    });
  }

  // ── The sums ────────────────────────────────────────────────────
  // Deliberately the same arithmetic as _finance_core, so a figure here can
  // never contradict Reports. Profit is only ever counted on a SOLD racket:
  // one on the shelf has a cost and no sale, and calling that a loss would
  // make every new purchase look like a bad week.

  static bool _isSold(Map r) => r['sold_on'] != null;
  static num _buy(Map r) => (r['buy_price'] as num?) ?? 0;
  static num _sell(Map r) => (r['sell_price'] as num?) ?? 0;

  /// Null until it has sold — see the note above.
  static num? _profit(Map r) => _isSold(r) ? _sell(r) - _buy(r) : null;

  @override
  Widget build(BuildContext context) {
    final sold = _rackets.where(_isSold).toList();
    final shelf = _rackets.where((r) => !_isSold(r)).toList();
    final onShelf = shelf.fold<num>(0, (s, r) => s + _buy(r));
    final made = sold.fold<num>(0, (s, r) => s + (_profit(r) ?? 0));

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(
                icon: Icons.inventory_2_outlined,
                tone: AdminColors.primary,
                label: 'On the shelf',
                value: '${shelf.length}'),
            StatCard(
                icon: Icons.payments_outlined,
                tone: AdminColors.warn,
                label: 'Money on the shelf',
                value: egpShortish(onShelf)),
            StatCard(
                icon: Icons.sell_outlined,
                tone: AdminColors.info,
                label: 'Sold',
                value: '${sold.length}'),
            StatCard(
                icon: Icons.trending_up_rounded,
                tone: made < 0 ? AdminColors.danger : AdminColors.success,
                label: 'Profit on sold',
                value: egpShortish(made)),
          ]),
          const SizedBox(height: 16),
          AdminSection(
            'Used rackets',
            sub: 'What you paid, what you sold it for',
            action: AdminButton('Add',
                icon: Icons.add_rounded,
                height: 34,
                onPressed: () => _form(null)),
          ),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AdminColors.primary),
              ),
            )
          else if (_rackets.isEmpty)
            _emptyState()
          else ...[
            if (shelf.isNotEmpty) ...[
              _groupLabel('ON THE SHELF', shelf.length),
              for (final r in shelf) _card(r),
            ],
            if (sold.isNotEmpty) ...[
              const SizedBox(height: 6),
              _groupLabel('SOLD', sold.length),
              for (final r in sold) _card(r),
            ],
            const SizedBox(height: 8),
            _moneyNote(),
          ],
        ],
      ),
    );
  }

  Widget _groupLabel(String text, int n) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Text('$text · $n', style: AdminText.kicker()),
      );

  Widget _emptyState() => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: AdminCard(
          child: Column(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AdminColors.wash(AdminColors.primary, 0.12),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.sports_tennis_rounded,
                  size: 24, color: AdminColors.primary),
            ),
            const SizedBox(height: 12),
            Text('No used rackets yet', style: AdminText.cardTitle()),
            const SizedBox(height: 3),
            Text(
                'Add one when you buy it, then record the sale when it goes. '
                'Both prices land in Reports on the day they happened.',
                textAlign: TextAlign.center,
                style: AdminText.small()),
          ]),
        ),
      );

  Widget _moneyNote() => AdminCard(
        color: AdminColors.surfaceAlt,
        padding: const EdgeInsets.all(13),
        child: Row(children: [
          const Icon(Icons.info_outline_rounded,
              size: 17, color: AdminColors.inkSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                'Reports counts what you paid on the day you bought it, and '
                'what you sold it for on the day it sold — so a racket still '
                'on the shelf shows as a cost until it goes. Don\'t also ring '
                'these up as store orders.',
                style: AdminText.small().copyWith(height: 1.45)),
          ),
        ]),
      );

  Widget _card(Map<String, dynamic> r) {
    final sold = _isSold(r);
    final profit = _profit(r);
    final fromTrade = r['source'] == 'trade_in';
    final brand = (r['brand'] as String?)?.trim() ?? '';
    final tone = profit == null
        ? AdminColors.inkFaint
        : (profit < 0 ? AdminColors.danger : AdminColors.success);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        onTap: () => _form(r),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        brand.isEmpty
                            ? (r['name'] as String?) ?? '—'
                            : '$brand ${r['name'] ?? ''}'.trim(),
                        style: AdminText.cardTitle().copyWith(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Text(
                        [
                          if ((r['condition'] as String?)?.isNotEmpty == true)
                            r['condition'] as String,
                          'bought ${prettyYmd(r['bought_on'] as String?)}',
                          if (sold) 'sold ${prettyYmd(r['sold_on'] as String?)}',
                        ].join(' · '),
                        style: AdminText.small()),
                  ]),
            ),
            StatusBadge(sold ? 'sold' : 'on_shelf', dot: true),
          ]),
          const SizedBox(height: 11),
          Row(children: [
            _fig('Paid', _buy(r) == 0 ? '—' : egp(_buy(r)),
                muted: fromTrade),
            const SizedBox(width: 10),
            _fig('Sold for', sold && _sell(r) > 0 ? egp(_sell(r)) : '—'),
            const SizedBox(width: 10),
            _fig('Profit', profit == null ? '—' : egp(profit), tone: tone),
          ]),
          if (fromTrade) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.swap_horiz_rounded,
                  size: 14, color: AdminColors.inkFaint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    'Came from a trade-in — already paid for as credit, so '
                    'Reports counts only the sale.',
                    style: AdminText.small(AdminColors.inkFaint)),
              ),
            ]),
          ],
          if (!sold) ...[
            const SizedBox(height: 11),
            AdminButton('Mark sold',
                icon: Icons.sell_outlined,
                full: true,
                height: 38,
                onPressed: () => _sellSheet(r)),
          ],
        ]),
      ),
    );
  }

  /// One figure in the money row. [muted] is the trade-in case: the number is
  /// real and worth seeing, but it is not what Reports charged you.
  Widget _fig(String label, String value,
          {Color? tone, bool muted = false}) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.toUpperCase(), style: AdminText.kicker()),
            const SizedBox(height: 4),
            Text(value,
                style: AdminText.sans(
                    14,
                    FontWeight.w800,
                    muted
                        ? AdminColors.inkFaint
                        : (tone ?? AdminColors.ink)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ]),
        ),
      );

  // ── Recording a sale ────────────────────────────────────────────

  Future<void> _sellSheet(Map<String, dynamic> r) async {
    final price = TextEditingController();
    final buyer = TextEditingController();
    var when = DateTime.now();

    await adminSheet<void>(
      context,
      title: 'Mark sold',
      sub: (r['name'] as String?) ?? 'Used racket',
      heightFactor: 0.52,
      body: StatefulBuilder(
        builder: (ctx, setSheet) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('WHAT IT SOLD FOR', style: AdminText.kicker()),
              const SizedBox(height: 7),
              TextField(
                controller: price,
                keyboardType: TextInputType.number,
                autofocus: true,
                style: AdminText.sans(22, FontWeight.w800, AdminColors.ink),
                decoration: _dec('0').copyWith(prefixText: 'EGP '),
              ),
              const SizedBox(height: 14),
              Text('WHEN', style: AdminText.kicker()),
              const SizedBox(height: 7),
              _dateField(ctx, when, (d) => setSheet(() => when = d)),
              const SizedBox(height: 14),
              Text('WHO BOUGHT IT (OPTIONAL)', style: AdminText.kicker()),
              const SizedBox(height: 7),
              TextField(
                  controller: buyer,
                  style: AdminText.body(),
                  textCapitalization: TextCapitalization.words,
                  decoration: _dec('Their name')),
              const SizedBox(height: 10),
              Text(
                  'This lands in Reports as money in on the date above, and '
                  'the racket moves to Sold.',
                  style: AdminText.small(AdminColors.inkFaint)),
            ]),
      ),
      footer: AdminButton('Save the sale', full: true, height: 50,
          onPressed: () async {
        final v = num.tryParse(price.text.trim());
        if (v == null || v < 0) {
          adminToast(context, 'Enter what it sold for', ok: false);
          return;
        }
        Navigator.pop(context);
        final err = await AdminService.sellUsedRacket(
            r['id'] as String, _ymd(when), v, buyer.text);
        await _load();
        if (mounted) {
          adminToast(context, err ?? 'Sale recorded', ok: err == null);
        }
      }),
    );
    price.dispose();
    buyer.dispose();
  }

  // ── The form ────────────────────────────────────────────────────

  Future<void> _form(Map<String, dynamic>? existing) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _UsedRacketSheet(existing: existing),
    );
    if (saved == true) {
      await _load();
      if (mounted) adminToast(context, 'Saved');
    }
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// "EGP 12k" for a KPI tile, "EGP 900" below that. The finance model's
/// `egpShort` only abbreviates from 10k; a shelf is usually smaller than that.
String egpShortish(num n) {
  final a = n.abs();
  if (a >= 10000) {
    final sign = n < 0 ? '−' : '';
    return '${sign}EGP ${(a / 1000).toStringAsFixed(a % 1000 == 0 ? 0 : 1)}k';
  }
  return egp(n);
}

InputDecoration _dec(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      hintStyle: AdminText.body().copyWith(color: AdminColors.inkFaint),
      filled: true,
      fillColor: AdminColors.surfaceAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      enabledBorder: OutlineInputBorder(
          borderRadius: AdminUI.fieldR,
          borderSide: const BorderSide(color: AdminColors.line)),
      focusedBorder: OutlineInputBorder(
          borderRadius: AdminUI.fieldR,
          borderSide:
              const BorderSide(color: AdminColors.primary, width: 1.6)),
    );

/// A tappable date row. Dates here are plain `date` columns — no time, no
/// timezone — because they answer "which week does this money belong to".
Widget _dateField(
        BuildContext context, DateTime value, ValueChanged<DateTime> onPick) =>
    InkWell(
      borderRadius: BorderRadius.circular(11),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 1)),
        );
        if (picked != null) onPick(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: AdminColors.line)),
        child: Row(children: [
          const Icon(Icons.calendar_today_rounded,
              size: 15, color: AdminColors.inkSoft),
          const SizedBox(width: 10),
          Text(prettyDate(value), style: AdminText.body()),
          const Spacer(),
          const Icon(Icons.expand_more_rounded,
              size: 18, color: AdminColors.inkSoft),
        ]),
      ),
    );

// ============================================================================
// Add / edit one racket. Both halves of its life in one form: what you paid,
// and — once it has gone — what you sold it for.
// ============================================================================
class _UsedRacketSheet extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _UsedRacketSheet({this.existing});
  @override
  State<_UsedRacketSheet> createState() => _UsedRacketSheetState();
}

class _UsedRacketSheetState extends State<_UsedRacketSheet> {
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _buy = TextEditingController();
  final _from = TextEditingController();
  final _sell = TextEditingController();
  final _to = TextEditingController();
  final _note = TextEditingController();

  late DateTime _boughtOn;
  DateTime? _soldOn;
  String _source = 'bought';
  String? _condition;
  bool _busy = false;

  bool get _editing => widget.existing != null;

  static const _conditions = ['New', 'Like new', 'Good', 'Fair', 'Poor'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _boughtOn = _parse(e?['bought_on'] as String?) ?? DateTime.now();
    _soldOn = _parse(e?['sold_on'] as String?);
    if (e != null) {
      _name.text = (e['name'] as String?) ?? '';
      _brand.text = (e['brand'] as String?) ?? '';
      _from.text = (e['bought_from'] as String?) ?? '';
      _to.text = (e['sold_to'] as String?) ?? '';
      _note.text = (e['note'] as String?) ?? '';
      _condition = e['condition'] as String?;
      _source = (e['source'] as String?) ?? 'bought';
      final b = e['buy_price'], s = e['sell_price'];
      if (b is num) _buy.text = _plain(b);
      if (s is num) _sell.text = _plain(s);
    }
  }

  static DateTime? _parse(String? ymd) {
    if (ymd == null || ymd.length < 10) return null;
    try {
      return DateTime.parse(ymd);
    } catch (_) {
      return null;
    }
  }

  static String _plain(num v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    _name.dispose();
    _brand.dispose();
    _buy.dispose();
    _from.dispose();
    _sell.dispose();
    _to.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Same sum as the card and as Reports: only a sold racket has a profit.
  num? get _profit {
    if (_soldOn == null) return null;
    return (num.tryParse(_sell.text.trim()) ?? 0) -
        (num.tryParse(_buy.text.trim()) ?? 0);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      adminToast(context, 'Say what the racket is', ok: false);
      return;
    }
    // Mirrors used_rackets_sold_chk — caught here so the admin gets a sentence
    // rather than a constraint name.
    final sell = num.tryParse(_sell.text.trim());
    if (sell != null && _soldOn == null) {
      adminToast(context, 'Pick the date it sold', ok: false);
      return;
    }
    setState(() => _busy = true);
    final err = await AdminService.saveUsedRacket(
      id: widget.existing?['id'] as String?,
      name: _name.text,
      brand: _brand.text,
      condition: _condition,
      source: _source,
      boughtOn: _AdminUsedRacketsScreenState._ymd(_boughtOn),
      buyPrice: num.tryParse(_buy.text.trim()),
      boughtFrom: _from.text,
      soldOn: _soldOn == null
          ? null
          : _AdminUsedRacketsScreenState._ymd(_soldOn!),
      sellPrice: sell,
      soldTo: _to.text,
      note: _note.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final id = widget.existing?['id'] as String?;
    if (id == null) return;
    Navigator.pop(context);
    await AdminService.deleteUsedRacket(id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.88,
        decoration: const BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
        child: Column(children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: AdminColors.line,
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 12, 6),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_editing ? 'Edit racket' : 'Add a used racket',
                          style: AdminText.h2()),
                      const SizedBox(height: 2),
                      Text('What you paid, and what you sold it for',
                          style: AdminText.small()),
                    ]),
              ),
              IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: AdminColors.inkSoft),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          const Divider(height: 16, color: AdminColors.lineSoft),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
              children: [
                _label('The racket'),
                TextField(
                    controller: _name,
                    style: AdminText.body(),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: _dec('e.g. Viper 2023')),
                const SizedBox(height: 10),
                TextField(
                    controller: _brand,
                    style: AdminText.body(),
                    textCapitalization: TextCapitalization.words,
                    decoration: _dec('Brand (optional)')),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in _conditions)
                      _chip(c, _condition == c,
                          () => setState(() => _condition = c)),
                  ],
                ),
                const SizedBox(height: 18),
                _label('Where it came from'),
                for (final s in kUsedSources) ...[
                  _sourceOption(s),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 10),
                _label('What you paid'),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _buy,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      style:
                          AdminText.sans(20, FontWeight.w800, AdminColors.ink),
                      decoration: _dec('0').copyWith(prefixText: 'EGP '),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _dateField(context, _boughtOn,
                          (d) => setState(() => _boughtOn = d))),
                ]),
                const SizedBox(height: 10),
                TextField(
                    controller: _from,
                    style: AdminText.body(),
                    textCapitalization: TextCapitalization.words,
                    decoration: _dec('Bought from (optional)')),
                const SizedBox(height: 18),
                _label('What you sold it for'),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _sell,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      style:
                          AdminText.sans(20, FontWeight.w800, AdminColors.ink),
                      decoration: _dec('0').copyWith(prefixText: 'EGP '),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _soldDateField()),
                ]),
                const SizedBox(height: 10),
                TextField(
                    controller: _to,
                    style: AdminText.body(),
                    textCapitalization: TextCapitalization.words,
                    decoration: _dec('Sold to (optional)')),
                const SizedBox(height: 12),
                _profitBox(),
                const SizedBox(height: 8),
                Text(
                  _soldOn == null
                      ? 'Leave the sale empty while it is still on the shelf. '
                          'Reports counts what you paid from the purchase date, '
                          'and the sale only once there is one.'
                      : 'Reports counts this sale on the date above.',
                  style: AdminText.small(AdminColors.inkFaint),
                ),
                const SizedBox(height: 18),
                _label('Note (optional)'),
                TextField(
                    controller: _note,
                    style: AdminText.body(),
                    maxLines: 3,
                    decoration: _dec('Anything worth remembering')),
                if (_editing) ...[
                  const SizedBox(height: 18),
                  AdminButton('Delete this racket',
                      full: true,
                      height: 44,
                      variant: AdminBtn.danger,
                      onPressed: _delete),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
            decoration: const BoxDecoration(
                color: AdminColors.surfaceAlt,
                border: Border(top: BorderSide(color: AdminColors.lineSoft))),
            child: AdminButton(_busy ? 'Saving…' : 'Save',
                full: true, height: 48, onPressed: _busy ? null : _save),
          ),
        ]),
      ),
    );
  }

  /// The sale date, which unlike the purchase date may be absent — that is
  /// what "still on the shelf" IS. So it needs a clear as well as a pick.
  Widget _soldDateField() {
    if (_soldOn == null) {
      return InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: DateTime.now(),
            firstDate: DateTime(2020),
            lastDate: DateTime.now().add(const Duration(days: 1)),
          );
          if (picked != null) setState(() => _soldOn = picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: AdminColors.line)),
          child: Row(children: [
            const Icon(Icons.add_rounded, size: 15, color: AdminColors.inkSoft),
            const SizedBox(width: 8),
            Text('Not sold yet', style: AdminText.small()),
          ]),
        ),
      );
    }
    return Row(children: [
      Expanded(
          child: _dateField(
              context, _soldOn!, (d) => setState(() => _soldOn = d))),
      IconButton(
        tooltip: 'Back on the shelf',
        icon: const Icon(Icons.close_rounded,
            size: 18, color: AdminColors.inkSoft),
        onPressed: () => setState(() {
          _soldOn = null;
          // The DB refuses a price with no date, and leaving it would also
          // claim a sale that no longer exists.
          _sell.clear();
        }),
      ),
    ]);
  }

  Widget _sourceOption((String, String, String) s) {
    final on = _source == s.$1;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _source = s.$1),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: on
              ? AdminColors.wash(AdminColors.primary, 0.08)
              : AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: on ? AdminColors.primary : AdminColors.line,
              width: on ? 1.6 : 1),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(on ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: on ? AdminColors.primary : AdminColors.inkFaint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.$2, style: AdminText.strong()),
                  const SizedBox(height: 2),
                  Text(s.$3,
                      style: AdminText.small().copyWith(height: 1.4)),
                ]),
          ),
        ]),
      ),
    );
  }

  Widget _profitBox() {
    final p = _profit;
    final tone = p == null
        ? AdminColors.inkFaint
        : (p < 0 ? AdminColors.danger : AdminColors.success);
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p == null ? AdminColors.surfaceAlt : tone.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: p == null ? AdminColors.line : tone.withValues(alpha: .5)),
      ),
      child: Row(children: [
        Text('PROFIT ON THIS RACKET', style: AdminText.kicker()),
        const Spacer(),
        Text(p == null ? 'Not sold yet' : egp(p),
            style: AdminText.sans(17, FontWeight.w800, tone)),
      ]),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t.toUpperCase(), style: AdminText.kicker()),
      );

  Widget _chip(String label, bool on, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: on
                ? AdminColors.wash(AdminColors.primary, 0.12)
                : AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: on ? AdminColors.primary : AdminColors.line),
          ),
          child: Text(label,
              style: AdminText.small(
                  on ? AdminColors.primary : AdminColors.inkSoft)),
        ),
      );
}
