// ============================================================================
// finance_model.dart — the money model behind the Reports tab.
//
// Mirrors `_finance_core` in supabase/changes/2026-08-06_expenses_and_pl.sql:
// money IN (store sales, entry fees, repairs), money OUT (cost of goods sold,
// trade-in credit, hand-recorded expenses) and the profit between them. The
// server is the only thing that computes these numbers — this file just names,
// formats and orders them for display.
//
// The category list MUST stay in lockstep with `expenses_category_chk` in the
// SQL. Note there is deliberately no "stock" category: inventory is costed per
// product (product_costs.cost) and lands in the P&L as cost of goods sold when
// the item actually sells. Recording a stock purchase too would count it twice.
// ============================================================================
import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';

/// One line of the P&L — a source of money in, or a cost.
class MoneyLine {
  final String key, label, hint;
  final num amount;
  final Color tone;
  final IconData icon;

  /// Not editable by hand: derived from the orders / trade-in ledgers.
  final bool auto;

  const MoneyLine({
    required this.key,
    required this.label,
    required this.amount,
    required this.tone,
    required this.icon,
    this.hint = '',
    this.auto = false,
  });
}

/// A grantable expense category — what a super admin can record paying for.
class ExpenseCategory {
  final String id, label, hint;
  final IconData icon;
  final Color tone;
  const ExpenseCategory(this.id, this.label, this.icon, this.tone, this.hint);
}

const List<ExpenseCategory> kExpenseCategories = [
  ExpenseCategory('materials', 'Materials & supplies', Icons.category_outlined,
      AdminColors.bronze,
      'Strings, grips, balls, packaging — things you buy and use up'),
  ExpenseCategory('court_rent', 'Courts & venue', Icons.place_outlined,
      AdminColors.green, 'Court hire for matches and events'),
  ExpenseCategory('prizes', 'Prizes & trophies', Icons.emoji_events_outlined,
      AdminColors.gold, 'Prize money, medals, trophies'),
  ExpenseCategory('marketing', 'Marketing & ads', Icons.campaign_outlined,
      AdminColors.primary, 'Ads, content, sponsorships, giveaways'),
  ExpenseCategory('salaries', 'Staff & coaches', Icons.badge_outlined,
      AdminColors.info, 'Wages, referees, coaching fees'),
  ExpenseCategory('shipping', 'Delivery & courier', Icons.local_shipping_outlined,
      AdminColors.silver, 'What the courier charges us per order'),
  ExpenseCategory('software', 'Software & fees', Icons.cloud_outlined,
      AdminColors.elite, 'Hosting, Supabase, stores, transfer fees'),
  ExpenseCategory('equipment', 'Equipment & upkeep', Icons.handyman_outlined,
      AdminColors.warn, 'Nets, machines, tools — kit that lasts'),
  ExpenseCategory('other', 'Other', Icons.more_horiz_rounded,
      AdminColors.inkSoft, 'Anything that fits nowhere else'),
];

ExpenseCategory expenseCategory(String? id) => kExpenseCategories.firstWhere(
      (c) => c.id == id,
      orElse: () => kExpenseCategories.last,
    );

/// A parsed `admin_finance_summary` / weekly `report` payload.
class FinanceReport {
  final num moneyIn, moneyOut, profit, margin;
  final num store, storeCollected, entries, repairs;
  final num cogs, tradeIn, expenses;
  final List<MapEntry<String, num>> byCategory; // category id → amount
  final Map<String, int> counts;

  /// The server refused (not a super admin / analyst) or the RPC isn't there.
  final String? error;

  const FinanceReport({
    this.moneyIn = 0,
    this.moneyOut = 0,
    this.profit = 0,
    this.margin = 0,
    this.store = 0,
    this.storeCollected = 0,
    this.entries = 0,
    this.repairs = 0,
    this.cogs = 0,
    this.tradeIn = 0,
    this.expenses = 0,
    this.byCategory = const [],
    this.counts = const {},
    this.error,
  });

  const FinanceReport.failed(this.error)
      : moneyIn = 0,
        moneyOut = 0,
        profit = 0,
        margin = 0,
        store = 0,
        storeCollected = 0,
        entries = 0,
        repairs = 0,
        cogs = 0,
        tradeIn = 0,
        expenses = 0,
        byCategory = const [],
        counts = const {};

  bool get locked => error == 'not_allowed';
  bool get ok => error == null;
  bool get isEmpty => moneyIn == 0 && moneyOut == 0;

  factory FinanceReport.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const FinanceReport.failed('no_data');
    final err = json['error'] as String?;
    if (err != null) return FinanceReport.failed(err);

    num n(Map? m, String k) => (m?[k] as num?) ?? 0;
    final mIn = json['in'] as Map?;
    final mOut = json['out'] as Map?;

    final cats = <MapEntry<String, num>>[];
    for (final row in (mOut?['by_category'] as List?) ?? const []) {
      final r = row as Map;
      cats.add(MapEntry(r['category'] as String? ?? 'other',
          (r['amount'] as num?) ?? 0));
    }

    final counts = <String, int>{};
    ((json['counts'] as Map?) ?? const {}).forEach((k, v) {
      counts[k.toString()] = (v as num?)?.toInt() ?? 0;
    });

