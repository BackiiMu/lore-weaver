import 'dart:convert';

import 'database.dart';

class TrashService {
  final Store db;
  TrashService(this.db);
  static const tables = [
    'works',
    'entities',
    'links',
    'layouts',
    'attachments',
    'covers',
    'markers',
    'drafts',
    'boards',
    'board_nodes',
    'catalog',
  ];
  Future<void> removeWork(String work) async {
    await db.transaction(() async {
      final works = await db.rows('SELECT * FROM works WHERE id=?', [work]);
      if (works.isEmpty) return;
      final payload = <String, dynamic>{};
      for (final table in tables) {
        payload[table] = await db.rows(
          'SELECT * FROM $table WHERE ${table == 'works' ? 'id' : 'work'}=?',
          [work],
        );
      }
      await db.run('INSERT INTO trash VALUES (?,?,?,?,?,?)', [
        db.id(),
        work,
        works.single['title'],
        'work',
        jsonEncode(payload),
        db.now(),
      ]);
      await db.run('DELETE FROM works WHERE id=?', [work]);
    });
  }

  Future<void> removeEntity(String id) async {
    await db.transaction(() async {
      final entities = await db.rows('SELECT * FROM entities WHERE id=?', [id]);
      if (entities.isEmpty) return;
      final entity = entities.single;
      final payload = <String, dynamic>{for (final t in tables) t: <dynamic>[]};
      payload['entities'] = entities;
      for (final table in ['layouts', 'attachments', 'board_nodes']) {
        payload[table] = await db.rows('SELECT * FROM $table WHERE entity=?', [
          id,
        ]);
      }
      payload['links'] = await db.rows(
        'SELECT * FROM links WHERE source=? OR target=?',
        [id, id],
      );
      payload['markers'] = await db.rows(
        'SELECT * FROM markers WHERE map=? OR location=?',
        [id, id],
      );
      payload['drafts'] = await db.rows('SELECT * FROM drafts WHERE id=?', [
        id,
      ]);
      await db.run('INSERT INTO trash VALUES (?,?,?,?,?,?)', [
        db.id(),
        entity['work'],
        entity['title'],
        entity['kind'],
        jsonEncode(payload),
        db.now(),
      ]);
      await db.run('DELETE FROM drafts WHERE id=?', [id]);
      await db.run('DELETE FROM entities WHERE id=?', [id]);
    });
  }

  Future<void> restore(String id) async {
    await db.transaction(() async {
      final records = await db.rows('SELECT * FROM trash WHERE id=?', [id]);
      if (records.isEmpty) throw const FormatException('휴지통에 자료가 없습니다');
      final p = Map<String, dynamic>.from(
        jsonDecode(records.single['payload']),
      );
      final work = records.single['work'];
      if ((p['works'] as List).isEmpty &&
          (await db.rows('SELECT id FROM works WHERE id=?', [work])).isEmpty) {
        throw const FormatException('먼저 이 자료가 속한 작품을 휴지통에서 복원하세요');
      }
      for (final table in tables) {
        for (final raw in p[table] as List) {
          final row = Map<String, dynamic>.from(raw);
          await db.run(
            'INSERT INTO $table (${row.keys.join(',')}) VALUES (${List.filled(row.length, '?').join(',')})',
            row.values.toList(),
          );
        }
      }
      await db.run('DELETE FROM trash WHERE id=?', [id]);
    });
  }

  static Set<String> filesInPayload(Map<String, dynamic> p) => {
    for (final a in [...?p['attachments'] as List?, ...?p['covers'] as List?])
      a['name'] as String,
  };
  Future<Set<String>> referencedFiles() async {
    final used = (await db.rows(
      'SELECT name FROM attachments UNION SELECT name FROM covers',
    )).map((r) => r['name'] as String).toSet();
    for (final t in await db.rows('SELECT payload FROM trash')) {
      used.addAll(filesInPayload(jsonDecode(t['payload'])));
    }
    return used;
  }
}
