# Disaster recovery

The repository is the source of truth for host configuration. Keep encrypted copies of `config/` and `versions.lock`; never back up `.env` or token files into Git. Recreate prerequisites with `make preflight`, `make install`, `make zfs`, `make nvidia-driver`, then restore model data from the ZFS snapshot or external backup before deploying the Quadlets.
