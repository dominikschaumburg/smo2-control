#!/bin/zsh
# Build the paper: figures and numbers from a real .fit file, then the PDF.
#
# Usage:  ./build.sh [activity.fit]
#
# MacTeX installs to /Library/TeX/texbin, which is not on the shell PATH.

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
FIT="${1:-$HOME/Desktop/i182958466.fit}"
export PATH="/Library/TeX/texbin:$PATH"

cd "$DIR"
python3 figures.py "$FIT" > /dev/null
latexmk -pdf -interaction=nonstopmode -halt-on-error smo2-control.tex > build.log 2>&1 \
    || { tail -40 build.log; exit 1; }
latexmk -c > /dev/null 2>&1
rm -f build.log
echo "Done -> $DIR/smo2-control.pdf"
