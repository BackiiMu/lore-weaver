import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lore_weaver/core/database.dart';
import 'package:lore_weaver/core/backup.dart';

void main() {
  // All test connections use distinct files or independent in-memory executors.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  late Store db;
  late Directory root, media;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lore-test-');
    media = await Directory('${root.path}/media').create();
    db = Store.file(File('${root.path}/test.sqlite'));
    await db.saveWork('w1', '첫 작품', '', '');
    await db.saveWork('w2', '둘째 작품', '', '');
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> entity(
    String id, {
    String work = 'w1',
    String kind = 'character',
  }) => db.saveEntity(id, work, kind, id, '설명', {'태그': '주인공'});
  Future<void> link(
    String id,
    String source,
    String target, {
    String work = 'w1',
  }) => db.run('INSERT INTO links VALUES (?,?,?,?,?,?,?)', [
    id,
    work,
    source,
    target,
    '스승',
    '제자',
    1,
  ]);
  test('작품별 분리와 교차 작품 연결 차단', () async {
    await entity('a');
    await entity('b', work: 'w2');
    expect(
      (await db.rows('SELECT * FROM entities WHERE work=?', ['w1'])).length,
      1,
    );
    await expectLater(link('bad', 'a', 'b'), throwsA(anything));
  });
  test('수정 내용과 좌표를 파일 DB 재실행 후 복원', () async {
    await entity('a');
    await db.saveEntity('a', 'w1', 'character', '새 이름', '수정', {'나이': '25'});
    await db.position('w1', 'a', 123, 456);
    await db.close();
    db = Store.file(File('${root.path}/test.sqlite'));
    expect(
      (await db.rows('SELECT title FROM entities')).single['title'],
      '새 이름',
    );
    expect((await db.rows('SELECT x,y FROM layouts')).single, {
      'x': 123.0,
      'y': 456.0,
    });
  });
  test('양방향 관계 조회와 인물 삭제 cascade', () async {
    await entity('a');
    await entity('b');
    await link('l', 'a', 'b');
    for (final id in ['a', 'b']) {
      expect(
        (await db.rows('SELECT * FROM links WHERE source=? OR target=?', [
          id,
          id,
        ])).length,
        1,
      );
    }
    await db.position('w1', 'a', 100, 100);
    await db.run('INSERT INTO attachments VALUES (?,?,?,?)', [
      'img',
      'w1',
      'a',
      'photo.png',
    ]);
    await db.run('DELETE FROM entities WHERE id=?', ['a']);
    expect(await db.rows('SELECT * FROM links'), isEmpty);
    expect(await db.rows('SELECT * FROM layouts'), isEmpty);
    expect(await db.rows('SELECT * FROM attachments'), isEmpty);
    expect((await db.rows('PRAGMA foreign_key_check')), isEmpty);
  });
  test('여러 세력 소속과 사건의 다중 참여', () async {
    await entity('a');
    await entity('b');
    await entity('f', kind: 'faction');
    await entity('f2', kind: 'faction');
    await entity('e', kind: 'event');
    await link('1', 'a', 'f');
    await link('2', 'b', 'f');
    await link('3', 'a', 'f2');
    await link('4', 'a', 'e');
    await link('5', 'b', 'e');
    expect(
      (await db.rows('SELECT * FROM links WHERE target=?', ['f'])).length,
      2,
    );
    expect(
      (await db.rows('SELECT * FROM links WHERE target=?', ['e'])).length,
      2,
    );
  });
  test('전체 ZIP 백업과 이미지 복원, ID 유지', () async {
    await entity('a');
    await entity('b');
    await link('l', 'a', 'b');
    await db.position('w1', 'a', 11, 22);
    await File('${media.path}/photo.png').writeAsBytes([137, 80, 78, 71]);
    await db.run('INSERT INTO attachments VALUES (?,?,?,?)', [
      'img',
      'w1',
      'a',
      'photo.png',
    ]);
    await db.run('INSERT INTO covers VALUES (?,?)', ['w1', 'photo.png']);
    final zip = await BackupService(db, media).export();
    final target = Store(NativeDatabase.memory());
    final targetMedia = await Directory('${root.path}/restored').create();
    try {
      await BackupService(target, targetMedia).restore(zip);
      expect((await target.rows('SELECT * FROM links')).single['id'], 'l');
      expect(await File('${targetMedia.path}/photo.png').readAsBytes(), [
        137,
        80,
        78,
        71,
      ]);
      expect((await target.rows('SELECT * FROM layouts')).single['x'], 11.0);
      expect(
        (await target.rows('SELECT * FROM covers')).single['name'],
        'photo.png',
      );
    } finally {
      await target.close();
    }
  });
  test('ID 충돌 시 복원 전체 rollback 및 새 파일 제거', () async {
    await entity('a');
    await File('${media.path}/p.png').writeAsBytes([1, 2]);
    await db.run('INSERT INTO attachments VALUES (?,?,?,?)', [
      'img',
      'w1',
      'a',
      'p.png',
    ]);
    final zip = await BackupService(db, media).export();
    final targetMedia = await Directory('${root.path}/conflict').create();
    await expectLater(
      BackupService(db, targetMedia).restore(zip),
      throwsA(anything),
    );
    expect(targetMedia.listSync(), isEmpty);
    expect((await db.rows('SELECT * FROM works')).length, 2);
  });
  test('잘못된 JSON 필드와 누락 첨부파일 거부', () async {
    final p = <String, dynamic>{
      'version': 2,
      for (final t in BackupService.columns.keys) t: <dynamic>[],
    };
    p['works'] = [
      {
        'id': 'evil',
        'title': 'x',
        'genre': '',
        'body': '',
        'updated': 0,
        'bad) VALUES(1); --': 1,
      },
    ];
    final data = utf8.encode(jsonEncode(p));
    final a = Archive()
      ..addFile(ArchiveFile('manifest.json', data.length, data));
    await expectLater(
      BackupService(db, media).restore(ZipEncoder().encode(a)),
      throwsA(isA<FormatException>()),
    );
    expect((await db.rows('SELECT * FROM works')).length, 2);
  });
  test('작품 복제는 관계와 좌표를 새 ID로 분리', () async {
    await entity('a');
    await entity('b');
    await link('l', 'a', 'b');
    await db.position('w1', 'a', 42, 24);
    final copy = await db.duplicate('w1');
    final entities = await db.rows('SELECT * FROM entities WHERE work=?', [
      copy,
    ]);
    expect(entities.length, 2);
    expect(entities.map((e) => e['id']), isNot(contains('a')));
    expect(
      (await db.rows('SELECT * FROM links WHERE work=?', [copy])).length,
      1,
    );
    await db.run('DELETE FROM works WHERE id=?', ['w1']);
    expect(
      (await db.rows('SELECT * FROM links WHERE work=?', [copy])).length,
      1,
    );
    expect(await db.rows('PRAGMA foreign_key_check'), isEmpty);
  });
  test('대량 인물·관계와 좌표 저장', () async {
    await db.transaction(() async {
      for (var i = 0; i < 500; i++) {
        await entity('c$i');
        await db.position('w1', 'c$i', (i % 20) * 180.0, (i ~/ 20) * 120.0);
        if (i > 0) await link('r$i', 'c${i - 1}', 'c$i');
      }
    });
    expect((await db.rows('SELECT * FROM entities')).length, 500);
    expect((await db.rows('SELECT * FROM links')).length, 499);
    expect((await db.rows('SELECT * FROM layouts')).length, 500);
  });
  test('지도 마커는 작품을 넘을 수 없고 삭제 시 정리', () async {
    await entity('map', kind: 'location');
    await entity('place', kind: 'location');
    await entity('other', work: 'w2', kind: 'location');
    await db.run('INSERT INTO markers VALUES (?,?,?,?,?,?)', [
      'm',
      'w1',
      'map',
      'place',
      .3,
      .7,
    ]);
    await expectLater(
      db.run('INSERT INTO markers VALUES (?,?,?,?,?,?)', [
        'bad',
        'w1',
        'map',
        'other',
        .3,
        .7,
      ]),
      throwsA(anything),
    );
    await db.run('DELETE FROM entities WHERE id=?', ['place']);
    expect(await db.rows('SELECT * FROM markers'), isEmpty);
  });

  test('지역 계층의 순환과 다른 유형 연결을 차단한다', () async {
    await entity('city', kind: 'location');
    await entity('country', kind: 'location');
    await entity('person');
    await db.saveLink(
      'parent',
      'w1',
      'city',
      'country',
      '상위 지역',
      '하위 지역',
      true,
    );
    await expectLater(
      db.saveLink('cycle', 'w1', 'country', 'city', '상위 지역', '하위 지역', true),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      db.saveLink('wrong', 'w1', 'city', 'person', '상위 지역', '하위 지역', true),
      throwsA(isA<FormatException>()),
    );
    expect((await db.rows('SELECT * FROM links')).length, 1);
  });
  test('저장 전 초안도 전체 백업으로 복원한다', () async {
    await db.run('INSERT INTO drafts VALUES (?,?,?,?,?,?)', [
      'draft',
      'w1',
      'character',
      '작성 중',
      '본문',
      '{"비밀":"내용"}',
    ]);
    final bytes = await BackupService(db, media).export();
    final target = Store(NativeDatabase.memory());
    try {
      await BackupService(target, media).restore(bytes);
      expect(
        (await target.rows('SELECT * FROM drafts')).single['title'],
        '작성 중',
      );
    } finally {
      await target.close();
    }
  });
  test('스키마 v1에서 v3로 데이터 보존 마이그레이션', () async {
    final file = File('${root.path}/old.sqlite');
    final old = _V1Store(NativeDatabase(file));
    await old.saveWork('legacy', '이전 작품', '', '');
    await old.saveEntity(
      'legacy-person',
      'legacy',
      'character',
      '기존 인물',
      '',
      {},
    );
    await old.close();
    final upgraded = Store.file(file);
    try {
      expect(
        (await upgraded.rows('SELECT title FROM entities')).single['title'],
        '기존 인물',
      );
      expect(await upgraded.rows('SELECT * FROM drafts'), isEmpty);
      expect(
        (await upgraded.rows('PRAGMA user_version')).single['user_version'],
        3,
      );
      expect(await upgraded.rows('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await upgraded.close();
    }
  });
  test('첨부 누락 또는 교차 작품 참조 백업은 기존 데이터를 변경하지 않는다', () async {
    await entity('a');
    await db.run('INSERT INTO attachments VALUES (?,?,?,?)', [
      'missing',
      'w1',
      'a',
      'missing.png',
    ]);
    await expectLater(
      BackupService(db, media).export(),
      throwsA(isA<FileSystemException>()),
    );
    final payload = <String, dynamic>{'version': 2};
    for (final t in BackupService.columns.keys) {
      payload[t] = await db.rows('SELECT * FROM $t');
    }
    List<int> zip(Map<String, dynamic> p) {
      final data = utf8.encode(jsonEncode(p));
      return ZipEncoder().encode(
        Archive()..addFile(ArchiveFile('manifest.json', data.length, data)),
      );
    }

    final target = Store(NativeDatabase.memory());
    try {
      await expectLater(
        BackupService(target, media).restore(zip(payload)),
        throwsA(isA<FormatException>()),
      );
      expect(await target.rows('SELECT * FROM works'), isEmpty);
      payload['attachments'] = [];
      payload['links'] = [
        {
          'id': 'bad',
          'work': 'w2',
          'source': 'a',
          'target': 'no-such-id',
          'label': '관계',
          'reverse': '',
          'directed': 0,
        },
      ];
      await expectLater(
        BackupService(target, media).restore(zip(payload)),
        throwsA(anything),
      );
      expect(await target.rows('SELECT * FROM works'), isEmpty);
    } finally {
      await target.close();
    }
  });
}

class _V1Store extends Store {
  _V1Store(super.e);
  @override
  int get schemaVersion => 1;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      for (final sql in Store.schema.where(
        (s) => !Store.additionsV2.contains(s) && !Store.additionsV3.contains(s),
      )) {
        await customStatement(sql);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys=ON');
    },
  );
}
