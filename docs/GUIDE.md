# divisi: operator guide

## Startup after a reboot

Nothing to start. Open a terminal and `divisi enter <name>` (or the
`<name>` launcher). The container starts on demand; all state lives in its
bind-mounted home, so logins, repos, and session logs survive reboots.

Sanity pass after a reboot or OS update:

```sh
divisi check
```

## Daily rules of the road

1. Agents run inside a context. The host versions are blocked, so this is
   enforced, not remembered. The escape hatch is explicit: `DIVISI_OVERRIDE=1`.
2. One identity per context, enforced by absence. If you want to log a second
   account into a context, that is the wall trying to fall; use the other
   context.
3. New checkouts go under the matching context's mounted tree. Risky or
   throwaway work goes in a no-mount, no-credential context.
4. Secrets never live in repo trees. Vault them (`CTX_SECRETS`); they appear
   as `~/.secrets` inside the context.

## Enforcement: how "must" is implemented

- Each guarded CLI on the host is a shim that prints where to go, logs the
  attempt to `$DIVISI_STATE/host-block.log`, and exits non-zero.
- Deliberate host run: `DIVISI_OVERRIDE=1 claude ...`. An env var is never
  typed by accident, and overrides are logged: an audit trail, not a hole.
- Real launchers are quarantined under `$DIVISI_STATE/host-tools/`.
- `divisi check` fails loudly if an `npm -g` update reinstalls a real binary
  over a shim. Fix with `divisi enforce` (idempotent).
- New agent CLI? Add it to `DIVISI_GUARD_TOOLS`, add it to the `Containerfile`
  if you want it in the image, then `divisi apply` (or just `divisi enforce`).
- Known gap: host GUI apps and IDE extensions (VS Code/Cursor assistants)
  bypass CLI shims. See the roadmap.

## Maintenance

Routine, roughly monthly:

- `divisi check` to confirm the walls hold.
- Update agent CLIs: `DIVISI_PULL=1 divisi apply` rebuilds the image (and
  refreshes the base) and recreates containers. Safe; containers hold no state.
- `podman image prune -f` to drop old layers.
- After any host `npm -g` change: `divisi enforce`.
- After moving/`cp -a`ing files into a context home: `divisi relabel`
  (SELinux preserves the source label; the container would otherwise get
  Permission denied).

Credentials:

- Per-context logins persist in the container home. When a token expires,
  re-login inside that context with that context's one identity.
- Prefer fine-grained, org-scoped tokens.

Backups:

- Back up `$DIVISI_STATE` (context homes, including vaults) and your mounted
  trees. The image and containers are disposable.
- Vaults hold live tokens: encrypt any backup that includes them.

## Moving to a new machine

1. Install rootless podman + ripgrep.
2. Copy this repo and your `~/.config/divisi/divisi.conf`.
3. Copy `$DIVISI_STATE` if you want existing logins/state, or start fresh.
4. `divisi apply`, then `divisi check`.

That is the whole point of keeping config and code separate: the machine is
reproducible from a config file plus a clone.

## Roadmap

- **MicroVM contexts.** Containers share the host kernel. For untrusted or
  experimental contexts, a real kernel boundary (libkrun microVMs, e.g. via
  Kaiden / openkaiden.ai) is the upgrade. divisi's model maps onto it directly.
- **Close the GUI gap.** Bring IDE assistants (Cursor, VS Code extensions)
  inside the walls instead of leaving them on the host.
- **Per-context egress control.** Today contexts share host networking for
  OAuth convenience. The tightening path is a per-context network with an
  allowlisting, logging proxy.
- **Spend/usage ledger.** Each context's agent logs are a clean, partitioned
  dataset. A read-only reader could attribute cost per context and per task.
