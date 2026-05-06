.PHONY: help build test lint format format-check clean

help:
	@echo "apple-mail-blade-mcp — Stallari-internal Apple Mail blade (DD-241)"
	@echo ""
	@echo "Targets:"
	@echo "  build         Build the library"
	@echo "  test          Run the test suite (fixtures only — never against real Mail.app data)"
	@echo "  lint          Run swift-format lint check"
	@echo "  format        Auto-format sources in place"
	@echo "  format-check  Verify sources are formatted (CI-style)"
	@echo "  clean         Remove .build artefacts"
	@echo ""
	@echo "Distribution: this library is consumed by StallariKit via SPM dependency."
	@echo "There is no notarised pkg, no standalone binary, no online CI signing."
	@echo "Stallari's existing Makefile pipeline signs everything that ships."

build:
	swift build

test:
	swift test --enable-code-coverage

lint:
	swift-format lint --strict --recursive Sources Tests

format:
	swift-format format --in-place --recursive Sources Tests

format-check:
	swift-format lint --recursive Sources Tests

clean:
	rm -rf .build .swiftpm Package.resolved
