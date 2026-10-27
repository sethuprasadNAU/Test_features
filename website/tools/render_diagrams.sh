#!/usr/bin/env bash
# Renders every website/diagrams/*.dot source into website/static/diagrams/*.svg.
#
# Diagrams follow the same rule as the screenshots: every image on this site
# is generated, none is taken by hand, and none may be. A hand-drawn picture
# rots silently when the thing it shows changes; a diagram has exactly that
# problem, so it is text in the repo (a Graphviz .dot file, reviewable as a
# diff) rendered here rather than an image somebody drew.
#
# Unlike the screenshots — which need a macOS simulator and are committed
# because they are expensive to produce — a diagram is one `dot` invocation.
# It is cheap enough to render on every build, so the output is NOT committed
# (see website/.gitignore) and this script runs before `hugo build`, in CI
# and locally. See website/README.md, "The diagrams".
#
# Usage: website/tools/render_diagrams.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."   # website/

SRC_DIR="diagrams"
OUT_DIR="static/diagrams"

if ! command -v dot >/dev/null 2>&1; then
  echo "render_diagrams.sh: no 'dot' on PATH. Install Graphviz — on a Mac," \
       "'brew install graphviz'; in CI, apt-get install graphviz. This is" \
       "the only thing needed to render the site's diagrams; it is not" \
       "needed to build the rest of the site." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

count=0
for src in "$SRC_DIR"/*.dot; do
  [ -e "$src" ] || continue
  name="$(basename "$src" .dot)"
  out="$OUT_DIR/$name.svg"

  # `dot -Tsvg` prints an XML prolog and a DOCTYPE before the <svg> element.
  # Those are invalid inside an HTML page, and the diagram shortcode inlines
  # this file's contents directly into the page (so the SVG can be themed by
  # the site's own light/dark CSS variables rather than carrying its own
  # copy of the palette). Strip everything before the opening <svg tag.
  rendered="$(dot -Tsvg "$src")"
  printf '%s\n' "$rendered" | awk '/<svg/{found=1} found{print}' > "$out"

  if ! grep -q '<svg' "$out"; then
    echo "render_diagrams.sh: 'dot' produced no <svg> for $src" >&2
    exit 1
  fi

  count=$((count + 1))
done

echo "render_diagrams.sh: rendered $count diagram(s) into $OUT_DIR"
