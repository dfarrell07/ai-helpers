#!/usr/bin/env python3
"""
Iterative Claude script that maintains context across iterations.
Each iteration commits changes if work was done.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path


def run_git_command(cmd, cwd):
    """Run a git command and return output."""
    result = subprocess.run(
        cmd, shell=True, cwd=cwd, capture_output=True, text=True
    )
    return result.returncode, result.stdout, result.stderr


def run_bash_command(cmd, cwd):
    """Run a bash command and return output."""
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=300
        )
        return {
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr
        }
    except subprocess.TimeoutExpired:
        return {
            "returncode": -1,
            "stdout": "",
            "stderr": "Command timed out after 300 seconds"
        }


def has_git_changes(cwd):
    """Check if there are any uncommitted changes."""
    returncode, stdout, _ = run_git_command("git status --porcelain", cwd)
    return returncode == 0 and bool(stdout.strip())


def commit_changes(cwd, iteration):
    """Commit all changes with an automatic message."""
    run_git_command("git add -A", cwd)

    _, diff_stat, _ = run_git_command("git diff --cached --stat", cwd)
    _, diff_files, _ = run_git_command("git diff --cached --name-only", cwd)

    files_changed = diff_files.strip().split('\n') if diff_files.strip() else []
    files_list = '\n'.join(f"  - {f}" for f in files_changed[:10])
    if len(files_changed) > 10:
        files_list += f"\n  ... and {len(files_changed) - 10} more"

    commit_msg = f"""Iteration {iteration}: AI-driven changes

Files modified:
{files_list}

Stats:
{diff_stat.strip()}"""

    # Use a temporary file for the commit message to avoid shell escaping issues
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
        f.write(commit_msg)
        msg_file = f.name

    try:
        cmd = f'git commit -F "{msg_file}"'
        returncode, stdout, stderr = run_git_command(cmd, cwd)

        if returncode == 0:
            print(f"✓ Committed changes from iteration {iteration}")
            # Get the commit hash
            _, commit_hash, _ = run_git_command("git rev-parse --short HEAD", cwd)
            print(f"  Commit: {commit_hash.strip()}")
            return True
        else:
            print(f"✗ Failed to commit: {stderr}")
            return False
    finally:
        os.unlink(msg_file)


# Define the bash tool for Claude
TOOLS = [{
    "name": "bash",
    "description": "Execute bash commands in the target directory. Use this to read files, write files, run scripts, etc.",
    "input_schema": {
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "The bash command to execute"
            }
        },
        "required": ["command"]
    }
}]


def iterate_claude(directory, prompt, max_iterations=None, model="claude-sonnet-4-5-20250929"):
    """Run Claude iteratively with maintained context."""

    # Validate directory first (before checking for dependencies)
    target_dir = Path(directory).resolve()
    if not target_dir.exists():
        print(f"Error: Directory does not exist: {directory}")
        sys.exit(1)

    # Check for anthropic package
    try:
        from anthropic import Anthropic
    except ImportError:
        print("Error: anthropic package not installed. Run: pip install anthropic")
        sys.exit(1)

    if not (target_dir / ".git").exists():
        print(f"Warning: {directory} is not a git repository. Changes won't be committed.")
        can_commit = False
    else:
        can_commit = True

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("Error: ANTHROPIC_API_KEY environment variable not set")
        sys.exit(1)

    client = Anthropic(api_key=api_key)
    messages = []

    system_prompt = f"""You are working in the directory: {target_dir}

Your task: {prompt}

You have access to a bash tool to execute commands in the target directory. Use it to:
- Read files (cat, head, grep, find, etc.)
- Write files (using echo, cat with heredoc, etc.)
- Run tests, linters, builds
- Any other command-line operations

