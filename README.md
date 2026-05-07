<div align="center">

# SITU Agent

### Nothing Leaves the Room.

**An open-source AI agent that runs entirely on your hardware, in an isolated environment, with no network access. Containers ensures complete privacy of your code and data.**

[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg?style=for-the-badge)](LICENSE)
[![Runs Locally](https://img.shields.io/badge/Runs-100%25%20Local-blue?style=for-the-badge)](#)
[![Air-Gapped](https://img.shields.io/badge/Network-None-red?style=for-the-badge)](#)
[![Podman](https://img.shields.io/badge/Powered%20by-Podman-892CA0?style=for-the-badge&logo=podman&logoColor=white)](https://podman.io)

[**Website**](https://situagent.com) &nbsp;·&nbsp; [**Knowledge Base**](https://situagent.com/kb/knowledgebase.html) &nbsp;·&nbsp; [**Install Guide**](https://situagent.com/kb/firststeps.html)

</div>

---

## Why SITU?

Most AI coding tools ship your source code to a cloud endpoint. They *promise* not to train on it. They *promise* not to leak it. They *promise* their employees can't read it.

**SITU doesn't ask you to trust a promise.**

The agent runs inside an isolated container with `--network=none`. There is no socket. No DNS. No route to the outside world. The kernel itself enforces the boundary — not a privacy policy, not a checkbox, not a vendor's word.

If the network doesn't exist, your code can't leave through it.

---

## What You Get

| | |
|---|---|
| **100% Local** | Runs on your own hardware with your own models. Zero cloud dependency. |
| **Kernel-Enforced Isolation** | The agent pod has no network namespace. Isolated by construction. |
| **Open Source** | Every container definition and shell script — MIT licensed, fully auditable. |
| **Model-Agnostic** | Drop in any OpenAI-compatible model: Gemma, Llama, Mistral, Qwen |
| **Two Modes** | `RESTRICTED` for full isolation (default setting), or `NETWORK` to point at an external LM server. |
| **Audit** | Run `--test` to confirm the hardening and isolation: checks the LM server is reachable and that external HTTP, HTTPS, DNS, and raw TCP are all blocked. |

---

## Who It's For

Developers whose code **cannot** be sent to the cloud:

- Finance, defense, legal, biotech, healthcare, government
- IP-sensitive teams under NDA, export control, or regulatory constraints
- Anyone who wants their work to stay on their machine — full stop

---

Get more information at [https://www.situagent.com](https://situagent.com)

</div>
