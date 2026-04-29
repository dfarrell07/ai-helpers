---
name: JQL Reference
description: Common JQL patterns and custom field IDs for redhat.atlassian.net
---

# JQL Reference

## Common Queries

```jql
# My open issues
assignee = currentUser() AND status NOT IN (Closed, Done, Resolved)
  ORDER BY updated DESC

# My issues by project
project = ACM AND assignee = currentUser()
  AND status NOT IN (Closed, Done, Resolved)
  ORDER BY updated DESC

# Issues updated recently
project = ACM AND updated >= -7d ORDER BY updated DESC

# Issues created recently
project = ACM AND created >= -7d ORDER BY created DESC

# Text search within a project
project = ACM AND text ~ "submariner" ORDER BY updated DESC

# Issues by status
project = ACM AND status = "In Progress" ORDER BY updated DESC
project = ACM AND status = "New" ORDER BY priority DESC

# Issues by priority
project = ACM AND priority IN (Blocker, Critical)
  AND status NOT IN (Closed, Done, Resolved)

# Issues by type
project = ACM AND type = Bug AND status NOT IN (Closed, Done, Resolved)
project = ACM AND type = Story AND status = "New"

# Issues by label
project = ACM AND labels = "Security" ORDER BY updated DESC

# Issues by component
project = ACM AND component = "Submariner" ORDER BY updated DESC

# CVE issues (Submariner-related)
project = ACM AND labels IN (Security)
  AND (text ~ submariner OR text ~ lighthouse OR text ~ subctl)
  ORDER BY updated DESC

# Unassigned issues
project = ACM AND assignee IS EMPTY
  AND status NOT IN (Closed, Done, Resolved)
  ORDER BY priority DESC

# Issues by fix version
project = ACM AND fixVersion = "ACM 2.13.0" ORDER BY priority DESC
```

## Status Values

Common statuses on redhat.atlassian.net (varies by project workflow):

- New
- Backlog
- Refinement
- In Progress
- Code Review
- Testing / ON_QA
- Review
- Verified
- Release Pending
- Closed / Done / Resolved

## Custom Fields (redhat.atlassian.net)

| Field | ID | Format | Usage |
| ----- | --- | ------ | ----- |
| Epic Name | `customfield_10011` | String | Required when creating Epics |
| Epic Link | `customfield_10014` | String (issue key) | Link Story/Task to Epic |
| Parent Link | `customfield_10018` | String (issue key) | Link Epic to Feature |
| Story Points | `customfield_10028` | Number | Estimate |
| Target Version | `customfield_10855` | Array of objects | `[{"id": "VERSION_ID"}]` |
| Blocked | `customfield_10517` | Dropdown | Mark issue blocked |

## JQL Tips

- Use `currentUser()` instead of your email for portable queries
- Quote status values with spaces: `status = "In Progress"`
- `text ~` searches summary, description, and comments
- `ORDER BY updated DESC` shows most recently active first
- `>=` and `<=` work with relative dates: `-7d`, `-30d`, `-1w`
- Combine with `AND`/`OR` and parentheses for complex filters
