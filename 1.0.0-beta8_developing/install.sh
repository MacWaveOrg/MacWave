#!/bin/bash

# MacWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.

set -e

INSTALL_DIR="$HOME/.local/macwave/bin"
WAVE_URL="https://raw.githubusercontent.com/MacWaveOrg/MacWave/main/wave.py"

echo "🌊 Welcome to MacWave!"
echo "🌊 Installing to $INSTALL_DIR..."

# 1. Create installation directory
mkdir -p "$INSTALL_DIR"

# 2. Download wave.py as 'wave'
echo "🌊 Downloading wave.py..."
curl -fsSL -o "$INSTALL_DIR/wave" "$WAVE_URL"

# 3. Make it executable
chmod +x "$INSTALL_DIR/wave"

# 4. Install Python dependencies: requests, packaging, and rich
echo "🌊 Checking Python dependencies..."
if ! python3 -c "import requests" 2>/dev/null; then
    echo "🌊 Installing 'requests' library..."
    pip3 install requests --quiet
else
    echo "🌊 'requests' library is already installed."
fi

if ! python3 -c "from packaging.version import parse" 2>/dev/null; then
    echo "🌊 Installing 'packaging' library..."
    pip3 install packaging --quiet
else
    echo "🌊 'packaging' library is already installed."
fi

if ! python3 -c "import rich" 2>/dev/null; then
    echo "🌊 Installing 'rich' library for progress bar..."
    if pip3 install rich --quiet; then
        echo "🌊 'rich' installed successfully."
    else
        echo "🌊 Warning: 'rich' installation failed. Progress bar will not be available."
        echo "🌊 You can install it manually later: pip3 install rich"
    fi
else
    echo "🌊 'rich' library is already installed."
fi

# 5. Add to PATH in .zshrc / .bashrc
if [[ "$SHELL" == *"zsh"* ]]; then
    RC_FILE="$HOME/.zshrc"
elif [[ "$SHELL" == *"bash"* ]]; then
    RC_FILE="$HOME/.bashrc"
else
    RC_FILE="$HOME/.profile"
fi

if ! grep -q "$INSTALL_DIR" "$RC_FILE" 2>/dev/null; then
    echo "🌊 Adding MacWave to PATH in $RC_FILE..."
    echo "" >> "$RC_FILE"
    echo "# MacWave" >> "$RC_FILE"
    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$RC_FILE"
else
    echo "🌊 MacWave is already in your PATH."
fi

# 6. Final message with colored prompt
echo ""
echo "🌊 Installation complete!"
echo ""
echo "🌊 To use 'wave' immediately in this terminal, run:"
echo -e "\033[33m    source ~/.zshrc\033[0m"
echo "🌊 (If you are using bash, run:"
echo -e "\033[33m    source ~/.bashrc\033[0m"
echo "🌊 Or simply open a new terminal window to apply changes automatically."
echo ""
echo "🌊 Try it now after refreshing:"
echo "    wave install test_001"

# 7. License Agreement Confirmation
echo ""
echo -e "\033[33mPlease read the agreement before use (see bottom of https://macwave.org).\033[0m"
read -p "Have you read and agreed to the agreement? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "\033[32mYou have agreed to the agreement. Installation continues.\033[0m"
else
    echo -e "\033[31mYou do not agree to the agreement. Installation stopped.\033[0m"
    exit 1
fi
