# ADR 0004: Quadlet as runtime source

- Status: Accepted
- Context: systemd should own restart, boot ordering and logs.
- Decision: Store container definitions as Quadlet templates generated from repository scripts.
- Consequences: Generated units must be reviewed after each template change.
