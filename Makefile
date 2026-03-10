.PHONY: help lint shellcheck markdownlint yamllint gitlint test work-summary

help:
	@echo "Available targets:"
	@echo "  lint          - Run all linters"
	@echo "  shellcheck    - Check bash scripts with shellcheck"
	@echo "  markdownlint  - Check markdown files with markdownlint"
	@echo "  yamllint      - Check YAML files with yamllint"
	@echo "  gitlint       - Check commit messages with gitlint"
	@echo "  test          - Run all tests (currently just linting)"
	@echo "  work-summary  - Generate work summary (last 7 days, or DAYS=N)"

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
	@bash skills/work-summary/scripts/work-summary.sh $(DAYS)
