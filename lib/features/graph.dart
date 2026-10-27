import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../core/runtime.dart';
import '../core/graph_history.dart';
import '../core/graph_layout.dart';

import 'package:go_router/go_router.dart';

import 'entities.dart';

class GraphScreen extends ConsumerStatefulWidget {
  final String work;
  final String kind;
  const GraphScreen({super.key, required this.work, this.kind = 'character'});
  @override
  ConsumerState<GraphScreen> createState() => _GraphState();
}

class _GraphState extends ConsumerState<GraphScreen> {
  final transform = TransformationController();
  final boundary = GlobalKey();
  List<Map<String, dynamic>> nodes = [], edges = [];
  Map<String, Offset> positions = {};
  Map<String, String> images = {};
  String? selected, focus, board;
  List<Map<String, dynamic>> boards = [];
  late GraphHistory history;
  bool busy = false, editing = true;
  int depth = 1;
  String? relationFilter;
  @override
  void initState() {
    super.initState();
    history = GraphHistory(db, widget.work);
  }

  Future<void> edit(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final before = await history.capture();
      await action();
      history.record(before, await history.capture());
      await load();
      refresh(ref);
    } catch (_) {
      await load();
      rethrow;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> replay(bool undo) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (undo) {
        await history.undo();
      } else {
        await history.redo();
      }
      await load();
      refresh(ref);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> switchBoard(String? id) async {
    if (busy) return;
    board = id;
    selected = null;
    focus = null;
    history = GraphHistory(db, widget.work, board: board);
    fitPending = true;
    await load();
  }

  Future<void> manageBoard(String action) async {
    if (action == 'delete') {
      if (board == null ||
          !await confirm(context, '이 보드를 삭제할까요? 인물과 관계는 유지됩니다.')) {
        return;
      }
      await db.run('DELETE FROM boards WHERE id=?', [board]);
      await switchBoard(null);
      return;
    }
    final ctrl = TextEditingController(
      text: action == 'rename'
          ? boards.firstWhere((b) => b['id'] == board)['title']
          : '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(action == 'rename' ? '보드 이름 변경' : '현재 보기를 새 보드로 저장'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '보드 이름'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) {
                Navigator.pop(c, ctrl.text.trim());
              }
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (name == null) return;
    if (action == 'rename') {
      await db.run('UPDATE boards SET title=? WHERE id=?', [name, board]);
      await load();
      return;
    }
    final id = db.id();
    await db.transaction(() async {
      await db.run('INSERT INTO boards VALUES (?,?,?,?)', [
        id,
        widget.work,
        widget.kind,
        name,
      ]);
      for (final n in visibleNodes) {
        final p = positions[n['id']]!;
        await db.graphPosition(widget.work, n['id'], p.dx, p.dy, board: id);
      }
    });
    await switchBoard(id);
  }

  String? error;
  bool ready = false, dragging = false;
  int version = -1;
  double zoom = 1;
  bool fitPending = false;
  final openedBoards = <String>{};
  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  int loadSequence = 0;
  Future<void> load() async {
    final request = ++loadSequence;
    final requestedBoard = board;
    try {
      final available = await db.rows(
        'SELECT * FROM boards WHERE work=? AND kind=? ORDER BY title',
        [widget.work, widget.kind],
      );
      if (request != loadSequence || !mounted) return;
      if (board != null && !available.any((b) => b['id'] == board)) {
        board = null;
        history = GraphHistory(db, widget.work);
      }
      final activeBoard = board;
      final n = await db.rows(
        activeBoard == null
            ? 'SELECT e.* FROM entities e LEFT JOIN layouts g ON g.entity=e.id WHERE e.work=? AND e.kind=? AND (g.visible IS NULL OR g.visible=1)'
            : 'SELECT e.* FROM entities e JOIN board_nodes g ON g.entity=e.id AND g.work=e.work WHERE e.work=? AND e.kind=? AND g.board=?',
        [widget.work, widget.kind, ?activeBoard],
      );
      final e = await db.rows('SELECT * FROM links WHERE work=?', [
        widget.work,
      ]);
      final layouts = await db.rows(
        activeBoard == null
            ? 'SELECT * FROM layouts WHERE work=?'
            : 'SELECT * FROM board_nodes WHERE work=? AND board=?',
        [widget.work, ?activeBoard],
      );
      final photos = await db.rows(
        'SELECT entity,name FROM attachments WHERE work=?',
        [widget.work],
      );
      final p = {
        for (final l in layouts)
          l['entity'] as String: Offset(
            (l['x'] as num).toDouble(),
            (l['y'] as num).toDouble(),
          ),
      };
      for (var i = 0; i < n.length; i++) {
        p.putIfAbsent(
          n[i]['id'],
          () => Offset(150 + (i % 8) * 210, 150 + (i ~/ 8) * 150),
        );
      }
      if (mounted &&
          request == loadSequence &&
          (requestedBoard == board || activeBoard == board)) {
        final scope = activeBoard ?? 'all';
        if (!openedBoards.contains(scope)) {
          final occupied = <String>{};
          final repaired = <String, Offset>{};
          for (final node in n) {
            final id = node['id'] as String;
            final original = p[id]!;
            var candidate = original;
            while (!occupied.add('${candidate.dx}/${candidate.dy}')) {
              candidate += const Offset(0, 150);
            }
            if (candidate != original) {
              p[id] = candidate;
              repaired[id] = candidate;
            }
          }
          if (repaired.isNotEmpty) {
            await db.transaction(() async {
              for (final node in repaired.entries) {
                await db.graphPosition(
                  widget.work,
                  node.key,
                  node.value.dx,
                  node.value.dy,
                  board: activeBoard,
                );
              }
            });
            fitPending = true;
          }
          openedBoards.add(scope);
          if (!mounted || request != loadSequence) return;
        }
        final oldIds = nodes.map((node) => node['id']).toSet();
        if (!ready || n.any((node) => !oldIds.contains(node['id']))) {
          fitPending = true;
        }
        setState(() {
          nodes = n;
          boards = available;
          if (!n.any((node) => node['id'] == focus)) focus = null;
          edges = e;
          positions = p;
          images = {
            for (final a in photos.where(
              (a) => RegExp(r'\.(png|jpg|jpeg|webp)$').hasMatch(a['name']),
            ))
              a['entity']: a['name'],
          };
          ready = true;
          error = null;
        });
        if (fitPending) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && request == loadSequence && fitPending) {
              fitPending = false;
              fit();
            }
          });
        }
      }
    } catch (e) {
      if (mounted && request == loadSequence) {
        setState(() => error = errorMessage(e));
      }
    }
  }

  List<Map<String, dynamic>> get visibleNodes {
    if (focus == null) return nodes;
    final ids = {focus};
    for (var step = 0; step < depth; step++) {
      final previous = {...ids};
      for (final e in edges.where(
        (e) => relationFilter == null || e['label'] == relationFilter,
      )) {
        if (previous.contains(e['source'])) ids.add(e['target']);
        if (previous.contains(e['target'])) ids.add(e['source']);
      }
    }
    return nodes.where((n) => ids.contains(n['id'])).toList();
  }

  void fit() {
    final visible = visibleNodes;
    if (visible.isEmpty) return;
    var rect = positions[visible.first['id']]! & const Size(160, 88);
    for (final node in visible.skip(1)) {
      rect = rect.expandToInclude(positions[node['id']]! & const Size(160, 88));
    }
    final viewport = boundary.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize || viewport.size.isEmpty) return;
    final size = viewport.size;
    final scale = math
        .min(
          math.max(1, size.width - 48) / rect.width,
          math.max(1, size.height - 48) / rect.height,
        )
        .clamp(.005, 2.5);
    final translation = Offset(
      (size.width - rect.width * scale) / 2 - rect.left * scale,
      (size.height - rect.height * scale) / 2 - rect.top * scale,
    );
    transform.value = Matrix4.identity()
      ..translateByDouble(translation.dx, translation.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    setState(() => zoom = scale);
  }

  Future<void> addToCanvas(String entity) async {
    final viewport = boundary.currentContext?.findRenderObject() as RenderBox?;
    final size = viewport?.size ?? MediaQuery.sizeOf(context);
    final origin = transform.toScene(const Offset(24, 24));
    final start = Offset(math.max(24, origin.dx), math.max(24, origin.dy));
    final columns = math.max(1, ((size.width / zoom - 48) / 210).floor());
    final occupied = [
      for (final node in nodes.where((node) => node['id'] != entity))
        positions[node['id']]! & const Size(160, 88),
    ];
    Offset? free;
    for (var i = 0; i <= occupied.length; i++) {
      final candidate =
          start + Offset((i % columns) * 210, (i ~/ columns) * 150);
      if (!occupied.any(
        (rect) => rect.overlaps((candidate & const Size(160, 88)).inflate(16)),
      )) {
        free = candidate;
        break;
      }
    }
    // Search beyond occupied rows when custom positions intersect several cells.
    free ??= Offset(
      start.dx,
      occupied.fold<double>(
            start.dy,
            (bottom, rect) => math.max(bottom, rect.bottom),
          ) +
          48,
    );
    setState(() {
      focus = null;
      relationFilter = null;
      selected = entity;
      fitPending = true;
    });
    await edit(
      () => db.graphPosition(
        widget.work,
        entity,
        free!.dx,
        free.dy,
        board: board,
      ),
    );
  }

  Future<void> arrange([GraphArrangement? mode]) async {
    await edit(() async {
      final p = arrangeGraph(
        visibleNodes.map((n) => n['id'] as String).toList(),
        edges,
        mode ??
            (widget.kind == 'faction'
                ? GraphArrangement.hierarchy
                : GraphArrangement.clusters),
      );
      await db.transaction(() async {
        for (final n in p.entries) {
          await db.graphPosition(
            widget.work,
            n.key,
            n.value.dx,
            n.value.dy,
            board: board,
          );
        }
      });
    });
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fit();
      });
    }
  }

  Future<void> edgeMenu(Map<String, dynamic> edge) async {
    if (!editing || busy) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              title: Text(edge['label']),
              subtitle: const Text('선택한 관계'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('관계 수정'),
              onTap: () => Navigator.pop(c, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('관계 삭제'),
              onTap: () => Navigator.pop(c, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await edit(() async {
      if (choice == 'edit') {
        await linkForm(
          context,
          ref,
          widget.work,
          edge['source'],
          existing: edge,
        );
      } else if (await confirm(context, '이 관계를 삭제할까요?')) {
        await db.run('DELETE FROM links WHERE id=?', [edge['id']]);
      }
    });
  }

  Future<void> export() async {
    final b =
        boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (b == null) return;
    final image = await b.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes != null) {
      await FilePicker.saveFile(
        fileName: '관계도.png',
        bytes: Uint8List.view(bytes.buffer),
      );
    }
  }

  @override
  Widget build(BuildContext c) {
    final v = ref.watch(changes);
    if (v != version) {
      version = v;
      WidgetsBinding.instance.addPostFrameCallback((_) => load());
    }
    final shown = visibleNodes;
    final screen = MediaQuery.sizeOf(c);
    final topLeft = transform.toScene(Offset.zero);
    final bottomRight = transform.toScene(Offset(screen.width, screen.height));
    final viewport = Rect.fromPoints(topLeft, bottomRight).inflate(250);
    final rendered = shown
        .where(
          (n) => viewport.overlaps(positions[n['id']]! & const Size(160, 88)),
        )
        .toList();
    final canvasWidth = math.max(
      2000.0,
      positions.values.fold<double>(0, (a, p) => math.max(a, p.dx)) + 400,
    );
    final canvasHeight = math.max(
      2000.0,
      positions.values.fold<double>(0, (a, p) => math.max(a, p.dy)) + 400,
    );
    final ids = shown.map((n) => n['id']).toSet();
    final lines = edges
        .where(
          (e) =>
              ids.contains(e['source']) &&
              ids.contains(e['target']) &&
              (relationFilter == null || e['label'] == relationFilter),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.kind == 'faction' ? '세력 관계·조직도' : '인물 관계도'),
        actions: [
          IconButton(
            tooltip: '실행 취소',
            onPressed: !editing || busy || !history.canUndo
                ? null
                : () => guarded(c, () => replay(true)),
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: '다시 실행',
            onPressed: !editing || busy || !history.canRedo
                ? null
                : () => guarded(c, () => replay(false)),
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: '노드 추가',
            onPressed: !editing || busy
                ? null
                : () => guarded(c, () async {
                    final hidden = await db.rows(
                      board == null
                          ? 'SELECT e.* FROM entities e JOIN layouts g ON g.entity=e.id WHERE e.work=? AND e.kind=? AND g.visible=0'
                          : 'SELECT e.* FROM entities e WHERE e.work=? AND e.kind=? AND NOT EXISTS(SELECT 1 FROM board_nodes g WHERE g.entity=e.id AND g.board=?)',
                      [widget.work, widget.kind, if (board != null) board],
                    );
                    if (!c.mounted) return;
                    await showModalBottomSheet(
                      context: c,
                      builder: (c) => SafeArea(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.person_add),
                              title: Text(
                                widget.kind == 'faction'
                                    ? '새 세력 등록'
                                    : '새 인물 등록',
                              ),
                              onTap: () async {
                                Navigator.pop(c);
                                final created = await editEntity(
                                  context,
                                  ref,
                                  widget.work,
                                  widget.kind,
                                );
                                if (mounted && created != null) {
                                  await addToCanvas(created);
                                }
                                refresh(ref);
                              },
                            ),
                            for (final n in hidden)
                              ListTile(
                                title: Text(n['title']),
                                onTap: () async {
                                  await addToCanvas(n['id']);
                                  refresh(ref);
                                  if (c.mounted) Navigator.pop(c);
                                },
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: '자동 배치',
            onPressed: busy || !editing
                ? null
                : () => guarded(c, () => arrange()),
            icon: const Icon(Icons.auto_awesome),
          ),
          PopupMenuButton<String>(
            tooltip: '관계도 메뉴',
            onSelected: (value) => guarded(c, () async {
              if (value == 'export') {
                await export();
                return;
              }
              if (value == 'lock') {
                setState(() => editing = !editing);
                return;
              }
              if (['new', 'rename', 'delete'].contains(value)) {
                await manageBoard(value);
                return;
              }
              if (editing) await arrange(GraphArrangement.values.byName(value));
            }),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'lock',
                child: Text(editing ? '보기 모드로 전환' : '편집 모드로 전환'),
              ),
              const PopupMenuItem(value: 'new', child: Text('현재 보기를 새 보드로 저장')),
              if (board != null) ...[
                const PopupMenuItem(value: 'rename', child: Text('보드 이름 변경')),
                const PopupMenuItem(value: 'delete', child: Text('보드 삭제')),
              ],
              if (editing) ...[
                const PopupMenuItem(value: 'grid', child: Text('격자 배치')),
                const PopupMenuItem(
                  value: 'hierarchy',
                  child: Text('가계도·조직도 배치'),
                ),
                const PopupMenuItem(
                  value: 'clusters',
                  child: Text('관계별 묶음 배치'),
                ),
              ],
              const PopupMenuItem(value: 'export', child: Text('현재 화면 PNG 저장')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: DropdownButtonFormField<String>(
              key: ValueKey(board),
              initialValue: board ?? 'all',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '관계 보드',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('전체 관계도')),
                for (final b in boards)
                  DropdownMenuItem(
                    value: b['id'] as String,
                    child: Text(b['title']),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) => guarded(
                      c,
                      () => switchBoard(value == 'all' ? null : value),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(focus),
                    initialValue: focus,
                    decoration: const InputDecoration(
                      labelText: '인물 중심 필터',
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('전체 관계도'),
                      ),
                      for (final n in nodes)
                        DropdownMenuItem(
                          value: n['id'] as String,
                          child: Text(n['title']),
                        ),
                    ],
                    onChanged: (v) {
                      setState(() => focus = v);
                      fit();
                    },
                  ),
                ),
                IconButton(
                  tooltip: '전체 화면 맞춤',
                  onPressed: () {
                    fit();
                  },
                  icon: const Icon(Icons.center_focus_strong),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                if (!editing) const Chip(label: Text('보기 모드')),
                ChoiceChip(
                  label: const Text('주변 1단계'),
                  selected: depth == 1,
                  onSelected: (_) => setState(() => depth = 1),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('주변 2단계'),
                  selected: depth == 2,
                  onSelected: (_) => setState(() => depth = 2),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  onSelected: (v) =>
                      setState(() => relationFilter = v == 'all' ? null : v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'all', child: Text('모든 관계')),
                    for (final label
                        in edges.map((e) => e['label'] as String).toSet())
                      PopupMenuItem(value: label, child: Text(label)),
                  ],
                  child: Chip(
                    label: Text(relationFilter ?? '모든 관계'),
                    avatar: const Icon(Icons.filter_list, size: 18),
                  ),
                ),
              ],
            ),
          ),

          if (error != null) Text(error!),
          Expanded(
            child: !ready
                ? const Center(child: CircularProgressIndicator())
                : nodes.isEmpty
                ? const Center(child: Text('상단 + 버튼으로 인물을 추가하세요.'))
                : RepaintBoundary(
                    key: boundary,
                    child: ColoredBox(
                      color: Theme.of(c).scaffoldBackgroundColor,
                      child: InteractiveViewer(
                        transformationController: transform,
                        constrained: false,
                        minScale: .005,
                        maxScale: 2.5,
                        panEnabled: !dragging,
                        boundaryMargin: const EdgeInsets.all(2000),
                        onInteractionUpdate: (_) {
                          final z = transform.value.getMaxScaleOnAxis();
                          setState(() => zoom = z);
                        },
                        child: SizedBox(
                          width: canvasWidth,
                          height: canvasHeight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) {
                              final edge = hitGraphEdge(
                                d.localPosition,
                                graphEdgePaths(lines, positions),
                                12 / zoom,
                              );
                              if (edge != null) {
                                guarded(c, () => edgeMenu(edge));
                              }
                            },
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: EdgePainter(
                                      lines,
                                      positions,
                                      Theme.of(c).scaffoldBackgroundColor,
                                    ),
                                  ),
                                ),
                                for (final n in rendered)
                                  Positioned(
                                    left: positions[n['id']]!.dx,
                                    top: positions[n['id']]!.dy,
                                    child: GestureDetector(
                                      key: ValueKey('graph-node-${n['id']}'),
                                      onTap: () =>
                                          setState(() => selected = n['id']),
                                      onPanStart: !editing || busy
                                          ? null
                                          : (_) =>
                                                setState(() => dragging = true),
                                      onPanUpdate: !editing || busy
                                          ? null
                                          : (d) => setState(() {
                                              final p =
                                                  positions[n['id']]! + d.delta;
                                              positions[n['id']] = Offset(
                                                math.max(0, p.dx),
                                                math.max(0, p.dy),
                                              );
                                            }),
                                      onPanEnd: !editing || busy
                                          ? null
                                          : (_) {
                                              setState(() => dragging = false);
                                              final p = positions[n['id']]!;
                                              guarded(
                                                c,
                                                () => edit(
                                                  () => db.graphPosition(
                                                    widget.work,
                                                    n['id'],
                                                    p.dx,
                                                    p.dy,
                                                    board: board,
                                                  ),
                                                ),
                                              );
                                            },
                                      onPanCancel: () =>
                                          setState(() => dragging = false),
                                      child: Container(
                                        width: 160,
                                        height: 88,
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: selected == n['id']
                                              ? Theme.of(c)
                                                    .colorScheme
                                                    .primaryContainer
                                              : Theme.of(c).colorScheme.surface,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          border: Border.all(
                                            color: selected == n['id']
                                                ? Theme.of(c)
                                                      .colorScheme
                                                      .primary
                                                : Theme.of(c).dividerColor,
                                            width: 2,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            if (zoom > .5)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 8,
                                                ),
                                                child: CircleAvatar(
                                                  backgroundImage:
                                                      images[n['id']] == null
                                                      ? null
                                                      : FileImage(
                                                          File(
                                                            '${media.path}/${images[n['id']]}',
                                                          ),
                                                        ),
                                                  child: images[n['id']] == null
                                                      ? const Icon(Icons.person)
                                                      : null,
                                                ),
                                              ),
                                            Expanded(
                                              child: Text(
                                                n['title'],
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          if (selected != null && nodes.any((n) => n['id'] == selected))
            SafeArea(
              top: false,
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => c.push('/entity/$selected'),
                    icon: const Icon(Icons.info_outline),
                    label: Text(
                      nodes.firstWhere((n) => n['id'] == selected)['title'],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: !editing || busy
                        ? null
                        : () => guarded(
                            c,
                            () => edit(
                              () => linkForm(c, ref, widget.work, selected!),
                            ),
                          ),
                    icon: const Icon(Icons.add_link),
                    label: const Text('관계 연결'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => focus = selected),
                    child: const Text('중심 보기'),
                  ),
                  TextButton(
                    onPressed: !editing || busy
                        ? null
                        : () => guarded(c, () async {
                            final p = positions[selected]!;
                            await edit(
                              () => db.graphPosition(
                                widget.work,
                                selected!,
                                p.dx,
                                p.dy,
                                visible: false,
                                board: board,
                              ),
                            );
                            setState(() => selected = null);
                            refresh(ref);
                          }),
                    child: const Text('캔버스에서 제거'),
                  ),
                ],
              ),
            ),
          const SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                '노드 드래그: 이동 · 선 선택: 관계 편집 · 두 손가락: 확대/축소\n보드는 배치만 구분하며 관계 수정은 작품 전체에 반영됩니다.',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EdgePainter extends CustomPainter {
  final List<Map<String, dynamic>> edges;
  final Map<String, Offset> positions;
  final Color background;
  EdgePainter(this.edges, this.positions, this.background);
  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in graphEdgePaths(edges, positions)) {
      final e = entry.edge;
      final color =
          Colors.primaries[e['label'].toString().codeUnits.fold<int>(
                0,
                (a, b) => a + b,
              ) %
              Colors.primaries.length];
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawPath(entry.path, paint);
      if (e['directed'] == 1) {
        final metric = entry.path.computeMetrics().first;
        final tangent = metric.getTangentForOffset(
          math.max(0, metric.length - 85),
        );
        if (tangent != null) {
          final angle = math.atan2(tangent.vector.dy, tangent.vector.dx);
          for (final offset in [-.5, .5]) {
            canvas.drawLine(
              tangent.position,
              tangent.position -
                  Offset(
                    math.cos(angle + offset) * 15,
                    math.sin(angle + offset) * 15,
                  ),
              paint,
            );
          }
        }
      }
      final text = TextPainter(
        text: TextSpan(
          text: e['label'],
          style: TextStyle(
            color:
                ThemeData.estimateBrightnessForColor(background) ==
                    Brightness.dark
                ? color.shade200
                : color.shade900,
            fontSize: 13,
            backgroundColor: background,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 160);
      text.paint(canvas, entry.label - Offset(text.width / 2, text.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant EdgePainter oldDelegate) => true;
}
