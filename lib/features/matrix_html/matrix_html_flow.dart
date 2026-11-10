import 'matrix_html_node.dart';

const _blockTags = {
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'ul',
  'ol',
  'li',
  'pre',
  'hr',
  'figure',
  'figcaption',
  'div',
  'table',
  'thead',
  'tbody',
  'tr',
  'th',
  'td',
  'caption',
};

bool _isInline(MatrixHtmlNode node) =>
    node is MatrixTextNode ||
    (!_blockTags.contains((node as MatrixElementNode).tag) &&
        node.tag != 'img');

bool _hasContent(List<MatrixHtmlNode> nodes) =>
    nodes.any((node) => node is! MatrixTextNode || node.text.trim().isNotEmpty);

/// HTML at the root can mix inline runs and blocks. A run is one paragraph,
/// regardless of whether a message has trailing time/read metadata.
Iterable<MatrixHtmlNode> matrixHtmlBlocks(List<MatrixHtmlNode> nodes) sync* {
  var inline = <MatrixHtmlNode>[];
  for (final node in nodes) {
    if (_isInline(node)) {
      inline.add(node);
      continue;
    }
    if (_hasContent(inline)) {
      yield MatrixElementNode(tag: 'p', children: inline);
    }
    inline = [];
    yield node;
  }
  if (_hasContent(inline)) {
    yield MatrixElementNode(tag: 'p', children: inline);
  }
}

/// A br and its adjacent source whitespace describe the same line boundary.
/// Work across inline tags, but stop at blocks, code, images and math. Each br
/// remains intact, so explicitly repeated br tags still produce blank lines.
List<MatrixHtmlNode> normalizeMatrixHtmlBreaks(List<MatrixHtmlNode> nodes) {
  final leaves = <MatrixHtmlNode?>[];
  void collect(MatrixHtmlNode node) {
    if (node is MatrixTextNode) {
      leaves.add(node);
      return;
    }
    final element = node as MatrixElementNode;
    if (element.tag == 'br' ||
        element.tag == 'code' ||
        element.tag == 'pre' ||
        element.tag == 'img' ||
        element.attributes.containsKey('data-mx-maths')) {
      leaves.add(element);
      return;
    }
    final block = _blockTags.contains(element.tag);
    if (block) leaves.add(null);
    for (final child in element.children) {
      collect(child);
    }
    if (block) leaves.add(null);
  }

  nodes.forEach(collect);
  final replacements = <MatrixTextNode, String>{};
  final leading = RegExp(r'^[ \t\r\n]+');
  final trailing = RegExp(r'[ \t\r\n]+$');
  for (var i = 0; i < leaves.length; i++) {
    final leaf = leaves[i];
    if (leaf is! MatrixElementNode || leaf.tag != 'br') continue;
    for (final step in [-1, 1]) {
      for (var j = i + step; j >= 0 && j < leaves.length; j += step) {
        final neighbor = leaves[j];
        if (neighbor is! MatrixTextNode) break;
        final text = (replacements[neighbor] ?? neighbor.text).replaceFirst(
          step < 0 ? trailing : leading,
          '',
        );
        replacements[neighbor] = text;
        if (text.isNotEmpty) break;
      }
    }
  }
  if (replacements.isEmpty) return nodes;

  MatrixHtmlNode replace(MatrixHtmlNode node) {
    if (node is MatrixTextNode) {
      final text = replacements[node];
      return text == null ? node : MatrixTextNode(text);
    }
    final element = node as MatrixElementNode;
    return MatrixElementNode(
      tag: element.tag,
      children: element.children.map(replace).toList(),
      attributes: element.attributes,
    );
  }

  return nodes.map(replace).toList();
}
