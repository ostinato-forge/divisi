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

1. Run agents inside a context. The guard blocks configured command names
   when its directory comes first on `PATH`. A direct path to a host binary
   bypasses the guard. The explicit guard override is `DIVISI_OVERRIDE=1`.
2. Use one identity per context. Divisi sets one git identity, but it does
   not prevent you from adding another `gh` account inside a context.
3. New checkouts go under the matching context's mounted tree. Risky or
   throwaway work goes in a no-mount, no-credential context.
4. Keep secrets out of repo trees. `CTX_SECRETS` copies files into
   `~/.secrets` inside the context. Remove source copies if you no longer
   need them.

## Enforcement: how "must" is implemented

- Each guarded CLI on the host is a shim that prints where to go, logs the
  attempt to `$DIVISI_STATE/host-block.log`, and exits non-zero. The log
  contains the tool name and time. It does not contain command arguments.
- Deliberate host run: `DIVISI_OVERRIDE=1 claude ...`. The guard logs the
  override without command arguments.
- Guard shims live in `~/.local/bin` by default. Divisi keeps a link or
  saved host command under `$DIVISI_STATE/host-tools/`.
- `divisi check` fails loudly if an `npm -g` update reinstalls a real binary
  ahead of a shim on `PATH`. Fix the path order, then run `divisi enforce`.
- To guard another agent CLI, add it to `DIVISI_GUARD_TOOLS`. Add it to the
  `Containerfile` if you want it in the image, then run `divisi apply`.
- Known gap: host GUI apps and IDE extensions (VS Code/Cursor assistants)
  bypass CLI shims. See the roadmap.


## Moving from an earlier Divisi checkout

Earlier versions created containers without a Divisi label. The current
`divisi apply` will not delete an unlabeled container with the same name. Check
its image and mounts with `podman inspect <name>`. If it is an earlier Divisi
container, rename it with `podman rename <name> <name>-old`, then run
`divisi apply` and `divisi check`. Keep the old container until you confirm
that the new one uses the intended home and credentials.

Earlier `divisi init` versions stored an Anthropic API key in `CTX_SEED` in
the config file. Move that value into
`$DIVISI_STATE/<name>/.secrets/anthropic_api_key`, set the file mode to 600,
and remove the `apikey:` entry from the config. The new loader refuses an
`apikey:` entry so the key is not copied back into the vault on each apply.

## Maintenance

Routine, roughly monthly:

- `divisi check` to confirm the walls hold.
- Update agent CLIs: `DIVISI_PULL=1 divisi apply` rebuilds the image and
  recreates containers. Context homes stay outside the containers. Run
  `divisi check` after apply.
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
