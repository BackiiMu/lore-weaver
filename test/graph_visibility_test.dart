import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lore_weaver/core/database.dart';
import 'package:lore_weaver/core/runtime.dart';
import 'package:lore_weaver/features/graph.dart';
import 'package:lore_weaver/app/theme.dart';

void main() {
  setUp(() async {
    db = Store(NativeDatabase.memory());
    media = await Directory.systemTemp.createTemp('graph-visibility-');
    await db.saveWork('w', '작품', '', '');
  });
  tearDown(() async {
    await db.close();
    await media.delete(recursive: true);
  });
  Future<void> settle(WidgetTester t) async {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
  }

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: PaperTheme.build(Brightness.light),
          home: const GraphScreen(work: 'w'),
        ),
      ),
    );
    await settle(t);
  }

  Future<void> add(WidgetTester t, String name) async {
    await t.tap(find.byTooltip('노드 추가'));
    await t.pumpAndSettle();
    await t.tap(find.text('새 인물 등록'));
    await settle(t);
    await t.enterText(find.byType(TextField).first, name);
    await t.tap(find.text('저장'));
    await settle(t);
  }

  void expectVisible(WidgetTester t, List<Map<String, dynamic>> people) {
    final viewer = t.getRect(find.byType(InteractiveViewer));
    for (final person in people) {
      final node = find.byKey(ValueKey('graph-node-${person['id']}'));
      expect(node, findsOneWidget);
      final rect = t.getRect(node);
      expect(
        viewer.contains(rect.topLeft),
        isTrue,
        reason: '${person['title']}의 왼쪽 위가 화면 밖입니다',
      );
      expect(
        viewer.contains(rect.bottomRight),
        isTrue,
        reason: '${person['title']}의 오른쪽 아래가 화면 밖입니다',
      );
    }
  }

  testWidgets('390px 관계도에서 이름 다음 와를 등록하면 두 인물이 모두 보인다', (t) async {
    await open(t);
    await add(t, '이름');
    await add(t, '와');
    final people = await db.rows('SELECT * FROM entities WHERE work=?', ['w']);
    expect(people.map((p) => p['title']).toSet(), {'이름', '와'});
    expectVisible(t, people);
    expect(t.takeException(), isNull);
  });
  testWidgets('기존 두 인물의 관계도를 열면 저장된 좌표를 바꾸지 않고 화면에 맞춘다', (t) async {
    await db.saveEntity('a', 'w', 'character', '이름', '', {});
    await db.saveEntity('b', 'w', 'character', '와', '', {});
    await db.position('w', 'a', 150, 150);
    await db.position('w', 'b', 360, 150);
    await open(t);
    expectVisible(t, await db.rows('SELECT * FROM entities'));
    expect(
      (await db.rows('SELECT x FROM layouts WHERE entity=?', [
        'b',
      ])).single['x'],
      360.0,
    );
    expect(t.takeException(), isNull);
  });
  testWidgets('개별 보드에 연속 등록한 인물이 겹치지 않고 모두 보인다', (t) async {
    await db.run('INSERT INTO boards VALUES (?,?,?,?)', [
      'board',
      'w',
      'character',
      '내 보드',
    ]);
    await open(t);
    await t.tap(find.byType(DropdownButtonFormField<String>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('내 보드').last);
    await settle(t);
    await add(t, '이름');
    await add(t, '와');
    final people = await db.rows('SELECT * FROM entities');
    expectVisible(t, people);
    final nodes = await db.rows('SELECT * FROM board_nodes');
    expect(nodes.length, 2);
    final a = Rect.fromLTWH(nodes[0]['x'], nodes[0]['y'], 160, 88),
        b = Rect.fromLTWH(nodes[1]['x'], nodes[1]['y'], 160, 88);
    expect(a.overlaps(b), isFalse);
    expect(t.takeException(), isNull);
  });
  testWidgets('이전 버전에서 같은 위치에 저장된 보드의 두 인물을 분리한다', (t) async {
    await db.saveEntity('a', 'w', 'character', '이름', '', {});
    await db.saveEntity('b', 'w', 'character', '와', '', {});
    await db.run('INSERT INTO boards VALUES (?,?,?,?)', [
      'board',
      'w',
      'character',
      '내 보드',
    ]);
    await db.graphPosition('w', 'a', 150, 150, board: 'board');
    await db.graphPosition('w', 'b', 150, 150, board: 'board');
    await open(t);
    await t.tap(find.byType(DropdownButtonFormField<String>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('내 보드').last);
    await settle(t);
    final a = t.getRect(find.byKey(const ValueKey('graph-node-a'))),
        b = t.getRect(find.byKey(const ValueKey('graph-node-b')));
    expect(a.overlaps(b), isFalse);
    expectVisible(t, await db.rows('SELECT * FROM entities'));
    expect(
      (await db.rows('SELECT * FROM board_nodes'))
          .map((n) => '${n['x']}/${n['y']}')
          .toSet()
          .length,
      2,
    );
    expect(t.takeException(), isNull);
  });
}
