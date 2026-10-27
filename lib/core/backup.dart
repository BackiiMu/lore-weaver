import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';

import 'database.dart';
import 'trash.dart';

/// Append-only restore: conflicting IDs abort the complete transaction.
class BackupService {
  final Store db;
  final Directory media;
  BackupService(this.db, this.media);
  static const columns = {
    'works': ['id', 'title', 'genre', 'body', 'updated'],
    'entities': [
      'id',
      'work',
      'kind',
      'title',
      'body',
      'data',
      'favorite',
      'updated',
    ],
    'links': ['id', 'work', 'source', 'target', 'label', 'reverse', 'directed'],
    'layouts': ['work', 'entity', 'x', 'y', 'visible'],
    'attachments': ['id', 'work', 'entity', 'name'],
    'covers': ['work', 'name'],
    'markers': ['id', 'work', 'map', 'location', 'x', 'y'],
    'drafts': ['id', 'work', 'kind', 'title', 'body', 'data'],
    'boards': ['id', 'work', 'kind', 'title'],
    'board_nodes': ['work', 'board', 'entity', 'x', 'y'],
    'catalog': ['id', 'work', 'type', 'name'],
    'trash': ['id', 'work', 'title', 'kind', 'payload', 'deleted'],
  };
  Future<List<int>> export({String? work}) async {
    final payload = <String, dynamic>{'version': 4};
    await db.transaction(() async {
      for (final t in columns.keys) {
        payload[t] = await db.rows(
          'SELECT * FROM $t${work == null
              ? ''
              : t == 'works'
              ? ' WHERE id=?'
              : ' WHERE work=?'}',
          work == null ? [] : [work],
        );
      }
    });
    final json = utf8.encode(jsonEncode(payload));
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', json.length, json));
    for (final name in mediaNames(payload)) {
      if (!safe(name)) throw const FormatException('잘못된 첨부 경로');
      if (archive.findFile('media/$name') != null) continue;
      final bytes = await File('${media.path}/$name').readAsBytes();
      archive.addFile(ArchiveFile('media/$name', bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }

  static Set<String> mediaNames(Map<String, dynamic> payload) => {
    for (final a in [...payload['attachments'], ...payload['covers']])
      a['name'] as String,
    for (final row in payload['trash'])
      ...TrashService.filesInPayload(jsonDecode(row['payload'])),
  };
  Future<BackupPreview> preview(List<int> bytes) async {
    final p = decode(bytes);
    final validation = _ValidationStore();
    try {
      await validation.transaction(() => insert(validation, p));
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      var conflicts = 0;
      for (final name in mediaNames(p)) {
        final file = archive.findFile('media/$name');
        if (!safe(name) || file == null || !file.isFile) {
          throw const FormatException('첨부파일이 누락되었거나 잘못되었습니다');
        }
        final target = File('${media.path}/$name');
        if (await target.exists() &&
            base64Encode(await target.readAsBytes()) !=
                base64Encode(file.content)) {
          conflicts++;
        }
      }
      for (final table in columns.keys) {
        for (final row in p[table]) {
          final where = table == 'layouts'
              ? 'work=? AND entity=?'
              : table == 'board_nodes'
              ? 'board=? AND entity=?'
              : table == 'covers'
              ? 'work=?'
              : 'id=?';
          final args = table == 'layouts'
              ? [row['work'], row['entity']]
              : table == 'board_nodes'
              ? [row['board'], row['entity']]
              : table == 'covers'
              ? [row['work']]
              : [row['id']];
          if ((await db.rows(
            'SELECT 1 FROM $table WHERE $where LIMIT 1',
            args,
          )).isNotEmpty) {
            conflicts++;
          }
        }
      }
      return BackupPreview(
        (p['works'] as List).map((w) => w['title'] as String).toList(),
        (p['entities'] as List).length,
        (p['links'] as List).length,
        mediaNames(p).length,
        (p['trash'] as List).length,
        conflicts,
      );
    } finally {
      await validation.close();
    }
  }

  Map<String, dynamic> decode(List<int> bytes) {
    if (bytes.length > 200 * 1024 * 1024) {
      throw const FormatException('백업은 200MB 이하여야 합니다');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    var total = 0;
    final names = <String>{};
    for (final f in archive) {
      total += f.size;
      if (total > 500 * 1024 * 1024 || !names.add(f.name)) {
        throw const FormatException('잘못되었거나 너무 큰 백업');
      }
    }
    final manifest = archive.findFile('manifest.json');
    if (manifest == null || manifest.size > 30 * 1024 * 1024) {
      throw const FormatException('잘못된 백업 정보');
    }
    final p = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(manifest.content)),
    );
    final version = p['version'];
    if (version is! int || version < 1 || version > 4) {
      throw const FormatException('지원하지 않는 백업 버전');
    }
    if (version < 2) {
      p['covers'] = [];
      p['markers'] = [];
    }
    if (version < 3) p['drafts'] = [];
    if (version < 4) {
      p['boards'] = [];
      p['board_nodes'] = [];
      p['catalog'] = [];
      p['trash'] = [];
    }
    return p;
  }

  static bool safe(String name) =>
      RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name) && !name.contains('..');
  static const entityKinds = [
    'character',
    'faction',
    'location',
    'event',
    'lore',
  ];
  void validateRow(String table, Map<String, dynamic> row) {
    final fields = columns[table];
    if (fields == null ||
        row.length != fields.length ||
        !fields.every(row.containsKey)) {
      throw const FormatException('잘못된 필드');
    }
    for (final entry in row.entries) {
      final key = entry.key, value = entry.value;
      if (['x', 'y'].contains(key)) {
        if (value is! num || !value.isFinite) {
          throw const FormatException('잘못된 좌표');
        }
      } else if (['favorite', 'directed', 'visible'].contains(key)) {
        if (value is! int || (value != 0 && value != 1)) {
          throw const FormatException('잘못된 상태 값');
        }
      } else if (['updated', 'deleted'].contains(key)) {
        if (value is! int || value < 0) {
          throw const FormatException('잘못된 수정 시점');
        }
      } else if (value is! String) {
        throw const FormatException('문자열 필드가 올바르지 않습니다');
      }
    }
    for (final key in [
      'id',
      'work',
      'source',
      'target',
      'entity',
      'board',
      'map',
      'location',
    ]) {
      if (row.containsKey(key) && (row[key] as String).trim().isEmpty) {
        throw const FormatException('자료 ID가 비어 있습니다');
      }
    }
    if (table == 'entities' || table == 'drafts') {
      if (!entityKinds.contains(row['kind']) || jsonDecode(row['data']) is! Map) {
        throw const FormatException('잘못된 자료');
      }
    }
    if (table == 'boards' && !['character', 'faction'].contains(row['kind'])) {
      throw const FormatException('알 수 없는 보드 종류');
    }
    if (table == 'catalog' && !['태그', '카테고리'].contains(row['type'])) {
      throw const FormatException('알 수 없는 분류 종류');
    }
    if (table == 'trash' && !['work', ...entityKinds].contains(row['kind'])) {
      throw const FormatException('잘못된 휴지통 자료 종류');
    }
    if ((table == 'attachments' || table == 'covers') && !safe(row['name'])) {
      throw const FormatException('잘못된 첨부 경로');
    }
  }

