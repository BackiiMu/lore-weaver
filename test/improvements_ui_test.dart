import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lore_weaver/core/database.dart';
import 'package:lore_weaver/core/runtime.dart';
import 'package:lore_weaver/core/trash.dart';
import 'package:lore_weaver/features/graph.dart';
import 'package:lore_weaver/features/works.dart';
import 'package:lore_weaver/features/entities.dart';
import 'package:lore_weaver/features/organize.dart';
import 'package:lore_weaver/features/trash.dart';
import 'package:lore_weaver/app/theme.dart';

void main() {
  setUp(() async {
    db = Store(NativeDatabase.memory());
    media = await Directory.systemTemp.createTemp('lore-new-ui-');
    await db.saveWork('w', '작품', '', '');
    await db.saveEntity('a', 'w', 'character', '연하', '', {});
    await db.saveEntity('b', 'w', 'character', '태윤', '', {});
    await db.saveLink('l', 'w', 'a', 'b', '친구', '친구', false);
  });
  tearDown(() async {
    await db.close();
    await media.delete(recursive: true);
  });
  Widget wrap(Widget child) => ProviderScope(
    child: MaterialApp(theme: PaperTheme.build(Brightness.light), home: child),
  );
  Future<void> settle(WidgetTester t) async {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
  }

  testWidgets('관계선을 눌러 수정한 뒤 실행 취소·다시 실행한다', (t) async {
    t.view.physicalSize = const Size(900, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(wrap(const GraphScreen(work: 'w')));
    await settle(t);
    final a = t.getRect(find.byKey(const ValueKey('graph-node-a')));
    final b = t.getRect(find.byKey(const ValueKey('graph-node-b')));
    await t.tapAt((a.center + b.center) / 2);
    await t.pumpAndSettle();
    expect(find.text('관계 수정'), findsOneWidget);
    await t.tap(find.text('관계 수정'));
    await settle(t);
    expect(find.text('자료 연결 / 관계'), findsOneWidget);
    await t.enterText(find.byType(TextField).first, '동료');
    await t.tap(find.text('저장').last);
    await settle(t);
    expect((await db.rows('SELECT * FROM links')).single['label'], '동료');
    await t.tap(find.byTooltip('실행 취소'));
    await settle(t);
    expect((await db.rows('SELECT * FROM links')).single['label'], '친구');
    await t.tap(find.byTooltip('다시 실행'));
    await settle(t);
    expect((await db.rows('SELECT * FROM links')).single['label'], '동료');
    expect(t.takeException(), isNull);
  });
  testWidgets('보드를 만든 뒤 노드 이동을 취소해 원래 좌표로 복구한다', (t) async {
    await t.pumpWidget(wrap(const GraphScreen(work: 'w')));
    await settle(t);
    await t.tap(find.byTooltip('관계도 메뉴'));
    await t.pumpAndSettle();
    await t.tap(find.text('현재 보기를 새 보드로 저장'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '왕실');
    await t.tap(find.text('저장'));
    await settle(t);
    expect((await db.rows('SELECT * FROM boards')).single['title'], '왕실');
    expect((await db.rows('SELECT * FROM board_nodes')).length, 2);
    final before = await db.rows('SELECT x FROM board_nodes WHERE entity=?', [
      'a',
    ]);
    await t.drag(
      find.byKey(const ValueKey('graph-node-a')),
      const Offset(80, 30),
    );
    await settle(t);
    expect(
      (await db.rows('SELECT x FROM board_nodes WHERE entity=?', [
        'a',
      ])).single['x'],
      isNot(before.single['x']),
    );
    await t.tap(find.byTooltip('실행 취소'));
    await settle(t);
    expect(
      (await db.rows('SELECT x FROM board_nodes WHERE entity=?', [
        'a',
      ])).single['x'],
      before.single['x'],
    );
    expect(await db.rows('SELECT * FROM layouts'), isEmpty);
    expect(t.takeException(), isNull);
  });
  testWidgets('보기 모드에서는 노드를 움직여도 저장하지 않는다', (t) async {
    await t.pumpWidget(wrap(const GraphScreen(work: 'w')));
    await settle(t);
    await t.tap(find.byTooltip('관계도 메뉴'));
    await t.pumpAndSettle();
    await t.tap(find.text('보기 모드로 전환'));
    await t.pumpAndSettle();
    await t.drag(find.text('연하').first, const Offset(40, 20));
    await settle(t);
    expect(await db.rows('SELECT * FROM layouts'), isEmpty);
    expect(find.text('보기 모드'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('유형별 연결 화면에 소속 세력이 별도로 표시된다', (t) async {
    await db.saveEntity('f', 'w', 'faction', '청운회', '', {});
    await db.saveLink('membership', 'w', 'a', 'f', '소속', '구성원', true);
    await t.pumpWidget(
      wrap(
        const Scaffold(
          body: SingleChildScrollView(
            child: EntityConnections(id: 'a', work: 'w'),
          ),
        ),
      ),
    );
    await settle(t);
    expect(find.text('소속·관련 세력 · 1'), findsOneWidget);
    expect(find.text('청운회'), findsOneWidget);
    expect(find.text('소속'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('휴지통 화면에서 인물과 연결을 복원한다', (t) async {
    await TrashService(db).removeEntity('a');
    await t.pumpWidget(wrap(const TrashScreen(work: 'w')));
    await settle(t);
    expect(find.text('연하'), findsOneWidget);
    await t.tap(find.byType(PopupMenuButton<String>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('복원'));
    await settle(t);
    expect(
      (await db.rows('SELECT * FROM entities WHERE id=?', ['a'])).length,
      1,
    );
    expect((await db.rows('SELECT * FROM links')).single['id'], 'l');
    expect(find.text('휴지통이 비어 있습니다.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('지역 계층을 펼쳐 하위 장소를 확인한다', (t) async {
    await db.saveEntity('country', 'w', 'location', '제국', '', {});
    await db.saveEntity('city', 'w', 'location', '수도', '', {});
    await db.saveLink('parent', 'w', 'city', 'country', '상위 지역', '하위 지역', true);
    await t.pumpWidget(
      wrap(const HierarchyScreen(work: 'w', kind: 'location')),
    );
    await settle(t);
    expect(find.text('제국'), findsOneWidget);
    expect(find.text('수도'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('360px 화면에서 관계도 도구가 넘치지 않는다', (t) async {
    t.view.physicalSize = const Size(360, 740);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(wrap(const GraphScreen(work: 'w')));
    await settle(t);
    expect(find.byTooltip('관계도 메뉴'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('작품 생성 대화상자를 닫아도 입력 컨트롤러 오류가 없다', (t) async {
    await t.pumpWidget(wrap(const Library()));
    await settle(t);
    await t.tap(find.text('새 작품').last);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).at(1), '새 이야기');
    await t.tap(find.text('저장'));
    await settle(t);
    expect(
      (await db.rows('SELECT * FROM works WHERE title=?', ['새 이야기'])).length,
      1,
    );
    expect(t.takeException(), isNull);
  });
}
