# Contributing to SITU Agent

Thank you for your interest in contributing. SITU is a single-maintainer open-source project, and contributions are welcome — especially bug reports, test coverage, and documentation improvements.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Filing Issues](#filing-issues)
- [Development Setup](#development-setup)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Security Vulnerabilities](#security-vulnerabilities)

---

## Code of Conduct

This project follows the [Contributor Covenant 2.1](CODE_OF_CONDUCT.md). By participating, you agree to uphold it.

---

## Filing Issues

Before opening an issue:

1. Search existing issues to avoid duplicates.
2. If you found a **security vulnerability**, do **not** open a public issue — see [Security Vulnerabilities](#security-vulnerabilities) below.

Use the issue templates provided:
- **Bug report** — for broken behavior, crashes, or unexpected output.
- **Feature request** — for new capabilities or improvements.

Good bug reports include: the exact command run, your OS + Podman/Docker version, the model being used, and the full terminal output.

---

## Development Setup

**Prerequisites**

- [Podman](https://podman.io/docs/installation) ≥ 4.x or [Docker](https://docs.docker.com/get-started/get-docker/)
- Bash 5+
- A `.gguf` model file (e.g., Gemma 3, Llama 3, Qwen 2.5)

**Build the container image**

```bash
scripts/build.sh
```

This pulls [pi-mono](https://github.com/badlogic/pi-mono) from GitHub at build time and compiles it inside a Node 22 build stage. The runtime image is Debian trixie-slim.

**Run an interactive session**

```bash
scripts/situ.sh
```

Copy `situ.conf` and point `MODEL` at your `.gguf` file before the first run.

**Verify isolation**

```bash
scripts/situ.sh --test
```

This confirms the LM server is reachable and that external HTTP, HTTPS, DNS, and raw TCP are all blocked.

**Key files**

| File | Purpose |
|---|---|
| `situ.conf` | Default config (mode, model path, ports) |
| `scripts/situ.sh` | Entry point — parses config and launches the containers |
| `scripts/build.sh` | Builds the `situ:latest` container image |
| `docker/Dockerfile` | Two-stage build |
| `docker/entrypoint.sh` | Patches model config at container start |

---

## Submitting a Pull Request

1. Fork the repo and create a feature branch from `main`.
2. Keep changes focused — one concern per PR.
3. Test your change: run `scripts/situ.sh --test` and verify the agent session works end-to-end in `RESTRICTED` mode.
4. If you change shell scripts, run them through `shellcheck` and fix any warnings.
5. Open the PR and fill in the pull request template.

PRs that break RESTRICTED mode network isolation will not be merged. Any change that adds an external network dependency to the agent container must be explicitly discussed in an issue first.

---

## Security Vulnerabilities

Please do **not** open a public GitHub issue for security vulnerabilities. Report them privately by email to **andreas.burner@gmail.com** with the subject line `[SITU] Security Report`. A response will follow within 72 hours.
