import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../markdown/markdown_composer.dart';
import 'matrix_html_flow.dart';
import 'matrix_html_node.dart';

/// Returns the text content of [source] with monospace (`pre`/`code`)
/// sections removed, so URLs inside code do not trigger link previews.
///
/// Inline nodes keep their original adjacency so URLs spanning inline
/// formatting stay intact; separators are inserted only at block-level
/// boundaries and where code nodes are removed.
String matrixHtmlTextExcludingCode(String source) {
  final nodes = const MatrixHtmlParser().parse(source);
  final buffer = StringBuffer();
  void collect(List<MatrixHtmlNode> nodes) {
    for (final node in nodes) {
      if (node is MatrixTextNode) {
        buffer.write(node.text);
        continue;
      }
      final element = node as MatrixElementNode;
      if (element.tag == 'pre' || element.tag == 'code') {
        buffer.write(' ');
      } else if (_blockLevelTags.contains(element.tag)) {
        buffer.write(' ');
        collect(element.children);
        buffer.write(' ');
      } else {
        collect(element.children);
      }
    }
  }

  collect(nodes);
  return buffer.toString();
}

const _blockLevelTags = {
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
  'br',
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

class MatrixHtmlParser {
  static const maxDepth = 100;
  static const _allowedTags = {
    'p',
    'strong',
    'b',
    'em',
    'i',
    'del',
    's',
    'code',
    'pre',
    'blockquote',
    'ul',
    'ol',
    'li',
    'a',
    'br',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'span',
    'img',
    'figure',
    'figcaption',
    'input',
    'table',
    'thead',
    'tbody',
    'tr',
    'th',
    'td',
    'caption',
  };
  static const _discardWithContents = {'script', 'style', 'iframe', 'object'};

  const MatrixHtmlParser();

  List<MatrixHtmlNode> parse(String source) {
    final fragment = html.parseFragment(source);
    return normalizeMatrixHtmlBreaks(_parseChildren(fragment.nodes, 0));
  }

  List<MatrixHtmlNode> _parseChildren(List<dom.Node> nodes, int depth) {
    if (depth > maxDepth) return const [];
    final result = <MatrixHtmlNode>[];
    for (final node in nodes) {
      if (node is dom.Text) {
        if (node.data.isNotEmpty) result.add(MatrixTextNode(node.data));
        continue;
      }
      if (node is! dom.Element) continue;
      final tag = node.localName?.toLowerCase() ?? '';
      if (_discardWithContents.contains(tag)) continue;
      final children = _parseChildren(node.nodes, depth + 1);
      // `div` survives as a math block carrier or an alignment container;
      // any other div is unwrapped so existing layout behavior is unchanged.
      if (tag == 'div') {
        final attributes = <String, String>{};
        final maths = node.attributes['data-mx-maths'];
        if (maths != null) attributes['data-mx-maths'] = maths;
        final align = safeMatrixHtmlAlign(node.attributes['align']);
        if (align != null) attributes['align'] = align;
        if (attributes.isNotEmpty) {
          result.add(
            MatrixElementNode(
              tag: tag,
              children: children,
              attributes: attributes,
            ),
          );
        } else {
          result.addAll(children);
        }
        continue;
      }
      // Deprecated but still common in the wild: `<center>` is just a
      // centered div.
      if (tag == 'center') {
        result.add(
          MatrixElementNode(
            tag: 'div',
            children: children,
            attributes: const {'align': 'center'},
          ),
        );
        continue;
      }
      if (tag == 'input') {
        // Only task-list checkboxes carry meaning; everything else is dropped.
        if (node.attributes['type'] == 'checkbox') {
          result.add(
            MatrixElementNode(
              tag: tag,
              children: const [],
              attributes: {
                'type': 'checkbox',
                if (node.attributes.containsKey('checked')) 'checked': 'true',
              },
            ),
          );
        }
        continue;
      }
      if (!_allowedTags.contains(tag)) {
        result.addAll(children);
        continue;
      }
      final attributes = <String, String>{};
      final align = safeMatrixHtmlAlign(node.attributes['align']);
      if (align != null &&
          const {
            'p',
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
            'h6',
            'th',
            'td',
          }.contains(tag)) {
        attributes['align'] = align;
      }
      if (tag == 'a') {
        final href = safeMatrixHtmlHref(node.attributes['href']);
        if (href != null) attributes['href'] = href;
      } else if (tag == 'img') {
        final src = safeMatrixHtmlImgSrc(node.attributes['src']);
        if (src == null) {
          // Unusable source: fall back to the alt text, as before.
          final alt = node.attributes['alt'];
          if (alt != null && alt.isNotEmpty) result.add(MatrixTextNode(alt));
          continue;
        }
        attributes['src'] = src;
        final alt = node.attributes['alt'];
        if (alt != null) attributes['alt'] = alt;
        final title = node.attributes['title'];
        if (title != null) attributes['title'] = title;
      } else if (tag == 'span') {
        final maths = node.attributes['data-mx-maths'];
        if (maths != null) attributes['data-mx-maths'] = maths;
        final spoiler = node.attributes['data-mx-spoiler'];
        if (spoiler != null) attributes['data-mx-spoiler'] = spoiler;
      } else if (tag == 'ol') {
        final start = int.tryParse(node.attributes['start'] ?? '');
        if (start != null) attributes['start'] = '$start';
      } else if (tag == 'code') {
        final className = node.attributes['class'];
        final language = className == null
            ? null
            : RegExp(r'(?:^|\s)language-([A-Za-z0-9_+-]{1,32})(?:\s|$)')
                  .firstMatch(className)
                  ?.group(1);
        if (language != null) attributes['class'] = 'language-$language';
      }
      result.add(
        MatrixElementNode(tag: tag, children: children, attributes: attributes),
      );
    }
    return result;
  }
}
