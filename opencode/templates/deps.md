---
description: Dependency audit — check for vulnerabilities, outdated packages, license issues
agent: build
subtask: true
---

Use the dependency-audit skill:
1. Security audit — npm audit / pip-audit / cargo audit
2. Outdated packages — npm outdated / pip list --outdated
3. Unused dependencies — depcheck
4. License compliance — license-checker

Report: vulnerable packages (CVE IDs), outdated deps with upgrade path, unused deps to remove.
