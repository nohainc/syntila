# Worker Profile files

The Worker Profile files are not in this folder. Profile Lab is an internal tool
and loads the Profile you validate, test and publish from the repository, one
file per Worker:

- `apps/profile_lab/assets/profiles/chatgpt.json` — Codex CLI
- `apps/profile_lab/assets/profiles/gemini.json` — Antigravity `agy` CLI
- `apps/profile_lab/assets/profiles/claude.json` — Claude Code CLI
- `apps/profile_lab/assets/profiles/copilot.json` — GitHub Copilot CLI
- `apps/profile_lab/assets/profiles/grok.json` — xAI Grok Build CLI (`grok`)

Profile Lab finds the repository from the nearest `.git` above its working
directory or app binary, so run it from a checkout. No rebuild is needed after
editing a file. Use the reload button in the Draft & Test toolbar (or
**More → Reload Profile from file…**) to re-read the current file. Loading
replaces the local candidate only and never publishes or overwrites the current
Cloud Profile.

Grok release 1 remains an authoring candidate. Installed-CLI evidence, validation
results and open qualification gates are recorded in
the Grok acceptance note.
