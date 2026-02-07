.PHONY: generate open clean

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
