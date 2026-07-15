import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/backend/models/mock_data.dart';
import 'package:padel_clay/backend/services/address_service.dart';
import 'package:padel_clay/backend/services/order_service.dart';

enum _Step { address, pay, instapay, done }

/// Multi-step store checkout: delivery address → payment method →
/// (InstaPay transfer) → order confirmed. Pushed from [CartScreen] once the
/// cart has items. Calls [onPlaced] when the order row is written so the cart
/// can clear; "Continue shopping" pops back to the store root.
class CheckoutFlowScreen extends StatefulWidget {
  final List<CartLine> cart;
  final int subtotal, shipping, discount, total;
  final String? promoCode;
  final VoidCallback onPlaced;

  const CheckoutFlowScreen({
    super.key,
    required this.cart,
    required this.subtotal,
    required this.shipping,
    required this.discount,
    required this.total,
    required this.promoCode,
    required this.onPlaced,
  });

  @override
  State<CheckoutFlowScreen> createState() => _CheckoutFlowScreenState();
}

class _CheckoutFlowScreenState extends State<CheckoutFlowScreen> {
  _Step _step = _Step.address;

  // Address
  List<Map<String, dynamic>> _addresses = [];
  bool _loadingAddr = true;
  String? _chosenId;
  Map<String, dynamic>? _addr; // confirmed delivery address
  bool _addingAddr = false;
  bool _savingAddr = false;
  String _newLabel = 'Home';
  String _governorate = 'Cairo';
  final _fullName = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  final _area = TextEditingController();
  final _street = TextEditingController();
  final _building = TextEditingController();
  final _apartment = TextEditingController();
  final _landmark = TextEditingController();

  static const _governorates = <String>[
    'Cairo', 'Giza', 'Alexandria', 'Qalyubia', 'Dakahlia', 'Sharqia',
    'Gharbia', 'Monufia', 'Beheira', 'Kafr El Sheikh', 'Damietta',
    'Port Said', 'Ismailia', 'Suez', 'North Sinai', 'South Sinai',
    'Faiyum', 'Beni Suef', 'Minya', 'Asyut', 'Sohag', 'Qena', 'Luxor',
    'Aswan', 'Red Sea', 'New Valley', 'Matrouh',
  ];

  // Payment
  String _method = 'cod'; // 'cod' | 'instapay'

  // InstaPay
  String _handle = 'padelpro@instapay';
  final _sender = TextEditingController();
  Uint8List? _proofBytes;
  String _proofExt = 'jpg';
  bool _placing = false;

  // Result
  String _orderRef = '';

  @override
  void initState() {
    super.initState();
    _loadAddresses();
    OrderService.fetchInstapayHandle().then((h) {
      if (mounted) setState(() => _handle = h);
    });
  }

  @override
  void dispose() {
    _fullName.dispose();
    _phone.dispose();
    _city.dispose();
    _area.dispose();
    _street.dispose();
    _building.dispose();
    _apartment.dispose();
    _landmark.dispose();
    _sender.dispose();
    super.dispose();
  }

  Future<void> _loadAddresses() async {
    final list = await AddressService.fetchAddresses();
    if (!mounted) return;
    setState(() {
      _addresses = list;
      _chosenId = list.isNotEmpty ? list.first['id'] as String : null;
      _loadingAddr = false;
    });
  }

  void _toast(String msg, {bool error = false}) {
    AppToast.show(context, msg,
        kind: error ? ToastKind.error : ToastKind.success);
  }

  // ── Address actions ───────────────────────────────────────────

  bool get _newAddrReady =>
      _fullName.text.trim().isNotEmpty &&
      _phone.text.trim().isNotEmpty &&
      _city.text.trim().isNotEmpty &&
      _street.text.trim().isNotEmpty;

  Map<String, dynamic> _withLine(Map<String, dynamic> a) =>
      {...a, 'line': AddressService.composeLine(a)};

