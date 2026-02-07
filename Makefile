.PHONY: generate open clean run

# Default target - generate and open
all: generate open

# Generate Xcode workspace
generate:
	@tuist install
	@tuist generate
	@rm -f "ZohoAIBookkeeper.xcworkspace/xcshareddata/xcschemes/ZohoAIBookkeeper-Workspace.xcscheme"

# Open the workspace
open:
	@open ZohoAIBookkeeper.xcworkspace

# Build and run the CLI
run:
	@xcodebuild -workspace ZohoAIBookkeeper.xcworkspace -scheme ZohoBookkeeperCLI -configuration Debug -destination "platform=macOS,arch=arm64" build -quiet
	$(eval BUILD_DIR := $(shell find ~/Library/Developer/Xcode/DerivedData/ZohoAIBookkeeper-* -type d -path "*/Build/Products/Debug" -not -path "*/Index.noindex/*" 2>/dev/null | head -1))
	@DYLD_FRAMEWORK_PATH="$(BUILD_DIR)" "$(BUILD_DIR)/ZohoBookkeeperCLI"

# Clean generated files, build artifacts, and caches
clean:
	@killall Xcode 2>/dev/null || true
	@echo "Cleaning Xcode workspace and projects..."
	@rm -rf *.xcworkspace
	@find . -name "*.xcodeproj" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "Cleaning DerivedData..."
	@rm -rf ~/Library/Developer/Xcode/DerivedData/ZohoAIBookkeeper-*
	@echo "Cleaning Tuist cache..."
	@tuist clean
	@echo "Done."
