.PHONY: help lint shellcheck markdownlint yamllint gitlint test work-summary iterate

help:
	@echo "Available targets:"
	@echo "  lint          - Run all linters"
	@echo "  shellcheck    - Check bash scripts with shellcheck"
	@echo "  markdownlint  - Check markdown files with markdownlint"
	@echo "  yamllint      - Check YAML files with yamllint"
	@echo "  gitlint       - Check commit messages with gitlint"
	@echo "  test          - Run all tests (currently just linting)"
	@echo "  work-summary  - Generate work summary (last 7 days, or DAYS=N)"
	@echo "  iterate       - Run Claude iteratively (DIR=path PROMPT='text' or PROMPT_FILE=path, optional MAX_ITERATIONS=N MODEL=model)"

lint: shellcheck markdownlint yamllint

test: lint

shellcheck:
	@echo "Running shellcheck..."
	@find skills -type f -name "*.sh" -exec shellcheck -S warning {} +

markdownlint:
	@echo "Running markdownlint..."
	@npx markdownlint-cli2 "**/*.md" "#node_modules"

yamllint:
	@echo "Running yamllint..."
	@yamllint --strict .

gitlint:
	@echo "Running gitlint..."
	@gitlint --commits origin/main..HEAD

work-summary:
	@bash skills/work-summary/scripts/work-summary.sh $${DAYS:-7} > /tmp/work-summary-data.json
	@bash skills/work-summary/scripts/render-report.sh /tmp/work-summary-data.json

iterate:
	@if [ -z "$(DIR)" ]; then \
		echo "Error: DIR parameter required."; \
		echo "Usage: make iterate DIR=/path/to/dir PROMPT='your prompt' [MAX_ITERATIONS=N] [MODEL=model]"; \
		echo "   or: make iterate DIR=/path/to/dir PROMPT_FILE=/path/to/prompt.txt [MAX_ITERATIONS=N] [MODEL=model]"; \
		exit 1; \
	fi; \
	if [ -z "$(PROMPT)" ] && [ -z "$(PROMPT_FILE)" ]; then \
		echo "Error: Either PROMPT or PROMPT_FILE parameter required."; \
		echo "Usage: make iterate DIR=/path/to/dir PROMPT='your prompt' [MAX_ITERATIONS=N] [MODEL=model]"; \
		echo "   or: make iterate DIR=/path/to/dir PROMPT_FILE=/path/to/prompt.txt [MAX_ITERATIONS=N] [MODEL=model]"; \
		exit 1; \
	fi; \
	PROMPT_TEXT="$(PROMPT)"; \
	if [ -n "$(PROMPT_FILE)" ]; then \
		PROMPT_TEXT=$$(cat "$(PROMPT_FILE)"); \
	fi; \
	EXTRA_ARGS=""; \
	if [ -n "$(MAX_ITERATIONS)" ]; then \
		EXTRA_ARGS="$$EXTRA_ARGS -n $(MAX_ITERATIONS)"; \
	fi; \
	if [ -n "$(MODEL)" ]; then \
		EXTRA_ARGS="$$EXTRA_ARGS -m $(MODEL)"; \
	fi; \
	python3 scripts/iterate-claude.py "$(DIR)" "$$PROMPT_TEXT" $$EXTRA_ARGS
