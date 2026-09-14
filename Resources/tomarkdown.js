// DOM → Markdown, just enough for article text: headings, paragraphs, lists,
// links, emphasis, code, quotes, images, tables (flattened). Runs after
// Readability has already removed navigation, ads and scripts.
function nutipToMarkdown(root, baseHref) {
  var base = baseHref || '';

  function abs(href) {
    try { return new URL(href, base).href; } catch (e) { return href; }
  }
  function text(s) {
    return (s || '').replace(/\s+/g, ' ');
  }
  function inline(node) {
    var out = '';
    node.childNodes.forEach(function (c) {
      if (c.nodeType === 3) { out += text(c.nodeValue); return; }
      if (c.nodeType !== 1) return;
      var tag = c.tagName.toLowerCase();
      var inner = inline(c);
      switch (tag) {
        case 'a': {
          var href = c.getAttribute('href');
          var t = inner.trim();
          if (!href || !t) { out += inner; break; }
          if (href.indexOf('#') === 0 || href.indexOf('javascript:') === 0) { out += inner; break; }
          out += '[' + t + '](' + abs(href) + ')';
          break;
        }
        case 'strong': case 'b': out += inner.trim() ? '**' + inner.trim() + '**' : ''; break;
        case 'em': case 'i': out += inner.trim() ? '*' + inner.trim() + '*' : ''; break;
        case 'code': case 'kbd': case 'samp': out += '`' + c.textContent.replace(/`/g, '\\`') + '`'; break;
        case 'br': out += '  \n'; break;
        case 'img': {
          var alt = c.getAttribute('alt') || '';
          var src = c.getAttribute('src') || c.getAttribute('data-src');
          if (src) out += '![' + text(alt) + '](' + abs(src) + ')';
          break;
        }
        case 'sup': case 'sub': case 'span': case 'small': case 'mark': case 'u': case 's': case 'del': case 'time': case 'abbr': case 'cite': case 'q':
          out += inner; break;
        default:
          out += block(c) ? '\n\n' + block(c) + '\n\n' : inner;
      }
    });
    return out;
  }
  function block(node) {
    var tag = node.tagName.toLowerCase();
    switch (tag) {
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
        return '#'.repeat(parseInt(tag[1], 10)) + ' ' + inline(node).trim();
      case 'p': return inline(node).trim();
      case 'blockquote':
        return blocks(node).split('\n').map(function (l) { return '> ' + l; }).join('\n');
      case 'pre': {
        var codeEl = node.querySelector('code');
        var lang = '';
        var cls = (codeEl && codeEl.className) || node.className || '';
        var m = cls.match(/(?:language|lang)-([\w+-]+)/);
        if (m) lang = m[1];
        return '```' + lang + '\n' + node.textContent.replace(/\n$/, '') + '\n```';
      }
      case 'ul': case 'ol': {
        var i = 0;
        return Array.prototype.filter.call(node.children, function (li) { return li.tagName.toLowerCase() === 'li'; })
          .map(function (li) {
            i += 1;
            var marker = tag === 'ol' ? i + '. ' : '- ';
            var content = blocks(li).trim().split('\n').join('\n  ');
            return marker + content;
          }).join('\n');
      }
      case 'hr': return '---';
      case 'table': {
        var rows = Array.prototype.slice.call(node.querySelectorAll('tr'));
        if (!rows.length) return '';
        var lines = rows.map(function (tr) {
          return '| ' + Array.prototype.map.call(tr.children, function (td) { return inline(td).trim().replace(/\|/g, '\\|'); }).join(' | ') + ' |';
        });
        var cols = rows[0].children.length;
        lines.splice(1, 0, '|' + ' --- |'.repeat(cols));
        return lines.join('\n');
      }
      case 'figure': {
        var img = node.querySelector('img');
        var cap = node.querySelector('figcaption');
        var s = img ? inline({ childNodes: [img] }) : '';
        if (cap) s += (s ? '\n\n' : '') + '*' + inline(cap).trim() + '*';
        return s;
      }
      case 'img': return inline({ childNodes: [node] });
      case 'div': case 'section': case 'article': case 'main': case 'header': case 'footer': case 'aside': case 'nav': case 'li': case 'dd': case 'dt': case 'dl': case 'details': case 'summary':
        return blocks(node);
      case 'script': case 'style': case 'noscript': case 'iframe': case 'svg': case 'button': case 'form': case 'input':
        return '';
      default:
        return null; // inline element
    }
  }
  function blocks(node) {
    var parts = [];
    var run = '';
    function flush() { if (run.trim()) parts.push(run.trim()); run = ''; }
    node.childNodes.forEach(function (c) {
      if (c.nodeType === 3) { run += text(c.nodeValue); return; }
      if (c.nodeType !== 1) return;
      var b = block(c);
      if (b === null) { run += inline({ childNodes: [c] }); return; }
      flush();
      if (b) parts.push(b);
    });
    flush();
    return parts.join('\n\n');
  }
  return blocks(root)
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}
