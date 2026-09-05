import 'package:flutter/material.dart';

/// Tiny markdown for chat bubbles: **bold**, `code`, ```blocks```, lists, links as plain text.
Widget chatMarkdown(String src, {required TextStyle base, Color? codeBg}) {
  final blocks = <String>[];
  var s = src.replaceAllMapped(RegExp(r'```[^\n]*\n?([\s\S]*?)```'), (m) {
    blocks.add(m.group(1)!.replaceAll(RegExp(r'\n$'), ''));
    return '\u0000${blocks.length - 1}\u0000';
  });

  final lines = s.split('\n');
  final children = <Widget>[];
  final listBuf = <InlineSpan>[];

  void flushList() {
    if (listBuf.isEmpty) return;
    children.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text.rich(TextSpan(style: base, children: List.of(listBuf))),
      ),
    );
    listBuf.clear();
  }

  for (final line in lines) {
    final block = RegExp(r'^\u0000(\d+)\u0000$').firstMatch(line);
    if (block != null) {
      flushList();
      children.add(
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8, top: 2),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: codeBg ?? const Color(0xFF0E1117),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            blocks[int.parse(block.group(1)!)],
            style: base.copyWith(
              fontFamily: 'monospace',
              fontSize: (base.fontSize ?? 14.5) - 0.5,
              height: 1.4,
            ),
          ),
        ),
      );
      continue;
    }

    final heading = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(line);
    final bullet = RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(line);
    final numbered = RegExp(r'^\s*\d+[.)]\s+(.*)$').firstMatch(line);

    if (heading != null) {
      flushList();
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Text.rich(
            TextSpan(
              style: base.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: (base.fontSize ?? 14.5) + (4 - heading.group(1)!.length),
              ),
              children: _inline(heading.group(2)!, base, codeBg),
            ),
          ),
        ),
      );
    } else if (bullet != null || numbered != null) {
      final body = bullet?.group(1) ?? numbered!.group(1)!;
      final mark = bullet != null ? '• ' : '· ';
      listBuf.add(TextSpan(text: mark));
      listBuf.addAll(_inline(body, base, codeBg));
      listBuf.add(const TextSpan(text: '\n'));
    } else if (line.trim().isEmpty) {
      flushList();
      children.add(const SizedBox(height: 6));
    } else {
      flushList();
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text.rich(
            TextSpan(style: base, children: _inline(line, base, codeBg)),
          ),
        ),
      );
    }
  }
  flushList();

  if (children.isEmpty) {
    return SelectableText(src, style: base);
  }
  return SelectionArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children));
}

List<InlineSpan> _inline(String line, TextStyle base, Color? codeBg) {
  // strip bare URLs look; keep **bold** `code` *italic*
  final out = <InlineSpan>[];
  final re = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)');
  var start = 0;
  for (final m in re.allMatches(line)) {
    if (m.start > start) {
      out.add(TextSpan(text: line.substring(start, m.start)));
    }
    final t = m.group(0)!;
    if (t.startsWith('**')) {
      out.add(TextSpan(
        text: t.substring(2, t.length - 2),
        style: base.copyWith(fontWeight: FontWeight.w700),
      ));
    } else if (t.startsWith('`')) {
      out.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: codeBg ?? const Color(0xFF0E1117),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            t.substring(1, t.length - 1),
            style: base.copyWith(
              fontFamily: 'monospace',
              fontSize: (base.fontSize ?? 14.5) - 0.5,
            ),
          ),
        ),
      ));
    } else {
      out.add(TextSpan(
        text: t.substring(1, t.length - 1),
        style: base.copyWith(fontStyle: FontStyle.italic),
      ));
    }
    start = m.end;
  }
  if (start < line.length) {
    out.add(TextSpan(text: line.substring(start)));
  }
  return out;
}
