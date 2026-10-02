# ADR 0002: Pennyroyal runtime

- Status: Accepted
- Context: RTX PRO 6000 SM120 needs the tested Flash-Next runtime path.
- Decision: Pin the Pennyroyal OCI image and keep the model read-only inside the container.
- Alternatives: Generic SGLang is not the baseline because the reference path targets this GPU.
