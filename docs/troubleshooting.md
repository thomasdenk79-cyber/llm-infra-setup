# Troubleshooting

- **No GPU in Podman:** run `nvidia-ctk cdi list`, regenerate `/etc/cdi/nvidia.yaml`, then rerun `make podman`.
- **Unit exits:** inspect `journalctl --user -u pennyroyal.service` and verify the model directory and image tag.
- **Healthcheck fails:** confirm port `8001` is listening and query `podman logs pennyroyal`.
- **Model download fails:** authenticate with Hugging Face outside Git and verify free space on the ZFS dataset.
- **ZFS issue:** stop; do not create, destroy, or alter pools automatically. Inspect `zpool status` and `zfs list` first.
