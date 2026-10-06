# Deployed configuration snapshot

Read `../../WSL-MIGRATION.md` before using these files.

This directory is a read-only source-host snapshot, not a deployment bundle.
`inventory.json` records original paths, exported-file hashes, redacted ENV
keys, live mounts/ports/images/networks and service state. `repositories.json`
records repository/branch recovery anchors. Later backup-documentation commits
are identified by the final remote verification receipt in the local ZIP.

The original files were captured without restarting services. Installed
Quadlets may differ from the files used when the current containers started;
both installed source and live mount metadata are deliberately retained.
Existing repository `config/monitoring/`, `config/pennyroyal/`, scripts and
image recipes remain part of the restore inputs.

`env-examples/` contains explicit `__RECREATE_LOCALLY__` placeholders, not
working credentials. Raw originals and sensitive files are only in the
private local ZIP. Never put that ZIP into this public repository.

Do not install every file from `quadlet/`: several are competing GPU
experiments. Do not enable the archived runner supervisor on WSL. Old Nginx
backup files remain historical; only deliberately selected `.conf` files
belong in a new active configuration.
