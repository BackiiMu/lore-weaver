import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import 'core/database.dart';
import 'app/theme.dart';
import 'core/runtime.dart';
import 'features/works.dart';
import 'features/entities.dart';
import 'features/settings.dart';
import 'features/graph.dart';
export 'core/runtime.dart';
export 'features/works.dart';
export 'features/entities.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await getApplicationDocumentsDirectory();
  media = await Directory('${root.path}/lore_weaver/media')
      .create(recursive: true);
  initialTheme = await loadTheme();
  db = Store.file(File('${root.path}/lore_weaver/world.sqlite'));
  runApp(const ProviderScope(child: LoreApp()));
}

final router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Library()),
    GoRoute(path: '/settings', builder: (_, _) => const Settings()),
    GoRoute(
      path: '/work/:id',
      builder: (_, s) => Workspace(work: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/entity/:id',
      builder: (_, s) => EntityDetail(id: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/graph/:id',
      builder: (_, s) => GraphScreen(work: s.pathParameters['id']!),
    ),
  ],
);

class LoreApp extends ConsumerWidget {
  const LoreApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: '로어 위버',
    locale: const Locale('ko'),
    supportedLocales: const [Locale('ko'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    themeMode: ref.watch(themePreference),
    darkTheme: PaperTheme.build(Brightness.dark),
    debugShowCheckedModeBanner: false,
    routerConfig: router,
    theme: PaperTheme.build(Brightness.light),
  );
}
