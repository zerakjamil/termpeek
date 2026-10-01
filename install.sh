#!/usr/bin/env bash
# Quick installer for termpeek

set -e

INSTALL_DIR="$HOME/.termpeek"
ZSHRC="$HOME/.zshrc"

echo "Installing termpeek to $INSTALL_DIR..."

mkdir -p "$INSTALL_DIR"
cp -r "$(dirname "$0")/"* "$INSTALL_DIR/"

if ! grep -q "termpeek.zsh" "$ZSHRC" 2>/dev/null; then
  echo "" >> "$ZSHRC"
  echo "# termpeek - live command history search" >> "$ZSHRC"
  echo "source $INSTALL_DIR/termpeek.zsh" >> "$ZSHRC"
  echo "Added termpeek to $ZSHRC."
else
  echo "termpeek is already referenced in $ZSHRC."
fi

echo "Done. Run 'exec zsh' to start using termpeek."
