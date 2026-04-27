# AI Helpers Skills

## /work-summary

Show recent work: git commits and GitHub activity (PRs, issues).

```bash
/work-summary           # Last 7 days with AI analysis (default)
/work-summary 14        # Last 14 days with AI analysis
make work-summary       # Last 7 days without AI analysis
make work-summary DAYS=14  # Last 14 days without AI analysis
```

**With skill (AI analysis):**

- Executive Summary with themed accomplishments
- In Progress section
- Activity Stats
- Detailed Work Log

**With make target (no AI):**

- Activity Stats
- Detailed Work Log only

## /notes

Take and manage persistent markdown notes organized by topic.

```bash
/notes <topic> <what to note>   # Save a note from current discussion
/notes <topic> list             # List notes for a topic
/notes <topic> view [N]         # View notes (optionally by number)
/notes <topic> search <query>   # Search within a topic
/notes list                     # List all topics
```

Notes are stored as plain markdown files in `~/notes-ai/<topic>/`.
