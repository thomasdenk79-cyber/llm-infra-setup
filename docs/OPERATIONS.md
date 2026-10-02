# Operations

```bash
make status
systemctl --user status pennyroyal.service
podman ps --all
make healthcheck
journalctl --user -u pennyroyal.service -n 100 --no-pager
```

Use `make backup` before changing configuration. Keep tokens in an external environment file or secret store. A runtime upgrade requires updating `versions.lock`, reviewing release notes, pulling the image, and recording the healthcheck result.
