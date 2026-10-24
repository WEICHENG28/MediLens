// 本机加密存储实机测试（SQLCipher + 系统安全存储密钥）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medilens/data/local_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('加密数据库：保存、读取、单条删除、全部删除、设置', (t) async {
    final store = SqlCipherStore();
    await store.deleteAll();
    SavedReport r(String id, String date) => SavedReport(
          id: id,
          testDate: date,
          savedAt: DateTime.now(),
          reportType: 'urinalysis',
          items: [
            {'original_label': '尿蛋白', 'raw_value': '1+', 'review_status': 'confirmed'},
          ],
          answers: {'q_sglt2': '__skip__'},
        );
    await store.saveReport(r('a', '2026-01-01'));
    await store.saveReport(r('b', '2026-10-01'));
    final list = await store.listReports();
    expect(list.map((e) => e.id), ['b', 'a']); // 按检验日期倒序
    expect(list.first.items.first['raw_value'], '1+');

    await store.deleteReport('a');
    expect((await store.listReports()).length, 1);
    await store.deleteAll();
    expect(await store.listReports(), isEmpty);

    await store.putSetting('k', 'v');
    expect(await store.getSetting('k'), 'v');

    // 数据库文件确实被加密：文件头不是明文 SQLite 标识
    final path = p.join(await getDatabasesPath(), 'medilens.db');
    final head = String.fromCharCodes((await File(path).openRead(0, 16).first).take(15));
    expect(head, isNot('SQLite format 3'));
  });
}
