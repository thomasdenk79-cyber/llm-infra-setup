# Architecture

Clients call LiteLLM on `:4000`; LiteLLM forwards to Pennyroyal/SGLang on `:8001`. The runtime receives the RTX PRO 6000 through NVIDIA CDI. Model files live on the existing ZFS dataset at `/srv/llm/models`. User Quadlets keep services rootless; system services are only used for host prerequisites.

Observability is composed of Prometheus, Grafana, Loki/Alloy, node/GPU/ZFS exporters and Dozzle. The service definitions are examples and must be enabled only after reviewing local storage and credentials.


## Model storage

`/srv/llm/models` is the canonical path because it is the mountpoint of the dedicated ZFS dataset (`zstd-9`, 1 MiB recordsize, atime off). Rootless Podman bind-mounts this path read-only as `/models`. The setup creates `~/llm/models` as a convenience symlink; it does not duplicate data or change the canonical path.
