# Notes for coding agents

- **Testing:** read [docs/guides/agent-testing.md](docs/guides/agent-testing.md)
  before asking the user to test something by hand.
  - `tools/verify.py unit|depth|ui|quest` checks most changes; run it with
    `/usr/bin/python3`.
  - `tools/nf.py` drives a running dev build: UI tree, clicks, state,
    screenshots, log.
  - `tools/quest.py` runs the headset from the desk. Ask before installing or
    launching on it.
- **Docs:** documentation lives in [docs/](docs/README.md). Proposed or
  ongoing work goes in `docs/plans/active/`.
