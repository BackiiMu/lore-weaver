import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lore_weaver/core/database.dart';
import 'package:lore_weaver/core/backup.dart';
import 'package:lore_weaver/core/catalog.dart';
import 'package:lore_weaver/core/graph_history.dart';
import 'package:lore_weaver/core/graph_layout.dart';
import 'package:lore_weaver/core/trash.dart';

void main() {
  late Store db;
  late Directory root, media;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() async {
    db = Store(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('lore-improved-');
    media = await Directory('${root.path}/media').create();
    await db.saveWork('w', '작품', '', '');
    await db.saveWork('other', '다른 작품', '', '');
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> person(
    String id, {
    String work = 'w',
    String kind = 'character',
    Map<String, dynamic> data = const {},
  }) => db.saveEntity(id, work, kind, id, '', data);
  Future<void> board(String id, {String work = 'w'}) => db.run(
    'INSERT INTO boards VALUES (?,?,?,?)',
    [id, work, 'character', id],
  );
  test('보드별 위치와 멤버십 분리, 작품·유형 경계 차단', () async {
    await person('a');
    await person('outsider', work: 'other');
    await person('f', kind: 'faction');
    await board('first');
    await board('second');
    await db.position('w', 'a', 10, 20);
    await db.graphPosition('w', 'a', 100, 200, board: 'first');
    await db.graphPosition('w', 'a', 300, 400, board: 'second');
    await db.graphPosition('w', 'a', 0, 0, board: 'first', visible: false);
    expect(
      (await db.rows('SELECT * FROM board_nodes')).single['board'],
      'second',
    );
    expect((await db.rows('SELECT * FROM layouts')).single['x'], 10.0);
    await expectLater(
      db.graphPosition('w', 'outsider', 0, 0, board: 'second'),
      throwsA(anything),
    );
    await expectLater(
      db.graphPosition('w', 'f', 0, 0, board: 'second'),
      throwsA(isA<FormatException>()),
    );
  });
  test('이동과 관계 삭제의 취소·다시 실행은 DB에 반영된다', () async {
    await person('a');
    await person('b');
    await db.saveLink('l', 'w', 'a', 'b', '친구', '친구', false);
    final history = GraphHistory(db, 'w');
    var before = await history.capture();
    await db.position('w', 'a', 99, 88);
    await db.run('DELETE FROM links WHERE id=?', ['l']);
    history.record(before, await history.capture());
    await history.undo();
    expect(await db.rows('SELECT * FROM layouts'), isEmpty);
    expect((await db.rows('SELECT * FROM links')).single['id'], 'l');
    await history.redo();
    expect((await db.rows('SELECT * FROM layouts')).single['x'], 99.0);
    expect(await db.rows('SELECT * FROM links'), isEmpty);
    await history.undo();
    before = await history.capture();
    await db.position('w', 'a', 1, 2);
    history.record(before, await history.capture());
    expect(history.canRedo, isFalse);
  });
  test('외부 수정과 충돌하면 실행 취소가 해당 수정을 덮어쓰지 않는다', () async {
    await person('a');
    await db.position('w', 'a', 1, 2);
    final history = GraphHistory(db, 'w');
    final before = await history.capture();
    await db.position('w', 'a', 3, 4);
    history.record(before, await history.capture());
    await db.position('w', 'a', 5, 6);
    await expectLater(history.undo(), throwsA(isA<FormatException>()));
    expect((await db.rows('SELECT * FROM layouts')).single['x'], 5.0);
    expect(history.canUndo, isTrue);
  });
  test('보드 편집 취소는 다른 보드의 좌표에 영향을 주지 않는다', () async {
    await person('a');
    await board('first');
    await board('second');
    await db.graphPosition('w', 'a', 10, 20, board: 'second');
    final history = GraphHistory(db, 'w', board: 'first');
    final before = await history.capture();
    await db.graphPosition('w', 'a', 30, 40, board: 'first');
    history.record(before, await history.capture());
    await history.undo();
    expect(
      (await db.rows('SELECT * FROM board_nodes')).single['board'],
      'second',
    );
  });
  test('계층 자동 배치는 부모를 위에 놓고 순환 자료에서도 종료한다', () {
    final edges = [
      {'source': 'child', 'target': 'parent', 'label': '부모'},
      {'source': 'grandchild', 'target': 'child', 'label': '부모'},
    ];
    final p = arrangeGraph(
      ['child', 'parent', 'grandchild', 'other'],
      edges,
      GraphArrangement.hierarchy,
    );
    expect(p['parent']!.dy, lessThan(p['child']!.dy));
    expect(p['child']!.dy, lessThan(p['grandchild']!.dy));
    expect(p.values.toSet().length, 4);
    expect(
      arrangeGraph(
        ['a', 'b'],
        [
          {'source': 'a', 'target': 'b', 'label': '상위 조직'},
          {'source': 'b', 'target': 'a', 'label': '상위 조직'},
        ],
        GraphArrangement.hierarchy,
      ).length,
      2,
    );
  });
  test('겹친 두 관계선은 다른 경로이며 각 선을 선택할 수 있다', () {
    final paths = graphEdgePaths(
      [
        {'id': 'one', 'source': 'a', 'target': 'b', 'label': '친구'},
        {'id': 'two', 'source': 'a', 'target': 'b', 'label': '동료'},
      ],
      {'a': const Offset(0, 0), 'b': const Offset(400, 0)},
    );
    expect(paths[0].label, isNot(paths[1].label));
    for (final path in paths) {
      expect(hitGraphEdge(path.label, paths, 8)!['id'], path.edge['id']);
    }
  });
  test('태그 병합은 자료·초안에 반영되고 다른 작품은 유지된다', () async {
    await person('a', data: {'태그': '영웅, 주인공'});
    await person('b', data: {'태그': '영웅'});
    await person('x', work: 'other', data: {'태그': '영웅'});
    await db.run('INSERT INTO drafts VALUES (?,?,?,?,?,?)', [
      'draft',
      'w',
      'character',
      '초안',
      '',
      '{"태그":"영웅"}',
    ]);
    final service = CatalogService(db, 'w');
    await service.add('태그', '#영웅');
    expect((await service.list('태그')).keys, isNot(contains('#영웅')));
    await service.rename('태그', '영웅', '#주인공');
    expect((await service.list('태그'))['주인공'], 2);
    expect(
      jsonDecode(
        (await db.rows('SELECT data FROM drafts')).single['data'],
      )['태그'],
      '주인공',
    );
    expect(
      jsonDecode(
        (await db.rows('SELECT data FROM entities WHERE id=?', [
          'x',
        ])).single['data'],
      )['태그'],
      '영웅',
    );
    await service.rename('태그', '주인공', null);
    expect(await service.list('태그'), isEmpty);
  });
  test('카테고리 등록·일괄 변경은 설정 자료에만 적용된다', () async {
    await person('lore', kind: 'lore', data: {'카테고리': '마법'});
    await person('a', data: {'카테고리': '마법'});
    final service = CatalogService(db, 'w');
    await service.add('카테고리', '기술');
    await service.rename('카테고리', '마법', '기술');
    expect((await service.list('카테고리'))['기술'], 1);
    expect(
      jsonDecode(
        (await db.rows('SELECT data FROM entities WHERE id=?', [
          'a',
        ])).single['data'],
      )['카테고리'],
      '마법',
    );
  });
  test('인물 휴지통 복원은 관계·첨부·보드·초안을 복구한다', () async {
    await person('a');
    await person('b');
    await db.saveLink('l', 'w', 'a', 'b', '친구', '친구', false);
    await board('board');
    await db.graphPosition('w', 'a', 20, 30, board: 'board');
    await db.run('INSERT INTO drafts VALUES (?,?,?,?,?,?)', [
      'a',
      'w',
      'character',
      '초안',
      '',
      '{}',
    ]);
    await File('${media.path}/p.png').writeAsBytes([1, 2, 3]);
    await db.run('INSERT INTO attachments VALUES (?,?,?,?)', [
      'p',
      'w',
      'a',
      'p.png',
    ]);
    final trash = TrashService(db);
    await trash.removeEntity('a');
    expect(await db.rows('SELECT * FROM links'), isEmpty);
    expect(await trash.referencedFiles(), contains('p.png'));
    final record = (await db.rows('SELECT * FROM trash')).single;
    await trash.restore(record['id']);
    expect((await db.rows('SELECT * FROM links')).single['id'], 'l');
    expect((await db.rows('SELECT * FROM board_nodes')).single['entity'], 'a');
    expect((await db.rows('SELECT * FROM drafts')).single['title'], '초안');
    expect(await db.rows('SELECT * FROM trash'), isEmpty);
  });
  test('작품 휴지통도 첨부 포함 백업·복원이 가능하다', () async {
    await person('a');
    await board('b');
    await db.graphPosition('w', 'a', 12, 34, board: 'b');
    await File('${media.path}/p.png').writeAsBytes([7, 8]);
    await db.run('INSERT INTO attachments VALUES (?,?,?,?)', [
      'p',
      'w',
      'a',
      'p.png',
    ]);
    await TrashService(db).removeWork('w');
    final bytes = await BackupService(db, media).export();
    final target = Store(NativeDatabase.memory());
    final targetMedia = await Directory('${root.path}/restored').create();
    try {
      await BackupService(target, targetMedia).restore(bytes);
      final trash = (await target.rows('SELECT * FROM trash')).single;
      await TrashService(target).restore(trash['id']);
      expect(
        (await target.rows('SELECT * FROM board_nodes')).single['x'],
        12.0,
      );
      expect(await File('${targetMedia.path}/p.png').readAsBytes(), [7, 8]);
      expect(await target.rows('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await target.close();
    }
  });
  test('복원 대상 연결이 없으면 전체 복구를 취소하고 휴지통을 보존한다', () async {
    await person('a');
    await person('b');
    await db.saveLink('l', 'w', 'a', 'b', '친구', '친구', false);
    final service = TrashService(db);
    await service.removeEntity('a');
    final id = (await db.rows('SELECT * FROM trash')).single['id'];
    await service.removeEntity('b');
    await expectLater(service.restore(id), throwsA(anything));
    expect(await db.rows('SELECT * FROM entities'), isEmpty);
    expect((await db.rows('SELECT * FROM trash')).length, 2);
  });
  test('백업 미리보기는 충돌 건수를 알려주고 데이터를 변경하지 않는다', () async {
    await person('a');
    await board('board');
    await db.graphPosition('w', 'a', 1, 2, board: 'board');
    await CatalogService(db, 'w').add('태그', '주인공');
    final service = BackupService(db, media),
        bytes = await BackupService(db, media).export();
    final preview = await service.preview(bytes);
    expect(preview.works.length, 2);
    expect(preview.entities, 1);
    expect(preview.conflicts, greaterThan(0));
    expect((await db.rows('SELECT * FROM entities')).length, 1);
    final target = Store(NativeDatabase.memory());
    try {
      final backup = BackupService(target, media);
      expect((await backup.preview(bytes)).conflicts, 0);
      expect(await target.rows('SELECT * FROM works'), isEmpty);
      await backup.restore(bytes);
      expect(
        (await target.rows('SELECT * FROM board_nodes')).single['board'],
        'board',
      );
      expect(
        (await target.rows('SELECT * FROM catalog')).single['name'],
        '주인공',
      );
    } finally {
      await target.close();
    }
  });
  test('작품 복제는 보드·카탈로그를 새 ID로 연결한다', () async {
    await person('a');
    await board('b');
    await db.graphPosition('w', 'a', 100, 200, board: 'b');
    await CatalogService(db, 'w').add('태그', '주인공');
    final copy = await db.duplicate('w');
    expect(
      (await db.rows('SELECT * FROM boards WHERE work=?', [copy])).single['id'],
      isNot('b'),
    );
    expect(
      (await db.rows('SELECT * FROM board_nodes WHERE work=?', [
        copy,
      ])).single['entity'],
      isNot('a'),
    );
    expect(
      (await db.rows('SELECT * FROM catalog WHERE work=?', [
        copy,
      ])).single['name'],
      '주인공',
    );
  });
  test('스키마 v2 파일에서 v3로 업그레이드할 때 기존 좌표 보존', () async {
    final file = File('${root.path}/old.sqlite');
    final old = _V2Store(NativeDatabase(file));
    await old.saveWork('old', '이전 작품', '', '');
    await old.saveEntity('a', 'old', 'character', '인물', '', {});
    await old.position('old', 'a', 55, 66);
    await old.close();
    final upgraded = Store.file(file);
    try {
      expect(
        (await upgraded.rows('PRAGMA user_version')).single['user_version'],
        3,
      );
      expect((await upgraded.rows('SELECT * FROM layouts')).single['x'], 55.0);
      expect(await upgraded.rows('SELECT * FROM boards'), isEmpty);
      expect(await upgraded.rows('SELECT * FROM trash'), isEmpty);
    } finally {
      await upgraded.close();
    }
  });
}

class _V2Store extends Store {
  _V2Store(super.e);
  @override
  int get schemaVersion => 2;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      for (final sql in Store.schema.where(
        (s) => !Store.additionsV3.contains(s),
      )) {
        await customStatement(sql);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys=ON');
    },
  );
}
