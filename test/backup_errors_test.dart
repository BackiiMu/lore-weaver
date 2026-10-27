import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lore_weaver/core/database.dart';
import 'package:lore_weaver/core/backup.dart';
import 'package:lore_weaver/core/trash.dart';

void main() {
  late Store db;
  late Directory media;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() async {
    db = Store(NativeDatabase.memory());
    media = await Directory.systemTemp.createTemp('bad-backup-');
    await db.saveWork('existing', '기존 작품', '', '');
  });
  tearDown(() async {
    await db.close();
    await media.delete(recursive: true);
  });
  Map<String, dynamic> payload() => {
    'version': 4,
    for (final table in BackupService.columns.keys)
      table: <Map<String, dynamic>>[],
    'works': [
      {'id': 'new', 'title': '가져올 작품', 'genre': '', 'body': '', 'updated': 1},
    ],
  };
  Map<String, dynamic> person() => {
    'id': 'a',
    'work': 'new',
    'kind': 'character',
    'title': '인물',
    'body': '',
    'data': '{}',
    'favorite': 0,
    'updated': 1,
  };
  List<int> zip(
    Map<String, dynamic> p, {
    Map<String, List<int>> files = const {},
  }) {
    final data = utf8.encode(jsonEncode(p));
    final a = Archive()
      ..addFile(ArchiveFile('manifest.json', data.length, data));
    for (final f in files.entries) {
      a.addFile(ArchiveFile('media/${f.key}', f.value.length, f.value));
    }
    return ZipEncoder().encode(a);
  }

  Future<void> unchanged() async {
    expect((await db.rows('SELECT * FROM works')).single['id'], 'existing');
    expect(await db.rows('SELECT * FROM entities'), isEmpty);
  }

  test('깨진 ZIP과 지원하지 않는 버전은 기존 데이터를 유지한다', () async {
    final service = BackupService(db, media);
    await expectLater(service.restore([1, 2, 3, 4]), throwsA(anything));
    final p = payload()..['version'] = 99;
    await expectLater(service.restore(zip(p)), throwsA(isA<FormatException>()));
    await unchanged();
  });
  test('미리보기가 기존 첨부파일의 내용 충돌도 보고한다', () async {
    final p = payload();
    p['entities'] = [person()];
    p['attachments'] = [
      {'id': 'img', 'work': 'new', 'entity': 'a', 'name': 'p.png'},
    ];
    await File('${media.path}/p.png').writeAsBytes([8, 9]);
    final bytes = zip(
      p,
      files: {
        'p.png': [1, 2],
      },
    );
    final preview = await BackupService(db, media).preview(bytes);
    expect(preview.conflicts, 1);
    await unchanged();
    expect(await File('${media.path}/p.png').readAsBytes(), [8, 9]);
  });
  test('알 수 없는 보드 종류는 미리보기와 복원에서 거부한다', () async {
    final p = payload();
    p['boards'] = [
      {'id': 'b', 'work': 'new', 'kind': 'unknown', 'title': '보드'},
    ];
    final service = BackupService(db, media);
    await expectLater(service.preview(zip(p)), throwsA(isA<FormatException>()));
    await expectLater(service.restore(zip(p)), throwsA(isA<FormatException>()));
    await unchanged();
  });
  test('잘못된 상태 값은 SQLite에 넣기 전에 거부한다', () async {
    final p = payload();
    p['entities'] = [person()..['favorite'] = 2];
    await expectLater(
      BackupService(db, media).restore(zip(p)),
      throwsA(isA<FormatException>()),
    );
    await unchanged();
  });
  test('휴지통 안의 잘못된 자료 종류도 검사한다', () async {
    final p = payload();
    final nested = {
      for (final t in TrashService.tables) t: <Map<String, dynamic>>[],
    };
    nested['entities'] = [person()..['kind'] = 'unknown'];
    p['trash'] = [
      {
        'id': 't',
        'work': 'new',
        'title': '삭제 자료',
        'kind': 'character',
        'payload': jsonEncode(nested),
        'deleted': 1,
      },
    ];
    await expectLater(
      BackupService(db, media).restore(zip(p)),
      throwsA(isA<FormatException>()),
    );
    await unchanged();
  });
  test('첨부 경로 탈출과 뒤늦은 첨부 누락은 파일·DB를 남기지 않는다', () async {
    final p = payload();
    p['entities'] = [person()];
    p['attachments'] = [
      {'id': 'img', 'work': 'new', 'entity': 'a', 'name': '../escape.png'},
    ];
    await expectLater(
      BackupService(db, media).restore(
        zip(
          p,
          files: {
            '../escape.png': [1],
          },
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    p['attachments'] = [
      {'id': 'img', 'work': 'new', 'entity': 'a', 'name': 'first.png'},
      {'id': 'missing', 'work': 'new', 'entity': 'a', 'name': 'second.png'},
    ];
    await expectLater(
      BackupService(db, media).restore(
        zip(
          p,
          files: {
            'first.png': [1],
          },
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(media.listSync(), isEmpty);
    await unchanged();
  });
  test('보드의 작품 경계를 넘는 첨부 노드는 전체 복원을 취소한다', () async {
    final p = payload();
    p['entities'] = [person()];
    p['boards'] = [
      {'id': 'b', 'work': 'new', 'kind': 'character', 'title': '보드'},
    ];
    p['board_nodes'] = [
      {'work': 'existing', 'board': 'b', 'entity': 'a', 'x': 1, 'y': 2},
    ];
    await expectLater(
      BackupService(db, media).restore(zip(p)),
      throwsA(anything),
    );
    await unchanged();
  });
  test('위치 문자열과 무한대로 변형된 숫자를 거부한다', () async {
    final p = payload();
    p['entities'] = [person()];
    p['layouts'] = [
      {'work': 'new', 'entity': 'a', 'x': 'NaN', 'y': 0, 'visible': 1},
    ];
    await expectLater(
      BackupService(db, media).restore(zip(p)),
      throwsA(isA<FormatException>()),
    );
    await unchanged();
  });
}
