import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:convert';

import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';

import '../core/runtime.dart';
import '../core/trash.dart';
import 'organize.dart';
import 'trash.dart';
import '../app/theme.dart';
import 'entities.dart';
import 'settings.dart';

Future<void> workForm(
  BuildContext c,
  WidgetRef ref, [
  Map<String, dynamic>? w,
]) async {
  await showDialog(
    context: c,
    builder: (_) => _WorkDialog(work: w),
  );
}

class _WorkDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? work;
  const _WorkDialog({this.work});
  @override
  ConsumerState<_WorkDialog> createState() => _WorkDialogState();
}

class _WorkDialogState extends ConsumerState<_WorkDialog> {
  late final title = TextEditingController(text: widget.work?['title']);
  late final genre = TextEditingController(text: widget.work?['genre']);
  late final body = TextEditingController(text: widget.work?['body']);
  @override
  void dispose() {
    title.dispose();
    genre.dispose();
    body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final w = widget.work;
    return AlertDialog(
      title: Text(w == null ? '새 작품' : '작품 수정'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: '제목 *'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: genre,
              decoration: const InputDecoration(labelText: '장르'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: body,
              maxLines: 4,
              decoration: const InputDecoration(labelText: '작품 설명'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
        FilledButton(
          onPressed: () => guarded(c, () async {
            if (title.text.trim().isEmpty) {
              return;
            }
            await db.saveWork(
              w?['id'] ?? db.id(),
              title.text.trim(),
              genre.text,
              body.text,
            );
            refresh(ref);
            if (c.mounted) {
              Navigator.pop(c);
            }
          }),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class Library extends ConsumerStatefulWidget {
  const Library({super.key});
  @override
  ConsumerState<Library> createState() => _LibraryState();
}

class _LibraryState extends ConsumerState<Library> {
  String query = '';
  @override
  Widget build(BuildContext c) {
    ref.watch(changes);
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_outlined, size: 20),
            SizedBox(width: 10),
            Text('로어 위버'),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => c.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => workForm(c, ref),
        icon: const Icon(Icons.add),
        label: const Text('새 작품'),
      ),
      body: PageWidth(
        child: Column(
          children: [
            if (MediaQuery.viewInsetsOf(c).bottom == 0 &&
                MediaQuery.sizeOf(c).height > 550)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '나만의 창작 공간',
                          style: Theme.of(c).textTheme.bodySmall,
                        ),
                        const Spacer(),
                        Icon(
                          Icons.cloud_off_outlined,
                          size: 14,
                          color: Theme.of(c).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text('오프라인', style: Theme.of(c).textTheme.bodySmall),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('작품 서재', style: Theme.of(c).textTheme.headlineLarge),
                    const SizedBox(height: 8),
                    Text(
                      '흩어진 상상을 하나의 세계로.',
                      style: Theme.of(c).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(c).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '작품 검색',
                ),
                onChanged: (s) => setState(() => query = s),
              ),
            ),
            Expanded(
              child: FutureBuilder(
                future: db.rows(
                  'SELECT w.*, (SELECT count(*) FROM entities e WHERE e.work=w.id AND kind=?) AS characters, (SELECT count(*) FROM entities e WHERE e.work=w.id AND kind=?) AS factions, (SELECT count(*) FROM entities e WHERE e.work=w.id AND kind=?) AS events FROM works w WHERE title LIKE ? ORDER BY updated DESC',
                  ['character', 'faction', 'event', '%$query%'],
                ),
                builder: (c, s) => loading(
                  s,
                  (rows) => rows.isEmpty
                      ? LibraryEmpty(
                          searching: query.isNotEmpty,
                          onCreate: () => workForm(c, ref),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                          itemCount: rows.length,
                          itemBuilder: (c, i) {
                            final w = rows[i];
                            return Card(
                              child: ListTile(
                                contentPadding: const EdgeInsets.all(20),
                                leading: WorkCover(work: w['id']),
                                title: Text(
                                  w['title'],
                                  style: Theme.of(c).textTheme.titleLarge,
                                ),
                                subtitle: Text(
                                  '${w['genre']}\n인물 ${w['characters']} · 세력 ${w['factions']} · 사건 ${w['events']}',
                                ),
                                isThreeLine: true,
                                onTap: () => c.push('/work/${w['id']}'),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (v) => guarded(c, () async {
                                    if (v == 'edit') {
                                      await workForm(c, ref, w);
                                    }
                                    if (v == 'cover') {
                                      await pickCover(w['id']);
                                      refresh(ref);
                                    }
                                    if (v == 'copy') {
                                      await db.duplicate(w['id']);
                                      refresh(ref);
                                    }
                                    if (c.mounted &&
                                        v == 'delete' &&
                                        await confirm(
                                          c,
                                          '작품과 모든 설정을 휴지통으로 옮길까요?',
                                        )) {
                                      await TrashService(db)
                                          .removeWork(w['id']);
                                      refresh(ref);
                                    }
                                  }),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'cover',
                                      child: Text('표지 이미지 등록'),
                                    ),
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text('수정'),
                                    ),
                                    PopupMenuItem(
                                      value: 'copy',
                                      child: Text('복제'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('삭제'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Workspace extends ConsumerStatefulWidget {
  final String work;
  const Workspace({super.key, required this.work});
  @override
  ConsumerState<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends ConsumerState<Workspace> {
  String section = 'dashboard', query = '', tag = '';
  bool alphabetical = false, favorites = false;
  String? factionFilter, typeFilter, categoryFilter;
  @override
  Widget build(BuildContext c) {
    ref.watch(changes);
    return Scaffold(
      appBar: AppBar(
        title: const Text('세계관 작업실'),
        actions: [
          IconButton(
            tooltip: '인물 관계도',
            onPressed: () => c.push('/graph/${widget.work}'),
            icon: const Icon(Icons.hub_outlined),
          ),
          IconButton(
            tooltip: '작품 백업',
            onPressed: () => exportBackup(c, widget.work),
            icon: const Icon(Icons.archive_outlined),
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('세계관 탐색')),
              ListTile(
                leading: const Icon(Icons.label_outline),
                title: const Text('태그·카테고리 관리'),
                onTap: () => Navigator.of(c).push(
                  MaterialPageRoute(
                    builder: (_) => CatalogScreen(work: widget.work),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: const Text('지역 계층'),
                onTap: () => Navigator.of(c).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        HierarchyScreen(work: widget.work, kind: 'location'),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('조직 계층'),
                onTap: () => Navigator.of(c).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        HierarchyScreen(work: widget.work, kind: 'faction'),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('휴지통'),
                onTap: () => Navigator.of(c).push(
                  MaterialPageRoute(
                    builder: (_) => TrashScreen(work: widget.work),
                  ),
                ),
              ),
              for (final e in {
                'dashboard': '대시보드',
                ...kinds,
                'search': '통합 검색',
              }.entries)
                ListTile(
                  selected: section == e.key,
                  title: Text(e.value),
                  onTap: () {
                    setState(() => section = e.key);
                    Navigator.pop(c);
                  },
                ),
              ListTile(
                title: const Text('자동 저장 초안'),
                onTap: () => Navigator.of(c).push(
                  MaterialPageRoute(
                    builder: (_) => DraftsScreen(work: widget.work),
                  ),
                ),
              ),
              ListTile(
                title: const Text('인물 관계도'),
                onTap: () => c.push('/graph/${widget.work}'),
              ),
              ListTile(
                title: const Text('설정·백업'),
                onTap: () => c.push('/settings'),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: section == 'dashboard' || section == 'search'
          ? null
          : FloatingActionButton.extended(
              onPressed: () => editEntity(c, ref, widget.work, section),
              icon: const Icon(Icons.add),
              label: Text('${kinds[section]} 등록'),
            ),
      body: FutureBuilder(
        future: Future.wait([
          db.rows('SELECT * FROM entities WHERE work=? ORDER BY updated DESC', [
            widget.work,
          ]),
          db.rows('SELECT * FROM links WHERE work=?', [widget.work]),
        ]),
        builder: (c, s) => loading(s, (raw) {
          final all = List<Map<String, dynamic>>.from(raw[0]);
          final links = List<Map<String, dynamic>>.from(raw[1]);
          final factionMembers = links
              .where(
                (l) =>
                    (l['label'] == '소속' || l['reverse'] == '소속') &&
                    (l['source'] == factionFilter ||
                        l['target'] == factionFilter),
              )
              .expand((l) => [l['source'], l['target']])
              .toSet();
          if (section == 'dashboard') {
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                PopupMenuButton<String>(
                  onSelected: (kind) => editEntity(c, ref, widget.work, kind),
                  itemBuilder: (_) => [
                    for (final k in kinds.entries)
                      PopupMenuItem(value: k.key, child: Text(k.value)),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.add_circle_outline),
                        SizedBox(width: 8),
                        Text('설정 빠른 등록'),
                      ],
                    ),
                  ),
                ),
                FutureBuilder(
                  future: db.rows('SELECT * FROM works WHERE id=?', [
                    widget.work,
                  ]),
                  builder: (c, s) => loading(
                    s,
                    (r) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.single['title'],
                          style: Theme.of(c).textTheme.headlineLarge,
                        ),
                        Text(r.single['body']),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final k in kinds.entries)
                      ActionChip(
                        label: Text(
                          '${k.value} ${all.where((e) => e['kind'] == k.key).length}',
                        ),
                        onPressed: () => setState(() => section = k.key),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => c.push('/graph/${widget.work}'),
                  icon: const Icon(Icons.hub),
                  label: const Text('인물 관계도 편집'),
                ),
                const SizedBox(height: 24),
                Text('즐겨찾기', style: Theme.of(c).textTheme.titleLarge),
                for (final e in all.where((e) => e['favorite'] == 1))
                  entityTile(c, e),
                const SizedBox(height: 20),
                Text('최근 수정한 설정', style: Theme.of(c).textTheme.titleLarge),
                if (all.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('메뉴에서 인물, 세력, 사건을 등록하세요.'),
                  ),
                for (final e in all.take(10)) entityTile(c, e),
              ],
            );
          }
          final categories =
              all
                  .where((e) => e['kind'] == 'lore')
                  .map((e) => '${jsonDecode(e['data'])['카테고리'] ?? ''}'.trim())
                  .where((s) => s.isNotEmpty)
                  .toSet()
                  .toList()
                ..sort();
          if (!categories.contains(categoryFilter)) categoryFilter = null;
          if (!all.any(
            (e) => e['id'] == factionFilter && e['kind'] == 'faction',
          )) {
            factionFilter = null;
          }
          var list = all
              .where(
                (e) =>
                    (section == 'search' || e['kind'] == section) &&
                    (section != 'lore' ||
                        categoryFilter == null ||
                        jsonDecode(e['data'])['카테고리'] == categoryFilter) &&
                    (section != 'search' ||
                        typeFilter == null ||
                        e['kind'] == typeFilter) &&
                    (section != 'character' ||
                        factionFilter == null ||
                        factionMembers.contains(e['id'])) &&
                    ('${e['title']} ${e['body']} ${e['data']}')
                        .toLowerCase()
                        .contains(query.toLowerCase()) &&
                    (!favorites || e['favorite'] == 1) &&
                    (tag.isEmpty ||
                        '${jsonDecode(e['data'])['태그'] ?? ''}'.contains(tag)),
              )
              .toList();
          if (alphabetical) {
            list.sort((a, b) => '${a['title']}'.compareTo('${b['title']}'));
          }
          if (section == 'event' && !alphabetical) {
            list.sort(
              (a, b) => (num.tryParse('${jsonDecode(a['data'])['순서']}') ?? 0)
                  .compareTo(
                    num.tryParse('${jsonDecode(b['data'])['순서']}') ?? 0,
                  ),
            );
          }
          return Column(
            children: [
              if (section == 'lore')
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(categoryFilter),
                    initialValue: categoryFilter,
                    decoration: const InputDecoration(labelText: '설정 카테고리'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('모든 카테고리'),
                      ),
                      for (final name in categories)
                        DropdownMenuItem(value: name, child: Text(name)),
                    ],
                    onChanged: (v) => setState(() => categoryFilter = v),
                  ),
                ),
              if (section == 'search')
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: DropdownButtonFormField<String>(
                    initialValue: typeFilter,
                    decoration: const InputDecoration(labelText: '자료 유형'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('전체 유형')),
                      for (final k in kinds.entries)
                        DropdownMenuItem(value: k.key, child: Text(k.value)),
                    ],
                    onChanged: (v) => setState(() => typeFilter = v),
                  ),
                ),
              if (section == 'character')
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: DropdownButtonFormField<String>(
                    initialValue: factionFilter,
                    decoration: const InputDecoration(labelText: '소속 세력 필터'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('모든 세력')),
                      for (final e in all.where((e) => e['kind'] == 'faction'))
                        DropdownMenuItem(
                          value: e['id'] as String,
                          child: Text(e['title']),
                        ),
                    ],
                    onChanged: (v) => setState(() => factionFilter = v),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  decoration: InputDecoration(
                    labelText: section == 'search'
                        ? '모든 설정·태그 검색'
                        : '${kinds[section]} 검색',
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => query = v),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('이름순'),
                      selected: alphabetical,
                      onSelected: (v) => setState(() => alphabetical = v),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('즐겨찾기'),
                      selected: favorites,
                      onSelected: (v) => setState(() => favorites = v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: '태그 필터',
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => tag = v),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('등록된 자료가 없습니다.'))
                    : section == 'event' &&
                          !alphabetical &&
                          query.isEmpty &&
                          tag.isEmpty &&
                          !favorites
                    ? ReorderableListView(
                        padding: const EdgeInsets.only(bottom: 100),
                        header: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('사건을 길게 눌러 순서를 바꾸세요.'),
                        ),
                        onReorderItem: (from, to) => guarded(c, () async {
                          final ordered = [...list];
                          final item = ordered.removeAt(from);
                          ordered.insert(to, item);
                          await db.transaction(() async {
                            for (var i = 0; i < ordered.length; i++) {
                              final e = ordered[i];
                              final data = Map<String, dynamic>.from(
                                jsonDecode(e['data']),
                              );
                              data['순서'] = '$i';
                              await db.saveEntity(
                                e['id'],
                                widget.work,
                                'event',
                                e['title'],
                                e['body'],
                                data,
                                favorite: e['favorite'] == 1,
                              );
                            }
                          });
                          refresh(ref);
                        }),
                        children: [
                          for (final e in list)
                            Container(
                              key: ValueKey(e['id']),
                              child: entityTile(c, e),
                            ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 100),
                        itemCount: list.length,
                        itemBuilder: (c, i) => entityTile(c, list[i]),
                      ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

Future<void> pickCover(String work) async {
  final f = await FilePicker.pickFile(type: FileType.image);
  if (f?.path == null) return;
  final ext = f!.path!.split('.').last.toLowerCase();
  if (!['png', 'jpg', 'jpeg', 'gif', 'webp'].contains(ext)) {
    throw const FormatException('지원하지 않는 이미지입니다');
  }
  final name = '${db.id()}.$ext';
  await File(f.path!).copy('${media.path}/$name');
  await db.run(
    'INSERT INTO covers VALUES (?,?) ON CONFLICT(work) DO UPDATE SET name=excluded.name',
    [work, name],
  );
}

class WorkCover extends StatelessWidget {
  final String work;
  const WorkCover({super.key, required this.work});
  @override
  Widget build(BuildContext c) => FutureBuilder(
    future: db.rows('SELECT name FROM covers WHERE work=?', [work]),
    builder: (c, s) {
      if (!s.hasData || s.data!.isEmpty) {
        return const Icon(Icons.auto_stories, size: 36);
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File('${media.path}/${s.data!.single['name']}'),
          width: 44,
          height: 60,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.auto_stories, size: 36),
        ),
      );
    },
  );
}

class LibraryEmpty extends StatelessWidget {
  final bool searching;
  final VoidCallback onCreate;
  const LibraryEmpty({
    super.key,
    required this.searching,
    required this.onCreate,
  });
  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (c, size) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 100),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: (size.maxHeight - 132).clamp(0, double.infinity),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Theme.of(c).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Theme.of(c).dividerColor),
                  ),
                  child: Icon(
                    searching ? Icons.search : Icons.auto_stories_outlined,
                    size: 34,
                    color: const Color(0xff615d59),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  searching ? '찾는 작품이 없어요' : '모든 이야기는 여기서 시작됩니다',
                  textAlign: TextAlign.center,
                  style: Theme.of(c).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Text(
                  searching ? '다른 제목으로 다시 검색해보세요.' : '첫 작품을 만들고 세계관을 기록하세요.',
                  textAlign: TextAlign.center,
                  style: Theme.of(c).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(c).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (!searching) ...[
                  const SizedBox(height: 20),
                  const Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _LibraryHint(
                        Icons.people_outline,
                        '등장인물',
                        Color(0xffa685c4),
                      ),
                      _LibraryHint(
                        Icons.hub_outlined,
                        '관계도',
                        Color(0xff2a9d99),
                      ),
                      _LibraryHint(
                        Icons.public_outlined,
                        '세계관',
                        Color(0xffdd5b00),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: onCreate,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('첫 작품 만들기'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _LibraryHint extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _LibraryHint(this.icon, this.label, this.color);
  @override
  Widget build(BuildContext c) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 5),
      Text(label, style: Theme.of(c).textTheme.bodySmall),
    ],
  );
}
