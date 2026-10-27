import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/runtime.dart';
import '../core/trash.dart';

class TrashScreen extends ConsumerWidget {
  final String? work;
  const TrashScreen({super.key, this.work});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    ref.watch(changes);
    return Scaffold(
      appBar: AppBar(title: const Text('휴지통')),
      body: FutureBuilder(
        future: db.rows(
          'SELECT * FROM trash${work == null ? '' : ' WHERE work=?'} ORDER BY deleted DESC',
          work == null ? [] : [work],
        ),
        builder: (c, s) => loading(
          s,
          (rows) => rows.isEmpty
              ? const Center(child: Text('휴지통이 비어 있습니다.'))
              : ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '작품을 먼저 복원한 뒤 그 안의 자료를 복원하세요. 연결 대상이 삭제된 경우 해당 자료를 먼저 복원해야 합니다.',
                      ),
                    ),
                    for (final item in rows)
                      ListTile(
                        leading: Icon(
                          item['kind'] == 'work'
                              ? Icons.auto_stories_outlined
                              : Icons.description_outlined,
                        ),
                        title: Text(item['title']),
                        subtitle: Text(
                          '${item['kind'] == 'work' ? '작품' : kinds[item['kind']] ?? '자료'} · ${DateTime.fromMillisecondsSinceEpoch(item['deleted']).toLocal().toString().substring(0, 16)}',
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) => guarded(c, () async {
                            if (v == 'restore') {
                              await TrashService(db).restore(item['id']);
                            } else if (await confirm(
                              c,
                              '영구 삭제하면 이 자료를 휴지통에서 복원할 수 없습니다. 삭제할까요?',
                            )) {
                              await db.run('DELETE FROM trash WHERE id=?', [
                                item['id'],
                              ]);
                            }
                            refresh(ref);
                          }),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'restore', child: Text('복원')),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('영구 삭제'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
