# Security Policy

## Supported Versions

This project is currently in active development. Security updates are provided for the latest version on the `main` branch.

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it by:

1. **Do not** open a public GitHub issue
2. Email the maintainer at <dfarrell@redhat.com>
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

You should receive a response within 48 hours. If the vulnerability is accepted, we will:

- Work on a fix
- Credit you in the security advisory (unless you prefer to remain anonymous)
- Release a patched version

## Security Best Practices

This marketplace contains bash scripts that are executed by Claude Code. When using or contributing to this project:

### For Users

- Review skill code before enabling the marketplace
- Understand what each skill does before invoking it
- Be cautious with skills that have `Bash` in `allowed-tools`
- Check that repository paths are expected before running skills

### For Contributors

- Never include hardcoded credentials or API keys
- Validate and sanitize all user inputs (`$ARGUMENTS`)
- Use `set -euo pipefail` in all bash scripts
- Quote all variable expansions to prevent word splitting
- Avoid command injection vulnerabilities
- Test skills in isolated environments before submitting PRs

## Dependencies

This project uses:

- GitHub Actions (managed by Dependabot)
- markdownlint-cli2 (npm package, managed by Dependabot)
- shellcheck (installed via package manager)

Dependabot automatically creates PRs for dependency updates.

## Automated Security Scanning

This repository uses GitHub Advanced Security features:

- **Dependabot**: Automated dependency updates
- **CodeQL**: Static code analysis (limited for bash/markdown repos)
- **Secret Scanning**: Automatically enabled for public repositories

Security scan results are available in the Security tab.
