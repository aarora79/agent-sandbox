# Sandboxing Agentic AI — slides

Marp deck accompanying the `lab/`. Live-preview with `npm run preview` (opens a watch server at http://localhost:8080), or build artifacts with `npm run build:html` (produces `slides.html`) and `npm run build:pdf` (produces `slides.pdf`). All commands run Marp through `npx -y @marp-team/marp-cli@^4`, so no global install is needed; `npm install` is optional.

## Diagrams

Marp core does not render ```mermaid``` fenced blocks (and client-side scripts are stripped by its bespoke template), so the diagrams are **pre-rendered to SVG** and embedded as images:

- Sources live in `diagrams/*.mmd`.
- Rendered output in `assets/*.svg` (referenced from `slides.md` as `![h:…](assets/…​.svg)`), so they appear in `preview`, `slides.html`, and `slides.pdf`.

Edit a diagram by changing its `.mmd`, then regenerate the SVGs:

```bash
npm run build:diagrams   # uses @mermaid-js/mermaid-cli (downloads a headless Chromium on first run)
```

## Theme & avoiding overflow

The deck uses a custom **`sandbox`** theme ([`themes/sandbox.css`](themes/sandbox.css)) —
gaia with a smaller base font (30px) and tighter padding, because gaia's defaults
(35px / 70px) overflow dense slides (tables, code, long bullet lists). Authoring
against this theme means new slides fit by default.

- **marp-cli** loads it via `--theme-set themes/sandbox.css` (already in every
  `npm run` script above).
- **VS Code "Marp for VS Code"** loads it via [`.vscode/settings.json`](../.vscode/settings.json)
  (`markdown.marp.themes`). Open the **repo root** in VS Code, trust the workspace,
  and reload the window once so the preview picks up the theme (otherwise the
  preview falls back to default and looks cramped).

A handful of the densest slides add a one-line `<style scoped>section{font-size:…}</style>`
nudge on top of the theme. If you add content and a slide overflows, either split
it or drop in the same scoped style. Quick check: `npm run build:html` then eyeball,
or just watch the live preview — if content touches the bottom edge, trim it.
