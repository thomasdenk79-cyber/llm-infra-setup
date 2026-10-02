# ADR 0001: Rootless Podman

- Status: Accepted
- Context: Services need container isolation without making daily runtime control rootful.
- Decision: Run application services as rootless Podman Quadlets and use CDI for NVIDIA access.
- Consequences: User linger and socket setup are required; host-only prerequisites remain scripted separately.
