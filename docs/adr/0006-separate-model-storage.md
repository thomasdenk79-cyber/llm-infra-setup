# ADR 0006: Separate model storage

- Status: Accepted
- Context: Models are large and benefit from ZFS compression and snapshots.
- Decision: Store models in `/srv/llm/models` on a dedicated dataset; keep runtime state under the user data directory.
- Consequences: The model path is independent of the home filesystem and has a convenience symlink at `~/llm/models`.
