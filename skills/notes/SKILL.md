---
name: notes
description: Take and manage persistent markdown notes organized by topic
version: 1.0.0
argument-hint: "<topic> [note instruction or list|view|search]"
user-invocable: true
allowed-tools: Bash, Read, Write
---

# Session Notes

```bash
/notes <topic> <what to note>   # Save a note about the current discussion
/notes <topic> list             # List notes for a topic
/notes <topic> view [N]         # View notes (optionally by number from list)
/notes <topic> search <query>   # Search within a topic
/notes list                     # List all topics
```

**Arguments:** $ARGUMENTS

**Notes directory:** ~/notes-ai/

---

## Step 0: Discover Current State

Run the helper script to show existing topics and notes for context.

```bash
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

ARGS="$ARGUMENTS"

if [[ -z "$ARGS" || "$ARGS" == "list" ]]; then
  bash "$SCRIPT_DIR/scripts/notes.sh" list-topics
else
  TOPIC="${ARGS%% *}"
  REST="${ARGS#"$TOPIC"}"
  REST="${REST# }"

  if [[ "$REST" == "list" ]]; then
    bash "$SCRIPT_DIR/scripts/notes.sh" list-notes "$TOPIC"
  elif [[ "$REST" == "search "* ]]; then
    QUERY="${REST#search }"
    bash "$SCRIPT_DIR/scripts/notes.sh" search "$TOPIC" "$QUERY"
  elif [[ "$REST" == "view" || "$REST" == "view "* ]]; then
    NUM="${REST#view}"
    NUM="${NUM# }"
    bash "$SCRIPT_DIR/scripts/notes.sh" list-notes "$TOPIC"
    if [[ -n "$NUM" ]]; then
      bash "$SCRIPT_DIR/scripts/notes.sh" view-note "$TOPIC" "$NUM"
    fi
  else
    bash "$SCRIPT_DIR/scripts/notes.sh" list-notes "$TOPIC"
  fi
fi
```

---

## Step 1: Act on the User's Intent

Based on $ARGUMENTS and the output from Step 0, do one of the following:

### If the user wants to add a note (most common — topic + description of what to note)

Look back through the conversation for the relevant context. Write a well-structured
markdown note that captures the key findings, decisions, or learnings.

Save the note using the Write tool to:
`~/notes-ai/<topic>/<YYYY-MM-DD-HHMMSS>.md`

Use this format:

```markdown
---
date: <ISO 8601 timestamp>
topic: <topic>
tags: [<relevant tags inferred from content>]
---

# <Descriptive Title>

<Structured note content based on conversation context>
```

Keep notes concise and focused. Use the conversation context to write something
genuinely useful — not a transcript, but a distilled summary of what was learned
or decided.

After saving, confirm with the file path.

### If the user wants to list topics (`/notes list` or `/notes` with no args)

Display the topic listing from Step 0 output clearly.

### If the user wants to list notes (`/notes <topic> list`)

Display the note listing from Step 0 output clearly.

### If the user wants to view a note (`/notes <topic> view [N]`)

If a number was given, display the note content from Step 0 output.
If no number, show the listing and ask which note to view.

### If the user wants to search (`/notes <topic> search <query>`)

Display the search results from Step 0 output.
