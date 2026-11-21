// Helpers Ask AI's hidden browser runs inside a chat page. Evaluated once per
// page; everything hangs off window.__askAi.
(() => {
  if (window.__askAi) return;

  // Hand an image to the page the way a real paste does: a paste event whose
  // clipboard holds the file. Chat composers attach pasted images.
  function pasteImage(target, base64, mime, name) {
    const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
    const file = new File([bytes], name, { type: mime, lastModified: Date.now() });
    const data = new DataTransfer();
    data.items.add(file);
    target.focus();
    const event = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true });
    target.dispatchEvent(event);
    return event.defaultPrevented;
  }

  // Rendered answer -> Markdown, so the card can show headings, lists, code
  // and links. Buttons and icons inside the answer (copy buttons and so on)
  // are skipped; maths comes back as its TeX source.
  function toMarkdown(root) {
    const skip = new Set(['BUTTON', 'SVG', 'svg', 'STYLE', 'SCRIPT', 'NOSCRIPT', 'TEMPLATE', 'IMG', 'VIDEO', 'AUDIO', 'CANVAS', 'TIME']);

    function inline(node) {
      let out = '';
      for (const child of node.childNodes) out += walk(child, true);
      return out;
    }

    // Text only screen readers get ("Claude responded:") or that isn't shown.
    function hidden(el) {
      if (/(^|\s)(sr-only|visually-hidden|screen-reader-only)(\s|$)/.test(el.className || '')) return true;
      if (el.closest('.katex')) return false;
      const style = getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden') return true;
      return style.position === 'absolute' && parseFloat(style.width) <= 1 && parseFloat(style.height) <= 1;
    }

    function tex(el) {
      const ann = el.querySelector('annotation[encoding="application/x-tex"]');
      return ann ? ann.textContent.trim() : el.innerText.trim();
    }

    function walk(node, inLine) {
      if (node.nodeType === Node.TEXT_NODE) return node.textContent.replace(/\s+/g, ' ');
      if (node.nodeType !== Node.ELEMENT_NODE) return '';
      const el = node;
      if (skip.has(el.tagName) || el.getAttribute('aria-hidden') === 'true' && !el.closest('.katex')) return '';
      if (hidden(el)) return '';
      // A reply's own toolbar: copy, retry, "just now".
      if (/actions/i.test(el.getAttribute('data-testid') || '')) return '';
      if (el.classList.contains('katex-display')) return `\n\n$$${tex(el)}$$\n\n`;
      if (el.classList.contains('katex')) return `$${tex(el)}$`;
      switch (el.tagName) {
        case 'BR': return '\n';
        case 'STRONG': case 'B': { const t = inline(el).trim(); return t ? `**${t}**` : ''; }
        case 'EM': case 'I': { const t = inline(el).trim(); return t ? `*${t}*` : ''; }
        case 'CODE':
          if (el.closest('pre')) return el.textContent;
          return '`' + el.textContent + '`';
        case 'A': {
          const t = inline(el).trim();
          const href = el.getAttribute('href') || '';
          return /^https?:/.test(href) ? `[${t || href}](${href})` : t;
        }
        case 'PRE': {
          const code = el.querySelector('code');
          const lang = code && (code.className.match(/language-([\w+-]+)/) || [])[1] || '';
          const text = (code || el).innerText.replace(/\n$/, '');
          return `\n\n\`\`\`${lang}\n${text}\n\`\`\`\n\n`;
        }
        case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6':
          return `\n\n${'#'.repeat(Number(el.tagName[1]))} ${inline(el).trim()}\n\n`;
        case 'P': return `\n\n${inline(el).trim()}\n\n`;
        case 'BLOCKQUOTE': return '\n\n' + block(el).trim().split('\n').map((l) => '> ' + l).join('\n') + '\n\n';
        case 'HR': return '\n\n---\n\n';
        case 'UL': case 'OL': {
          const ordered = el.tagName === 'OL';
          let n = Number(el.getAttribute('start') || 1);
          const items = [...el.children].filter((c) => c.tagName === 'LI').map((li) => {
            const marker = ordered ? `${n++}.` : '-';
            const body = block(li).trim().replace(/\n{2,}/g, '\n').split('\n');
            return `${marker} ${body[0]}` + body.slice(1).map((l) => '\n   ' + l).join('');
          });
          return `\n\n${items.join('\n')}\n\n`;
        }
        case 'TABLE': {
          const rows = [...el.querySelectorAll('tr')].map((tr) =>
            [...tr.children].map((c) => inline(c).trim().replace(/\|/g, '\\|')));
          if (!rows.length) return '';
          const width = Math.max(...rows.map((r) => r.length));
          const line = (r) => '| ' + Array.from({ length: width }, (_, i) => r[i] || '').join(' | ') + ' |';
          return '\n\n' + [line(rows[0]), line(Array(width).fill('---')), ...rows.slice(1).map(line)].join('\n') + '\n\n';
        }
        default:
          return inLine ? inline(el) : block(el);
      }
    }

    function block(node) {
      let out = '';
      for (const child of node.childNodes) out += walk(child, false);
      return out;
    }

    return block(root).replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  }

  window.__askAi = { pasteImage, toMarkdown };
})();
