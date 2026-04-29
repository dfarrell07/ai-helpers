---
name: jira
description: Query, view, and update Jira issues via acli
version: 1.0.0
argument-hint: "[my-issues | search <JQL> | view <key> | update <key> <action>]"
user-invocable: true
allowed-tools: Bash, Read, Write
---

# Jira

```bash
/jira                              # List my open issues (default)
/jira my-issues                    # Same as above
/jira search <JQL>                 # Search issues with JQL
/jira view <issue-key>             # View full issue details
/jira update <issue-key> <action>  # Update an issue
```

**Arguments:** $ARGUMENTS

**JQL Reference:** Read `reference/jql-reference.md` (relative to this file) if you need
help constructing JQL queries.

---

## Step 0: Collect Data

Parse the subcommand and run the helper script. For update commands, collect the
current issue state first.

```bash
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
umask 077
rm -f /tmp/jira-data.json /tmp/jira-meta.json

ARGS="$ARGUMENTS"

if [[ -z "$ARGS" || "$ARGS" == "my-issues" ]]; then
  bash "$SCRIPT_DIR/scripts/jira.sh" my-issues > /tmp/jira-data.json
  jq -n '{command:"my-issues"}' > /tmp/jira-meta.json
  cat /tmp/jira-data.json

elif [[ "$ARGS" == "search "* ]]; then
  JQL="${ARGS#search }"
  bash "$SCRIPT_DIR/scripts/jira.sh" search "$JQL" > /tmp/jira-data.json
  jq -n --arg jql "$JQL" '{command:"search", jql:$jql}' > /tmp/jira-meta.json
  cat /tmp/jira-data.json

elif [[ "$ARGS" == "view "* ]]; then
  KEY="${ARGS#view }"
  KEY="${KEY%% *}"
  bash "$SCRIPT_DIR/scripts/jira.sh" view "$KEY" > /tmp/jira-data.json
  jq -n --arg key "$KEY" '{command:"view", key:$key}' > /tmp/jira-meta.json
  cat /tmp/jira-data.json

elif [[ "$ARGS" == "update "* ]]; then
  REST="${ARGS#update }"
  KEY="${REST%% *}"
  ACTION="${REST#"$KEY"}"
  ACTION="${ACTION# }"
  bash "$SCRIPT_DIR/scripts/jira.sh" view "$KEY" > /tmp/jira-data.json
  jq -n --arg key "$KEY" --arg action "$ACTION" '{command:"update", key:$key, action:$action}' > /tmp/jira-meta.json
  cat /tmp/jira-data.json

elif [[ "$ARGS" == "search" || "$ARGS" == "view" || "$ARGS" == "update" ]]; then
  echo "ERROR: /jira $ARGS requires arguments."
  echo "Usage:"
  echo "  /jira search <JQL>                 # Search issues"
  echo "  /jira view <issue-key>             # View issue details"
  echo "  /jira update <issue-key> <action>  # Update an issue"

else
  echo "Unknown command: ${ARGS%% *}"
  echo "Usage:"
  echo "  /jira                              # List my open issues"
  echo "  /jira search <JQL>                 # Search issues"
  echo "  /jira view <issue-key>             # View issue details"
  echo "  /jira update <issue-key> <action>  # Update an issue"
fi
```

---

## Step 1: Present Results or Execute Update

Read `/tmp/jira-meta.json` and `/tmp/jira-data.json` to determine what to do.

### For `my-issues` or `search`

Format the JSON results as a clean summary. For each issue show:

- **Key** (linked to `https://redhat.atlassian.net/browse/<key>`)
- **Type** and **Priority**
- **Status**
- **Summary**

Present as a markdown table sorted by most recently updated (the default query order).
Include a count header (e.g., "Found 12 open issues").

### For `view`

Show full issue details in a readable format:

- Key, Type, Status, Priority, Assignee, Reporter
- Summary and Description
- Labels, Components, Fix Versions
- Recent comments (last 3, showing author, date, and body)
- Linked issues
- Link to issue: `https://redhat.atlassian.net/browse/<key>`

If the issue has **Security** or **SecurityTracking** labels, show a prominent
warning at the top of the output (e.g., "This is a security-restricted issue")
before the other fields. If the stderr from Step 0 includes an embargo warning
(unresolved CVE), emphasize that details must not be shared outside the
organization until the CVE is resolved and publicly disclosed.

### For `update`

Parse the `action` field from `/tmp/jira-meta.json`. The first word is the action
type and everything after it is the value. Examples:
`"transition In Progress"` -> type=transition, value="In Progress".
`"comment Fixed in PR #456"` -> type=comment, value="Fixed in PR #456".
Before executing any update, show the user what will change and ask for
confirmation (e.g., "Current status: New. Change to: In Progress?").

The action will be one of:

**`transition <status>`** — Move the issue to a new status.
Show the current status from the JSON data, confirm with the user, then run:

```bash
acli jira workitem transition --key "<KEY>" --status "<status>" --yes
```

**`comment <text>`** — Add a comment to the issue.
Show the comment text to the user and confirm they want to post it.
Also scan the comment text for credential patterns:

- API tokens: `(sk|pk)_` followed by 20+ alphanumeric characters
- GitHub tokens: `gh[pos]_` followed by 36+ characters
- AWS access keys: `AKIA` followed by 16 uppercase alphanumeric characters
- URLs with credentials: `https?://user:pass@...`
- JWT tokens: `eyJ...` three-part base64-encoded strings
- Private keys: `-----BEGIN ... PRIVATE KEY-----`

If any pattern matches, warn the user and ask them to redact (use placeholders
like `<redacted>` or `YOUR_API_KEY`). Do not post the comment until confirmed safe.

```bash
acli jira workitem comment create --key "<KEY>" --body "<text>"
```

**`assign <user>`** — Reassign the issue. Use `@me` for self-assignment.
Show the current assignee from the JSON data, confirm with the user, then run:

```bash
acli jira workitem assign --key "<KEY>" --assignee "<user>" --yes
```

After any update, confirm what was done and show the issue link.

---

## Step 2: Cleanup

```bash
rm -f /tmp/jira-data.json /tmp/jira-meta.json
```
