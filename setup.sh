#!/bin/bash
set -e
cat > 'pubspec.yaml' << 'LEDGER_EOF'
name: digital_ledger
description: الدفتر الرقمي - Digital Ledger
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.3.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:
    sdk: flutter
  sqflite: ^2.3.3
  path: ^1.9.0
  uuid: ^4.4.0
  intl: any
  pdf: ^3.11.0
  path_provider: ^2.1.3
  share_plus: ^10.0.0
  url_launcher: ^6.3.0
  another_telephony: ^0.4.1

flutter:
  uses-material-design: true
  fonts:
    - family: Cairo
      fonts:
        - asset: assets/fonts/Cairo-Regular.ttf
        - asset: assets/fonts/Cairo-Bold.ttf
          weight: 700
LEDGER_EOF
mkdir -p 'lib'
cat > 'lib/database.dart' << 'LEDGER_EOF'
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

/// قاعدة البيانات المحلية (Offline-First).
/// - المعرّفات UUID نصية لتفادي تعارض المزامنة لاحقاً.
/// - المبالغ أعداد صحيحة (أصغر وحدة تتعامل بها) لتفادي أخطاء الفاصلة العائمة.
/// - sync_status: 0 = بحاجة للمزامنة، 1 = تمت المزامنة.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();
  static const _uuid = Uuid();

  Database? _db;
  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'ledger.db');
    return openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        final b = db.batch();
        b.execute('''
          CREATE TABLE customers(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            phone TEXT,
            current_balance INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            last_tx_at INTEGER,
            sync_status INTEGER NOT NULL DEFAULT 0
          )''');
        b.execute('''
          CREATE TABLE transactions(
            id TEXT PRIMARY KEY,
            customer_id TEXT NOT NULL,
            amount INTEGER NOT NULL CHECK(amount > 0),
            type TEXT NOT NULL CHECK(type IN ('GAVE','GOT')),
            note TEXT,
            created_at INTEGER NOT NULL,
            sync_status INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(customer_id) REFERENCES customers(id) ON DELETE CASCADE
          )''');
        b.execute('CREATE INDEX idx_tx_customer ON transactions(customer_id, created_at DESC)');
        b.execute('CREATE INDEX idx_customers_last ON customers(last_tx_at DESC)');
        b.execute('CREATE INDEX idx_customers_name ON customers(name)');
        await b.commit(noResult: true);
      },
    );
  }

  // ---------- الزبائن ----------

  Future<String> addCustomer(String name, String? phone) async {
    final db = await database;
    final id = _uuid.v4();
    final p = phone?.trim();
    await db.insert('customers', {
      'id': id,
      'name': name.trim(),
      'phone': (p == null || p.isEmpty) ? null : p,
      'current_balance': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'sync_status': 0,
    });
    return id;
  }

  /// الأحدث معاملة أولاً، مع بحث اختياري بالاسم أو الهاتف.
  Future<List<Customer>> getCustomers({String query = ''}) async {
    final db = await database;
    final q = query.trim();
    final rows = await db.query(
      'customers',
      where: q.isEmpty ? null : 'name LIKE ? OR phone LIKE ?',
      whereArgs: q.isEmpty ? null : ['%$q%', '%$q%'],
      orderBy: 'COALESCE(last_tx_at, created_at) DESC',
    );
    return rows.map(Customer.fromMap).toList();
  }

  Future<Customer?> getCustomer(String id) async {
    final db = await database;
    final rows = await db.query('customers', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Customer.fromMap(rows.first);
  }

  /// بحث بالاسم (لمطابقة الإدخال الصوتي ورسائل SMS).
  Future<List<Customer>> findCustomersByName(String name) async {
    final db = await database;
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return [];
    final where = words.map((_) => 'name LIKE ?').join(' AND ');
    final rows = await db.query(
      'customers',
      where: where,
      whereArgs: words.map((w) => '%$w%').toList(),
      orderBy: 'COALESCE(last_tx_at, created_at) DESC',
    );
    return rows.map(Customer.fromMap).toList();
  }

  /// (إجمالي لك، إجمالي عليك)
  Future<(int, int)> getTotals() async {
    final db = await database;
    final r = await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN current_balance > 0 THEN current_balance END), 0) AS owed_to_me,
        COALESCE(SUM(CASE WHEN current_balance < 0 THEN -current_balance END), 0) AS i_owe
      FROM customers''');
    return (r.first['owed_to_me'] as int, r.first['i_owe'] as int);
  }

  // ---------- المعاملات ----------

  /// إضافة معاملة + تحديث الرصيد في transaction واحدة (ذرّياً).
  Future<String> addTransaction({
    required String customerId,
    required int amount,
    required String type,
    String note = '',
    DateTime? at,
  }) async {
    if (amount <= 0) throw ArgumentError('amount must be > 0');
    final db = await database;
    final id = _uuid.v4();
    final ts = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final delta = type == TxType.gave ? amount : -amount;

    await db.transaction((txn) async {
      await txn.insert('transactions', {
        'id': id,
        'customer_id': customerId,
        'amount': amount,
        'type': type,
        'note': note.trim(),
        'created_at': ts,
        'sync_status': 0,
      });
      final n = await txn.rawUpdate('''
        UPDATE customers
        SET current_balance = current_balance + ?,
            last_tx_at = MAX(COALESCE(last_tx_at, 0), ?),
            sync_status = 0
        WHERE id = ?''', [delta, ts, customerId]);
      if (n == 0) throw StateError('customer not found: $customerId');
    });
    return id;
  }

  Future<List<LedgerTx>> getTransactions(String customerId) async {
    final db = await database;
    final rows = await db.query(
      'transactions',
      where: 'customer_id = ?',
      whereArgs: [customerId],
      orderBy: 'created_at DESC',
    );
    return rows.map(LedgerTx.fromMap).toList();
  }

  /// حذف معاملة مع عكس أثرها على الرصيد.
  Future<void> deleteTransaction(String txId) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('transactions', where: 'id = ?', whereArgs: [txId], limit: 1);
      if (rows.isEmpty) return;
      final t = LedgerTx.fromMap(rows.first);
      final delta = t.type == TxType.gave ? -t.amount : t.amount;
      await txn.delete('transactions', where: 'id = ?', whereArgs: [txId]);
      await txn.rawUpdate(
        'UPDATE customers SET current_balance = current_balance + ?, sync_status = 0 WHERE id = ?',
        [delta, t.customerId],
      );
    });
  }
}
LEDGER_EOF
mkdir -p 'lib'
cat > 'lib/dialogs.dart' << 'LEDGER_EOF'
import 'package:flutter/material.dart';

import 'database.dart';
import 'models.dart';
import 'services/sms_parser.dart';
import 'services/voice_parser.dart';
import 'theme.dart';

int? parseAmount(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final sb = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final d = ar.indexOf(ch);
    sb.write(d >= 0 ? '$d' : ch);
  }
  return int.tryParse(sb.toString().replaceAll(RegExp(r'[^\d]'), ''));
}

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

Future<bool> showAddCustomerDialog(BuildContext context) async {
  final name = TextEditingController();
  final phone = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('زبون جديد'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم')),
        const SizedBox(height: 10),
        TextField(
          controller: phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'رقم الهاتف (اختياري)'),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isNotEmpty) Navigator.pop(c, true);
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await AppDatabase.instance.addCustomer(name.text, phone.text);
    return true;
  }
  return false;
}

/// شاشة إدخال معاملة (أعطيته / قبضت).
Future<bool> showAddTxSheet(BuildContext context, String customerId, String type) async {
  final amount = TextEditingController();
  final note = TextEditingController();
  final isGave = type == TxType.gave;
  final color = isGave ? kRed : kGreen;

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(c).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(isGave ? 'أعطيته (آجل)' : 'قبضت منه (سداد)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 14),
        TextField(
          controller: amount,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'المبلغ'),
        ),
        const SizedBox(height: 10),
        TextField(controller: note, decoration: const InputDecoration(labelText: 'البيان (اختياري)')),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: color, padding: const EdgeInsets.all(14)),
            onPressed: () {
              final v = parseAmount(amount.text);
              if (v == null || v <= 0) return;
              Navigator.pop(c, true);
            },
            child: const Text('حفظ'),
          ),
        ),
      ]),
    ),
  );
  if (saved == true) {
    await AppDatabase.instance.addTransaction(
      customerId: customerId,
      amount: parseAmount(amount.text)!,
      type: type,
      note: note.text,
    );
    return true;
  }
  return false;
}

/// إدخال نصي/صوتي: الصق أو أملِ الجملة (زر الميكروفون في لوحة المفاتيح) ثم يُحلَّل.
Future<bool> showVoiceEntryDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('إدخال سريع'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: 'مثال: عثمان أحمد أخذ اثنين كيلو سكر بـ 5000 آجل',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('تحليل')),
      ],
    ),
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return false;

  final e = VoiceLedgerParser.parse(text);
  if (!e.isComplete) {
    _snack(context, 'لم أفهم الجملة كاملة. تأكد من ذكر الاسم والمبلغ و(آجل/سداد).');
    return false;
  }

  final db = AppDatabase.instance;
  final matches = await db.findCustomersByName(e.customerName!);
  if (!context.mounted) return false;
  final existing = matches.isNotEmpty ? matches.first : null;
  final isGave = e.type == TxType.gave;

  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('تأكيد المعاملة'),
      content: Text(
        '${isGave ? 'آجل (أعطيته)' : 'سداد (قبضت)'} بمبلغ ${fmt(e.amount!)}\n'
        'الزبون: ${existing?.name ?? '${e.customerName} (جديد)'}\n'
        '${e.note.isEmpty ? '' : 'البيان: ${e.note}'}',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('تسجيل')),
      ],
    ),
  );
  if (ok != true) return false;

  final id = existing?.id ?? await db.addCustomer(e.customerName!, null);
  await db.addTransaction(
    customerId: id,
    amount: e.amount!.round(),
    type: e.type!,
    note: e.note,
  );
  return true;
}

/// إشعار تحويل بنكي وارد.
Future<bool> showTransferDialog(BuildContext context, IncomingTransfer t) async {
  final db = AppDatabase.instance;
  Customer? target;
  if ((t.sender ?? '').isNotEmpty) {
    final m = await db.findCustomersByName(t.sender!);
    if (m.isNotEmpty) target = m.first;
  }
  if (!context.mounted) return false;

  target ??= await _pickCustomer(context);
  if (target == null || !context.mounted) return false;

  final chosen = target;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('تحويل وارد'),
      content: Text(
        'وصلك تحويل بمبلغ ${fmt(t.amount)}، هل تريد تسجيلها كعملية سداد لحساب ${chosen.name}؟',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('لا')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kGreen),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('نعم، سجّل'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await db.addTransaction(
    customerId: chosen.id,
    amount: t.amount.round(),
    type: TxType.got,
    note: 'تحويل بنكي${t.sender == null ? '' : ' من ${t.sender}'}',
  );
  return true;
}

Future<Customer?> _pickCustomer(BuildContext context) async {
  final all = await AppDatabase.instance.getCustomers();
  if (!context.mounted) return null;
  return showDialog<Customer>(
    context: context,
    builder: (c) => SimpleDialog(
      title: const Text('لأي زبون هذا التحويل؟'),
      children: [
        for (final x in all)
          SimpleDialogOption(onPressed: () => Navigator.pop(c, x), child: Text(x.name)),
        if (all.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('لا يوجد زبائن بعد')),
      ],
    ),
  );
}
LEDGER_EOF
mkdir -p 'lib'
cat > 'lib/main.dart' << 'LEDGER_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/dashboard_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LedgerApp());
}

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'الدفتر الرقمي',
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(),
      home: const DashboardScreen(),
    );
  }
}
LEDGER_EOF
mkdir -p 'lib'
cat > 'lib/models.dart' << 'LEDGER_EOF'
/// أنواع المعاملات.
/// GAVE = أعطيته (آجل/دين)  → يزيد الرصيد (الزبون مدين لك)
/// GOT  = قبضت منه (سداد)   → ينقص الرصيد
class TxType {
  static const gave = 'GAVE';
  static const got = 'GOT';
}

/// الرصيد الموجب = الزبون عليه لك (أخضر)، السالب = لك عليك (أحمر).
class Customer {
  final String id;
  final String name;
  final String? phone;
  final int balance;
  final int createdAt;
  final int? lastTxAt;

  const Customer({
    required this.id,
    required this.name,
    this.phone,
    required this.balance,
    required this.createdAt,
    this.lastTxAt,
  });

  factory Customer.fromMap(Map<String, Object?> m) => Customer(
        id: m['id'] as String,
        name: m['name'] as String,
        phone: m['phone'] as String?,
        balance: m['current_balance'] as int,
        createdAt: m['created_at'] as int,
        lastTxAt: m['last_tx_at'] as int?,
      );
}

class LedgerTx {
  final String id;
  final String customerId;
  final int amount;
  final String type;
  final String note;
  final int createdAt;

  const LedgerTx({
    required this.id,
    required this.customerId,
    required this.amount,
    required this.type,
    required this.note,
    required this.createdAt,
  });

  bool get isGave => type == TxType.gave;

  factory LedgerTx.fromMap(Map<String, Object?> m) => LedgerTx(
        id: m['id'] as String,
        customerId: m['customer_id'] as String,
        amount: m['amount'] as int,
        type: m['type'] as String,
        note: (m['note'] as String?) ?? '',
        createdAt: m['created_at'] as int,
      );
}
LEDGER_EOF
mkdir -p 'lib'
cat > 'lib/theme.dart' << 'LEDGER_EOF'
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

const kGreen = Color(0xFF1B5E20);
const kRed = Color(0xFFC62828);
const kStoreName = 'متجري'; // TODO: اجعله إعداداً يغيّره المستخدم

final _money = NumberFormat('#,##0', 'en');
String fmt(num v) => _money.format(v);
String fmtDate(int ms) =>
    DateFormat('dd/MM/yyyy', 'en').format(DateTime.fromMillisecondsSinceEpoch(ms));

ThemeData buildTheme() => ThemeData(
      useMaterial3: true,
      fontFamily: 'Cairo',
      colorScheme: ColorScheme.fromSeed(seedColor: kGreen),
      scaffoldBackgroundColor: const Color(0xFFF6F7F5),
      appBarTheme: const AppBarTheme(
        backgroundColor: kGreen,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
LEDGER_EOF
mkdir -p 'lib/screens'
cat > 'lib/screens/customer_profile_screen.dart' << 'LEDGER_EOF'
import 'package:flutter/material.dart';

import '../database.dart';
import '../dialogs.dart';
import '../models.dart';
import '../services/statement_service.dart';
import '../theme.dart';
import 'summary_card.dart';

class CustomerProfileScreen extends StatefulWidget {
  final String customerId;
  const CustomerProfileScreen({super.key, required this.customerId});
  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
  final _db = AppDatabase.instance;
  Customer? _c;
  List<LedgerTx> _txs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await _db.getCustomer(widget.customerId);
    final t = await _db.getTransactions(widget.customerId);
    if (!mounted) return;
    setState(() {
      _c = c;
      _txs = t;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final color = c.balance > 0 ? kGreen : c.balance < 0 ? kRed : Colors.grey;
    final label = c.balance > 0 ? 'الصافي لك' : c.balance < 0 ? 'الصافي عليك' : 'الحساب مسدد';

    return Scaffold(
      appBar: AppBar(
        title: Text(c.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => _onMenu(v, c),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pdf', child: Text('مشاركة كشف PDF')),
              PopupMenuItem(value: 'image', child: Text('مشاركة صورة ملخص')),
              PopupMenuItem(value: 'wa', child: Text('تذكير عبر واتساب')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 4))],
          ),
          child: Column(children: [
            if (c.phone != null) Text(c.phone!, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(color: color)),
            Text(fmt(c.balance.abs()), style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
        Expanded(
          child: _txs.isEmpty
              ? const Center(child: Text('لا توجد معاملات بعد'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _txs.length,
                  itemBuilder: (_, i) => _txTile(_txs[i]),
                ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: _actionButton('أعطيته (آجل)', kRed, TxType.gave)),
            const SizedBox(width: 12),
            Expanded(child: _actionButton('قبضت منه (سداد)', kGreen, TxType.got)),
          ]),
        ),
      ),
    );
  }

  Widget _actionButton(String text, Color color, String type) => FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: () async {
          if (await showAddTxSheet(context, widget.customerId, type)) _load();
        },
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );

  Widget _txTile(LedgerTx t) {
    final color = t.isGave ? kRed : kGreen;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onLongPress: () => _confirmDelete(t),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: BorderDirectional(start: BorderSide(color: color, width: 4)),
          ),
          child: Row(children: [
            Icon(t.isGave ? Icons.arrow_upward : Icons.arrow_downward, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.isGave ? 'أعطيته (آجل)' : 'قبضت (سداد)',
                    style: TextStyle(fontWeight: FontWeight.w600, color: color)),
                if (t.note.isNotEmpty) Text(t.note, style: const TextStyle(fontSize: 12)),
                Text(fmtDate(t.createdAt), style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ]),
            ),
            Text(fmt(t.amount), style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(LedgerTx t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('حذف المعاملة؟'),
        content: const Text('سيتم عكس أثرها على الرصيد.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('حذف')),
        ],
      ),
    );
    if (ok == true) {
      await _db.deleteTransaction(t.id);
      _load();
    }
  }

  Future<void> _onMenu(String v, Customer c) async {
    switch (v) {
      case 'pdf':
        await StatementService.sharePdf(customer: c, txs: _txs);
      case 'wa':
        if (c.phone == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أضف رقم هاتف للزبون أولاً')));
          return;
        }
        final ok = await StatementService.openWhatsApp(
          phone: c.phone!,
          text: StatementService.reminderText(c),
        );
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذّر فتح واتساب')));
        }
      case 'image':
        final key = GlobalKey();
        await showDialog<void>(
          context: context,
          builder: (d) => Dialog(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              RepaintBoundary(key: key, child: StatementSummaryCard(customer: c, lastTxs: _txs)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  icon: const Icon(Icons.share),
                  label: const Text('مشاركة'),
                  onPressed: () => StatementService.shareWidgetImage(key, name: 'summary_${c.id}'),
                ),
              ),
            ]),
          ),
        );
    }
  }
}
LEDGER_EOF
mkdir -p 'lib/screens'
cat > 'lib/screens/dashboard_screen.dart' << 'LEDGER_EOF'
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../database.dart';
import '../dialogs.dart';
import '../models.dart';
import '../services/sms_watcher.dart';
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
    if (Platform.isAndroid) _startSms();
  }

  Future<void> _startSms() async {
    try {
      await SmsWatcher.start(onTransfer: (t) async {
        if (!mounted) return;
        if (await showTransferDialog(context, t)) _load();
      });
    } catch (_) {/* الصلاحية مرفوضة أو غير مدعومة */}
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
LEDGER_EOF
mkdir -p 'lib/screens'
cat > 'lib/screens/summary_card.dart' << 'LEDGER_EOF'
import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// بطاقة ملخص قابلة للتحويل إلى صورة ومشاركتها عبر واتساب.
class StatementSummaryCard extends StatelessWidget {
  final Customer customer;
  final List<LedgerTx> lastTxs;
  const StatementSummaryCard({super.key, required this.customer, required this.lastTxs});

  @override
  Widget build(BuildContext context) {
    final net = customer.balance;
    final color = net > 0 ? kRed : kGreen;
    final label = net > 0 ? 'المبلغ المطلوب سداده' : net < 0 ? 'الرصيد لصالحك' : 'الحساب مسدد';
    return Container(
      width: 340,
      padding: const EdgeInsets.all(20),
      color: Colors.white, // خلفية صلبة حتى لا تكون الصورة شفافة
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(kStoreName, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: kGreen)),
        const SizedBox(height: 4),
        Text('كشف حساب: ${customer.name}', style: const TextStyle(fontSize: 14)),
        Text(fmtDate(DateTime.now().millisecondsSinceEpoch),
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const Divider(height: 24),
        for (final t in lastTxs.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(
                child: Text(t.note.isNotEmpty ? t.note : (t.isGave ? 'آجل' : 'سداد'),
                    style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
              ),
              Text('${t.isGave ? '+' : '-'}${fmt(t.amount)}',
                  style: TextStyle(fontSize: 12, color: t.isGave ? kRed : kGreen)),
            ]),
          ),
        const Divider(height: 24),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(children: [
            Text(label, style: TextStyle(color: color)),
            Text(fmt(net.abs()), style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
      ]),
    );
  }
}
LEDGER_EOF
mkdir -p 'lib/services'
cat > 'lib/services/sms_parser.dart' << 'LEDGER_EOF'
/// استخراج المبلغ والمحوِّل من رسالة تحويل بنكي واردة.
/// عدّل الأنماط لتناسب صيغ رسائل بنوك/محافظ بلدك (اجمع 10 رسائل حقيقية واختبرها).
class IncomingTransfer {
  final num amount;
  final String? sender;
  final String? account;
  final String raw;
  const IncomingTransfer({required this.amount, this.sender, this.account, required this.raw});
}

class SmsTransferParser {
  static final _incoming = RegExp(
    r'(تم\s*استلام|وصلك|وصلتك|ايداع|إيداع|حوالة\s*واردة|تحويل\s*وارد|استلمت|received|credited)',
    caseSensitive: false,
  );
  static final _outgoing = RegExp(r'(خصم|سحب|مشتريات|debited|withdraw|purchase)', caseSensitive: false);

  static const _num = r'(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?';
  static final _amtCurrency = RegExp(
    '$_num\\s*(?:ريال|ر\\.?\\s?ي|ر\\.?\\s?س|SAR|YER|جنيه|EGP|SDG|دينار|درهم|AED|USD|\\\$)',
    caseSensitive: false,
  );
  static final _amtKeyword = RegExp(
    '(?:مبلغ|قدره|قدرها|بقيمة|amount)\\s*[:：]?\\s*$_num',
    caseSensitive: false,
  );
  static final _sender = RegExp(
    r'(?:^|\s)(?:من|المحول|المرسل|from)\s*[:：]?\s*([^\d\n\r,،.:]{2,40}?)(?=\s*(?:برقم|رقم|حساب|بتاريخ|عبر|رصيد|مبلغ|بمبلغ|الى|إلى|\d|$|[\n\r.,،]))',
    caseSensitive: false,
  );
  static final _account = RegExp(r'(?:حساب|رقم|acc(?:ount)?\.?)\s*[:：]?\s*([\d*xX]{4,})', caseSensitive: false);

  static IncomingTransfer? parse(String body) {
    final text = _digits(body);
    if (!_incoming.hasMatch(text) || _outgoing.hasMatch(text)) return null;

    final m = _amtCurrency.firstMatch(text) ?? _amtKeyword.firstMatch(text);
    if (m == null) return null;
    final amount = num.tryParse('${m.group(1)!.replaceAll(',', '')}${m.group(2) ?? ''}');
    if (amount == null || amount <= 0) return null;

    return IncomingTransfer(
      amount: amount,
      sender: _sender.firstMatch(text)?.group(1)?.trim(),
      account: _account.firstMatch(text)?.group(1),
      raw: body,
    );
  }

  static String _digits(String s) {
    const ar = '٠١٢٣٤٥٦٧٨٩';
    final sb = StringBuffer();
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      final d = ar.indexOf(ch);
      sb.write(d >= 0 ? '$d' : (ch == '٬' ? ',' : ch));
    }
    return sb.toString();
  }
}
LEDGER_EOF
mkdir -p 'lib/services'
cat > 'lib/services/sms_watcher.dart' << 'LEDGER_EOF'
import 'package:another_telephony/telephony.dart';

import 'sms_parser.dart';

/// يستمع للرسائل الواردة (أندرويد فقط، والتطبيق في المقدمة).
/// ملاحظة: سياسة Google Play تقيّد صلاحيات SMS؛ راجع README.
class SmsWatcher {
  static final Telephony _t = Telephony.instance;

  static Future<bool> start({
    required void Function(IncomingTransfer) onTransfer,
    Set<String> allowedSenders = const {}, // أسماء/أرقام مرسلي البنوك
  }) async {
    final ok = await _t.requestSmsPermissions ?? false;
    if (!ok) return false;
    _t.listenIncomingSms(
      onNewMessage: (SmsMessage m) {
        final addr = (m.address ?? '').toLowerCase();
        if (allowedSenders.isNotEmpty &&
            !allowedSenders.any((s) => addr.contains(s.toLowerCase()))) {
          return;
        }
        final t = SmsTransferParser.parse(m.body ?? '');
        if (t != null) onTransfer(t);
      },
      listenInBackground: false,
    );
    return true;
  }
}
LEDGER_EOF
mkdir -p 'lib/services'
cat > 'lib/services/statement_service.dart' << 'LEDGER_EOF'
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../theme.dart';

class StatementService {
  /// كشف حساب PDF بالعربية (RTL). يحتاج خط Cairo في assets/fonts.
  static Future<Uint8List> buildPdf({
    required String storeName,
    required Customer customer,
    required List<LedgerTx> txs,
  }) async {
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));

    final sorted = [...txs]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var running = 0;
    final rows = <List<String>>[];
    for (final t in sorted) {
      running += t.isGave ? t.amount : -t.amount;
      rows.add([
        fmtDate(t.createdAt),
        t.note.isNotEmpty ? t.note : (t.isGave ? 'آجل' : 'سداد'),
        t.isGave ? fmt(t.amount) : '-',
        t.isGave ? '-' : fmt(t.amount),
        fmt(running),
      ]);
    }

    final net = customer.balance;
    final netLabel = net > 0
        ? 'الصافي المطلوب سداده: ${fmt(net)}'
        : net < 0
            ? 'الرصيد لصالح الزبون: ${fmt(-net)}'
            : 'الحساب مسدد بالكامل';
    final netColor = net > 0 ? PdfColors.red800 : PdfColors.green800;

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          textDirection: pw.TextDirection.rtl,
          theme: pw.ThemeData.withFont(base: regular, bold: bold),
        ),
        build: (ctx) => [
          pw.Text(storeName, style: pw.TextStyle(font: bold, fontSize: 22)),
          pw.SizedBox(height: 4),
          pw.Text('كشف حساب: ${customer.name}', style: const pw.TextStyle(fontSize: 14)),
          pw.Text('التاريخ: ${fmtDate(DateTime.now().millisecondsSinceEpoch)}',
              style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
          pw.SizedBox(height: 16),
          pw.TableHelper.fromTextArray(
            headers: ['التاريخ', 'البيان', 'أعطيته', 'قبضت منه', 'الرصيد المتبقي'],
            data: rows,
            headerStyle: pw.TextStyle(font: bold, color: PdfColors.white, fontSize: 11),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.green900),
            cellStyle: const pw.TextStyle(fontSize: 10),
            cellAlignment: pw.Alignment.center,
            oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
          ),
          pw.SizedBox(height: 20),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: net > 0 ? PdfColors.red50 : PdfColors.green50,
              border: pw.Border.all(color: netColor, width: 1.2),
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Text(netLabel,
                style: pw.TextStyle(font: bold, fontSize: 16, color: netColor)),
          ),
        ],
      ),
    );
    return doc.save();
  }

  static Future<void> sharePdf({
    required Customer customer,
    required List<LedgerTx> txs,
    String storeName = kStoreName,
  }) async {
    final bytes = await buildPdf(storeName: storeName, customer: customer, txs: txs);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/statement_${customer.id}.pdf');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/pdf')],
      text: 'كشف حساب ${customer.name}',
    );
  }

  /// يفتح واتساب برسالة تذكير. countryCode مثال: '967' لليمن، '249' للسودان.
  static Future<bool> openWhatsApp({
    required String phone,
    required String text,
    String countryCode = '967',
  }) async {
    var d = phone.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('00')) {
      d = d.substring(2);
    } else if (d.startsWith('0')) {
      d = '$countryCode${d.substring(1)}';
    }
    final uri = Uri.parse('https://wa.me/$d?text=${Uri.encodeComponent(text)}');
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static String reminderText(Customer c, {String storeName = kStoreName}) =>
      'السلام عليكم ${c.name}،\n'
      'نذكّرك بأن المبلغ المتبقي في حسابك لدى $storeName هو ${fmt(c.balance)}.\n'
      'شكراً لتعاونك 🌹';

  /// يلتقط ويجعل الويدجت صورة PNG ويشاركها.
  static Future<void> shareWidgetImage(GlobalKey key, {String name = 'summary'}) async {
    final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name.png');
    await file.writeAsBytes(data!.buffer.asUint8List());
    await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')]);
  }
}
LEDGER_EOF
mkdir -p 'lib/services'
cat > 'lib/services/voice_parser.dart' << 'LEDGER_EOF'
/// محلل النص الصوتي (بعد Speech-to-Text) إلى معاملة منظّمة.
/// أمثلة:
///  "عثمان أحمد أخذ اثنين كيلو سكر بـ 5000 آجل"
///   → {customer_name: عثمان أحمد, amount: 5000, type: GAVE, note: اثنين كيلو سكر}
///  "دفع لي محمد علي مبلغ 10000 سداد"
///   → {customer_name: محمد علي, amount: 10000, type: GOT, note: null}
class ParsedEntry {
  final String? customerName;
  final num? amount;
  final String? type; // GAVE | GOT
  final String note;
  final String original;

  const ParsedEntry({
    this.customerName,
    this.amount,
    this.type,
    this.note = '',
    required this.original,
  });

  bool get isComplete =>
      (customerName ?? '').isNotEmpty && (amount ?? 0) > 0 && type != null;

  Map<String, dynamic> toJson() => {
        'customer_name': customerName,
        'amount': amount,
        'type': type,
        'note': note.isEmpty ? null : note,
      };
}

class VoiceLedgerParser {
  // الكلمات بعد التطبيع (بدون همزات/تشكيل).
  static const _got = {'دفع', 'سداد', 'سدد', 'قبضت', 'استلمت', 'حول', 'وصلني'};
  static const _gave = {'اخذ', 'اجل', 'دين', 'جاب', 'استلف', 'سلف', 'اعطيته', 'ادان'};
  static const _fillers = {
    'لي', 'له', 'لها', 'لهم', 'من', 'الى', 'الي', 'على', 'عليه',
    'مبلغ', 'بمبلغ', 'بقيمة', 'قيمة', 'ب', 'فلوس',
  };
  static const _markers = {'ب', 'مبلغ', 'بمبلغ', 'بقيمة', 'قيمة'};

  static final _numRe = RegExp(r'^\d[\d,]*(\.\d+)?$');

  static const _units = <String, int>{
    'واحد': 1, 'اثنين': 2, 'اثنان': 2, 'ثلاثة': 3, 'ثلاث': 3, 'اربعة': 4, 'اربع': 4,
    'خمسة': 5, 'خمس': 5, 'ستة': 6, 'ست': 6, 'سبعة': 7, 'سبع': 7, 'ثمانية': 8,
    'ثمان': 8, 'تسعة': 9, 'تسع': 9, 'عشرة': 10, 'عشر': 10,
    'عشرين': 20, 'ثلاثين': 30, 'اربعين': 40, 'خمسين': 50,
    'ستين': 60, 'سبعين': 70, 'ثمانين': 80, 'تسعين': 90,
  };
  static const _mult = <String, int>{
    'الف': 1000, 'الاف': 1000, 'الفين': 2000, 'مليون': 1000000, 'ملايين': 1000000,
  };
  static final Map<String, int> _hundreds = _buildHundreds();

  static Map<String, int> _buildHundreds() {
    final m = <String, int>{
      'ميتين': 200, 'مئتين': 200, 'مائتين': 200,
    };
    for (final s in ['مية', 'ميه', 'مئة', 'مائة']) {
      m[s] = 100;
    }
    const bases = {
      'ثلاث': 3, 'اربع': 4, 'خمس': 5, 'ست': 6, 'سبع': 7, 'ثمان': 8, 'ثمن': 8, 'تسع': 9,
    };
    bases.forEach((b, n) {
      for (final s in ['مية', 'ميه', 'مئة', 'مائة']) {
        m['$b$s'] = n * 100;
      }
    });
    return m;
  }

  static bool _isKeyword(String t) => _got.contains(t) || _gave.contains(t);
  static bool _isNumberToken(String t) =>
      _numRe.hasMatch(t) ||
      _units.containsKey(t) ||
      _hundreds.containsKey(t) ||
      _mult.containsKey(t);

  static ParsedEntry parse(String input) {
    final tokens = _normalize(input)
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    // 1) النوع: السداد له الأولوية إن وُجدت كلمتان متعارضتان.
    String? type;
    if (tokens.any(_got.contains)) {
      type = 'GOT';
    } else if (tokens.any(_gave.contains)) {
      type = 'GAVE';
    }

    // 2) المبلغ
    final consumed = <int>{};
    num? amount;

    final numIdx = <int>[
      for (var i = 0; i < tokens.length; i++)
        if (_numRe.hasMatch(tokens[i])) i
    ];
    if (numIdx.isNotEmpty) {
      int pick = numIdx.last;
      for (final i in numIdx) {
        if (i > 0 && _markers.contains(tokens[i - 1])) pick = i;
      }
      amount = num.parse(tokens[pick].replaceAll(',', ''));
      consumed.add(pick);
      if (pick > 0 && _markers.contains(tokens[pick - 1])) consumed.add(pick - 1);
      // "5 الاف"
      if (pick + 1 < tokens.length && _mult.containsKey(tokens[pick + 1])) {
        amount = amount * _mult[tokens[pick + 1]]!;
        consumed.add(pick + 1);
      }
    } else {
      // مبلغ بالكلمات: نبحث عنه فقط بعد كلمة مفتاحية (ب / مبلغ) لتفادي "اثنين كيلو".
      final m = tokens.indexWhere(_markers.contains);
      if (m >= 0) {
        final (value, used) = _parseWords(tokens.sublist(m + 1));
        if (used > 0) {
          amount = value;
          consumed.add(m);
          for (var k = 1; k <= used; k++) {
            consumed.add(m + k);
          }
        }
      }
    }

    // 3) اسم الزبون: أول مقطع متصل من الكلمات بعد تجاوز الكلمات المفتاحية والحشو.
    var i = 0;
    while (i < tokens.length &&
        (_isKeyword(tokens[i]) || _fillers.contains(tokens[i]))) {
      i++;
    }
    final nameTokens = <String>[];
    while (i < tokens.length &&
        !_isKeyword(tokens[i]) &&
        !_fillers.contains(tokens[i]) &&
        !_isNumberToken(tokens[i])) {
      nameTokens.add(tokens[i]);
      i++;
    }

    // 4) البيان: ما تبقى بعد الاسم بدون الكلمات المفتاحية وأجزاء المبلغ.
    final noteTokens = <String>[
      for (var k = i; k < tokens.length; k++)
        if (!consumed.contains(k) && !_isKeyword(tokens[k])) tokens[k]
    ];
    while (noteTokens.isNotEmpty && _fillers.contains(noteTokens.first)) {
      noteTokens.removeAt(0);
    }
    while (noteTokens.isNotEmpty && _fillers.contains(noteTokens.last)) {
      noteTokens.removeLast();
    }

    return ParsedEntry(
      customerName: nameTokens.isEmpty ? null : nameTokens.join(' '),
      amount: amount,
      type: type,
      note: noteTokens.join(' '),
      original: input,
    );
  }

  /// يحوّل أرقاماً منطوقة ("خمسة الاف وخمسمية") إلى رقم. يرجع (القيمة، عدد الكلمات).
  static (num, int) _parseWords(List<String> tokens) {
    num total = 0, cur = 0;
    var used = 0;
    for (final raw in tokens) {
      var w = raw;
      final known = _units.containsKey(w) || _hundreds.containsKey(w) || _mult.containsKey(w);
      if (!known && w.startsWith('و') && w.length > 2) w = w.substring(1);
      if (_units.containsKey(w)) {
        cur += _units[w]!;
      } else if (_hundreds.containsKey(w)) {
        final v = _hundreds[w]!;
        cur = v == 100 ? (cur == 0 ? 1 : cur) * 100 : cur + v;
      } else if (_mult.containsKey(w)) {
        final v = _mult[w]!;
        if (v == 2000) {
          total += 2000;
        } else {
          total += (cur == 0 ? 1 : cur) * v;
          cur = 0;
        }
      } else {
        break;
      }
      used++;
    }
    return (used == 0 ? 0 : total + cur, used);
  }

  static String _normalize(String s) {
    const ar = '٠١٢٣٤٥٦٧٨٩', fa = '۰۱۲۳۴۵۶۷۸۹';
    final sb = StringBuffer();
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      var d = ar.indexOf(ch);
      if (d < 0) d = fa.indexOf(ch);
      sb.write(d >= 0 ? '$d' : ch);
    }
    var t = sb
        .toString()
        .replaceAll(RegExp('[\u064B-\u065F\u0670\u0640]'), '') // تشكيل + تطويل
        .replaceAll(RegExp('[أإآ]'), 'ا')
        .replaceAll('٬', ',')
        .replaceAll('،', ' ');
    // فصل الحروف عن الأرقام: "ب5000" → "ب 5000"
    t = t.replaceAllMapped(RegExp(r'([^\d\s.,])(\d)'), (m) => '${m[1]} ${m[2]}');
    t = t.replaceAllMapped(RegExp(r'(\d)([^\d\s.,])'), (m) => '${m[1]} ${m[2]}');
    return t.trim();
  }
}
LEDGER_EOF
