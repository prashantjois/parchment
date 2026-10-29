# Parchment Theme CSS, version 1

Parchment themes are UTF-8 files with the `.theme.css` extension. They use standard CSS. No custom CSS parser or preprocessing language is required.

The app implements this rendering contract with a native interface and a local WebKit preview.

## Bundled themes

The collection takes inspiration from [markdown.style](https://markdown.style/themes), with original CSS, new names, and local font stacks. Each theme supports System, Light, and Dark appearance. The Evening category also includes a light palette.

| Theme | Category | Style |
| --- | --- | --- |
| Harbor | Reports | Navy headings, teal links, and ruled tables |
| Canopy | Reports | Deep green headings on warm paper |
| Flare | Reports | Bold type with an orange title bar |
| Waypoint | Reference | Violet accents and clear documentation hierarchy |
| Keystroke | Reference | Monospace text and restrained blue details |
| Workbench | Reference | System fonts and familiar README styling |
| Storybook | Reading | Expressive serif titles and relaxed spacing |
| Periodical | Reading | Centered titles and small-cap subheadings |
| Vellum | Reading | Warm paper and soft brown serif text |
| Academy | Reading | Formal serif text, justified paragraphs, and blue accents |
| Cotton | Quiet | Soft neutral colors and rounded details |
| Breeze | Quiet | Airy spacing and lightweight system type |
| Pebble | Quiet | Cool gray surfaces and compact typography |
| Gazette | Expressive | Tall serif headlines and red accents |
| Jubilee | Expressive | Large geometric headings and vivid purple |
| Blueprint | Expressive | Uppercase headings, firm rules, and blue accents |
| Cinder | Evening | Charcoal surfaces and soft blue links |
| Fireside | Evening | Warm amber accents and humanist type |
| Starlight | Evening | Navy and gold with serif typography |
| Phosphor | Evening | Green terminal ink and prompt headings |

Vellum is the default for new installations. Previous built-in selections move to a similar new theme during upgrade. Custom CSS, appearance, and font overrides remain available.

## Scope and loading

The renderer exposes one document root: `<article class="markdown-doc" data-appearance="light">`. Dark appearance uses `data-appearance="dark"`.

The app resolves Follow System, Light, or Dark before it renders the document. Themes use this explicit attribute instead of media queries. An explicit appearance choice therefore takes precedence over the system appearance.

The renderer establishes this layer order before it loads any theme:

```css
@layer parchment-base, parchment-theme, parchment-user;
```

It loads `themes/base.css`, then exactly one selected theme. User font and color overrides belong to `parchment-user`. Themes put all declarations in `parchment-theme`.

Each selector must target `.markdown-doc` or its descendants. Themes affect rendered Markdown, including the rendered pane in Split mode. The native toolbar, sidebars, comments, and raw editor use separate app settings.

The format permits ordinary selectors, custom properties, and CSS values supported by WebKit. Version 1 permits no `@import`, `@font-face`, external resources, `url()`, animation, or `!important`. Fonts come from installed system fonts. The import and save validator checks these restrictions with WebKit's CSS object model.

The format defines an HTML rendering contract. The native app uses WebKit for the rendered pane and AppKit for the raw editor.

## Theme identity

The filename without `.theme.css` is the stable theme ID. The root declaration supplies the display name and format version:

```css
@layer parchment-theme {
  .markdown-doc {
    --pt-theme-name: "My Theme";
    --pt-theme-description: "Warm serif text for long documents.";
    --pt-theme-version: 1;
    --pt-font-body: Georgia, "Times New Roman", serif;
    --pt-font-heading: var(--pt-font-body);
    --pt-font-code: Menlo, monospace;
    --pt-font-size: 18px;
    --pt-line-height: 1.65;
    --pt-content-width: 100%;
  }

  .markdown-doc[data-appearance="light"] {
    --pt-background: #f8f1e3;
    --pt-text: #40352b;
    --pt-heading: #30271f;
    --pt-link: #80551e;
  }

  .markdown-doc[data-appearance="dark"] {
    --pt-background: #25211c;
    --pt-text: #e8ddcb;
    --pt-heading: #f4e9d8;
    --pt-link: #e7be7b;
  }

  .markdown-doc h1 { letter-spacing: -0.025em; }
  .markdown-doc h2 { border-bottom: 1px solid var(--pt-border); }
}
```

The base stylesheet supplies omitted values in both appearances. The twenty bundled themes supply complete palettes.

Built-in themes use optional `--pt-theme-category` and `--pt-theme-description` metadata for the theme picker. Imported and duplicated themes appear under Custom.

## Style variables

Custom themes can override these variables or style individual elements directly.

| Variable | Purpose |
| --- | --- |
| `--pt-font-body`, `--pt-font-heading`, `--pt-font-code` | Font stacks |
| `--pt-font-size` | Base rendered size, in CSS pixels |
| `--pt-line-height` | Unitless body line height |
| `--pt-content-width` | Maximum content width |
| `--pt-document-padding` | Space around the document |
| `--pt-block-gap` | Space between blocks |
| `--pt-h1-size` through `--pt-h6-size` | Heading sizes relative to the document font |
| `--pt-heading-weight`, `--pt-heading-line-height` | Heading weight and line height |
| `--pt-background`, `--pt-surface` | Document and inset backgrounds |
| `--pt-text`, `--pt-muted`, `--pt-heading` | Body, secondary, and heading colors |
| `--pt-link`, `--pt-border`, `--pt-code` | Link, border, and code colors |
| `--pt-mark-background`, `--pt-mark-text` | Markdown highlight colors |
| `--pt-selection-background`, `--pt-selection-text` | Text selection colors |
| `--pt-syntax-comment`, `--pt-syntax-keyword` | Highlighted code comments and keywords |
| `--pt-syntax-string`, `--pt-syntax-number` | Highlighted code strings and numbers |
| `--pt-syntax-function`, `--pt-syntax-type` | Highlighted code functions and types |

CSS pixels are logical display units. The renderer must account for display scale. User font-size changes affect relative heading and code sizes.

## Code highlighting

The fence language selects local lexical highlighting for Swift, Kotlin, Java, JavaScript, TypeScript, Python, JSON, Bash, SQL, and YAML. Common aliases include `kt`, `js`, `ts`, `py`, `sh`, and `yml`. Unspecified and unsupported languages remain plain text.

The renderer uses the six `--pt-syntax-*` colors and `.token` selectors listed in this contract. Override the colors inside the theme layer. For example:

```css
@layer parchment-theme {
  .markdown-doc { --pt-syntax-keyword: #7139a8; }
  .markdown-doc[data-appearance="dark"] { --pt-syntax-keyword: #d5adff; }
}
```

Highlighting uses lexical rules rather than a compiler or language server. It does not require network access. Code text stays escaped, and token spans retain source offsets for comments and selections.

## Markdown element contract

| Markdown content | Stable selector |
| --- | --- |
| Headings, levels 1–6 | `h1`, `h2`, `h3`, `h4`, `h5`, `h6` |
| Paragraph, hard break, thematic break | `p`, `br`, `hr` |
| Emphasis, strong emphasis | `em`, `strong` |
| Strikethrough, highlight | `del`, `mark` |
| Link, image | `a`, `img` |
| Image with an optional caption | `figure`, `figcaption` |
| Ordered list, unordered list, item | `ol`, `ul`, `li` |
| Task list and item | `.task-list`, `.task-list-item` |
| Task checkbox | `.task-list-item > input[type="checkbox"]` |
| Quotation, including nested quotation | `blockquote` |
| Inline code | `:not(pre) > code` |
| Fenced or indented code | `pre > code` |
| Code language | `code[data-language="swift"]` (language varies) |
| Table | `table`, `thead`, `tbody`, `tr`, `th`, `td` |
| Table overflow container | `.table-scroll` |
| Column alignment | `[data-align="left"]`, `[data-align="center"]`, `[data-align="right"]` on cells |
| Footnote reference | `a[data-footnote-ref]` |
| Footnote section and return link | `section[data-footnotes]`, `a[data-footnote-backref]` |
| Definition list | `dl`, `dt`, `dd` |
| Keyboard key, superscript, subscript | `kbd`, `sup`, `sub` |
| Collapsible content | `details`, `summary` |
| Inline and block math | `.math-inline`, `.math-block` |
| Diagram container | `.diagram` |
| Highlighted code token | `.token.comment`, `.token.keyword`, `.token.string`, `.token.number`, `.token.function`, `.token.type` |

Every selector is relative to `.markdown-doc`. Extension selectors define appearance only. They do not enable math, diagrams, footnotes, or other parser extensions.

The renderer preserves code whitespace and ordered-list start values. It provides heading IDs and escapes document text. Raw HTML appears as escaped text. Frontmatter does not yet receive special parsing.

Images retain their aspect ratio. Tables and code blocks scroll horizontally within the document. The renderer supplies the same document markup in Rendered and Split modes.

## Comments and selection

Markdown `mark` elements are document content. Comment anchors are separate app annotations and never become Markdown markup.

The app draws comment highlights and active selections independently of theme content styles. Themes cannot hide comment controls or change anchor data. The source and rendered views share the anchor contract in `comments.md`.

## Customization

Built-in themes are immutable. A user duplicates a theme to create an editable local `.theme.css` file. The theme editor previews changes before saving.

The selected theme and appearance are app-wide settings. File layout persistence remains independent of theme preferences. WebKit ignores unsupported CSS declarations under normal CSS rules. The validator reports unsupported rule types, scope violations, and forbidden resources.