Important instructions:
- Work iteratively. Each iteration should make concrete progress.
- Use bash commands to make actual changes to files.
- After completing substantial work, state "ITERATION_COMPLETE" if truly done.
- If there's more work, explain what you did and what's next.
- Be efficient - combine related commands when possible.
"""

    print(f"Starting iterative Claude sessions in {target_dir}")
    print(f"Model: {model}")
    if max_iterations:
        print(f"Max iterations: {max_iterations}")
    else:
        print("Iterations: unlimited (Ctrl+C to stop)")
    print("=" * 60)

    iteration = 1
    iterations_completed = 0

    try:
        while True:
            if max_iterations and iteration > max_iterations:
                print(f"\nReached maximum iterations ({max_iterations})")
                break

            print(f"\n{'=' * 60}")
            print(f"ITERATION {iteration}")
            print(f"{'=' * 60}\n")

            if iteration == 1:
                user_message = prompt
            else:
                user_message = "Continue with the next iteration. What else needs to be done?"

            messages.append({
                "role": "user",
                "content": user_message
            })

            # Tool use loop for this iteration
            iteration_complete = False
            tool_use_count = 0
            max_tool_uses = 50  # Safety limit per iteration

            while not iteration_complete and tool_use_count < max_tool_uses:
                print(f"  Calling Claude API... (tool use {tool_use_count + 1})")

                response = client.messages.create(
                    model=model,
                    max_tokens=8000,
                    system=system_prompt,
                    messages=messages,
                    tools=TOOLS
                )

                # Extract text and tool uses
                response_text = ""
                tool_uses = []

                for block in response.content:
                    if block.type == "text":
                        response_text += block.text
                    elif block.type == "tool_use":
                        tool_uses.append(block)

                # Display Claude's response
                if response_text:
                    print(f"\n{response_text}")

                # Add assistant response to history
                messages.append({
                    "role": "assistant",
                    "content": response.content
                })

                # Check if iteration is complete
                if "ITERATION_COMPLETE" in response_text and not tool_uses:
                    print("\n✓ Claude indicates work is complete")
                    iteration_complete = True
                    break

                # Execute any tool calls
                if tool_uses:
                    tool_results = []

                    for tool_use in tool_uses:
                        tool_input = tool_use.input

                        print(f"\n  → Executing: {tool_input['command']}")

                        result = run_bash_command(tool_input['command'], target_dir)

                        # Truncate large outputs to avoid API limits
                        max_output_size = 50000  # chars
                        if len(result['stdout']) > max_output_size:
                            result['stdout'] = result['stdout'][:max_output_size] + f"\n... (truncated, {len(result['stdout'])} bytes total)"
                        if len(result['stderr']) > max_output_size:
                            result['stderr'] = result['stderr'][:max_output_size] + f"\n... (truncated, {len(result['stderr'])} bytes total)"

                        if result['stdout']:
                            print(f"    stdout: {result['stdout'][:200]}")
                            if len(result['stdout']) > 200:
                                print(f"    ... ({len(result['stdout'])} bytes total)")
                        if result['stderr']:
                            print(f"    stderr: {result['stderr'][:200]}")
                        print(f"    exit code: {result['returncode']}")

                        tool_results.append({
                            "type": "tool_result",
                            "tool_use_id": tool_use.id,
                            "content": json.dumps(result)
                        })

                    # Add tool results to messages
                    messages.append({
                        "role": "user",
                        "content": tool_results
                    })

                    tool_use_count += 1
                else:
                    # No more tool uses, iteration done
                    iteration_complete = True

            if tool_use_count >= max_tool_uses:
                print(f"\n⚠ Reached tool use limit ({max_tool_uses}) for this iteration")

            # Check for changes and commit
            if can_commit and has_git_changes(target_dir):
                commit_changes(target_dir, iteration)
            else:
                if can_commit:
                    print(f"\n→ No changes to commit in iteration {iteration}")

            iterations_completed += 1

            # Check if Claude said it's completely done
            if "ITERATION_COMPLETE" in response_text:
                break

            iteration += 1

    except KeyboardInterrupt:
        print("\n\n⚠ Interrupted by user")
        print(f"\n{'=' * 60}")
        print(f"Completed {iterations_completed} iteration(s)")
        print(f"{'=' * 60}")
        sys.exit(0)
    except Exception as e:
        print(f"\n✗ Error: {e}")
        traceback.print_exc()
        sys.exit(1)

    print(f"\n{'=' * 60}")
    print(f"Completed {iterations_completed} iteration(s)")
    print(f"{'=' * 60}")


def main():
    parser = argparse.ArgumentParser(
        description="Run Claude iteratively with maintained context and auto-commits"
    )
    parser.add_argument(
        "directory",
        help="Directory to work in (must be a git repository for auto-commits)"
    )
    parser.add_argument(
        "prompt",
        help="Task prompt for Claude"
    )
    parser.add_argument(
        "-n", "--max-iterations",
        type=int,
        help="Maximum number of iterations (default: unlimited)"
    )
    parser.add_argument(
        "-m", "--model",
        default="claude-sonnet-4-5-20250929",
        help="Claude model to use (default: claude-sonnet-4-5-20250929)"
    )

    args = parser.parse_args()

    iterate_claude(
        args.directory,
        args.prompt,
        args.max_iterations,
        args.model
    )


if __name__ == "__main__":
    main()
