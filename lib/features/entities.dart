import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';
import 'dart:convert';

import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';

import '../core/runtime.dart';
import '../core/trash.dart';
import 'organize.dart';
import 'graph.dart';
import 'map.dart';

Widget entityTile(BuildContext c, Map<String, dynamic> e) => ListTile(
  leading: EntityAvatar(id: e['id'], favorite: e['favorite'] == 1),
  title: Text(e['title']),
  subtitle: Text(
    e['kind'] == 'event'
        ? '${jsonDecode(e['data'])['발생 시점 / 연호'] ?? '날짜 미정'} · 중요도 ${jsonDecode(e['data'])['중요도'] ?? '-'}\n${e['body']}'
        : '${kinds[e['kind']]} · ${e['body']}',
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
  ),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => c.push('/entity/${e['id']}'),
);
const fields = {
  'character': [
    '별명 / 별호',
    '성별',
    '나이',
    '생일',
    '출신',
    '외모',
    '성격',
    '말투',
    '직업',
    '상태',
    '능력',
    '무공 / 마법 / 기술',
    '장비',
    '과거',
    '목표',
    '비밀',
    '사용자 메모',
  ],
  'faction': ['유형', '사용자 메모'],
  'location': ['유형', '사용자 메모'],
  'event': ['발생 시점 / 연호', '순서', '중요도', '사용자 메모'],
  'lore': ['카테고리', '사용자 메모'],
};
Future<String?> editEntity(
  BuildContext c,
  WidgetRef ref,
  String work,
  String kind, [
  Map<String, dynamic>? entity,
]) async {
  final result = await Navigator.of(c).push<String>(
    MaterialPageRoute(
      builder: (_) => EntityEditor(work: work, kind: kind, entity: entity),
    ),
  );
  refresh(ref);
  return result;
}

class EntityEditor extends StatefulWidget {
  final String work, kind;
  final Map<String, dynamic>? entity;
  final String? draftId;
  const EntityEditor({
    super.key,
    required this.work,
    required this.kind,
    this.entity,
    this.draftId,
  });
  @override
  State<EntityEditor> createState() => _EntityEditorState();
}

