import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/runtime.dart';
import '../core/catalog.dart';

Future<String?> askName(
  BuildContext c,
  String title, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '이름'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
        FilledButton(
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(c, controller.text.trim());
            }
          },
          child: const Text('저장'),
        ),
      ],
    ),
  );
}

class CatalogScreen extends ConsumerStatefulWidget {
  final String work;
  const CatalogScreen({super.key, required this.work});
  @override
  ConsumerState<CatalogScreen> createState() => _CatalogState();
}

class _CatalogState extends ConsumerState<CatalogScreen> {
  String type = '태그';
  @override
  Widget build(BuildContext c) {
    ref.watch(changes);
    final service = CatalogService(db, widget.work);
    return Scaffold(
      appBar: AppBar(title: const Text('태그·카테고리 관리')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => guarded(c, () async {
          final name = await askName(c, '$type 추가');
          if (name == null) return;
          await service.add(type, name);
          refresh(ref);
        }),
        icon: const Icon(Icons.add),
        label: Text('$type 추가'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: '태그', label: Text('태그')),
                ButtonSegment(value: '카테고리', label: Text('설정 카테고리')),
              ],
              selected: {type},
              onSelectionChanged: (s) => setState(() => type = s.single),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('이름을 바꾸면 이 작품의 자료와 초안에 함께 반영됩니다. 같은 이름은 하나로 합쳐집니다.'),
          ),
          Expanded(
            child: FutureBuilder(
              future: service.list(type),
              builder: (c, s) => loading(
                s,
                (data) => data.isEmpty
                    ? const Center(child: Text('등록된 항목이 없습니다.'))
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 100),
                        children: [
                          for (final entry
                              in (data as Map<String, int>).entries)
                            ListTile(
                              title: Text(entry.key),
                              subtitle: Text('자료 ${entry.value}개'),
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) => guarded(c, () async {
                                  if (v == 'rename') {
                                    final name = await askName(
                                      c,
                                      '$type 이름 변경',
                                      initial: entry.key,
                                    );
                                    if (name != null) {
                                      await service.rename(
                                        type,
                                        entry.key,
                                        name,
                                      );
                                    }
                                  } else if (await confirm(
                                    c,
                                    '모든 자료에서 이 $type 표시를 제거할까요? 자료 자체는 유지됩니다.',
                                  )) {
                                    await service.rename(type, entry.key, null);
                                  }
                                  refresh(ref);
                                }),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('이름 변경·병합'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('표시 제거'),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> pickCatalog(
  BuildContext c,
  String work,
  String type,
  TextEditingController controller,
) async {
  final values = await CatalogService(db, work).list(type);
  if (!c.mounted) return;
  final selected = type == '태그'
      ? parseTags(controller.text).toSet()
      : {controller.text};
  final names = {
    ...values.keys,
    ...selected.where((s) => s.isNotEmpty),
    if (type == '카테고리') ...[
      '무공',
      '마법',
      '기술',
      '아이템',
      '종족',
      '역사',
      '문화',
      '종교',
      '규칙',
      '기타',
    ],
  }.toList()..sort();
  await showDialog(
    context: c,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text('$type 선택'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              if (names.isEmpty)
                const Text('아직 등록된 태그가 없습니다. 입력창에 쉼표로 구분해 추가하세요.'),
              for (final name in names)
                CheckboxListTile(
                  title: Text(name),
                  value: selected.contains(name),
                  onChanged: (v) => set(() {
                    if (type == '카테고리') selected.clear();
                    if (v == true) {
                      selected.add(name);
                    } else {
                      selected.remove(name);
                    }
                  }),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              controller.text = selected.where((s) => s.isNotEmpty).join(', ');
              Navigator.pop(c);
            },
            child: const Text('적용'),
          ),
        ],
      ),
    ),
  );
}

class HierarchyScreen extends ConsumerWidget {
  final String work, kind;
  const HierarchyScreen({super.key, required this.work, required this.kind});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    ref.watch(changes);
    return Scaffold(
      appBar: AppBar(title: Text(kind == 'location' ? '지역 계층' : '조직 계층')),
      body: FutureBuilder(
        future: Future.wait([
          db.rows(
            'SELECT * FROM entities WHERE work=? AND kind=? ORDER BY title',
            [work, kind],
          ),
          db.rows('SELECT * FROM links WHERE work=?', [work]),
        ]),
        builder: (c, s) => loading(s, (data) {
          final entries = List<Map<String, dynamic>>.from(data[0]);
          final ids = entries.map((e) => e['id']).toSet();
          final children = <String, List<String>>{}, parent = <String>{};
          final up = kind == 'location' ? '상위 지역' : '상위 조직',
              down = kind == 'location' ? '하위 지역' : '하위 조직';
          for (final edge in data[1]) {
            String? p, child;
            if (edge['label'] == up) {
              p = edge['target'];
              child = edge['source'];
            } else if (edge['label'] == down) {
              p = edge['source'];
              child = edge['target'];
            }
            if (p != null &&
                child != null &&
                ids.contains(p) &&
                ids.contains(child)) {
              children.putIfAbsent(p, () => []).add(child);
              parent.add(child);
            }
          }
          final visited = <String>{};
          Widget node(String id, Set<String> path) {
            final e = entries.firstWhere((e) => e['id'] == id);
            if (visited.contains(id)) {
              return ListTile(
                title: Text('${e['title']} · 다른 경로에서도 연결'),
                onTap: () => c.push('/entity/$id'),
              );
            }
            visited.add(id);
            if (path.contains(id)) {
              return ListTile(
                title: Text('${e['title']} · 순환 연결'),
                onTap: () => c.push('/entity/$id'),
              );
            }
            final nested = children[id] ?? [];
            if (nested.isEmpty) {
              return ListTile(
                leading: Icon(
                  kind == 'location'
                      ? Icons.place_outlined
                      : Icons.groups_outlined,
                ),
                title: Text(e['title']),
                onTap: () => c.push('/entity/$id'),
              );
            }
            return ExpansionTile(
              key: PageStorageKey('hierarchy-$id'),
              initiallyExpanded: true,
              title: Text(e['title']),
              trailing: IconButton(
                tooltip: '자료 상세',
                onPressed: () => c.push('/entity/$id'),
                icon: const Icon(Icons.open_in_new),
              ),
              childrenPadding: const EdgeInsets.only(left: 20),
              children: [
                for (final child in nested.toSet()) node(child, {...path, id}),
              ],
            );
          }

          final widgets = [
            for (final e in entries.where((e) => !parent.contains(e['id'])))
              node(e['id'], {}),
          ];
          for (final e in entries) {
            if (!visited.contains(e['id'])) widgets.add(node(e['id'], {}));
          }
          return entries.isEmpty
              ? const Center(child: Text('등록된 자료가 없습니다.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text('상위 지역·상위 조직 연결로 구성됩니다. 이름을 눌러 관련 자료를 탐색하세요.'),
                    const SizedBox(height: 12),
                    ...widgets,
                  ],
                );
        }),
      ),
    );
  }
}