  Future<void> insert(Store target, Map<String, dynamic> payload) async {
    for (final table in columns.entries) {
      final values = payload[table.key];
      if (values is! List) throw FormatException('${table.key} 누락');
      if (values.length > 100000) throw const FormatException('백업 레코드 한도 초과');
      for (final raw in values) {
        if (raw is! Map) throw const FormatException('잘못된 레코드');
        final row = Map<String, dynamic>.from(raw);
        validateRow(table.key, row);
        if (table.key == 'trash') {
          final payload = jsonDecode(row['payload']);
          if (payload is! Map) throw const FormatException('잘못된 휴지통');
          for (final t in TrashService.tables) {
            if (payload[t] is! List) throw const FormatException('잘못된 휴지통 자료');
            for (final raw in payload[t]) {
              if (raw is! Map) throw const FormatException('잘못된 휴지통 레코드');
              validateRow(t, Map<String, dynamic>.from(raw));
              if (t == 'works'
                  ? raw['id'] != row['work']
                  : raw['work'] != row['work']) {
                throw const FormatException('다른 작품의 휴지통 자료');
              }
            }
          }
        }
        await target.run(
          'INSERT INTO ${table.key} (${table.value.join(',')}) VALUES (${List.filled(table.value.length, '?').join(',')})',
          table.value.map((k) => row[k]).toList(),
        );
      }
    }
    if ((await target.rows(
      'SELECT 1 FROM board_nodes n JOIN boards b ON b.id=n.board JOIN entities e ON e.id=n.entity WHERE b.kind<>e.kind LIMIT 1',
    )).isNotEmpty) {
      throw const FormatException('보드의 자료 유형이 올바르지 않습니다');
    }
  }

  Future<void> restore(List<int> bytes) async {
    final p = decode(bytes);
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final validation = _ValidationStore();
    final staged = <File>[];
    try {
      await validation.transaction(() => insert(validation, p));
      if ((await validation.rows('PRAGMA foreign_key_check')).isNotEmpty) {
        throw const FormatException('연결 무결성 오류');
      }
      for (final name in mediaNames(p)) {
        if (!safe(name)) throw const FormatException('잘못된 첨부 경로');
        final f = archive.findFile('media/$name');
        if (f == null || !f.isFile) throw const FormatException('첨부파일 누락');
        final target = File('${media.path}/$name');
        if (await target.exists()) {
          if (base64Encode(await target.readAsBytes()) !=
              base64Encode(f.content)) {
            throw const FormatException('첨부파일 충돌');
          }
        } else {
          staged.add(target);
          await target.writeAsBytes(f.content, flush: true);
        }
      }
      await db.transaction(() => insert(db, p));
    } catch (_) {
      for (final f in staged) {
        if (await f.exists()) await f.delete();
      }
      rethrow;
    } finally {
      await validation.close();
    }
  }
}

// This connection never shares an executor or file with the live database.
class _ValidationStore extends Store {
  _ValidationStore() : super(NativeDatabase.memory());
}

class BackupPreview {
  final List<String> works;
  final int entities, links, files, trash, conflicts;
  BackupPreview(
    this.works,
    this.entities,
    this.links,
    this.files,
    this.trash,
    this.conflicts,
  );
}
