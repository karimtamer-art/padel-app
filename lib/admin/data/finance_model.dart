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

/// Money TAKEN outside the app — the mirror of [kExpenseCategories]. Store
/// orders, entry fees and repairs are counted from their own ledgers, so these
/// are only the sales the database has no other way of seeing.
/// Mirrors `income_category_chk` in the SQL — change both.
const List<ExpenseCategory> kIncomeCategories = [
  ExpenseCategory('cash_sale', 'Cash sale', Icons.payments_outlined,
      AdminColors.success, 'Sold in person, outside the store'),
  ExpenseCategory('coaching', 'Coaching', Icons.sports_tennis_rounded,
      AdminColors.primary, 'Lessons, clinics, private sessions'),
  ExpenseCategory('court_hire', 'Court hire', Icons.place_outlined,
      AdminColors.green, 'A court let out directly'),
  ExpenseCategory('sponsorship', 'Sponsorship', Icons.handshake_outlined,
      AdminColors.gold, 'Sponsors, partnerships, brand deals'),
  ExpenseCategory('event', 'Event takings', Icons.emoji_events_outlined,
      AdminColors.info, 'Entry fees collected at the venue'),
  ExpenseCategory('other', 'Other', Icons.more_horiz_rounded,
      AdminColors.inkSoft, 'Anything that fits nowhere else'),
];

ExpenseCategory incomeCategory(String? id) => kIncomeCategories.firstWhere(
      (c) => c.id == id,
      orElse: () => kIncomeCategories.last,
    );

/// The two hand-kept ledgers. Everything that differs between them lives here,
/// so the list, the sheet and the service methods are written once.
enum LedgerKind { expense, income }

extension LedgerKindX on LedgerKind {
  bool get isIncome => this == LedgerKind.income;
  String get table => isIncome ? 'income' : 'expenses';

  /// The date column — when the money actually moved.
  String get dateColumn => isIncome ? 'received_on' : 'spent_on';

  /// Who the money came from / went to.
  String get partyColumn => isIncome ? 'payer' : 'vendor';
  String get partyLabel => isIncome ? 'Received from' : 'Paid to';
  String get partyHint =>
      isIncome ? 'Player, club, sponsor…' : 'Club, supplier, courier…';

  String get addLabel => isIncome ? 'Add money in' : 'Record expense';
  String get editTitle => isIncome ? 'Edit money in' : 'Edit expense';
  String get newTitle => isIncome ? 'Record money in' : 'Record an expense';
  String get sheetSub => isIncome
      ? 'Money you took outside the app'
      : 'Something you paid for outside the app';
  String get sectionTitle => isIncome ? 'Recorded money in' : 'Recorded expenses';

  List<ExpenseCategory> get categories =>
      isIncome ? kIncomeCategories : kExpenseCategories;
  ExpenseCategory category(String? id) =>
      isIncome ? incomeCategory(id) : expenseCategory(id);
  String get defaultCategory => isIncome ? 'cash_sale' : 'materials';

  Color get tone => isIncome ? AdminColors.success : AdminColors.danger;
}

/// A parsed `admin_finance_summary` / weekly `report` payload.
class FinanceReport {
  final num moneyIn, moneyOut, profit, margin;
  final num store, storeCollected, entries, repairs, manualIn;
  final num cogs, tradeIn, expenses;
  final List<MapEntry<String, num>> byCategory;   // expense category → amount
  final List<MapEntry<String, num>> inByCategory; // income category  → amount
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
    this.manualIn = 0,
    this.cogs = 0,
    this.tradeIn = 0,
    this.expenses = 0,
    this.byCategory = const [],
    this.inByCategory = const [],
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
        manualIn = 0,
        cogs = 0,
        tradeIn = 0,
        expenses = 0,
        byCategory = const [],
        inByCategory = const [],
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

    List<MapEntry<String, num>> cats(Map? m) => [
          for (final row in (m?['by_category'] as List?) ?? const [])
            MapEntry((row as Map)['category'] as String? ?? 'other',
                (row['amount'] as num?) ?? 0),
        ];

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
      manualIn: n(mIn, 'manual'),
      cogs: n(mOut, 'cogs'),
      tradeIn: n(mOut, 'trade_in'),
      expenses: n(mOut, 'expenses'),
      byCategory: cats(mOut),
      inByCategory: cats(mIn),
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
      // Recorded by hand — broken out per category so "cash sale" and
      // "sponsorship" don't collapse into one anonymous "manual" line.
      for (final e in inByCategory)
        MoneyLine(
          key: 'in_${e.key}',
          label: incomeCategory(e.key).label,
          amount: e.value,
          tone: incomeCategory(e.key).tone,
          icon: incomeCategory(e.key).icon,
          hint: 'outside the app',
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
