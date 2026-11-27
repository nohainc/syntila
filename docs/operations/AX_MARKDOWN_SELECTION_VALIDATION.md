# AX Markdown Selection Validation

Syntila renders authored and Worker Markdown through the shared
`SyntilaMarkdownBody` widget. Each message owns one Flutter `SelectionArea`;
`MarkdownBody.selectable` remains disabled so paragraphs, lists, tables, and
the custom syntax-highlighted code block participate in the same selection
boundary.

## Automated coverage

Run the focused renderer suite from `apps/app`:

```bash
flutter test test/syntila_markdown_body_test.dart test/syntila_code_block_test.dart
```

Run the same focused suite through Chrome's web test platform:

```bash
flutter test --platform chrome test/syntila_markdown_body_test.dart test/syntila_code_block_test.dart
```

Safari and Firefox remain manual browser checks; they are not available as
Flutter test devices in the local development environment.

The suite covers:

- GFM headings, paragraphs, inline formatting, lists, tables, quotes, links,
  images, and malformed/untrusted input;
- selecting across ordinary Markdown and a syntax-highlighted code block;
- message-scoped Select All and exact code copying;
- selection after a live message replacement;
- long responses containing hundreds of paragraphs, a table, and a code block;
- link validation without executing unsupported schemes or HTML.

## Browser acceptance matrix

Use a fresh browser session for each browser. The debug launcher is suitable
for iteration; release mode is required to check the production web rendering
path.

```bash
cd /Users/vitaliinoha/Documents/Syntila/Syntila
./scripts/local-start.sh
```

For a release-mode browser check:

```bash
cd /Users/vitaliinoha/Documents/Syntila/Syntila
./scripts/local-start.sh --web-release
```

Check Chrome, Safari, and Firefox with a Worker response containing:

1. a heading and two paragraphs;
2. bold, italic, inline code, a link, and a blockquote;
3. ordered and unordered lists;
4. a table wider than the message column;
5. a fenced syntax-highlighted code block;
6. a second message below it.

For each browser, verify:

- drag selection within a paragraph;
- drag selection from the first paragraph through the code block;
- selection across paragraphs, lists, tables, and quotes;
- keyboard copy copies only the selected text;
- Select All inside a message excludes its header, actions, neighboring
  messages, and sidebar UI;
- the code header and Copy code button are not selected;
- Copy code copies the exact source, including whitespace;
- links remain clickable when not selecting;
- switching Threads or Spaces, refreshing, and receiving a live update does
  not leave stale selection handles or throw an error;
- long responses remain scrollable and do not overflow the message column.

## Known boundary

The Markdown source remains independently available through Copy Markdown.
Images are represented by accessible alt text rather than loaded remote image
widgets. The code language label and action controls are intentionally outside
the selectable content. Continuous selection cannot include non-text media;
the original Markdown and dedicated copy actions remain the reliable fallback.
