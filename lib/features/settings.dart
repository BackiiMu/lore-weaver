import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../core/runtime.dart';
import '../core/backup.dart';
import '../core/trash.dart';
import 'trash.dart';

Future<void> exportBackup(BuildContext c, [String? work]) =>
    guarded(c, () async {
      final bytes = await BackupService(db, media).export(work: work);
      final path = await FilePicker.saveFile(
        dialogTitle: '백업 ZIP 저장',
        fileName: 'lore-${DateTime.now().millisecondsSinceEpoch}.zip',
        bytes: Uint8List.fromList(bytes),
      );
      if (path != null && c.mounted) {
        ScaffoldMessenger.of(c)
            .showSnackBar(const SnackBar(content: Text('백업 파일을 저장했습니다.')));
      }
    });

class Settings extends ConsumerWidget {
  const Settings({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('설정 및 백업')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('시스템')),
              ButtonSegment(value: ThemeMode.light, label: Text('밝게')),
              ButtonSegment(value: ThemeMode.dark, label: Text('어둡게')),
            ],
            selected: {ref.watch(themePreference)},
            onSelectionChanged: (s) => guarded(
              c,
              () => ref.read(themePreference.notifier).update(s.single),
            ),
          ),
        ),
        const ListTile(
          leading: Icon(Icons.lock_outline),
          title: Text('기기에만 저장되는 나만의 세계관'),
          subtitle: Text(
            '로그인이나 서버 연결 없이 사용할 수 있습니다. 앱을 삭제하면 데이터가 사라질 수 있으니 백업을 보관하세요.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('휴지통'),
          subtitle: const Text('삭제한 작품과 자료 복원'),
          onTap: () =>
              Navigator.of(c)
                  .push(MaterialPageRoute(builder: (_) => const TrashScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.archive_outlined),
          title: const Text('전체 데이터 백업'),
          subtitle: const Text('JSON과 첨부파일이 포함된 ZIP 저장'),
          onTap: () => exportBackup(c),
        ),
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('백업 가져오기'),
          subtitle: const Text('기존 ID와 충돌하면 전체 가져오기를 취소합니다.'),
          onTap: () => guarded(c, () async {
            final result = await FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: ['zip'],
            );
            final path = result?.path;
            if (path == null) return;
            final file = File(path);
            if (await file.length() > 200 * 1024 * 1024) {
              throw const FormatException('백업은 200MB 이하여야 합니다');
            }
            final bytes = await file.readAsBytes();
            final service = BackupService(db, media);
            final preview = await service.preview(bytes);
            if (!c.mounted) return;
            final proceed = await showDialog<bool>(
              context: c,
              builder: (dialog) => AlertDialog(
                title: const Text('백업 복원 미리보기'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '작품 ${preview.works.length}개 · 자료 ${preview.entities}개\n연결 ${preview.links}개 · 파일 ${preview.files}개\n휴지통 ${preview.trash}개',
                      ),
                      const SizedBox(height: 12),
                      for (final title in preview.works) Text('• $title'),
                      const SizedBox(height: 12),
                      Text(
                        preview.conflicts > 0
                            ? '기존 자료와 ${preview.conflicts}건이 충돌합니다. 현재 데이터는 변경하지 않았습니다.'
                            : '검증을 마쳤습니다. 기존 자료를 유지하며 추가합니다.',
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: preview.conflicts > 0
                        ? null
                        : () => Navigator.pop(dialog, true),
                    child: const Text('복원'),
                  ),
                ],
              ),
            );
            if (proceed != true) return;
            await service.restore(bytes);
            refresh(ref);
            if (c.mounted) {
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(const SnackBar(content: Text('검증을 마치고 복원했습니다.')));
            }
          }),
        ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('사용하지 않는 첨부파일 정리'),
          onTap: () => guarded(c, () async {
            final used = await TrashService(db).referencedFiles();
            for (final f in media.listSync().whereType<File>()) {
              if (!used.contains(f.uri.pathSegments.last)) await f.delete();
            }
            if (c.mounted) {
              ScaffoldMessenger.of(
                c,
              ).showSnackBar(const SnackBar(content: Text('첨부파일 정리를 완료했습니다.')));
            }
          }),
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever),
          title: const Text('전체 데이터 초기화'),
          onTap: () => guarded(c, () async {
            if (await confirm(c, '모든 작품과 첨부파일을 영구 삭제할까요? 백업을 먼저 저장해주세요.')) {
              await db.transaction(() async {
                await db.run('DELETE FROM works');
                await db.run('DELETE FROM trash');
              });
              for (final f in media.listSync().whereType<File>()) {
                await f.delete();
              }
              refresh(ref);
            }
          }),
        ),
        const Divider(),
        const ListTile(
          title: Text('로어 위버 1.0.0'),
          subtitle: Text(
            '오프라인 소설 세계관·인물 관계도\n저장: 작성 중 초안 자동 저장, 저장 버튼 또는 뒤로 이동 시 확정\n삭제: 연결은 함께 삭제, 첨부 실파일은 정리 메뉴로 제거',
          ),
        ),
      ],
    ),
  );
}
