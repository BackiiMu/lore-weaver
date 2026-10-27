import 'dart:math' as math;

import 'package:flutter/material.dart';

enum GraphArrangement { grid, hierarchy, clusters }

Map<String, Offset> arrangeGraph(
  List<String> ids,
  List<Map<String, dynamic>> edges,
  GraphArrangement mode,
) {
  final result = <String, Offset>{};
  final allowed = ids.toSet();
  if (mode == GraphArrangement.hierarchy) {
    final children = {for (final id in ids) id: <String>{}};
    final incoming = {for (final id in ids) id: 0};
    for (final edge in edges) {
      String? parent, child;
      if (['부모', '상위 조직', '상위 지역', '스승'].contains(edge['label'])) {
        parent = edge['target'];
        child = edge['source'];
      }
      if (['자녀', '하위 조직', '하위 지역', '제자'].contains(edge['label'])) {
        parent = edge['source'];
        child = edge['target'];
      }
      if (parent != null &&
          child != null &&
          allowed.contains(parent) &&
          allowed.contains(child) &&
          children[parent]!.add(child)) {
        incoming[child] = incoming[child]! + 1;
      }
    }
    final depth = {for (final id in ids) id: 0};
    final queue = ids.where((id) => incoming[id] == 0).toList();
    for (var i = 0; i < queue.length; i++) {
      final id = queue[i];
      for (final child in children[id]!) {
        depth[child] = math.max(depth[child]!, depth[id]! + 1);
        incoming[child] = incoming[child]! - 1;
        if (incoming[child] == 0) queue.add(child);
      }
    }
    final rows = <int, int>{};
    final last = depth.values.fold<int>(0, math.max) + 1;
    for (final id in ids) {
      final d = incoming[id]! > 0 ? last : depth[id]!;
      final col = rows[d] ?? 0;
      rows[d] = col + 1;
      result[id] = Offset(100 + col * 210, 100 + d * 170);
    }
    return result;
  }
  if (mode == GraphArrangement.clusters) {
    final adjacent = {for (final id in ids) id: <String>{}};
    for (final e in edges) {
      if (allowed.contains(e['source']) && allowed.contains(e['target'])) {
        adjacent[e['source']]!.add(e['target']);
        adjacent[e['target']]!.add(e['source']);
      }
    }
    final visited = <String>{};
    double left = 100, top = 100, rowHeight = 0;
    for (final seed in ids) {
      if (!visited.add(seed)) continue;
      final component = [seed];
      for (var i = 0; i < component.length; i++) {
        for (final n in adjacent[component[i]]!) {
          if (visited.add(n)) component.add(n);
        }
      }
      final columns = math.max(1, math.sqrt(component.length).ceil());
      final width = columns * 210.0,
          height = (component.length / columns).ceil() * 150.0;
      if (left > 100 && left + width > 1800) {
        left = 100;
        top += rowHeight + 100;
        rowHeight = 0;
      }
      for (var i = 0; i < component.length; i++) {
        result[component[i]] = Offset(
          left + (i % columns) * 210,
          top + (i ~/ columns) * 150,
        );
      }
      left += width + 120;
      rowHeight = math.max(rowHeight, height);
    }
    return result;
  }
  final columns = math.max(1, math.sqrt(ids.length).ceil());
  for (var i = 0; i < ids.length; i++) {
    result[ids[i]] = Offset(
      100 + (i % columns) * 210,
      100 + (i ~/ columns) * 150,
    );
  }
  return result;
}

class GraphEdgePath {
  final Map<String, dynamic> edge;
  final Path path;
  final Offset label;
  GraphEdgePath(this.edge, this.path, this.label);
}

List<GraphEdgePath> graphEdgePaths(
  List<Map<String, dynamic>> edges,
  Map<String, Offset> positions,
) {
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final edge in edges) {
    final pair = [edge['source'].toString(), edge['target'].toString()]..sort();
    groups.putIfAbsent(pair.join('/'), () => []).add(edge);
  }
  final result = <GraphEdgePath>[];
  for (final group in groups.values) {
    for (var i = 0; i < group.length; i++) {
      final e = group[i],
          a = positions[group[i]['source']],
          b = positions[group[i]['target']];
      if (a == null || b == null) continue;
      final start = a + const Offset(80, 44),
          end = b + const Offset(80, 44),
          delta = end - start;
      if (delta.distance < 1) continue;
      final normal =
          Offset(-delta.dy, delta.dx) /
          delta.distance *
          (e['source'].toString().compareTo(e['target']) < 0 ? 1 : -1);
      final bend = (i - (group.length - 1) / 2) * 65;
      final mid = (start + end) / 2 + normal * bend;
      result.add(
        GraphEdgePath(
          e,
          Path()
            ..moveTo(start.dx, start.dy)
            ..quadraticBezierTo(mid.dx, mid.dy, end.dx, end.dy),
          (start + end) / 2 + normal * bend / 2,
        ),
      );
    }
  }
  return result;
}

Map<String, dynamic>? hitGraphEdge(
  Offset point,
  List<GraphEdgePath> paths,
  double tolerance,
) {
  double nearest = tolerance;
  Map<String, dynamic>? hit;
  for (final edge in paths) {
    for (final metric in edge.path.computeMetrics()) {
      for (double distance = 0; distance <= metric.length; distance += 6) {
        final p = metric.getTangentForOffset(distance)?.position;
        if (p == null) continue;
        final gap = (p - point).distance;
        if (gap < nearest) {
          nearest = gap;
          hit = edge.edge;
        }
      }
    }
  }
  return hit;
}
