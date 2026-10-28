---
title: Exit codes
description: The exit codes turnstile adds on top of the tool's own.
slug: /exit-codes
---

# Exit codes

Exit codes are the tool's own. turnstile adds three:

| Code | Meaning |
| --- | --- |
| `125` | Someone ran `turnstile kill` on the job. It prints `cancelled by you, don't retry`, so agents don't mistake it for a flaky failure |
| `126` | The tool couldn't start |
| `127` | The tool isn't installed |

An explicit cancellation still returns `125` if the tool exits before the
cancellation message arrives while turnstile is draining its output.

If a run you joined is cancelled, your command runs on its own instead.
