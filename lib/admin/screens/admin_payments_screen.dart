import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

class AdminPaymentsScreen extends StatefulWidget {
  const AdminPaymentsScreen({super.key});
  @override
  State<AdminPaymentsScreen> createState() => _AdminPaymentsScreenState();
}

class _AdminPaymentsScreenState extends State<AdminPaymentsScreen> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await AdminService.fetchOrders();
      if (mounted) setState(() { _orders = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _fmtDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }

  static Color _statusColor(String? s) {
    switch (s) {
      case 'paid': return AdminColors.success;
      case 'pending': return AdminColors.warn;
      case 'refunded': return AdminColors.danger;
      default: return AdminColors.inkSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }

    final totalRevenue = _orders
        .where((o) => o['status'] == 'paid')
        .fold<double>(0, (s, o) => s + ((o['total_amount'] as num?)?.toDouble() ?? 0));

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(icon: Icons.receipt_long_outlined, tone: AdminColors.primary, label: 'Total orders', value: '${_orders.length}'),
            StatCard(icon: Icons.payments_outlined, tone: AdminColors.success, label: 'Revenue', value: 'EGP ${totalRevenue.toStringAsFixed(0)}'),
            StatCard(icon: Icons.pending_outlined, tone: AdminColors.warn, label: 'Pending', value: '${_orders.where((o) => o['status'] == 'pending').length}'),
            StatCard(icon: Icons.undo_rounded, tone: AdminColors.danger, label: 'Refunded', value: '${_orders.where((o) => o['status'] == 'refunded').length}'),
          ]),
          const SizedBox(height: 16),
          AdminSection('Orders', sub: '${_orders.length} total'),
          if (_orders.isEmpty)
            _emptyState()
          else
            for (final o in _orders) _card(o),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> o) {
    final status = o['status'] as String?;
    final sc = _statusColor(status);
    final player = (o['profiles'] as Map?)?['name'] as String? ?? 'Unknown';
    final amount = (o['total_amount'] as num?)?.toDouble() ?? 0;
    final date = _fmtDate(o['created_at'] as String?);
    final id = (o['id'] as String?)?.substring(0, 8) ?? '—';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AdminColors.wash(sc, 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.receipt_outlined, size: 20, color: sc),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(player, style: AdminText.strong(), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('Order #$id  ·  $date', style: AdminText.small()),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('EGP ${amount.toStringAsFixed(0)}',
                style: AdminText.sans(14, FontWeight.w800, AdminColors.ink)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AdminColors.wash(sc, 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                status != null ? status[0].toUpperCase() + status.substring(1) : '—',
                style: AdminText.sans(11, FontWeight.w700, sc),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _emptyState() => Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56, height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.payments_outlined, size: 26, color: AdminColors.inkFaint),
          ),
          const SizedBox(height: 14),
          Text('No orders yet', style: AdminText.h2()),
          const SizedBox(height: 6),
          Text('Store orders will appear here once players start purchasing.',
              textAlign: TextAlign.center, style: AdminText.small()),
        ]),
      );
}
