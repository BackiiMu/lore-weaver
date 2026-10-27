import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:uuid/uuid.dart';

class Store extends GeneratedDatabase {
  Store(super.e);
  factory Store.file(File file) =>
      Store(NativeDatabase.createInBackground(file));
  @override
  int get schemaVersion => 3;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      for (final sql in schema) {
        await customStatement(sql);
      }
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        for (final sql in additionsV2) {
          await customStatement(sql);
        }
      }
      if (from < 3) {
        for (final sql in additionsV3) {
          await customStatement(sql);
        }
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
  static const additionsV2 = [
    'CREATE TABLE covers (work TEXT PRIMARY KEY REFERENCES works(id) ON DELETE CASCADE, name TEXT NOT NULL)',
    'CREATE TABLE markers (id TEXT PRIMARY KEY, work TEXT NOT NULL, map TEXT NOT NULL, location TEXT NOT NULL, x REAL NOT NULL CHECK(x>=0 AND x<=1), y REAL NOT NULL CHECK(y>=0 AND y<=1), FOREIGN KEY(work,map) REFERENCES entities(work,id) ON DELETE CASCADE, FOREIGN KEY(work,location) REFERENCES entities(work,id) ON DELETE CASCADE)',
    'CREATE TABLE drafts (id TEXT PRIMARY KEY, work TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, data TEXT NOT NULL)',
  ];
  static const additionsV3 = [
    'CREATE TABLE catalog (id TEXT PRIMARY KEY, work TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE, type TEXT NOT NULL, name TEXT NOT NULL, UNIQUE(work,type,name))',
    'CREATE TABLE boards (id TEXT PRIMARY KEY, work TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE, kind TEXT NOT NULL, title TEXT NOT NULL, UNIQUE(work,id))',
    'CREATE TABLE board_nodes (work TEXT NOT NULL, board TEXT NOT NULL, entity TEXT NOT NULL, x REAL NOT NULL, y REAL NOT NULL, PRIMARY KEY(board,entity), FOREIGN KEY(work,board) REFERENCES boards(work,id) ON DELETE CASCADE, FOREIGN KEY(work,entity) REFERENCES entities(work,id) ON DELETE CASCADE)',
    'CREATE TABLE trash (id TEXT PRIMARY KEY, work TEXT NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, deleted INTEGER NOT NULL)',
  ];
  static const schema = [
    'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT NOT NULL, genre TEXT NOT NULL DEFAULT \'\', body TEXT NOT NULL DEFAULT \'\', updated INTEGER NOT NULL)',
    'CREATE TABLE entities (id TEXT PRIMARY KEY, work TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL DEFAULT \'\', data TEXT NOT NULL DEFAULT \'{}\', favorite INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL, UNIQUE(work,id))',
    'CREATE INDEX entity_search ON entities(work,kind,updated)',
    'CREATE TABLE links (id TEXT PRIMARY KEY, work TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE, source TEXT NOT NULL, target TEXT NOT NULL, label TEXT NOT NULL, reverse TEXT NOT NULL DEFAULT \'\', directed INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(work,source) REFERENCES entities(work,id) ON DELETE CASCADE, FOREIGN KEY(work,target) REFERENCES entities(work,id) ON DELETE CASCADE, CHECK(source <> target))',
    'CREATE TABLE layouts (work TEXT NOT NULL, entity TEXT NOT NULL, x REAL NOT NULL, y REAL NOT NULL, visible INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(work,entity), FOREIGN KEY(work,entity) REFERENCES entities(work,id) ON DELETE CASCADE)',
    ...additionsV2,
    ...additionsV3,
    'CREATE TABLE attachments (id TEXT PRIMARY KEY, work TEXT NOT NULL, entity TEXT NOT NULL, name TEXT NOT NULL, FOREIGN KEY(work,entity) REFERENCES entities(work,id) ON DELETE CASCADE)',
  ];
  Future<List<Map<String, dynamic>>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) async => (await customSelect(
    sql,
    variables: args.map((e) => Variable(e)).toList(),
  ).get()).map((e) => e.data).toList();
  Future<void> run(String sql, [List<Object?> args = const []]) =>
      customStatement(sql, args);
  String id() => const Uuid().v4();
  int now() => DateTime.now().millisecondsSinceEpoch;
  Future<void> saveWork(String id, String title, String genre, String body) =>
      run(
        'INSERT INTO works (id,title,genre,body,updated) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,genre=excluded.genre,body=excluded.body,updated=excluded.updated',
        [id, title, genre, body, now()],
      );
  Future<void> saveEntity(
    String id,
    String work,
    String kind,
    String title,
    String body,
    Map<String, dynamic> data, {
    bool favorite = false,
  }) async {
    await transaction(() async {
      await run(
        'INSERT INTO entities VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,body=excluded.body,data=excluded.data,favorite=excluded.favorite,updated=excluded.updated WHERE entities.work=excluded.work',
        [
          id,
          work,
          kind,
          title,
          body,
          jsonEncode(data),
          favorite ? 1 : 0,
          now(),
        ],
      );
      await run('UPDATE works SET updated=? WHERE id=?', [now(), work]);
    });
  }

  Future<void> saveLink(
    String id,
    String work,
    String source,
    String target,
    String label,
    String reverse,
    bool directed,
  ) async {
    final previous = await rows('SELECT work,source FROM links WHERE id=?', [
      id,
    ]);
    if (previous.isNotEmpty &&
        (previous.single['work'] != work ||
            previous.single['source'] != source)) {
      throw const FormatException('다른 자료의 연결 ID를 변경할 수 없습니다');
    }
    final hierarchy = {
      '상위 조직': 'faction',
      '상위 지역': 'location',
      '선행 사건': 'event',
    };
    final requiredKind = hierarchy[label];
    if (requiredKind != null) {
      final ends = await rows(
        'SELECT id,kind FROM entities WHERE work=? AND (id=? OR id=?)',
        [work, source, target],
      );
      if (ends.length != 2 || ends.any((e) => e['kind'] != requiredKind)) {
        throw const FormatException('계층 연결은 같은 유형의 서로 다른 자료를 선택하세요');
      }
      final cycle = await rows(
        'WITH RECURSIVE ancestors(id) AS (SELECT ? UNION SELECT l.target FROM links l JOIN ancestors a ON l.source=a.id WHERE l.work=? AND l.label=? AND l.id<>?) SELECT id FROM ancestors WHERE id=? LIMIT 1',
        [target, work, label, id, source],
      );
      if (cycle.isNotEmpty) {
        throw const FormatException('순환하는 계층 또는 사건 선후관계는 만들 수 없습니다');
      }
    }
    await run(
      'INSERT INTO links VALUES (?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET target=excluded.target,label=excluded.label,reverse=excluded.reverse,directed=excluded.directed',
      [id, work, source, target, label, reverse, directed ? 1 : 0],
    );
  }

  Future<void> position(
    String work,
    String entity,
    double x,
    double y, {
    bool visible = true,
  }) => run(
    'INSERT INTO layouts VALUES (?,?,?,?,?) ON CONFLICT(work,entity) DO UPDATE SET x=excluded.x,y=excluded.y,visible=excluded.visible',
    [work, entity, x, y, visible ? 1 : 0],
  );
  Future<void> graphPosition(
    String work,
    String entity,
    double x,
    double y, {
    String? board,
    bool visible = true,
  }) async {
    if (board == null) {
      await position(work, entity, x, y, visible: visible);
      return;
    }
    final valid = await rows(
      'SELECT 1 FROM boards b JOIN entities e ON e.work=b.work AND e.kind=b.kind WHERE b.id=? AND b.work=? AND e.id=?',
      [board, work, entity],
    );
    if (valid.isEmpty) throw const FormatException('이 보드에 추가할 수 없는 자료입니다');
    if (!visible) {
      await run('DELETE FROM board_nodes WHERE board=? AND entity=?', [
        board,
        entity,
      ]);
      return;
    }
    await run(
      'INSERT INTO board_nodes VALUES (?,?,?,?,?) ON CONFLICT(board,entity) DO UPDATE SET x=excluded.x,y=excluded.y',
      [work, board, entity, x, y],
    );
  }

  Future<String> duplicate(String work) async {
    final w = (await rows('SELECT * FROM works WHERE id=?', [work])).single;
    final newId = id();
    await transaction(() async {
      await saveWork(newId, '${w['title']} (복사)', w['genre'], w['body']);
      final mapping = <String, String>{};
      for (final e in await rows('SELECT * FROM entities WHERE work=?', [
        work,
      ])) {
        final n = id();
        mapping[e['id']] = n;
        await saveEntity(
          n,
          newId,
          e['kind'],
          e['title'],
          e['body'],
          jsonDecode(e['data']),
          favorite: e['favorite'] == 1,
        );
      }
      for (final l in await rows('SELECT * FROM links WHERE work=?', [work])) {
        await run('INSERT INTO links VALUES (?,?,?,?,?,?,?)', [
          id(),
          newId,
          mapping[l['source']],
          mapping[l['target']],
          l['label'],
          l['reverse'],
          l['directed'],
        ]);
      }
      for (final l in await rows('SELECT * FROM layouts WHERE work=?', [
        work,
      ])) {
        await position(
          newId,
          mapping[l['entity']]!,
          l['x'],
          l['y'],
          visible: l['visible'] == 1,
        );
      }
      for (final tag in await rows('SELECT * FROM catalog WHERE work=?', [
        work,
      ])) {
        await run('INSERT INTO catalog VALUES (?,?,?,?)', [
          id(),
          newId,
          tag['type'],
          tag['name'],
        ]);
      }
      for (final b in await rows('SELECT * FROM boards WHERE work=?', [work])) {
        final newBoard = id();
        await run('INSERT INTO boards VALUES (?,?,?,?)', [
          newBoard,
          newId,
          b['kind'],
          b['title'],
        ]);
        for (final n in await rows('SELECT * FROM board_nodes WHERE board=?', [
          b['id'],
        ])) {
          await graphPosition(
            newId,
            mapping[n['entity']]!,
            n['x'],
            n['y'],
            board: newBoard,
          );
        }
      }
      for (final a in await rows('SELECT * FROM covers WHERE work=?', [work])) {
        await run('INSERT INTO covers VALUES (?,?)', [newId, a['name']]);
      }
      for (final a in await rows('SELECT * FROM markers WHERE work=?', [
        work,
      ])) {
        await run('INSERT INTO markers VALUES (?,?,?,?,?,?)', [
          id(),
          newId,
          mapping[a['map']],
          mapping[a['location']],
          a['x'],
          a['y'],
        ]);
      }
      for (final a in await rows('SELECT * FROM attachments WHERE work=?', [
        work,
      ])) {
        await run('INSERT INTO attachments VALUES (?,?,?,?)', [
          id(),
          newId,
          mapping[a['entity']],
          a['name'],
        ]);
      }
    });
    return newId;
  }
}
