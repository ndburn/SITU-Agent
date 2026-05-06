# SITU Coding Agent

**Intelligence stays in situ. Your IP stays yours.**


## Installation and Hello-World

**0. Prerequisite: Podman 4 or later**

Check version or install from https://podman.io/docs/installation

```bash
podman --version
```

**1. Clone the project**

```bash
mkdir ~/.situ/ && cd $_
git clone TODO
```

**2. Build the SITU container**

```bash
~/.situ/scripts/build.sh
```

**3. Download a model** (e.g. Gemma4-E4B Q4)

```bash
mkdir -p ~/.situ/models && curl -L --output-dir ~/.situ/models -O "https://huggingface.co/lmstudio-community/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf"
```

**4. Run a test**
```bash
~/.situ/scripts/situ.sh -q "Who was Albert Einstein?"
```


**5. Create an alias** (on Mac `~/.zshrc`, Ubuntu '~/.bashrc', etc.)

```bash
alias situ=~/.situ/scripts/situ.sh
```


## Usage

```
Usage: situ [options]

Options:
  -q, --query '<prompt>'        Run a single query non-interactively and exit.
  -s, --silent                  Suppress status messages (useful when piping output).
  -t, --test                    Run network connectivity tests and exit.
  -c, --config <file>           Use a specific config file (default: situ.conf).
  -l, --llama-config <file>     Inject a llama.cpp JSON config, however situ.conf take precedence
  -h, --help                    Show this help message and exit.
```


## Dependencies

| Tool | Author | URL | License |
|------|--------|-----|---------|
| pi-mono (coding agent) | Mario Zechner | https://github.com/badlogic/pi-mono | MIT |
| llama.cpp | Georgi Gerganov | https://github.com/ggml-org/llama.cpp | MIT |
| Podman | Red Hat / containers community | https://podman.io | Apache 2.0 |
| Node.js | OpenJS Foundation | https://nodejs.org | MIT |
| fd | David Peter | https://github.com/sharkdp/fd | MIT |
| ripgrep | Andrew Gallant | https://github.com/BurntSushi/ripgrep | MIT |


## Tuning

### Memory Limit

To allow the llama container to use more than the default VM memory (e.g. for large models):

```bash
podman machine stop
podman machine set --memory 16384   # MB, so this = 16 GB
podman machine start
```
