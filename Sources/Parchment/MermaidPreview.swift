import Foundation
import WebKit

enum MermaidPreview {
    // The classic bundle includes every diagram type, without network imports.
    static let library: String? = {
        let relativePath = "vendor/mermaid/mermaid.min.js"
        if let root = Bundle.main.resourceURL,
           let script = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8) { return script }
        guard let root = Bundle.module.resourceURL else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }()

    static func install(in controller: WKUserContentController) {
        guard let library else { return }
        controller.addUserScript(WKUserScript(
            source: "if (document.querySelector('.mermaid-diagram')) {\n" + library + "\n}",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    static let script = #"""
    async function renderMermaidDiagrams() {
      const diagrams = [...document.querySelectorAll('.mermaid-diagram')];
      if (!diagrams.length) return;
      const article = document.querySelector('.markdown-doc');
      if (window.mermaid) {
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: 'strict',
          suppressErrorRendering: true,
          maxTextSize: 50000,
          theme: article.dataset.appearance === 'dark' ? 'dark' : 'default',
          fontFamily: getComputedStyle(article).fontFamily,
          htmlLabels: false,
          flowchart: {htmlLabels: false},
          secure: ['secure', 'securityLevel', 'startOnLoad', 'suppressErrorRendering',
                   'maxTextSize', 'htmlLabels', 'flowchart', 'theme', 'themeCSS',
                   'themeVariables', 'fontFamily']
        });
      }
      for (const [index, figure] of diagrams.entries()) {
        const source = figure.querySelector('pre');
        try {
          if (!window.mermaid) throw new Error('The bundled Mermaid renderer is unavailable.');
          const {svg} = await mermaid.render('parchment-mermaid-' + index, source.textContent);
          const output = document.createElement('div');
          output.className = 'mermaid-output';
          output.dataset.leaf = 'true';
          output.dataset.precise = '0';
          output.dataset.start = figure.dataset.start;
          output.dataset.end = figure.dataset.end;
          const template = document.createElement('template');
          template.innerHTML = svg;
          // Diagram images must not bypass the editor's remote-image controls.
          template.content.querySelectorAll('image, foreignObject').forEach(element => element.remove());
          template.content.querySelectorAll('[href], [src], [xlink\\:href]').forEach(element => {
            for (const attribute of [...element.attributes]) {
              if (['href', 'src', 'xlink:href'].includes(attribute.name) && !attribute.value.startsWith('#')) {
                element.removeAttributeNode(attribute);
              }
            }
          });
          output.appendChild(template.content);
          output.querySelector('svg')?.setAttribute('role', 'img');
          source.replaceWith(output);
          figure.dataset.mermaidState = 'rendered';
        } catch (error) {
          const caption = document.createElement('figcaption');
          caption.className = 'mermaid-error';
          caption.textContent = 'Mermaid diagram: ' + (error.message || String(error));
          figure.appendChild(caption);
          figure.dataset.mermaidState = 'error';
        }
      }
      setComments(commentRanges);
    }
    """#
}
