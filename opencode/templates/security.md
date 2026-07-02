---
description: Security audit — scan code, deps, and config for vulnerabilities
agent: security-auditor
subtask: true
---

Use the security-audit skill:
1. OWASP Top 10 scan — injection, XSS, auth, access control
2. Dependency audit — npm audit, CVE check
3. Secret detection — exposed keys, tokens, passwords
4. Configuration review — headers, CORS, open ports

Report: CRITICAL > HIGH > MEDIUM findings with file:line and remediation steps.
