# AI Helpers

Claude Code marketplace for work tracking and iterative development.

## Installation

```bash
/plugin marketplace add ai-helpers https://github.com/dfarrell07/ai-helpers
/plugin install ai-helpers@ai-helpers
```

For the iterative development script:
```bash
pip install -r requirements.txt
export ANTHROPIC_API_KEY=your_api_key_here
```

## Skills

- `/work-summary` - Show recent git commits and GitHub activity

See [.claude/SKILLS.md](.claude/SKILLS.md) for details.

## Tools

### Iterative Claude

Run Claude iteratively with maintained context, auto-committing changes after each iteration:

```bash
# Basic usage
make iterate DIR=/path/to/project PROMPT="Fix all linting errors"

# With max iterations
make iterate DIR=/path/to/project PROMPT="Refactor the API" MAX_ITERATIONS=5

# With specific model
make iterate DIR=/path/to/project PROMPT="Add tests" MODEL=claude-opus-4-6

# Using a prompt file
make iterate DIR=/path/to/project PROMPT_FILE=task.txt MAX_ITERATIONS=10
```

**How it works:**
- Claude maintains conversation history across all iterations
- Claude can execute bash commands in the target directory to read/write files, run tests, etc.
- After each iteration, if changes exist, they're automatically committed
- Continues until max iterations reached, Claude says "ITERATION_COMPLETE", or you interrupt (Ctrl+C)
