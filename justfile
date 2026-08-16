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