class _EntityEditorState extends State<EntityEditor>
    with WidgetsBindingObserver {
  late final String id;
  late final TextEditingController title, body;
  late Map<String, TextEditingController> values;
  bool busy = false, closing = false;
  bool edited = false, restoring = false;
  Timer? timer;
  Future<void> draftWrite = Future.value();
  String status = '변경 내용을 저장하세요';
  @override
  void initState() {
    super.initState();
    id = widget.entity?['id'] ?? widget.draftId ?? db.id();
    WidgetsBinding.instance.addObserver(this);
    title = TextEditingController(text: widget.entity?['title']);
    body = TextEditingController(text: widget.entity?['body']);
    final data = widget.entity == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(widget.entity!['data']));
    values = {
      for (final k in {...?fields[widget.kind], '태그', ...data.keys})
        k: TextEditingController(text: '${data[k] ?? ''}'),
    };
    status = '입력 내용은 초안으로 자동 저장됩니다';
    for (final controller in [title, body, ...values.values]) {
      controller.addListener(scheduleDraft);
    }
    restoreDraft();
  }

  Future<void> restoreDraft() async {
    final rows = await db.rows('SELECT * FROM drafts WHERE id=?', [id]);
    if (!mounted || edited || rows.isEmpty) return;
    final draft = rows.single;
    restoring = true;
    title.text = draft['title'];
    body.text = draft['body'];
    for (final e
        in (jsonDecode(draft['data']) as Map<String, dynamic>).entries) {
      if (!values.containsKey(e.key)) {
        values[e.key] = TextEditingController()..addListener(scheduleDraft);
      }
      values[e.key]!.text = '${e.value}';
    }
    restoring = false;
    setState(() => status = '저장되지 않은 초안을 복구했습니다');
  }

  void scheduleDraft() {
    if (restoring || busy || closing) return;
    edited = true;
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 500), persistDraft);
  }

  bool get hasContent =>
      title.text.trim().isNotEmpty ||
      body.text.trim().isNotEmpty ||
      values.values.any((value) => value.text.trim().isNotEmpty);
  Future<void> persistDraft({bool force = false}) async {
    if ((busy || closing) && !force) return;
    final content = hasContent;
    final name = title.text,
        text = body.text,
        data = jsonEncode({
          for (final e in values.entries) e.key: e.value.text,
        });
    draftWrite = draftWrite
        .catchError((Object _) {})
        .then(
          (_) => !content
              ? db.run('DELETE FROM drafts WHERE id=?', [id])
              : db.run(
                  'INSERT INTO drafts VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,body=excluded.body,data=excluded.data',
                  [id, widget.work, widget.kind, name, text, data],
                ),
        );
    try {
      await draftWrite;
      if (mounted) setState(() => status = '초안 자동 저장됨');
    } catch (e) {
      if (mounted) setState(() => status = '초안 저장 실패: ${errorMessage(e)}');
      if (force) rethrow;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && edited && !busy && !closing) {
      timer?.cancel();
      persistDraft();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    title.dispose();
    body.dispose();
    for (final v in values.values) {
      v.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    timer?.cancel();
    await draftWrite.catchError((Object _) {});
    if (title.text.trim().isEmpty) {
      throw const FormatException('이름 또는 제목을 입력하세요');
    }
    await db.transaction(() async {
      await db.saveEntity(
        id,
        widget.work,
        widget.kind,
        title.text.trim(),
        body.text,
        {for (final e in values.entries) e.key: e.value.text},
        favorite: widget.entity?['favorite'] == 1,
      );
      await db.run('DELETE FROM drafts WHERE id=?', [id]);
    });
  }

  Future<void> finish({bool allowDraft = false}) async {
    if (busy || closing) return;
    setState(() => busy = true);
    timer?.cancel();
    try {
      if (allowDraft && title.text.trim().isEmpty) {
        await persistDraft(force: true);
      } else {
        await save();
      }
      if (mounted) {
        closing = true;
        Navigator.pop(context, title.text.trim().isEmpty ? null : id);
      }
    } finally {
      if (mounted && !closing) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) async {
      if (!didPop) await guarded(c, () => finish(allowDraft: true));
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text('${kinds[widget.kind]} 편집'),
        actions: [
          TextButton(
            onPressed: busy || closing
                ? null
                : () => guarded(c, () => finish()),
            child: const Text('저장'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(status),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('소속·지역 계층·사건 참여 등 연결은 저장 후 상세 화면의 자료 연결에서 설정하세요.'),
          ),
          const SizedBox(height: 12),
          TextField(
            readOnly: busy || closing,
            controller: title,
            decoration: const InputDecoration(labelText: '이름 / 제목 *'),
          ),
          const SizedBox(height: 16),
          TextField(
            readOnly: busy || closing,
            controller: body,
            maxLines: 5,
            decoration: const InputDecoration(labelText: '소개 / 설명'),
          ),
          const SizedBox(height: 16),
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('상세 속성'),
            children: [
              for (final e in values.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        readOnly: busy || closing,
                        controller: e.value,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(labelText: e.key),
                      ),
                      if (e.key == '태그' || e.key == '카테고리')
                        TextButton.icon(
                          onPressed: busy || closing
                              ? null
                              : () => guarded(
                                  c,
                                  () => pickCatalog(
                                    c,
                                    widget.work,
                                    e.key,
                                    e.value,
                                  ),
                                ),
                          icon: const Icon(Icons.label_outline, size: 16),
                          label: Text('등록된 ${e.key} 선택'),
                        ),
                    ],
                  ),
                ),
            ],
          ),
          TextButton.icon(
            onPressed: busy || closing
                ? null
                : () async {
                    final ctrl = TextEditingController();
                    final key = await showDialog<String>(
                      context: c,
                      builder: (c) => AlertDialog(
                        title: const Text('사용자 정의 속성'),
                        content: TextField(
                          controller: ctrl,
                          decoration: const InputDecoration(labelText: '속성 이름'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
                            child: const Text('추가'),
                          ),
                        ],
                      ),
                    );
                    if (key != null &&
                        key.isNotEmpty &&
                        !values.containsKey(key)) {
                      setState(
                        () =>
                            values[key] = TextEditingController()
                              ..addListener(scheduleDraft),
                      );
                      scheduleDraft();
                    }
                  },
            icon: const Icon(Icons.add),
            label: const Text('속성 추가'),
          ),
        ],
      ),
    ),
  );
}

