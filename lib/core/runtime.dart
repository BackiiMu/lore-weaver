import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';

late Store db;
late Directory media;

class Revision extends Notifier<int> {
  @override
  int build() => 0;
  void refresh() => state++;
}

final changes = NotifierProvider<Revision, int>(Revision.new);
const kinds = {
  'character': '등장인물',
  'faction': '세력·조직',
  'location': '지역·장소',
  'event': '사건 연표',
  'lore': '설정 자료실',
};
void refresh(WidgetRef ref) => ref.read(changes.notifier).refresh();
Future<void> guarded(BuildContext c, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (c.mounted) {
      ScaffoldMessenger.of(c)
          .showSnackBar(SnackBar(content: Text(errorMessage(e))));
    }
  }
}

Future<bool> confirm(BuildContext c, String message) async =>
    await showDialog<bool>(
      context: c,
      builder: (c) => AlertDialog(
        title: const Text('확인'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    ) ??
    false;
Widget loading(AsyncSnapshot<dynamic> s, Widget Function(dynamic) builder) {
  if (s.hasError) {
    return Center(child: Text('데이터를 불러오지 못했습니다.\n${errorMessage(s.error!)}'));
  }
  if (!s.hasData) {
    return const Center(child: CircularProgressIndicator());
  }
  return builder(s.data);
}

ThemeMode initialTheme = ThemeMode.system;
final themePreference = NotifierProvider<ThemePreference, ThemeMode>(
  ThemePreference.new,
);
Future<ThemeMode> loadTheme() async {
  try {
    final name = await File('${media.parent.path}/theme.txt').readAsString();
    return ThemeMode.values.firstWhere((m) => m.name == name);
  } catch (_) {
    return ThemeMode.system;
  }
}

class ThemePreference extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => initialTheme;
  Future<void> update(ThemeMode mode) async {
    await File('${media.parent.path}/theme.txt')
        .writeAsString(mode.name, flush: true);
    state = mode;
  }
}

String errorMessage(Object error) {
  if (error is FormatException) return error.message;
  if (error is FileSystemException) {
    return '파일을 읽거나 저장하지 못했습니다. 파일 접근 권한과 저장 공간을 확인해주세요.';
  }
  final message = error.toString();
  if (message.contains('FOREIGN KEY constraint')) {
    return '연결에 필요한 작품·자료·보드가 없습니다. 휴지통에서 관련 자료를 먼저 복원해주세요.';
  }
  if (message.contains('UNIQUE constraint')) {
    return '같은 ID 또는 이름의 자료가 이미 있습니다. 기존 자료를 덮어쓰지 않았습니다.';
  }
  debugPrint('Lore Weaver: $error');
  return '처리 중 오류가 발생했습니다. 다시 시도하거나 백업 파일을 확인해주세요.';
}