    return FinanceReport(
      moneyIn: n(mIn, 'total'),
      moneyOut: n(mOut, 'total'),
      profit: (json['profit'] as num?) ?? 0,
      margin: (json['margin'] as num?) ?? 0,
      store: n(mIn, 'store'),
      storeCollected: n(mIn, 'store_collected'),
      entries: n(mIn, 'entries'),
      repairs: n(mIn, 'repairs'),
      cogs: n(mOut, 'cogs'),
      tradeIn: n(mOut, 'trade_in'),
      expenses: n(mOut, 'expenses'),
      byCategory: cats,
      counts: counts,
    );
  }

  /// What we get, biggest first, zero-value lines dropped.
  List<MoneyLine> get inLines {
    final lines = [
      MoneyLine(
        key: 'store',
        label: 'Store sales',
        amount: store,
        tone: AdminColors.primary,
        icon: Icons.shopping_bag_outlined,
        hint: '${counts['orders'] ?? 0} orders',
      ),
      MoneyLine(
        key: 'entries',
        label: 'Tournament entries',
        amount: entries,
        tone: AdminColors.gold,
        icon: Icons.emoji_events_outlined,
        hint: '${counts['entries'] ?? 0} paid entries',
      ),
      MoneyLine(
        key: 'repairs',
        label: 'Repairs',
        amount: repairs,
        tone: AdminColors.info,
        icon: Icons.build_outlined,
        hint: '${counts['repairs'] ?? 0} collected',
      ),
    ]..removeWhere((l) => l.amount == 0);
    lines.sort((a, b) => b.amount.compareTo(a.amount));
    return lines;
  }

  /// What we pay, biggest first. The two automatic lines are flagged so the UI
  /// can say they come from the ledgers rather than the expense sheet.
  List<MoneyLine> get outLines {
    final lines = <MoneyLine>[
      MoneyLine(
        key: 'cogs',
        label: 'Cost of goods sold',
        amount: cogs,
        tone: AdminColors.bronze,
        icon: Icons.inventory_2_outlined,
        hint: 'What the items sold cost us',
        auto: true,
      ),
      MoneyLine(
        key: 'trade_in',
        label: 'Trade-in credit',
        amount: tradeIn,
        tone: AdminColors.silver,
        icon: Icons.swap_horiz_rounded,
        hint: '${counts['trade_in'] ?? 0} offers accepted',
        auto: true,
      ),
      for (final e in byCategory)
        MoneyLine(
          key: e.key,
          label: expenseCategory(e.key).label,
          amount: e.value,
          tone: expenseCategory(e.key).tone,
          icon: expenseCategory(e.key).icon,
        ),
    ]..removeWhere((l) => l.amount == 0);
    lines.sort((a, b) => b.amount.compareTo(a.amount));
    return lines;
  }
}

/// One Monday-to-Sunday week of the weekly report.
class FinanceWeek {
  final DateTime start, end;
  final bool isCurrent;
  final FinanceReport report;
  const FinanceWeek(this.start, this.end, this.isCurrent, this.report);

  factory FinanceWeek.fromJson(Map<String, dynamic> j) => FinanceWeek(
        DateTime.parse(j['week_start'] as String),
        DateTime.parse(j['week_end'] as String),
        j['is_current'] == true,
        FinanceReport.fromJson(
            (j['report'] as Map?)?.cast<String, dynamic>()),
      );

  /// "Aug 3 – 9" / "Jul 28 – Aug 3".
  String get label => start.month == end.month
      ? '${monthShort(start)} ${start.day} – ${end.day}'
      : '${monthShort(start)} ${start.day} – ${monthShort(end)} ${end.day}';
}

// ── Dates ────────────────────────────────────────────────────────────────────

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String monthShort(DateTime d) => _months[d.month - 1];

/// "Aug 6" — an expense row's date.
String prettyDay(DateTime d) => '${monthShort(d)} ${d.day}';

/// "Aug 6, 2026" — the date field in the expense sheet.
String prettyDate(DateTime d) => '${monthShort(d)} ${d.day}, ${d.year}';

/// Postgres `date` → "Aug 6". Falls back to the raw string.
String prettyYmd(String? ymd) {
  if (ymd == null || ymd.length < 10) return '—';
  try {
    return prettyDay(DateTime.parse(ymd));
  } catch (_) {
    return ymd;
  }
}

// ── Money formatting (EGP, no decimals — the store prices in whole pounds) ───

String egp(num n) {
  final neg = n < 0;
  final s = n.abs().round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '${neg ? '−' : ''}EGP $buf';
}

String egpShort(num n) {
  final a = n.abs();
  final sign = n < 0 ? '−' : '';
  if (a >= 1000000) {
    return '${sign}EGP ${(a / 1000000).toStringAsFixed(a % 1000000 == 0 ? 0 : 1)}M';
  }
  if (a >= 10000) {
    return '${sign}EGP ${(a / 1000).toStringAsFixed(a % 1000 == 0 ? 0 : 1)}k';
  }
  return egp(n);
}

/// "34" / "34.3" — a percentage without a pointless trailing ".0".
String pct(num n) {
  final s = n.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Percent change from [before] to [after]; null when there's no baseline.
double? pctChange(num before, num after) {
  if (before == 0) return null;
  return ((after - before) / before.abs()) * 100;
}
