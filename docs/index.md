---
layout: default
title: codex-ticketing service operations
---

# codex-ticketing service operations

This repository provides a small POSIX `sh` process-management shim for the
macOS ticketing daemon:

```sh
cd /Users/Shared/prompt-cult/codex-ticketing
PORT=8099 ./skills/codex-ticketing/serve.sh start --repo-local
```

## Files and paths

With `--repo-local`, the service uses:

| Item | Path |
| --- | --- |
| SQLite database | `.ticketing/tickets.db` |
| PID file | `.ticketing/server.pid` |
| Server log | `.ticketing/server.log` |
| MCP endpoint | `http://127.0.0.1:8099/mcp` |

If `TICKETS_DB` is set to an absolute path, the database, PID file, and log
are kept together beside that database. This makes it safe to run the shim
from the repository containing the database or from another checkout.

## Lifecycle

```sh
PORT=8099 ./skills/codex-ticketing/serve.sh status --repo-local
PORT=8099 ./skills/codex-ticketing/serve.sh start --repo-local
PORT=8099 ./skills/codex-ticketing/serve.sh restart --repo-local
PORT=8099 ./skills/codex-ticketing/serve.sh stop --repo-local
```

`start` checks the PID before launching, removes only a stale PID file, uses
`setsid` when available, detaches standard input, and waits for the HTTP root
endpoint to answer. `restart` stops the PID recorded by the selected database
path before starting the replacement. `status` is read-only and returns a
non-zero exit status when the service is down.

The shim is intentionally not a system-wide launchd installer. If the daemon
must start at login, call the same `start --repo-local` command from a
user-owned launchd plist and keep the repository and database paths absolute.

## Recovery

If the PID file is stale:

```sh
PORT=8099 ./skills/codex-ticketing/serve.sh status --repo-local
PORT=8099 ./skills/codex-ticketing/serve.sh start --repo-local
tail -n 100 .ticketing/server.log
```

Before starting, check that the configured port is not owned by another
process. The shim does not kill an unrelated process merely because it uses
the same port.