class EntityDetail extends ConsumerWidget {
  final String id;
  const EntityDetail({super.key, required this.id});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    ref.watch(changes);
    return FutureBuilder(
      future: db.rows('SELECT * FROM entities WHERE id=?', [id]),
      builder: (c, s) => loading(s, (rows) {
        if (rows.isEmpty) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('삭제된 자료입니다.')),
          );
        }
        final e = rows.single;
        final data = Map<String, dynamic>.from(jsonDecode(e['data']));
        return Scaffold(
          appBar: AppBar(
            title: Text(e['title']),
            actions: [
              IconButton(
                icon: Icon(e['favorite'] == 1 ? Icons.star : Icons.star_border),
                onPressed: () => guarded(c, () async {
                  await db.run(
                    'UPDATE entities SET favorite=1-favorite WHERE id=?',
                    [id],
                  );
                  refresh(ref);
                }),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => editEntity(c, ref, e['work'], e['kind'], e),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => guarded(c, () async {
                  if (await confirm(
                    c,
                    '자료를 휴지통으로 옮길까요? 복원하면 연결과 첨부도 함께 복구됩니다.',
                  )) {
                    await TrashService(db).removeEntity(id);
                    refresh(ref);
                    if (c.mounted) c.pop();
                  }
                }),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (e['kind'] == 'location')
                FilledButton.icon(
                  onPressed: () => Navigator.of(c).push(
                    MaterialPageRoute(
                      builder: (_) => WorldMap(work: e['work'], mapId: id),
                    ),
                  ),
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('지도·장소 마커'),
                ),
              if (e['kind'] == 'faction')
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(c).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          GraphScreen(work: e['work'], kind: 'faction'),
                    ),
                  ),
                  icon: const Icon(Icons.account_tree_outlined),
                  label: const Text('세력 관계·조직도'),
                ),
              Text(e['body'], style: Theme.of(c).textTheme.bodyLarge),
              const SizedBox(height: 16),
              for (final field in data.entries.where(
                (v) => '${v.value}'.isNotEmpty,
              ))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(field.key),
                  subtitle: Text('${field.value}'),
                ),
              const Divider(),
              Row(
                children: [
                  Text('연결된 자료', style: Theme.of(c).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    onPressed: () => linkForm(c, ref, e['work'], id),
                    icon: const Icon(Icons.add_link),
                  ),
                ],
              ),
              EntityConnections(id: id, work: e['work']),
              const Divider(),
              Row(
                children: [
                  Text('이미지·첨부파일', style: Theme.of(c).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: () => guarded(c, () async {
                      final result = await FilePicker.pickFile();
                      final path = result?.path;
                      if (path == null) return;
                      final ext = path.split('.').last.toLowerCase();
                      final name =
                          '${db.id()}.${RegExp(r"^[a-z0-9]+$").hasMatch(ext) ? ext : 'bin'}';
                      await File(path).copy('${media.path}/$name');
                      await db.run('INSERT INTO attachments VALUES (?,?,?,?)', [
                        db.id(),
                        e['work'],
                        id,
                        name,
                      ]);
                      refresh(ref);
                    }),
                  ),
                ],
              ),
              FutureBuilder(
                future: db.rows('SELECT * FROM attachments WHERE entity=?', [
                  id,
                ]),
                builder: (c, s) => loading(
                  s,
                  (r) => Column(
                    children: [
                      for (final a in r)
                        Column(
                          children: [
                            if (RegExp(r'\.(jpg|jpeg|png|webp|gif)$')
                                .hasMatch(a['name']))
                              Image.file(
                                File('${media.path}/${a['name']}'),
                                height: 240,
                                errorBuilder: (_, _, _) =>
                                    const Text('이미지를 읽을 수 없습니다'),
                              ),
                            ListTile(
                              title: Text(a['name']),
                              subtitle: const Text('눌러서 파일 내보내기'),
                              onTap: () => guarded(c, () async {
                                await FilePicker.saveFile(
                                  fileName: a['name'],
                                  bytes: await File(
                                    '${media.path}/${a['name']}',
                                  ).readAsBytes(),
                                );
                              }),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => guarded(c, () async {
                                  if (await confirm(c, '첨부파일 연결을 삭제할까요?')) {
                                    await db.run(
                                      'DELETE FROM attachments WHERE id=?',
                                      [a['id']],
                                    );
                                    refresh(ref);
                                  }
                                }),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

Future<void> linkForm(
  BuildContext c,
  WidgetRef ref,
  String work,
  String source, {
  Map<String, dynamic>? existing,
  String? targetKind,
}) async {
  final items = await db.rows(
    'SELECT * FROM entities WHERE work=? AND id<>?${targetKind == null ? '' : ' AND kind=?'} ORDER BY title',
    [work, source, ?targetKind],
  );
  if (!c.mounted) return;
  final sourceKind = (await db.rows('SELECT kind FROM entities WHERE id=?', [
    source,
  ])).single['kind'];
  if (!c.mounted) return;
  final defaults = targetKind == 'faction' && sourceKind == 'character'
      ? ['소속', '구성원']
      : targetKind == 'character' && sourceKind == 'faction'
      ? ['구성원', '소속']
      : targetKind == 'event'
      ? ['참여 사건', '참여자']
      : ['관련', '관련'];
  await showDialog(
    context: c,
    builder: (_) => _LinkDialog(
      work: work,
      source: source,
      items: items,
      defaults: defaults,
      existing: existing,
    ),
  );
}

class _LinkDialog extends ConsumerStatefulWidget {
  final String work, source;
  final List<Map<String, dynamic>> items;
  final List<String> defaults;
  final Map<String, dynamic>? existing;
  const _LinkDialog({
    required this.work,
    required this.source,
    required this.items,
    required this.defaults,
    this.existing,
  });
  @override
  ConsumerState<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends ConsumerState<_LinkDialog> {
  late final label = TextEditingController(
    text: widget.existing?['label'] ?? widget.defaults[0],
  );
  late final reverse = TextEditingController(
    text: widget.existing?['reverse'] ?? widget.defaults[1],
  );
  late String? target = widget.existing?['target'];
  late bool directed = widget.existing?['directed'] == 1;
  @override
  void dispose() {
    label.dispose();
    reverse.dispose();
    super.dispose();
  }

  void set(VoidCallback action) => setState(action);
  @override
  Widget build(BuildContext c) {
    final work = widget.work,
        source = widget.source,
        items = widget.items,
        existing = widget.existing;
    return AlertDialog(
      title: const Text('자료 연결 / 관계'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: target,
              isExpanded: true,
              items: [
                for (final e in items)
                  DropdownMenuItem(
                    value: e['id'] as String,
                    child: Text('${e['title']} · ${kinds[e['kind']]}'),
                  ),
              ],
              onChanged: (v) => target = v,
              decoration: const InputDecoration(labelText: '연결할 자료'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final pair in const [
                  ['가족', '가족'],
                  ['부모', '자녀'],
                  ['형제', '형제'],
                  ['스승', '제자'],
                  ['연인', '연인'],
                  ['친구', '친구'],
                  ['동료', '동료'],
                  ['동맹', '동맹'],
                  ['적대', '적대'],
                  ['라이벌', '라이벌'],
                  ['소속', '구성원'],
                  ['구성원', '소속'],
                  ['대표자', '대표 세력'],
                  ['상위 조직', '하위 조직'],
                  ['상위 지역', '하위 지역'],
                  ['참여 사건', '참여자'],
                  ['선행 사건', '후속 사건'],
                ])
                  ActionChip(
                    label: Text(pair.first),
                    onPressed: () => set(() {
                      label.text = pair.first;
                      reverse.text = pair.last;
                      directed = pair.first != pair.last;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: label,
              decoration: const InputDecoration(
                labelText: '관계 (예: 스승, 소속, 참여)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reverse,
              decoration: const InputDecoration(
                labelText: '반대쪽에서 표시할 관계 (예: 제자)',
              ),
            ),
            SwitchListTile(
              title: const Text('방향 표시'),
              value: directed,
              onChanged: (v) => set(() => directed = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
        FilledButton(
          onPressed: () => guarded(c, () async {
            if (target == null || label.text.trim().isEmpty) return;
            await db.saveLink(
              existing?['id'] ?? db.id(),
              work,
              source,
              target!,
              label.text.trim(),
              reverse.text.trim(),
              directed,
            );
            refresh(ref);
            if (c.mounted) Navigator.pop(c);
          }),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class DraftsScreen extends ConsumerWidget {
  final String work;
  const DraftsScreen({super.key, required this.work});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    ref.watch(changes);
    return Scaffold(
      appBar: AppBar(title: const Text('자동 저장 초안')),
      body: FutureBuilder(
        future: db.rows('SELECT * FROM drafts WHERE work=?', [work]),
        builder: (c, s) => loading(
          s,
          (rows) => rows.isEmpty
              ? const Center(child: Text('미완료 초안이 없습니다.'))
              : ListView(
                  children: [
                    for (final d in rows)
                      ListTile(
                        title: Text(
                          d['title'].toString().isEmpty
                              ? '제목 없는 초안'
                              : d['title'],
                        ),
                        subtitle: Text(kinds[d['kind']] ?? ''),
                        onTap: () => guarded(c, () async {
                          final entities = await db.rows(
                            'SELECT * FROM entities WHERE id=?',
                            [d['id']],
                          );
                          if (!c.mounted) return;
                          await Navigator.of(c).push(
                            MaterialPageRoute(
                              builder: (_) => EntityEditor(
                                work: work,
                                kind: d['kind'],
                                draftId: d['id'],
                                entity: entities.isEmpty
                                    ? null
                                    : entities.single,
                              ),
                            ),
                          );
                          refresh(ref);
                        }),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => guarded(c, () async {
                            if (await confirm(c, '이 초안을 삭제할까요?')) {
                              await db.run('DELETE FROM drafts WHERE id=?', [
                                d['id'],
                              ]);
                              refresh(ref);
                            }
                          }),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class EntityAvatar extends StatelessWidget {
  final String id;
  final bool favorite;
  const EntityAvatar({super.key, required this.id, required this.favorite});
  @override
  Widget build(BuildContext c) => FutureBuilder(
    future: db.rows('SELECT name FROM attachments WHERE entity=?', [id]),
    builder: (c, s) {
      final photos = s.data
          ?.where(
            (a) => RegExp(r'\.(png|jpg|jpeg|gif|webp)$').hasMatch(a['name']),
          )
          .toList();
      final fallback = Icon(favorite ? Icons.star : Icons.person_outline);
      if (photos == null || photos.isEmpty) return fallback;
      return ClipOval(
        child: Image.file(
          File('${media.path}/${photos.first['name']}'),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          cacheWidth: 120,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    },
  );
}

class EntityConnections extends ConsumerWidget {
  final String id, work;
  const EntityConnections({super.key, required this.id, required this.work});
  @override
  Widget build(BuildContext c, WidgetRef ref) => FutureBuilder(
    future: db.rows(
      'SELECT l.*,e.title,e.kind FROM links l JOIN entities e ON e.id=CASE WHEN l.source=? THEN l.target ELSE l.source END WHERE l.work=? AND (l.source=? OR l.target=?)',
      [id, work, id, id],
    ),
    builder: (c, s) => loading(
      s,
      (rows) => Column(
        children: [
          for (final group in const {
            'character': '관련 인물',
            'faction': '소속·관련 세력',
            'location': '관련 장소',
            'event': '참여·관련 사건',
            'lore': '관련 설정',
          }.entries)
            ExpansionTile(
              key: PageStorageKey('links-$id-${group.key}'),
              initiallyExpanded: (rows as List).any(
                (l) => l['kind'] == group.key,
              ),
              title: Text(
                '${group.value} · ${rows.where((l) => l['kind'] == group.key).length}',
              ),
              children: [
                for (final l in rows.where((l) => l['kind'] == group.key))
                  ListTile(
                    title: Text(l['title']),
                    subtitle: Text(
                      l['target'] == id && l['reverse'] != ''
                          ? l['reverse']
                          : l['label'],
                    ),
                    onTap: () => c.push(
                      '/entity/${l['source'] == id ? l['target'] : l['source']}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => guarded(c, () async {
                        if (v == 'edit') {
                          await linkForm(
                            c,
                            ref,
                            work,
                            l['source'],
                            existing: l,
                          );
                        } else if (await confirm(c, '이 연결을 삭제할까요?')) {
                          await db.run('DELETE FROM links WHERE id=?', [
                            l['id'],
                          ]);
                          refresh(ref);
                        }
                      }),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('관계 수정')),
                        PopupMenuItem(value: 'delete', child: Text('연결 삭제')),
                      ],
                    ),
                  ),
                TextButton.icon(
                  onPressed: () =>
                      linkForm(c, ref, work, id, targetKind: group.key),
                  icon: const Icon(Icons.add_link),
                  label: Text('${group.value} 연결'),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}
