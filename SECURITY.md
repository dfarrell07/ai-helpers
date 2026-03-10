# Security Policy

## Supported Versions

Security updates are provided for the `main` branch.

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it by:

1. **Do not** open a public GitHub issue
2. Email the maintainer at <dfarrell@redhat.com>
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

You should receive a response within 48 hours.

## Security Best Practices

### For Users

- Review skill code before enabling the marketplace
- Understand what each skill does before invoking it

### For Contributors

- Use `set -euo pipefail` in all bash scripts
- Validate and sanitize all user inputs (`$ARGUMENTS`)
- Quote all variable expansions
- Test skills in isolated environments

## Automated Security

- **Dependabot**: Automated dependency updates (GitHub Actions, markdownlint-cli2)
- **Secret Scanning**: Enabled for public repositories
