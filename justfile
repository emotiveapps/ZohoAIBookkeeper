# Justfile for ZohoAIBookkeeper (run `just --list` for a summary)

# Default: generate the workspace and open Xcode
default: generate open

# Generate the Xcode workspace (does NOT open Xcode — intentional)
generate:
    tuist install
    tuist generate --no-open
    rm -f "ZohoAIBookkeeper.xcworkspace/xcshareddata/xcschemes/ZohoAIBookkeeper-Workspace.xcscheme"

# Open the workspace
open:
    open ZohoAIBookkeeper.xcworkspace

# Build and run the CLI
run: generate
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild -workspace ZohoAIBookkeeper.xcworkspace -scheme ZohoBookkeeperCLI \
        -configuration Debug -destination "platform=macOS,arch=arm64" build -quiet
    BUILD_DIR=$(find ~/Library/Developer/Xcode/DerivedData/ZohoAIBookkeeper-* -type d \
        -path "*/Build/Products/Debug" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
    DYLD_FRAMEWORK_PATH="$BUILD_DIR" "$BUILD_DIR/ZohoBookkeeperCLI"

# Run the BookkeeperCore unit tests (macOS)
test: generate
    xcodebuild -workspace ZohoAIBookkeeper.xcworkspace -scheme ZohoBookkeeperCLI \
        -configuration Debug -destination "platform=macOS,arch=arm64" test

# Run the iOS app unit tests (simulator; boot it first if tests fail to launch)
test-app: generate
    xcodebuild -workspace ZohoAIBookkeeper.xcworkspace -scheme ZohoBookkeeperApp \
        -configuration Debug -destination "platform=iOS Simulator,name=iPhone 17" test

# Install the CLI to ~/.zoho-ai-bookkeeper/bin and schedule receipts sync
# every 4 hours (and at login) via a LaunchAgent
install: generate
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building Release CLI..."
    xcodebuild -workspace ZohoAIBookkeeper.xcworkspace -scheme ZohoBookkeeperCLI \
        -configuration Release -destination "platform=macOS,arch=arm64" build -quiet
    BUILD_DIR=$(find ~/Library/Developer/Xcode/DerivedData/ZohoAIBookkeeper-* -type d \
        -path "*/Build/Products/Release" -not -path "*/Index.noindex/*" 2>/dev/null | head -1)
    BIN="$HOME/.zoho-ai-bookkeeper/bin"
    rm -rf "$BIN"
    mkdir -p "$BIN" "$HOME/.zoho-ai-bookkeeper/logs"
    cp -R "$BUILD_DIR/ZohoBookkeeperCLI" "$BIN/"
    cp -R "$BUILD_DIR"/*.framework "$BIN/"
    find "$BUILD_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$BIN/" \;
    # Let the binary find its frameworks next to itself, so it runs without
    # DYLD_FRAMEWORK_PATH. Re-sign (ad-hoc) since editing rpaths breaks the signature.
    install_name_tool -add_rpath @executable_path "$BIN/ZohoBookkeeperCLI" 2>/dev/null || true
    codesign -f -s - "$BIN/ZohoBookkeeperCLI"
    PLIST="$HOME/Library/LaunchAgents/com.emotiveapps.zoho-bookkeeper.receipts-sync.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLISTEOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>com.emotiveapps.zoho-bookkeeper.receipts-sync</string>
        <key>ProgramArguments</key>
        <array>
            <string>$BIN/ZohoBookkeeperCLI</string>
            <string>receipts</string>
            <string>sync</string>
        </array>
        <key>EnvironmentVariables</key>
        <dict><key>DYLD_FRAMEWORK_PATH</key><string>$BIN</string></dict>
        <key>StartInterval</key><integer>14400</integer>
        <key>RunAtLoad</key><true/>
        <key>StandardOutPath</key><string>$HOME/.zoho-ai-bookkeeper/logs/receipts-sync.log</string>
        <key>StandardErrorPath</key><string>$HOME/.zoho-ai-bookkeeper/logs/receipts-sync.log</string>
    </dict>
    </plist>
    PLISTEOF
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed. Sync runs every 4h and at login."
    echo "  Force a run:  launchctl kickstart -k gui/$(id -u)/com.emotiveapps.zoho-bookkeeper.receipts-sync"
    echo "  Watch logs:   tail -f ~/.zoho-ai-bookkeeper/logs/receipts-sync.log"
    echo "NOTE: if macOS shows a Keychain prompt on first run, click 'Always Allow'"
    echo "(the installed binary is distinct from the dev build that saved the tokens)."

# Leaves config, tokens, cache, logs, and the receipts archive untouched.
# Remove the installed CLI and the scheduled receipts-sync LaunchAgent
uninstall:
    #!/usr/bin/env bash
    set -uo pipefail
    PLIST="$HOME/Library/LaunchAgents/com.emotiveapps.zoho-bookkeeper.receipts-sync.plist"
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$HOME/.zoho-ai-bookkeeper/bin"
    echo "Removed the receipts-sync LaunchAgent and ~/.zoho-ai-bookkeeper/bin."
    echo "Kept: config.json, Keychain tokens, cache, logs, and the receipts archive."
    echo "(Reinstall any time with: just install)"

# Clean generated files, build artifacts, and caches
clean:
    -killall Xcode 2>/dev/null
    @echo "Cleaning Xcode workspace and projects..."
    rm -rf ZohoAIBookkeeper.xcworkspace
    -find . -name "*.xcodeproj" -type d -exec rm -rf {} +
    @echo "Cleaning DerivedData..."
    rm -rf ~/Library/Developer/Xcode/DerivedData/ZohoAIBookkeeper-*
    @echo "Cleaning Tuist cache..."
    tuist clean
    @echo "Done."
