import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/runtime.dart';

import 'package:go_router/go_router.dart';

/// Coordinates are normalized to the original image, independent of orientation.
class WorldMap extends ConsumerStatefulWidget {
  final String work, mapId;
  const WorldMap({super.key, required this.work, required this.mapId});
  @override
  ConsumerState<WorldMap> createState() => _WorldMapState();
}

class _WorldMapState extends ConsumerState<WorldMap> {
  String? selected;
  bool adding = false;
  Future<Map<String, dynamic>> load() async => {
    'photos': await db.rows('SELECT * FROM attachments WHERE entity=?', [
      widget.mapId,
    ]),
    'places': await db.rows('SELECT * FROM entities WHERE work=? AND kind=?', [
      widget.work,
      'location',
    ]),
    'markers': await db.rows(
      'SELECT m.*,e.title FROM markers m JOIN entities e ON e.id=m.location WHERE m.map=?',
      [widget.mapId],
    ),
  };
  @override
  Widget build(BuildContext c) {
    ref.watch(changes);
    return Scaffold(
      appBar: AppBar(
        title: const Text('세계 지도'),
        actions: [
          IconButton(
            tooltip: '장소 마커 추가 모드',
            isSelected: adding,
            onPressed: () => setState(() => adding = !adding),
            icon: const Icon(Icons.add_location_alt_outlined),
          ),
        ],
      ),
      body: FutureBuilder(
        future: load(),
        builder: (c, s) => loading(s, (data) {
          final photos = (data['photos'] as List)
              .where(
                (a) => RegExp(r'\.(png|jpg|jpeg|webp)$').hasMatch(a['name']),
              )
              .toList();
          if (photos.isEmpty) {
            return const Center(child: Text('지역 상세 화면에서 지도 이미지를 먼저 첨부하세요.'));
          }
          return Column(
            children: [
              if (adding)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: DropdownButtonFormField<String>(
                    decoration: const InputDecoration(
                      labelText: '표시할 장소를 선택하고 지도를 누르세요',
                    ),
                    items: [
                      for (final e in data['places'])
                        DropdownMenuItem(
                          value: e['id'] as String,
                          child: Text(e['title']),
                        ),
                    ],
                    onChanged: (v) => selected = v,
                  ),
                ),
              Expanded(
                child: InteractiveViewer(
                  minScale: .2,
                  maxScale: 5,
                  child: Center(
                    child: LayoutBuilder(
                      builder: (c, box) {
                        return Image.file(
                          File('${media.path}/${photos.first['name']}'),
                          errorBuilder: (_, _, _) =>
                              const Text('지도 이미지를 열 수 없습니다'),
                          frameBuilder: (c, image, frame, sync) {
                            if (frame == null && !sync) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            return Stack(
                              children: [
                                image,
                                Positioned.fill(
                                  child: LayoutBuilder(
                                    builder: (c, size) => GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTapUp: !adding || selected == null
                                          ? null
                                          : (d) => guarded(c, () async {
                                              await db.run(
                                                'INSERT INTO markers VALUES (?,?,?,?,?,?)',
                                                [
                                                  db.id(),
                                                  widget.work,
                                                  widget.mapId,
                                                  selected,
                                                  d.localPosition.dx /
                                                      size.maxWidth,
                                                  d.localPosition.dy /
                                                      size.maxHeight,
                                                ],
                                              );
                                              refresh(ref);
                                            }),
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          for (final m in data['markers'])
                                            Positioned(
                                              left:
                                                  (m['x'] as num) *
                                                      size.maxWidth -
                                                  16,
                                              top:
                                                  (m['y'] as num) *
                                                      size.maxHeight -
                                                  32,
                                              child: GestureDetector(
                                                onTap: () => showModalBottomSheet(
                                                  context: c,
                                                  builder: (sheet) => SafeArea(
                                                    child: Wrap(
                                                      children: [
                                                        ListTile(
                                                          title: Text(
                                                            m['title'],
                                                          ),
                                                          leading: const Icon(
                                                            Icons.location_on,
                                                          ),
                                                          onTap: () {
                                                            Navigator.pop(
                                                              sheet,
                                                            );
                                                            c.push(
                                                              '/entity/${m['location']}',
                                                            );
                                                          },
                                                        ),
                                                        ListTile(
                                                          title: const Text(
                                                            '마커 삭제',
                                                          ),
                                                          leading: const Icon(
                                                            Icons
                                                                .delete_outline,
                                                          ),
                                                          onTap: () => guarded(
                                                            sheet,
                                                            () async {
                                                              await db.run(
                                                                'DELETE FROM markers WHERE id=?',
                                                                [m['id']],
                                                              );
                                                              refresh(ref);
                                                              if (sheet
                                                                  .mounted) {
                                                                Navigator.pop(
                                                                  sheet,
                                                                );
                                                              }
                                                            },
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const Icon(
                                                      Icons.location_on,
                                                      color: Colors.deepOrange,
                                                      size: 32,
                                                    ),
                                                    Container(
                                                      color: Colors.white,
                                                      child: Text(
                                                        m['title'],
                                                        style: const TextStyle(
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}