  Future<void> _deliverHere() async {
    if (_addingAddr) {
      if (!_newAddrReady) return;
      setState(() => _savingAddr = true);
      final (err, row) = await AddressService.addAddress(
        label: _newLabel,
        fullName: _fullName.text,
        phone: _phone.text,
        governorate: _governorate,
        city: _city.text,
        area: _area.text,
        street: _street.text,
        building: _building.text,
        apartment: _apartment.text,
        landmark: _landmark.text,
        makeDefault: _addresses.isEmpty,
      );
      if (!mounted) return;
      setState(() => _savingAddr = false);
      if (err != null) {
        _toast(err, error: true);
        return;
      }
      setState(() {
        _addr = _withLine(row!);
        _addingAddr = false;
        _step = _Step.pay;
      });
    } else {
      final chosen = _addresses.firstWhere(
        (a) => a['id'] == _chosenId,
        orElse: () => _addresses.first,
      );
      setState(() {
        _addr = _withLine(chosen);
        _step = _Step.pay;
      });
    }
  }

  // ── Place order ───────────────────────────────────────────────

  Future<void> _placeOrder() async {
    setState(() => _placing = true);
    String? proofPath;
    if (_method == 'instapay' && _proofBytes != null) {
      proofPath = await OrderService.uploadPaymentProof(_proofBytes!, _proofExt);
    }
    final (err, orderId) = await OrderService.placeOrder(
      cart: widget.cart,
      subtotal: widget.subtotal,
      shipping: widget.shipping,
      discount: widget.discount,
      total: widget.total,
      promoCode: widget.promoCode,
      paymentMethod: _method,
      address: _addr,
      instapaySender: _method == 'instapay' ? _sender.text.trim() : null,
      instapayProofPath: proofPath,
    );
    if (!mounted) return;
    setState(() => _placing = false);
    if (err != null) {
      _toast(err, error: true);
      return;
    }
    final raw = (orderId ?? '').replaceAll('-', '').toUpperCase();
    setState(() {
      _orderRef = raw.length >= 6 ? '#PD-${raw.substring(0, 6)}' : '#PD-NEW';
      _step = _Step.done;
    });
    widget.onPlaced();
  }

