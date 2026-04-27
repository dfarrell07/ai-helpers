#!/bin/bash
set -euo pipefail

NOTES_DIR="$HOME/notes-ai"
COMMAND="${1:-}"
TOPIC="${2:-}"
ARG="${3:-}"

validate_topic() {
  local topic="$1"
  if [[ "$topic" =~ [/\\] || "$topic" == .* ]]; then
    echo "Invalid topic name: '$topic' (must not contain slashes or start with a dot)"
    exit 1
  fi
}

load_note_files() {
  local dir="$1"
  files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -name '*.md' -type f | sort)
}

case "$COMMAND" in
  list-topics)
    if [[ ! -d "$NOTES_DIR" ]]; then
      echo "No notes directory yet (~/notes-ai/). It will be created when you save your first note."
      exit 0
    fi

    topics=()
    while IFS= read -r dir; do
      topics+=("$dir")
    done < <(find "$NOTES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [[ ${#topics[@]} -eq 0 ]]; then
      echo "No topics yet. Use '/notes <topic> <what to note>' to create your first note."
      exit 0
    fi

    echo "Topics in ~/notes-ai/:"
    echo ""
    for dir in "${topics[@]}"; do
      topic_name="$(basename "$dir")"
      count="$(find "$dir" -maxdepth 1 -name '*.md' -type f | wc -l)"
      echo "  - $topic_name ($count notes)"
    done
    ;;

  list-notes)
    if [[ -z "$TOPIC" ]]; then
      echo "Usage: notes.sh list-notes <topic>"
      exit 1
    fi
    validate_topic "$TOPIC"

    topic_dir="$NOTES_DIR/$TOPIC"
    if [[ ! -d "$topic_dir" ]]; then
      echo "No notes for topic '$TOPIC' yet."
      exit 0
    fi

    load_note_files "$topic_dir"

    if [[ ${#files[@]} -eq 0 ]]; then
      echo "No notes for topic '$TOPIC' yet."
      exit 0
    fi

    echo "Notes for '$TOPIC' (${#files[@]} notes):"
    echo ""
    i=1
    for f in "${files[@]}"; do
      filename="$(basename "$f" .md)"
      title=""
      while IFS= read -r line; do
        if [[ "$line" == "# "* ]]; then
          title="${line#\# }"
          break
        fi
      done < "$f"
      if [[ -z "$title" ]]; then
        title="(untitled)"
      fi
      echo "  $i. $filename — $title"
      i=$((i + 1))
    done
    ;;

  view-note)
    if [[ -z "$TOPIC" || -z "$ARG" ]]; then
      echo "Usage: notes.sh view-note <topic> <number>"
      exit 1
    fi
    validate_topic "$TOPIC"
    if [[ ! "$ARG" =~ ^[0-9]+$ ]]; then
      echo "Note number must be a positive integer, got: '$ARG'"
      exit 1
    fi

    topic_dir="$NOTES_DIR/$TOPIC"
    if [[ ! -d "$topic_dir" ]]; then
      echo "No notes for topic '$TOPIC'."
      exit 1
    fi

    load_note_files "$topic_dir"

    idx=$((ARG - 1))
    if [[ $idx -lt 0 || $idx -ge ${#files[@]} ]]; then
      echo "Note number $ARG out of range (1-${#files[@]})."
      exit 1
    fi

    echo "--- ${files[$idx]} ---"
    cat "${files[$idx]}"
    ;;

  search)
    if [[ -z "$TOPIC" || -z "$ARG" ]]; then
      echo "Usage: notes.sh search <topic> <query>"
      exit 1
    fi
    validate_topic "$TOPIC"

    topic_dir="$NOTES_DIR/$TOPIC"
    if [[ ! -d "$topic_dir" ]]; then
      echo "No notes for topic '$TOPIC'."
      exit 1
    fi

    echo "Searching '$TOPIC' for: $ARG"
    echo ""
    grep -rin --include='*.md' "$ARG" "$topic_dir" || echo "No matches found."
    ;;

  *)
    echo "Usage: notes.sh <list-topics|list-notes|view-note|search> [args...]"
    exit 1
    ;;
esac
