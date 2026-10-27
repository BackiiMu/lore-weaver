import 'dart:convert';

import 'database.dart';

typedef GraphSnapshot = Map<String, List<Map<String, dynamic>>>;

/// Session history changes only rows touched by a graph action. It refuses to
/// overwrite a later edit made elsewhere, and never restores/deletes entities.
class GraphHistory {
  final Store db;
  final String work;
  final String? board;
  GraphHistory(this.db, this.work, {this.board});
  final List<_Edit> _undo = [], _redo = [];
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  Future<GraphSnapshot> capture() async => {
    'links': await db.rows('SELECT * FROM links WHERE work=?', [work]),
    if (board == null)
      'layouts': await db.rows('SELECT * FROM layouts WHERE work=?', [work])
    else
      'board_nodes': await db.rows('SELECT * FROM board_nodes WHERE board=?', [
        board,
      ]),
  };
  void record(GraphSnapshot before, GraphSnapshot after) {
    final changes = <_Change>[];
    for (final table in before.keys) {
      final a = {for (final r in before[table]!) key(table, r): r};
      final b = {for (final r in after[table]!) key(table, r): r};
      for (final id in {...a.keys, ...b.keys}) {
        if (!same(a[id], b[id])) changes.add(_Change(table, a[id], b[id]));
      }
    }
    if (changes.isEmpty) return;
    _undo.add(_Edit(changes));
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  static String key(String table, Map<String, dynamic> row) => table == 'links'
      ? row['id']
      : '${row['board'] ?? row['work']}/${row['entity']}';
  static bool same(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) return a == b;
    return a.length == b.length &&
        a.keys.every((k) => jsonEncode(a[k]) == jsonEncode(b[k]));
  }

  Future<void> undo() => _apply(true);
  Future<void> redo() => _apply(false);
  Future<void> _apply(bool undo) async {
    final source = undo ? _undo : _redo, destination = undo ? _redo : _undo;
    if (source.isEmpty) return;
    final edit = source.last;
    await db.transaction(() async {
      for (final change in edit.changes) {
        final expected = undo ? change.after : change.before;
        final desired = undo ? change.before : change.after;
        final sample = expected ?? desired!;
        final where = change.table == 'links'
            ? 'id=?'
            : change.table == 'layouts'
            ? 'work=? AND entity=?'
            : 'board=? AND entity=?';
        final args = change.table == 'links'
            ? [sample['id']]
            : [sample['board'] ?? sample['work'], sample['entity']];
        final current = await db.rows(
          'SELECT * FROM ${change.table} WHERE $where',
          args,
        );
        if (!same(current.isEmpty ? null : current.single, expected)) {
          throw const FormatException('다른 화면에서 변경된 내용이 있어 되돌릴 수 없습니다');
        }
        await db.run('DELETE FROM ${change.table} WHERE $where', args);
        if (desired != null) {
          if (change.table == 'links') {
            await db.saveLink(
              desired['id'],
              desired['work'],
              desired['source'],
              desired['target'],
              desired['label'],
              desired['reverse'],
              desired['directed'] == 1,
            );
          } else {
            await db.run(
              'INSERT INTO ${change.table} (${desired.keys.join(',')}) VALUES (${List.filled(desired.length, '?').join(',')})',
              desired.values.toList(),
            );
          }
        }
      }
    });
    source.removeLast();
    destination.add(edit);
  }
}

class _Change {
  final String table;
  final Map<String, dynamic>? before, after;
  _Change(this.table, this.before, this.after);
}

class _Edit {
  final List<_Change> changes;
  _Edit(this.changes);
}
