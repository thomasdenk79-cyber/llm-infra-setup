# ADR 0003: LiteLLM gateway

- Status: Accepted
- Context: Clients need one OpenAI-compatible endpoint and policy boundary.
- Decision: Use localhost LiteLLM on port 4000 in front of Pennyroyal on port 8001.
- Consequences: PostgreSQL and a secret-backed master key are required before virtual keys are enabled.
