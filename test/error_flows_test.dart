import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lore_weaver/core/database.dart';
import 'package:lore_weaver/core/runtime.dart';
import 'package:lore_weaver/features/entities.dart';

class DelayedStore extends Store {
  DelayedStore() : super(NativeDatabase.memory());
  Completer<void>? gate;
  int saves = 0;
  @override
  Future<void> saveEntity(
    String id,
    String work,
    String kind,
    String title,
    String body,
    Map<String, dynamic> data, {
    bool favorite = false,
  }) async {
    if (gate != null) {
      saves++;
      await gate!.future;
    }
    await super.saveEntity(
      id,
      work,
      kind,
      title,
      body,
      data,
      favorite: favorite,
    );
  }
}

void main() {
  late DelayedStore store;
  setUp(() async {
    store = DelayedStore();
    db = store;
    media = await Directory.systemTemp.createTemp('lore-errors-');
    await db.saveWork('w', '작品', '', '');
  });
  tearDown(() async {
    await db.close();
    await media.delete(recursive: true);
  });
  Future<void> settle(WidgetTester t) async {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pumpAndSettle();
  }

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(c).push(
                MaterialPageRoute(
                  builder: (c) => Scaffold(
                    appBar: AppBar(title: const Text('인물 목록')),
                    body: TextButton(
                      onPressed: () => Navigator.of(c).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const EntityEditor(work: 'w', kind: 'character'),
                        ),
                      ),
                      child: const Text('인물 추가'),
                    ),
                  ),
                ),
              ),
              child: const Text('작품 열기'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('작품 열기'));
    await t.pumpAndSettle();
    await t.tap(find.text('인물 추가'));
    await settle(t);
  }

  testWidgets('저장 처리 중 뒤로 가도 편집 화면만 한 번 닫힌다', (t) async {
    await open(t);
    await t.enterText(find.byType(TextField).first, '이름');
    store.gate = Completer<void>();
    await t.tap(find.text('저장'));
    await t.pump();
    await t.pageBack();
    await t.pump();
    store.gate!.complete();
    await settle(t);
    expect(store.saves, 1);
    expect(find.text('인물 목록'), findsOneWidget);
    expect((await db.rows('SELECT * FROM entities')).length, 1);
    expect(t.takeException(), isNull);
  });
  testWidgets('뒤로 가기를 연속 눌러도 부모 목록까지 닫히지 않는다', (t) async {
    await open(t);
    await t.enterText(find.byType(TextField).first, '와');
    store.gate = Completer<void>();
    await t.pageBack();
    await t.pump();
    await t.pageBack();
    await t.pump();
    store.gate!.complete();
    await settle(t);
    expect(store.saves, 1);
    expect(find.text('인물 목록'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('작성하지 않은 새 편집기를 닫으면 빈 초안을 남기지 않는다', (t) async {
    await open(t);
    await t.pageBack();
    await settle(t);
    expect(await db.rows('SELECT * FROM drafts'), isEmpty);
    expect(await db.rows('SELECT * FROM entities'), isEmpty);
    expect(find.text('인물 목록'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('저장 도중 앱이 비활성화되어도 저장된 초안이 되살아나지 않는다', (t) async {
    await open(t);
    await t.enterText(find.byType(TextField).first, '주인공');
    store.gate = Completer<void>();
    await t.tap(find.text('저장'));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    store.gate!.complete();
    await settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(await db.rows('SELECT * FROM drafts'), isEmpty);
    expect((await db.rows('SELECT * FROM entities')).single['title'], '주인공');
    expect(t.takeException(), isNull);
  });
}
