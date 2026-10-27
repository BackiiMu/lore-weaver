import 'dart:convert';

import 'database.dart';

List<String> parseTags(String value) => value
    .split(RegExp(r'[,，\n]'))
    .map((s) => s.trim().replaceFirst(RegExp(r'^#+'), ''))
    .where((s) => s.isNotEmpty)
    .toSet()
    .toList();

class CatalogService {
  final Store db;
  final String work;
  CatalogService(this.db, this.work);
  Future<Map<String, int>> list(String type) async {
    final result = <String, int>{};
    for (final r in await db.rows(
      'SELECT name FROM catalog WHERE work=? AND type=?',
      [work, type],
    )) {
      result[r['name']] = 0;
    }
    for (final e in await db.rows(
      'SELECT kind,data FROM entities WHERE work=?',
      [work],
    )) {
      if (type == '카테고리' && e['kind'] != 'lore') continue;
      final data = jsonDecode(e['data']);
      final values = type == '태그'
          ? parseTags('${data[type] ?? ''}')
          : ['${data[type] ?? ''}'.trim()];
      for (final name in values.where((s) => s.isNotEmpty)) {
        result.update(name, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return Map.fromEntries(
      result.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  Future<void> add(String type, String name) async {
    name = name.trim();
    if (name.isEmpty) throw const FormatException('이름을 입력하세요');
    if (type == '태그' && parseTags(name).length != 1) {
      throw const FormatException('태그를 한 개씩 등록하세요');
    }
    if (type == '태그') name = parseTags(name).single;
    await db.run(
      'INSERT INTO catalog VALUES (?,?,?,?) ON CONFLICT(work,type,name) DO NOTHING',
      [db.id(), work, type, name],
    );
  }

  Future<void> rename(String type, String old, String? replacement) async {
    var name = replacement?.trim();
    if (type == '태그' && name != null) {
      final tags = parseTags(name);
      if (tags.length != 1) throw const FormatException('태그를 한 개씩 입력하세요');
      name = tags.single;
    }

    if (name != null && name.isEmpty) throw const FormatException('이름을 입력하세요');
    await db.transaction(() async {
      if (name != null) await add(type, name);
      for (final table in ['entities', 'drafts']) {
        for (final e in await db.rows('SELECT * FROM $table WHERE work=?', [
          work,
        ])) {
          if (type == '카테고리' && e['kind'] != 'lore') continue;
          final data = Map<String, dynamic>.from(jsonDecode(e['data']));
          if (type == '태그') {
            final tags = parseTags('${data[type] ?? ''}');
            if (!tags.contains(old)) continue;
            data[type] = tags
                .expand(
                  (t) => t == old ? (name == null ? <String>[] : [name]) : [t],
                )
                .toSet()
                .join(', ');
          } else {
            if (data[type] != old) continue;
            if (name == null) {
              data.remove(type);
            } else {
              data[type] = name;
            }
          }
          if (table == 'entities') {
            await db.saveEntity(
              e['id'],
              work,
              e['kind'],
              e['title'],
              e['body'],
              data,
              favorite: e['favorite'] == 1,
            );
          } else {
            await db.run('UPDATE drafts SET data=? WHERE id=?', [
              jsonEncode(data),
              e['id'],
            ]);
          }
        }
      }
      if (old != name) {
        await db.run('DELETE FROM catalog WHERE work=? AND type=? AND name=?', [
          work,
          type,
          old,
        ]);
      }
    });
  }
}
