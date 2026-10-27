import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lore_weaver/core/database.dart';
import 'package:lore_weaver/core/runtime.dart';
import 'package:lore_weaver/features/graph.dart';

void main() {
  setUp(() async {
    db = Store(NativeDatabase.memory());
    media = await Directory.systemTemp.createTemp('graph-filter-errors-');
    await db.saveWork('w', '작품', '', '');
    for (final id in ['a', 'b', 'c']) {
      await db.saveEntity(id, 'w', 'character', id.toUpperCase(), '', {});
    }
    await db.saveLink('ab', 'w', 'a', 'b', '친구', '친구', false);
    await db.saveLink('bc', 'w', 'b', 'c', '동료', '동료', false);
  });
  tearDown(() async {
    await db.close();
    await media.delete(recursive: true);
  });
  Future<void> settle(WidgetTester t) async {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pumpAndSettle();
  }

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: const GraphScreen(work: 'w')),
      ),
    );
    await settle(t);
  }

  Finder node(String id) => find.byKey(ValueKey('graph-node-$id'));
  Future<void> selectBoard(WidgetTester t, String name) async {
    await t.tap(find.byType(DropdownButtonFormField<String>).first);
    await t.pumpAndSettle();
    await t.tap(find.text(name).last);
    await settle(t);
  }

  testWidgets('중심·깊이·관계 종류 필터를 바꿔도 필요한 노드가 정확히 표시된다', (t) async {
    await open(t);
    await t.tap(find.byType(DropdownButtonFormField<String>).last);
    await t.pumpAndSettle();
    await t.tap(find.text('A').last);
    await settle(t);
    expect(node('a'), findsOneWidget);
    expect(node('b'), findsOneWidget);
    expect(node('c'), findsNothing);
    await t.tap(find.text('주변 2단계'));
    await t.pumpAndSettle();
    expect(node('c'), findsOneWidget);
    await t.tap(find.text('모든 관계'));
    await t.pumpAndSettle();
    await t.tap(find.text('친구'));
    await t.pumpAndSettle();
    expect(node('c'), findsNothing);
    expect(node('b'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('중심 인물을 캔버스에서 제거한 뒤 실행 취소해도 필터 오류가 없다', (t) async {
    await open(t);
    await t.tap(node('a'));
    await t.pumpAndSettle();
    await t.tap(find.text('중심 보기'));
    await t.pumpAndSettle();
    await t.tap(find.text('캔버스에서 제거'));
    await settle(t);
    expect(node('a'), findsNothing);
    await t.tap(find.byTooltip('실행 취소'));
    await settle(t);
    expect(node('a'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('두 개의 보드와 전체 관계도를 반복 전환해도 멤버가 섞이지 않는다', (t) async {
    for (final b in ['첫 보드', '둘째 보드']) {
      await db.run('INSERT INTO boards VALUES (?,?,?,?)', [
        b,
        'w',
        'character',
        b,
      ]);
    }
    await db.graphPosition('w', 'a', 10, 20, board: '첫 보드');
    await db.graphPosition('w', 'b', 20, 30, board: '둘째 보드');
    await open(t);
    for (var i = 0; i < 3; i++) {
      await selectBoard(t, '첫 보드');
      expect(node('a'), findsOneWidget);
      expect(node('b'), findsNothing);
      await selectBoard(t, '둘째 보드');
      expect(node('b'), findsOneWidget);
      expect(node('a'), findsNothing);
      await selectBoard(t, '전체 관계도');
      expect(node('a'), findsOneWidget);
      expect(node('b'), findsOneWidget);
      expect(node('c'), findsOneWidget);
    }
    expect(t.takeException(), isNull);
  });
  testWidgets('관계도에서 새 인물 등록을 취소해도 빈 인물·초안·오류가 남지 않는다', (t) async {
    await open(t);
    await t.tap(find.byTooltip('노드 추가'));
    await t.pumpAndSettle();
    await t.tap(find.text('새 인물 등록'));
    await settle(t);
    await t.pageBack();
    await settle(t);
    expect((await db.rows('SELECT * FROM entities')).length, 3);
    expect(await db.rows('SELECT * FROM drafts'), isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    expect(t.takeException(), isNull);
  });
}
