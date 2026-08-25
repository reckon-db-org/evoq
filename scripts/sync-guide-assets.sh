#!/bin/sh
set -eu

# ex_doc flattens guides/ and assets/ into one output directory, so guide
# sources must reference images as "assets/foo.svg" (see the `assets`
# mapping in rebar.config). That same path is one level too shallow when
# GitHub renders guides/*.md in place, so the images show broken there.
# This script mirrors the SVGs guides/*.md actually reference into
# guides/assets/ so both hexdocs and GitHub render correctly. Re-run it
# after adding or renaming a diagram used from guides/.

cd -P -- "$(dirname -- "$0")/.."

mkdir -p guides/assets

grep -ohE 'assets/[A-Za-z0-9_.-]+\.svg' guides/*.md \
    | sort -u \
    | sed 's#^assets/##' \
    | while IFS= read -r svg; do
        cp "assets/$svg" "guides/assets/$svg"
    done

echo "Synced $(ls guides/assets | wc -l) SVG(s) into guides/assets/"
