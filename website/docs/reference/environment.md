---
title: Environment variables
description: Variables that change how turnstile behaves in a shell.
slug: /environment
---

# Environment variables

| Variable | Effect |
| --- | --- |
| `TURNSTILE_DISABLE=1` | Commands in this shell pass straight through |
| `TURNSTILE_AGENT=1` / `0` | Force whether this shell counts as an agent. Otherwise, [known agent variables](../start/agents.md#how-a-shell-is-identified) or no terminal at all mean an agent |
| `TURNSTILE_HOME` | Where shims, the socket, and history live. Default `~/.turnstile` |
| `TURNSTILE_CONFIG_DIR` | Directory holding `config.json`. Default `$XDG_CONFIG_HOME/turnstile`, or `~/.config/turnstile` when `XDG_CONFIG_HOME` isn't set |
