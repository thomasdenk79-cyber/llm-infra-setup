# Git backup receipt - 2026-10-06

All 13 worktrees under `~/work` were included (nine distinct Git repositories).
All local branches and tags of the six operator-owned repositories were
pushed without force, deletion or merging historical variants.
Three clean research clones retain their remotely available upstream pins
and are additionally included in the private ZIP as Git bundles.

| Repository / branch | Backup implementation checkpoint |
|---|---|
| `llm-infra-setup` / `turbo-c6-production` | `5e944fa` |
| same repo / `pennyroyal-plugin-variant` | `b017145` |
| same repo / `turbo-upstream-ple-graph` | `19eced7` |
| same repo / `variant-b-mmap-pagecache` | `0386f6d` |
| same repo / `variant-d-staging-double-buffer` | `3f3f110` |
| same repo / `main` | `2735fe1` (unchanged) |
| same repo / `turbo-c6-penny-ssd-experimental` | `dafe115` (unchanged, preserved) |
| `qwen38-flash-next-sm120` / `copilot-sm120` | `13f97cd5a` |
| same repo / `pennyroyal-main-sm120-final` | `529b57c69` (donor branch, preserved) |
| `qwen38-flash-next-blackwell` / `main` | `b582044` |
| `workstation-setup` / `main` | `f664060` |
| `hermes-team-workspace` / `main` | `4027862` |
| `cachyos-kvm-lab` / `main` | `7f90def` |

The infrastructure documentation commit containing this receipt is necessarily
newer than its implementation checkpoint above. Final exact branch/tag SHAs
and remote verification are in `backup-verification.json` inside the local
ZIP. `repositories.json` records the earlier capture anchors and all research
refs; it is not advertised as the final post-documentation HEAD list.

The source fork's own remote is private:
`https://github.com/thomasdenk79-cyber/qwen38-flash-next-sm120`.
Its default branch is `copilot-sm120`. The existing infrastructure and VM-lab
repos remain public; no secret payload was added. Private ZIP contents are
not Git additions, and ignored runtime data remains ignored.

The archive includes `howto.md`, checksums, offline Git bundles, original
private configurations, selected service data and ignored experiment evidence.
Model/PLE bulk data, container image layers, caches and VM media are separate
transfer/rebuild items. Nothing was deleted as "stale", no reference restart
or new benchmark window was performed.
