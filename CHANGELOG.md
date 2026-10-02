# Changelog

## Unreleased

- Added model download, pinned Pennyroyal image/Quadlet generation, rootless deployment, healthcheck, and configuration backup scripts.
- Completed the resumable Qwen model download and added indexed safetensor verification with Hub revision locking.
- Pinned the Pennyroyal image digest and restricted its generated API binding to localhost.
- Adapted the Pennyroyal Quadlet to the installed Podman CDI device key.
- Made Quadlet deployment start generated services correctly and documented the missing eGPU diagnostic.
- Added a GPU-independent observability deployment path with an external Grafana secret.
- Fixed rootless ownership for persistent observability volumes.
- Added GPU-independent PostgreSQL preparation and startup.
- Added a provisioned Grafana LLM overview dashboard.
- Improved `llmctl` service visibility and aligned benchmarks with the served model alias.
- Added a one-command full-stack deployment path with internal inference networking and external local secrets.
- Ignored local config environment files while keeping tracked examples.
- Added current status and installation documentation with explicit done/todo tracking.

- Added the initial repository quality checks and reproducible host preflight.
- Recorded the initial CachyOS, kernel, ZFS, storage, and missing runtime prerequisites in `state/preflight-report.txt`.
- Added reproducible NVIDIA open DKMS driver setup, kernel module configuration, and CDI preparation for the RTX PRO 6000.
- Added MkDocs documentation, bilingual entry points, ADRs, repository secret checks, localhost-only service bindings, and a PostgreSQL Quadlet for LiteLLM virtual keys.
