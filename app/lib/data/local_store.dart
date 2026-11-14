// 个人资料存储接口。登入后存服务器（RemoteStore）；游客模式只在内存（MemoryStore）。
// SqlCipherStore 是旧版的本机加密数据库：只用来把登入前留下的记录搬到账户，搬完即删除。
// 原始报告图片从不保存、不上传。

import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/auth.dart';
import 'remote_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

class SavedReport {
  final String id;
  final String? testDate;
  final DateTime savedAt;
  final String reportType;
  final List<Map<String, dynamic>> items; // LabItem.toJson()
  final Map<String, dynamic> answers;
  final Map<String, dynamic>? analysis; // 保存时的解读快照（含规则版本）
  final List<Map<String, dynamic>> messages; // 对话记录

  const SavedReport({
    required this.id,
    required this.testDate,
    required this.savedAt,
    required this.reportType,
    required this.items,
    required this.answers,
    this.analysis,
    this.messages = const [],
  });

  String get overallLevel =>
      (analysis?['overall'] as Map?)?['level'] as String? ?? 'unknown';

  Map<String, Object?> toRow() => {
    'id': id,
    'test_date': testDate,
    'saved_at': savedAt.toIso8601String(),
    'report_type': reportType,
    'payload': jsonEncode({
      'items': items,
      'answers': answers,
      'analysis': analysis,
      'messages': messages,
    }),
  };

  factory SavedReport.fromRow(Map<String, Object?> r) {
    final payload = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
    return SavedReport(
      id: r['id'] as String,
      testDate: r['test_date'] as String?,
      savedAt: DateTime.parse(r['saved_at'] as String),
      reportType: r['report_type'] as String,
      items: (payload['items'] as List).cast<Map<String, dynamic>>(),
      answers: (payload['answers'] as Map).cast<String, dynamic>(),
      analysis: (payload['analysis'] as Map?)?.cast<String, dynamic>(),
      messages: ((payload['messages'] as List?) ?? const [])
          .cast<Map<String, dynamic>>(),
    );
  }
}

abstract class LocalStore {
  Future<void> saveReport(SavedReport r);
  Future<List<SavedReport>> listReports();
  Future<void> deleteReport(String id);
  Future<void> deleteAll();
  Future<String?> getSetting(String key);
  Future<void> putSetting(String key, String value);
}

class SqlCipherStore implements LocalStore {
  Database? _db;
  final String _fileName, _keyName;
  SqlCipherStore() : _fileName = 'medilens.db', _keyName = 'medilens_db_key';

  /// Dedicated device-test database and keystore entry; never touches the user's store.
  SqlCipherStore.forTesting()
    : _fileName = 'medilens_device_test.db',
      _keyName = 'medilens_device_test_key';
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<Database> get _database async {
    if (_db != null) return _db!;
    const secure = FlutterSecureStorage();
    var key = await secure.read(key: _keyName);
    if (key == null) {
      final rnd = Random.secure();
      key = base64UrlEncode(List<int>.generate(32, (_) => rnd.nextInt(256)));
      await secure.write(key: _keyName, value: key);
    }
    final path = p.join(await getDatabasesPath(), _fileName);
    _db = await openDatabase(
      path,
      password: key,
      version: 1,
      onCreate: (db, v) async {
        await db.execute(
          'CREATE TABLE reports (id TEXT PRIMARY KEY, test_date TEXT, saved_at TEXT, report_type TEXT, payload TEXT)',
        );
        await db.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)',
        );
      },
    );
    return _db!;
  }

  /// 本机已有的全部设置（登入后把旧记录搬到账户用）。
  Future<Map<String, String>> allSettings() async {
    final rows = await (await _database).query('settings');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  /// 搬到账户后彻底删除本机数据库文件与密钥（之后资料只存在服务器）。
  Future<void> wipe() async {
    await close();
    await deleteDatabase(p.join(await getDatabasesPath(), _fileName));
    await const FlutterSecureStorage().delete(key: _keyName);
  }

  /// 本机是否有旧数据库（不会因为检查而新建）。
  Future<bool> exists() async => databaseExists(p.join(await getDatabasesPath(), _fileName));

  @override
  Future<void> saveReport(SavedReport r) async => (await _database).insert(
    'reports',
    r.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<List<SavedReport>> listReports() async {
    final rows = await (await _database).query(
      'reports',
      orderBy: 'test_date DESC, saved_at DESC',
    );
    return rows.map(SavedReport.fromRow).toList();
  }

  @override
  Future<void> deleteReport(String id) async =>
      (await _database).delete('reports', where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> deleteAll() async => (await _database).delete('reports');

  @override
  Future<String?> getSetting(String key) async {
    final rows = await (await _database).query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  Future<void> putSetting(String key, String value) async =>
      (await _database).insert('settings', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// 内存实现：用于测试，以及「不保存」模式下的会话。
class MemoryStore implements LocalStore {
  final Map<String, SavedReport> reports = {};
  final Map<String, String> settings = {};

  @override
  Future<void> saveReport(SavedReport r) async => reports[r.id] = r;
  @override
  Future<List<SavedReport>> listReports() async {
    final l = reports.values.toList();
    l.sort((a, b) => (b.testDate ?? '').compareTo(a.testDate ?? ''));
    return l;
  }

  @override
  Future<void> deleteReport(String id) async => reports.remove(id);
  @override
  Future<void> deleteAll() async => reports.clear();
  @override
  Future<String?> getSetting(String key) async => settings[key];
  @override
  Future<void> putSetting(String key, String value) async =>
      settings[key] = value;
}

/// 游客模式：资料只在内存，关闭 APP 即消失。
final guestStoreProvider = Provider<LocalStore>((ref) => MemoryStore());

/// 个人资料存储：登入后存服务器（按账户分开），未登入为游客模式（不在本机留下任何资料）。
final localStoreProvider = Provider<LocalStore>((ref) {
  final token = ref.watch(authProvider.select((a) => a.token));
  return token == null
      ? ref.watch(guestStoreProvider)
      : RemoteStore(ref.watch(accountApiProvider), onExpired: () => ref.read(authProvider.notifier).expired());
});

/// 历史列表（保存/删除后需 invalidate）。
final historyProvider = FutureProvider<List<SavedReport>>(
  (ref) => ref.watch(localStoreProvider).listReports(),
);
