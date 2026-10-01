# llm-infra-setup
llm-infra-setup setup podman, sqclang e.g and downloading qwen 3.8 flash next
# llm-infra-setup

Git-based local LLM infrastructure for CachyOS/Arch Linux. The repository is being built in phases; the first phase records a read-only host preflight.

## Quick start

```bash
make preflight
make validate
```

The generated report is stored under `state/` and is intentionally ignored by Git.
