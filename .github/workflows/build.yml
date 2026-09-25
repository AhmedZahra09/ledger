import 'package:flutter/material.dart';

import '../database.dart';
import '../dialogs.dart';
import '../models.dart';
import '../theme.dart';
import 'customer_profile_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _db = AppDatabase.instance;
  List<Customer> _customers = [];
  int _owedToMe = 0, _iOwe = 0;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await _db.getCustomers(query: _query);
    final t = await _db.getTotals();
    if (!mounted) return;
    setState(() {
      _customers = c;
      _owedToMe = t.$1;
      _iOwe = t.$2;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الدفتر الرقمي'),
        actions: [
          IconButton(
            icon: const Icon(Icons.mic),
            tooltip: 'إدخال سريع',
            onPressed: () async {
              if (await showVoiceEntryDialog(context)) _load();
            },
          ),
        ],
      ),
      body: Column(children: [
        _totalsCard(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'ابحث بالاسم أو رقم الهاتف',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) {
              _query = v;
              _load();
            },
          ),
        ),
        Expanded(
          child: _customers.isEmpty
              ? const Center(child: Text('لا يوجد زبائن بعد'))
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 90),
                  itemCount: _customers.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _tile(_customers[i]),
                ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('زبون جديد'),
        onPressed: () async {
          if (await showAddCustomerDialog(context)) _load();
        },
      ),
    );
  }

  Widget _totalsCard() => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 4))],
        ),
        child: Row(children: [
          _total('إجمالي الأموال التي لك', _owedToMe, kGreen),
          Container(width: 1, height: 44, color: Colors.grey.shade300),
          _total('إجمالي الأموال التي عليك', _iOwe, kRed),
        ]),
      );

  Widget _total(String label, int v, Color c) => Expanded(
        child: Column(children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 4),
          Text(fmt(v), style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: c)),
        ]),
      );

  Widget _tile(Customer c) {
    final color = c.balance > 0 ? kGreen : c.balance < 0 ? kRed : Colors.grey;
    final label = c.balance > 0 ? 'لك' : c.balance < 0 ? 'عليك' : 'مسدد';
    return ListTile(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => CustomerProfileScreen(customerId: c.id)),
        );
        _load();
      },
      leading: CircleAvatar(
        backgroundColor: kGreen.withOpacity(0.12),
        child: Text(c.name.substring(0, 1), style: const TextStyle(color: kGreen)),
      ),
      title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(c.lastTxAt == null ? 'لا معاملات' : 'آخر معاملة: ${fmtDate(c.lastTxAt!)}'),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(fmt(c.balance.abs()), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}