  Future<void> _pickProof() async {
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'jpg';
      if (!mounted) return;
      setState(() {
        _proofBytes = bytes;
        _proofExt = ext;
      });
    } catch (e) {
      _toast('Could not attach image.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: switch (_step) {
        _Step.address => _addressStep(),
        _Step.pay => _payStep(),
        _Step.instapay => _instapayStep(),
        _Step.done => _doneStep(),
      },
    );
  }

  // ── Shared chrome ─────────────────────────────────────────────

  Widget _header(String kicker, String title, {VoidCallback? onBack, IconData? icon}) =>
      Container(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 8, 16, 16),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.hero, AppColors.hero2]),
        ),
        child: Row(children: [
          if (onBack != null) ...[
            _glassBtn(Icons.arrow_back_rounded, onBack),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kicker,
                  style: AppText.tag(AppColors.heroFaint)
                      .copyWith(fontSize: 11, letterSpacing: 1.5)),
              Text(title, style: AppText.stat(20, AppColors.heroInk).copyWith(height: 1.1)),
            ]),
          ),
          if (icon != null) Icon(icon, size: 24, color: AppColors.heroFaint),
        ]),
      );

  Widget _glassBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 20, color: AppColors.heroInk),
        ),
      );

  Widget _footer(Widget child) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
        decoration: const BoxDecoration(
            color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.lineSoft))),
        child: child,
      );

  Widget _totalRow() => Padding(
        padding: const EdgeInsets.only(bottom: 11),
        child: Row(children: [
          Text('TOTAL', style: AppText.tag().copyWith(fontSize: 12, letterSpacing: 0.5)),
          const Spacer(),
          Text(MockData.egp(widget.total), style: AppText.stat(20)),
        ]),
      );

  // ── Step 1: address ───────────────────────────────────────────

  Widget _addressStep() {
    final ready = _addingAddr ? _newAddrReady : _chosenId != null;
    return Column(children: [
      _header('CHECKOUT', 'Delivery address', onBack: () => Navigator.pop(context)),
      Expanded(
        child: _loadingAddr
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : ListView(
                padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 8),
                children: _addingAddr ? _addrForm() : _addrList(),
              ),
      ),
      _footer(AppButton(
        _savingAddr ? 'Saving…' : 'Deliver here',
        full: true,
        height: 52,
        icon: Icons.arrow_forward_rounded,
        onPressed: (ready && !_savingAddr) ? _deliverHere : null,
      )),
    ]);
  }

  List<Widget> _addrList() => [
        for (final a in _addresses) _addrCard(a),
        GestureDetector(
          onTap: () => setState(() => _addingAddr = true),
          child: Container(
            height: 48,
            margin: const EdgeInsets.only(top: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: AppRadius.btnR,
              border: Border.all(color: AppColors.line, style: BorderStyle.solid),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.add_rounded, size: 18, color: AppColors.ink),
              const SizedBox(width: 8),
              Text('Add a new address',
                  style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
            ]),
          ),
        ),
        if (_addresses.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text('Add where we should deliver your order.',
                textAlign: TextAlign.center, style: AppText.small()),
          ),
      ];

  IconData _addrIcon(String? label) => switch (label) {
        'Work' => Icons.work_outline_rounded,
        'Home' => Icons.home_outlined,
        _ => Icons.location_on_outlined,
      };

  Widget _addrCard(Map<String, dynamic> a) {
    final id = a['id'] as String;
    final sel = _chosenId == id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        active: sel,
        color: sel ? AppColors.surface : AppColors.surface,
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        onTap: () => setState(() => _chosenId = id),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: sel ? AppColors.primary : AppColors.field,
                borderRadius: BorderRadius.circular(11)),
            child: Icon(_addrIcon(a['label'] as String?),
                size: 20, color: sel ? AppColors.primaryInk : AppColors.inkSoft),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((a['label'] as String?)?.isNotEmpty == true
                      ? a['label'] as String
                      : (a['full_name'] as String? ?? 'Address'),
                  style: AppText.bodyStrong().copyWith(fontSize: 14)),
              const SizedBox(height: 2),
              Text('${AddressService.composeLine(a)} · ${a['city']}, ${a['governorate']}',
                  style: AppText.small().copyWith(fontSize: 12.5, height: 1.4)),
              const SizedBox(height: 2),
              Text('${a['full_name']} · ${a['phone']}',
                  style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11.5)),
            ]),
          ),
          const SizedBox(width: 8),
          Container(
            width: 21,
            height: 21,
            margin: const EdgeInsets.only(top: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: sel ? AppColors.primary : Colors.transparent,
              border: sel ? null : Border.all(color: AppColors.line, width: 2),
            ),
            child: sel
                ? const Icon(Icons.check_rounded, size: 13, color: AppColors.primaryInk)
                : null,
          ),
        ]),
      ),
    );
  }

  List<Widget> _addrForm() => [
        Row(
          children: ['Home', 'Work', 'Other'].map((l) {
            final on = _newLabel == l;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: l == 'Other' ? 0 : 8),
                child: GestureDetector(
                  onTap: () => setState(() => _newLabel = l),
                  child: Container(
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? AppColors.primary.withValues(alpha: 0.12) : AppColors.surface,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: on ? AppColors.primary : AppColors.line, width: 1.5),
                    ),
                    child: Text(l,
                        style: AppText.bodyStrong(on ? AppColors.primary : AppColors.inkSoft)
                            .copyWith(fontSize: 13)),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        _fieldLabel('Full name'),
        _input(_fullName, 'Recipient name'),
        const SizedBox(height: 12),
        _fieldLabel('Phone for the courier'),
        _input(_phone, '+20 1XX XXX XXXX', keyboard: TextInputType.phone),
        const SizedBox(height: 12),
        _fieldLabel('Governorate'),
        _govField(),
        const SizedBox(height: 12),
        _fieldLabel('City / District'),
        _input(_city, 'e.g. Maadi, Nasr City'),
        const SizedBox(height: 12),
        _fieldLabel('Area (optional)'),
        _input(_area, 'Neighbourhood / zone'),
        const SizedBox(height: 12),
        _fieldLabel('Street'),
        _input(_street, 'Street name & number'),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _fieldLabel('Building (optional)'),
              _input(_building, 'No.'),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _fieldLabel('Apartment (optional)'),
              _input(_apartment, 'No.'),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        _fieldLabel('Landmark (optional)'),
        _input(_landmark, 'Nearby landmark to help the courier'),
        const SizedBox(height: 14),
        GestureDetector(
          onTap: () => setState(() => _addingAddr = false),
          child: Text('← Use a saved address',
              style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 13)),
        ),
      ];

  Widget _govField() => Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppColors.line, width: 1.5)),
        alignment: Alignment.centerLeft,
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _governorate,
            isExpanded: true,
            isDense: true,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.inkSoft),
            style: AppText.bodyStrong().copyWith(fontSize: 14),
            dropdownColor: AppColors.surface,
            items: [
              for (final g in _governorates)
                DropdownMenuItem(value: g, child: Text(g)),
            ],
            onChanged: (v) => setState(() => _governorate = v ?? 'Cairo'),
          ),
        ),
      );

  Widget _fieldLabel(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t.toUpperCase(),
            style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10, letterSpacing: 0.6)),
      );

  Widget _input(TextEditingController c, String hint, {TextInputType? keyboard}) => Container(
        decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppColors.line, width: 1.5)),
        // contentPadding fills the box so the whole field is a tap target
        // (InputDecoration.collapsed shrank it to the text line).
        child: TextField(
          controller: c,
          keyboardType: keyboard,
          textInputAction: TextInputAction.next,
          onEditingComplete: () => FocusScope.of(context).nextFocus(),
          onChanged: (_) => setState(() {}),
          style: AppText.bodyStrong().copyWith(fontSize: 14),
          decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 15),
              hintText: hint,
              hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 14)),
        ),
      );

  // ── Step 2: payment ───────────────────────────────────────────

  Widget _payStep() {
    final note = _method == 'instapay'
        ? "Next you'll send the transfer and confirm."
        : 'Have the cash ready for the courier.';
    return Column(children: [
      _header('CHECKOUT', 'Payment method', onBack: () => setState(() => _step = _Step.address)),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 8),
          children: [
            if (_addr != null) _addrSummary(),
            _methodCard('cod', Icons.payments_outlined, 'Cash on delivery',
                'Pay the courier when it arrives'),
            _methodCard('instapay', Icons.account_balance_outlined, 'InstaPay',
                'Bank transfer via the InstaPay app'),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(children: [
                const Icon(Icons.verified_user_outlined, size: 14, color: AppColors.inkSoft),
                const SizedBox(width: 7),
                Expanded(child: Text(note, style: AppText.small().copyWith(fontSize: 11.5))),
              ]),
            ),
          ],
        ),
      ),
      _footer(Column(mainAxisSize: MainAxisSize.min, children: [
        _totalRow(),
        AppButton(
          _placing
              ? 'Placing order…'
              : (_method == 'instapay' ? 'Continue to InstaPay' : 'Place order'),
          full: true,
          height: 52,
          icon: _method == 'instapay' ? Icons.arrow_forward_rounded : Icons.check_rounded,
          onPressed: _placing
              ? null
              : () {
                  if (_method == 'instapay') {
                    setState(() => _step = _Step.instapay);
                  } else {
                    _placeOrder();
                  }
                },
        ),
      ])),
    ]);
  }

  String _addrTitle(Map<String, dynamic> a) =>
      (a['label'] as String?)?.isNotEmpty == true
          ? a['label'] as String
          : (a['full_name'] as String? ?? 'Address');

  Widget _addrSummary() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          onTap: () => setState(() => _step = _Step.address),
          child: Row(children: [
            Icon(_addrIcon(_addr!['label'] as String?), size: 19, color: AppColors.primary),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('DELIVER TO · ${_addrTitle(_addr!).toUpperCase()}',
                    style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10)),
                const SizedBox(height: 1),
                Text('${_addr!['line']} · ${_addr!['city']}, ${_addr!['governorate']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyStrong().copyWith(fontSize: 12.5)),
              ]),
            ),
            const SizedBox(width: 8),
            Text('Change', style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 12)),
          ]),
        ),
      );

  Widget _methodCard(String id, IconData icon, String title, String sub) {
    final sel = _method == id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        active: sel,
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        onTap: () => setState(() => _method = id),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: sel ? AppColors.primary : AppColors.field,
                borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, size: 22, color: sel ? AppColors.primaryInk : AppColors.inkSoft),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong().copyWith(fontSize: 14.5)),
              const SizedBox(height: 1),
              Text(sub, style: AppText.small().copyWith(fontSize: 11.5)),
            ]),
          ),
          const SizedBox(width: 8),
          Container(
            width: 21,
            height: 21,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: sel ? AppColors.primary : Colors.transparent,
              border: sel ? null : Border.all(color: AppColors.line, width: 2),
            ),
            child: sel
                ? const Icon(Icons.check_rounded, size: 13, color: AppColors.primaryInk)
                : null,
          ),
        ]),
      ),
    );
  }

  // ── Step 3: InstaPay transfer ─────────────────────────────────

  Widget _instapayStep() {
    // InstaPay orders require both the sending username and a transfer proof.
    final ready = _sender.text.trim().isNotEmpty && _proofBytes != null;
    return Column(children: [
      _header('INSTAPAY TRANSFER', 'Send payment', onBack: () => setState(() => _step = _Step.pay)),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 14, AppSpacing.screen, 8),
          children: [
            Text('Open your InstaPay app, send the total to this username, then confirm below.',
                style: AppText.small().copyWith(fontSize: 12.5, height: 1.45)),
            const SizedBox(height: 10),
            _copyField('Send to · InstaPay username', _handle, mono: true),
            const SizedBox(height: 10),
            _copyField('Amount', MockData.egp(widget.total), copyable: false),
            const SizedBox(height: 12),
            _fieldLabel("Your InstaPay username · who you're sending from"),
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: AppRadius.cardR,
                  border: Border.all(color: ready ? AppColors.primary : AppColors.line, width: 1.5)),
              child: Row(children: [
                Icon(Icons.account_balance_outlined,
                    size: 18, color: ready ? AppColors.primary : AppColors.inkFaint),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    controller: _sender,
                    onChanged: (_) => setState(() {}),
                    style: AppText.bodyStrong().copyWith(fontSize: 14.5),
                    decoration: InputDecoration.collapsed(
                        hintText: 'yourname@instapay',
                        hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 14.5)),
                  ),
                ),
                if (ready)
                  const Icon(Icons.check_circle_rounded, size: 18, color: AppColors.success),
              ]),
            ),
            const SizedBox(height: 12),
            _fieldLabel('Transaction screenshot · required'),
            _proofPicker(),
          ],
        ),
      ),
      _footer(Column(mainAxisSize: MainAxisSize.min, children: [
        AppButton(
          _placing ? 'Submitting…' : "I've sent the payment",
          full: true,
          height: 52,
          icon: Icons.check_rounded,
          onPressed: (ready && !_placing) ? _placeOrder : null,
        ),
        const SizedBox(height: 9),
        Text(
          ready
              ? "We'll match your transfer and confirm your order."
              : "Enter the username you're sending from to continue.",
          textAlign: TextAlign.center,
          style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11),
        ),
      ])),
    ]);
  }

  Widget _copyField(String label, String value,
      {bool mono = false, bool copyable = true}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.cardR,
          border: Border.all(color: AppColors.line)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.toUpperCase(),
                style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10, letterSpacing: 0.6)),
            const SizedBox(height: 2),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyStrong().copyWith(
                    fontSize: mono ? 16 : 15.5,
                    fontFeatures: mono ? const [FontFeature.tabularFigures()] : null)),
          ]),
        ),
        if (copyable) ...[
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              _toast('Copied');
            },
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.copy_rounded, size: 15, color: AppColors.primary),
                const SizedBox(width: 6),
                Text('Copy', style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 12)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _proofPicker() {
    if (_proofBytes != null) {
      return ClipRRect(
        borderRadius: AppRadius.cardR,
        child: Stack(children: [
          Image.memory(_proofBytes!, width: double.infinity, height: 140, fit: BoxFit.cover),
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => setState(() => _proofBytes = null),
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.close_rounded, size: 15, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: AppColors.success.withValues(alpha: 0.92),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_rounded, size: 13, color: Colors.white),
                const SizedBox(width: 5),
                Text('Attached',
                    style: AppText.bodyStrong(Colors.white).copyWith(fontSize: 11)),
              ]),
            ),
          ),
        ]),
      );
    }
    return GestureDetector(
      onTap: _pickProof,
      child: Container(
        height: 90,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: AppColors.field,
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppColors.line, width: 1.5)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.image_outlined, size: 26, color: AppColors.inkSoft),
          const SizedBox(height: 6),
          Text('Tap to attach a screenshot',
              style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 12.5)),
        ]),
      ),
    );
  }

  // ── Step 4: done ──────────────────────────────────────────────

  Widget _doneStep() {
    final instapay = _method == 'instapay';
    return Column(children: [
      _header('ORDER CONFIRMED', 'Thank you!'),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: const Icon(Icons.check_circle_outline_rounded, size: 50, color: AppColors.primary),
            ),
            const SizedBox(height: 18),
            Text('Order placed', style: AppText.stat(22)),
            const SizedBox(height: 6),
            Text(
              instapay
                  ? "We're verifying your transfer — you'll get a confirmation text shortly."
                  : "We'll text you a tracking link once it ships from the Cairo warehouse.",
              textAlign: TextAlign.center,
              style: AppText.small().copyWith(fontSize: 13.5, height: 1.5),
            ),
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _stat('Order', _orderRef, AppColors.ink),
              _statDivider(),
              _stat('Total', MockData.egp(widget.total), AppColors.primary),
              _statDivider(),
              _stat('Paid via', instapay ? 'InstaPay' : 'Cash', AppColors.ink),
            ]),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_circle_outline_rounded, size: 14, color: AppColors.success),
                const SizedBox(width: 6),
                Text(instapay ? 'InstaPay transfer' : 'Cash on delivery',
                    style: AppText.bodyStrong(AppColors.success).copyWith(fontSize: 11.5)),
              ]),
            ),
            if (_addr != null) ...[
              const SizedBox(height: 14),
              Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.location_on_outlined, size: 15, color: AppColors.inkSoft),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                      'Delivering to ${_addrTitle(_addr!)} · ${_addr!['line']}, ${_addr!['city']}',
                      style: AppText.small().copyWith(fontSize: 12, height: 1.4)),
                ),
              ]),
            ],
          ]),
        ),
      ),
      _footer(AppButton('Continue shopping',
          full: true,
          height: 52,
          onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst))),
    ]);
  }

  Widget _stat(String k, String v, Color c) => Column(children: [
        Text(k, style: AppText.small().copyWith(fontSize: 11)),
        const SizedBox(height: 2),
        Text(v, style: AppText.stat(15, c)),
      ]);

  Widget _statDivider() =>
      Container(width: 1, height: 30, color: AppColors.line, margin: const EdgeInsets.symmetric(horizontal: 18));
}
