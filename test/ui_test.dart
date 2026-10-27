import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lore_weaver/main.dart' as app;
import 'package:lore_weaver/core/database.dart';
import 'package:lore_weaver/features/graph.dart';
import 'package:lore_weaver/features/map.dart';

void main() {
  setUp(() async {
    app.db = Store(NativeDatabase.memory());
    app.media = await Directory.systemTemp.createTemp('lore-ui-');
    await app.db.saveWork('w', '테스트 작품', '판타지', '세계관');
  });
  tearDown(() async {
    await app.db.close();
    await app.media.delete(recursive: true);
  });
  Widget wrap(Widget child) => ProviderScope(child: MaterialApp(home: child));
  testWidgets('작품 대시보드는 실제 통계를 표시한다', (t) async {
    await app.db.saveEntity('a', 'w', 'character', '연하', '주인공', {});
    await t.pumpWidget(wrap(const app.Workspace(work: 'w')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
    expect(find.text('등장인물 1'), findsOneWidget);
    expect(find.text('테스트 작품'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('인물 작성은 초안을 저장하고 저장 버튼으로 DB에 반영한다', (t) async {
    await t.pumpWidget(
      wrap(
        Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(c).push(
                MaterialPageRoute(
                  builder: (_) =>
                      const app.EntityEditor(work: 'w', kind: 'character'),
                ),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('열기'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '연하');
    await t.pump(const Duration(milliseconds: 700));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    expect((await app.db.rows('SELECT * FROM drafts')).single['title'], '연하');
    await t.tap(find.text('저장'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
    expect((await app.db.rows('SELECT * FROM entities')).single['title'], '연하');
    expect(await app.db.rows('SELECT * FROM drafts'), isEmpty);
    expect(find.text('열기'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('관계도 노드 드래그는 좌표를 저장한다', (t) async {
    await app.db.saveEntity('a', 'w', 'character', '연하', '', {});
    await t.pumpWidget(wrap(const GraphScreen(work: 'w')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
    expect(find.text('연하'), findsWidgets);
    await t.drag(find.text('연하').first, const Offset(60, 30));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
    final rows = await app.db.rows('SELECT * FROM layouts WHERE entity=?', [
      'a',
    ]);
    expect(rows, isNotEmpty);
    expect(rows.single['x'], greaterThan(150));
    expect(t.takeException(), isNull);
  });
  testWidgets('작은 화면에서 검색·폼이 넘치지 않는다', (t) async {
    t.view.physicalSize = const Size(360, 740);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(wrap(const app.Workspace(work: 'w')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.text('등장인물').first);
    await t.pumpAndSettle();
    expect(find.text('소속 세력 필터'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('500명 관계도는 화면 안 노드만 만들고 가로 화면에서도 표시한다', (t) async {
    await app.db.transaction(() async {
      for (var i = 0; i < 500; i++) {
        await app.db.saveEntity('n$i', 'w', 'character', '노드 $i', '', {});
      }
    });
    t.view.physicalSize = const Size(900, 430);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(wrap(const GraphScreen(work: 'w')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pumpAndSettle();
    expect(find.byType(CircleAvatar).evaluate().length, lessThan(100));
    expect(t.takeException(), isNull);
    await t.tap(find.byTooltip('자동 배치'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await t.pumpAndSettle();
    expect((await app.db.rows('SELECT * FROM layouts')).length, 500);
    expect(t.takeException(), isNull);
  });
  testWidgets('저장하지 못한 초안을 편집기에서 복구한다', (t) async {
    await app.db.run('INSERT INTO drafts VALUES (?,?,?,?,?,?)', [
      'draft',
      'w',
      'character',
      '복구된 이름',
      '작성중 설명',
      '{"비밀":"숨겨둔 설정"}',
    ]);
    await t.pumpWidget(
      wrap(
        const app.EntityEditor(work: 'w', kind: 'character', draftId: 'draft'),
      ),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
    expect(find.text('복구된 이름'), findsOneWidget);
    expect(find.text('작성중 설명'), findsOneWidget);
    expect(find.text('저장되지 않은 초안을 복구했습니다'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('사용자 지도 이미지를 표시하고 저장된 장소 마커를 탐색한다', (t) async {
    await app.db.saveEntity('map', 'w', 'location', '세계 지도', '', {});
    await app.db.saveEntity('village', 'w', 'location', '마을', '', {});
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 320, 180),
      Paint()..color = Colors.green,
    );
    final image = await t.runAsync(
      () => recorder.endRecording().toImage(320, 180),
    );
    final bytes = await t.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.png),
    );
    image!.dispose();
    await t.runAsync(
      () =>
          File('${app.media.path}/map.png')
              .writeAsBytes(bytes!.buffer.asUint8List()),
    );
    await app.db.run('INSERT INTO attachments VALUES (?,?,?,?)', [
      'img',
      'w',
      'map',
      'map.png',
    ]);
    await app.db.run('INSERT INTO markers VALUES (?,?,?,?,?,?)', [
      'marker',
      'w',
      'map',
      'village',
      .5,
      .5,
    ]);
    await t.pumpWidget(wrap(const SizedBox()));
    await t.runAsync(
      () => precacheImage(
        FileImage(File('${app.media.path}/map.png')),
        t.element(find.byType(SizedBox).first),
      ),
    );
    await t.pumpWidget(wrap(const WorldMap(work: 'w', mapId: 'map')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pumpAndSettle();
    expect(find.text('마을'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.tap(find.text('마을'));
    await t.pumpAndSettle();
    expect(find.text('마커 삭제'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('작품 서재 쿼리는 SQLite 문자열 모드와 무관하게 실제 개수를 표시한다', (t) async {
    await app.db.saveEntity('a', 'w', 'character', '인물', '', {});
    await t.pumpWidget(wrap(const app.Library()));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
    expect(find.text('테스트 작품'), findsOneWidget);
    expect(find.textContaining('인물 1 · 세력 0 · 사건 0'), findsOneWidget);
    expect(find.textContaining('데이터를 불러오지 못했습니다'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
