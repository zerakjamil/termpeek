#!/bin/sh
# Universal installer for termpeek
# Supports Linux, macOS, Termux (Android), and Windows (WSL/MSYS2/Git Bash)

set -e

INSTALL_DIR="${HOME}/.termpeek"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"

echo "=== termpeek Universal Installer ==="

# Check for Zsh
if ! command -v zsh >/dev/null 2>&1; then
  echo "Notice: zsh is not installed on this system."
  if [ -n "$PREFIX" ] && [ -d "$PREFIX" ]; then
    echo "  -> On Termux: run 'pkg install zsh'"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "  -> On Debian/Ubuntu: run 'sudo apt install zsh'"
  elif command -v pacman >/dev/null 2>&1; then
    echo "  -> On Arch Linux: run 'sudo pacman -S zsh'"
  elif command -v dnf >/dev/null 2>&1; then
    echo "  -> On Fedora: run 'sudo dnf install zsh'"
  elif command -v brew >/dev/null 2>&1; then
    echo "  -> On macOS: run 'brew install zsh'"
  fi
  echo "Please install zsh and run this script again."
  exit 1
fi

# Check for Python (worker dependency)
if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
  echo "Notice: python is not found on this system."
  if [ -n "$PREFIX" ] && [ -d "$PREFIX" ]; then
    echo "  -> On Termux: run 'pkg install python'"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "  -> On Debian/Ubuntu: run 'sudo apt install python3'"
  elif command -v pacman >/dev/null 2>&1; then
    echo "  -> On Arch Linux: run 'sudo pacman -S python'"
  elif command -v dnf >/dev/null 2>&1; then
    echo "  -> On Fedora: run 'sudo dnf install python3'"
  elif command -v brew >/dev/null 2>&1; then
    echo "  -> On macOS: run 'brew install python'"
  fi
  echo "Please install python and run this script again."
  exit 1
fi

echo "Installing termpeek to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)"
cp -r "$SCRIPT_SRC/"* "$INSTALL_DIR/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/bin/termpeek-worker" 2>/dev/null || true

touch "$ZSHRC"
if ! grep -q "termpeek.zsh" "$ZSHRC" 2>/dev/null; then
  echo "" >> "$ZSHRC"
  echo "# termpeek: live type-ahead command history search" >> "$ZSHRC"
  echo "source $INSTALL_DIR/termpeek.zsh" >> "$ZSHRC"
  echo "Added termpeek to $ZSHRC."
else
  echo "termpeek is already referenced in $ZSHRC."
fi

echo ""
echo "Installation complete!"
echo "Run 'exec zsh' or 'source $ZSHRC' to start using termpeek."
