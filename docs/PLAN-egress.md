# Egress control plan

Lessons from a working implementation on a Fedora workstation with rootless
podman, pasta networking, and dnsmasq. This replaces the one-line roadmap
entry ("per-context network with an allowlisting, logging proxy") with
concrete steps, gotchas, and design decisions.

## Architecture

```
container app → glibc → resolv.conf → 169.254.1.1 (pasta forwarder)
  → dnsmasq on host 127.0.0.53 → threat blocklist check
  → upstream DNS (e.g. 192.168.4.1)

cross-contamination: --add-host per container (/etc/hosts, checked first)
```

Two layers, both DNS-level:

1. **Threat blocklist** (universal): dnsmasq returns 0.0.0.0 / :: for ~83k
   known-bad domains. Community-maintained (Steven Black hosts), refreshed
   weekly via cron.
2. **Cross-contamination rules** (per-context): `--add-host` entries that
   null-route peer-context domains. Example: personal context blocks
   `gitlab.cee.redhat.com`; work context blocks nothing extra.

Allow-by-default. No full traffic logging. Throwaway/experiment contexts stay
unrestricted (no credentials, nothing to leak).

## Step 1: Migrate from --network host to pasta

divisi currently uses `--network host`. Pasta gives each container its own
network namespace while preserving OAuth callbacks via auto-port-forwarding.

```
--network "pasta:-t,auto"          # credentialed contexts
--network pasta                    # throwaway (no port forwarding)
```

**Gotcha:** `pasta:` (trailing colon, no options) is a parse error.
Use `pasta` (bare) when no options are needed.

This is the prerequisite for everything else — without per-container
namespaces, there's nothing to filter.

## Step 2: Replace systemd-resolved stub with dnsmasq

Pasta's DNS forwarder (169.254.1.1 inside containers) reads the host's
`/etc/resolv.conf` to find upstream DNS. On systemd-based distros, resolv.conf
points to 127.0.0.53 (resolved's stub listener). Replace the stub with
dnsmasq:

1. `DNSStubListener=no` in `/etc/systemd/resolved.conf.d/no-stub.conf`
2. dnsmasq listens on 127.0.0.53 and 127.0.0.1, forwards to real upstream
3. `/etc/resolv.conf` becomes a static file: `nameserver 127.0.0.53`

**Gotcha: resolv.conf symlink.** Fedora symlinks `/etc/resolv.conf` →
`/run/systemd/resolve/stub-resolv.conf`. When `DNSStubListener=no`, resolved
rewrites that file to list the upstream directly (e.g. `nameserver 192.168.4.1`),
bypassing dnsmasq. You must break the symlink and write a static file.

**Gotcha: pasta ignores loopback DNS.** Pasta sees `127.0.0.53` in resolv.conf,
recognizes it as loopback, and looks up the "real" upstream from resolved's
runtime files (`/run/systemd/resolve/resolv.conf`). It then forwards directly
to the upstream, skipping dnsmasq entirely.

Fix: use pasta's `--dns-host` flag to explicitly tell it where to forward:

```
--network "pasta:-t,auto,--dns-host,127.0.0.53"
```

Also use `--dns 169.254.1.1` (podman flag) to prevent pasta from injecting
the upstream as a fallback nameserver in the container's resolv.conf.

**Gotcha: --dns-forward rejects loopback.** Pasta's `--dns-forward` flag
(which sets the *container-side* intercept address) rejects 127.x.x.x with
"Invalid DNS forwarding address." Don't confuse it with `--dns-host` (which
sets the *host-side* target and accepts loopback).

## Step 3: Threat blocklist

Download Steven Black's consolidated hosts file, filter to `0.0.0.0` entries,
load via dnsmasq `addn-hosts`.

**Gotcha: IPv6 bypass.** The hosts file only has `0.0.0.0 domain` entries (A
records). AAAA queries pass through unblocked, and modern glibc prefers IPv6.
`getent hosts malware.example` returns the real IPv6 address even when IPv4
is null-routed.

Fix: generate `::` entries alongside `0.0.0.0`:

```bash
curl ... | grep '^0.0.0.0' | grep -v '^0.0.0.0 0.0.0.0' \
  | awk '{print $0; print ":: " $2}' \
  > /var/lib/dnsmasq/threat-blocklist.hosts
```

**Gotcha: blocklist path.** Do NOT put the hosts file in `/etc/dnsmasq.d/` —
dnsmasq's `conf-dir` directive loads every file there as config. The hosts
format (`0.0.0.0 domain`) causes "bad option at line 1". Use a separate path
like `/var/lib/dnsmasq/` and reference it with `addn-hosts=`.

Weekly auto-refresh via `/etc/cron.weekly/update-threat-blocklist`.

## Step 4: Cross-contamination rules

Per-container `/etc/hosts` entries via `--add-host`:

```bash
# personal context: block work-internal domains
--add-host internal.corp.example.com:0.0.0.0 \
--add-host git.corp.example.com:0.0.0.0 \
```

These go into `/etc/hosts` inside the container, which glibc checks *before*
DNS. No IPv6 bypass issue here (getent returns the hosts entry directly).

Work contexts typically need no cross-contamination blocks (personal forges
are public, and there's no credential to authenticate with anyway).

**Limitation:** `--add-host` doesn't support wildcards — only exact FQDNs.
For wildcard blocking, use dnsmasq `address=/corp.example.com/0.0.0.0` in a
per-context config (requires dnsmasq awareness of contexts, not yet built).

## Step 5: NSS resolver ordering (Fedora-specific)

Fedora's `/etc/nsswitch.conf` has:

```
hosts: files myhostname resolve [!UNAVAIL=return] dns
```

`resolve` = nss-resolve, systemd-resolved's NSS module. It queries resolved
via D-Bus, bypassing `/etc/resolv.conf` entirely. On the HOST this means
dnsmasq is bypassed for applications using glibc (everything except `dig`).

Inside containers this is fine — no D-Bus socket means nss-resolve returns
UNAVAIL and glibc falls through to `dns` (resolv.conf → dnsmasq).

For host-side blocking (if desired): either remove `resolve` from nsswitch.conf
or configure resolved to use dnsmasq as its upstream via
`DNS=127.0.0.1` in `resolved.conf` (not 127.0.0.53, to avoid a loop).

## Step 6: Agent log hygiene (companion feature)

Not egress per se, but related to cross-contamination:

- Separate agent session logs by context (each context's `~/.claude/` etc.
  stays in its own home — divisi already handles this)
- 30-day retention trim (cron or `divisi maintenance` command)
- Scrub work logs of personal/OSS project references (grep + delete flagged
  sessions)
- Context-awareness guardrails in agent config (CLAUDE.md etc.) that prompt
  agents to confirm they're in the right context

## What this does NOT cover

- **Direct-IP connections.** DNS blocking doesn't catch `curl 1.2.3.4`. This
  covers ~99% of agent traffic (agents resolve domains, they don't hardcode
  IPs).
- **Hostile agent escape.** This is accident prevention, not a security
  boundary. A determined agent could bypass DNS (use DoH, hardcode IPs). For
  that, use iptables/nftables egress rules or microVM isolation.
- **DHCP IP changes.** The host IP is dynamic. If the upstream DNS changes,
  dnsmasq config needs updating (or use `server` with an interface directive).
- **Full traffic logging / allowlisting.** This is allow-by-default with a
  denylist. An allowlist proxy (Squid, mitmproxy) is a heavier lift, deferred.

## Config surface for divisi

To integrate this into `divisi apply`:

```ini
# divisi.conf additions
DIVISI_NETWORK=pasta                    # default: host (current)
DIVISI_EGRESS=denylist                  # off | denylist | allowlist (future)
DIVISI_THREAT_BLOCKLIST=stevenblack     # off | stevenblack | custom URL
DIVISI_BLOCKLIST_PATH=/var/lib/dnsmasq/threat-blocklist.hosts
```

Per-context config:

```ini
[work]
egress_block_domains=                   # none (work can reach everything)

[personal]
egress_block_domains=gitlab.cee.redhat.com,source.redhat.com,...
```

`divisi apply` would:
1. Set up dnsmasq (if DIVISI_EGRESS != off) via a generated setup script
2. Create containers with `--dns-host`, `--dns`, and `--add-host` flags
3. `divisi check` would verify dnsmasq is running and blocklist is loaded

## Appendix: additional findings from implementation

### SELinux label on blocklist file

If the blocklist is written via a temp file and moved (`mv /tmp/... target`),
SELinux preserves the `user_tmp_t` label. dnsmasq runs in its own domain and
gets Permission Denied on `user_tmp_t` files. Any script that writes the
blocklist must call `restorecon` afterward:

```bash
curl ... > /var/lib/dnsmasq/threat-blocklist.hosts
restorecon /var/lib/dnsmasq/threat-blocklist.hosts
```

This is the same class of issue that `divisi relabel` solves for context
homes: labels follow the source, not the destination.

### dnsmasq systemd unit has no reload handler

`systemctl reload dnsmasq` fails ("Job type reload is not applicable").
SIGHUP clears the cache but does NOT re-read `addn-hosts` files. A full
`systemctl restart` is required after blocklist updates. If the restart
races (socket not released), use stop-wait-start:

```bash
systemctl stop dnsmasq && sleep 1 && systemctl start dnsmasq
```

### resolv.conf static file is required

When `DNSStubListener=no`, resolved rewrites BOTH
`/run/systemd/resolve/resolv.conf` AND `/run/systemd/resolve/stub-resolv.conf`
to list the upstream DNS directly. Even if `/etc/resolv.conf` is symlinked to
`stub-resolv.conf`, it will contain `nameserver 192.168.4.1` (not 127.0.0.53).

The fix: break the symlink and write a static file:

```bash
rm -f /etc/resolv.conf
printf 'nameserver 127.0.0.53\n' > /etc/resolv.conf
```

`divisi apply` should own this file when egress is enabled.

### Container image: custom repo support

Work-specific tools (rhtlc, scaffolding) require custom dnf repos with
credentials. divisi should support copying repo files and GPG keys into the
image at build time:

```ini
# divisi.conf
DIVISI_EXTRA_REPOS=/path/to/yum.repos.d/
DIVISI_EXTRA_GPG_KEYS=/path/to/rpm-gpg/
```

Credentials in repo files are baked into image layers. Acceptable for
local-only images; for shared images, use `--secret` build mounts instead.

### Terminal theming per context

Implemented via:
1. **PS1 prompt colors**: `\[\e[1;31m\][context-name]` (red/green/yellow)
2. **Terminal title**: `\[\e]0;context-name: \w\a\]` in PS1 — sets tab/window title
3. **Claude Code theme**: `light-daltonized` (work), `dark` (personal), `dark-ansi` (experiment)

`divisi apply` should generate `.bashrc` with the prompt + title, and set
the Claude Code theme in each context's `~/.claude/settings.json`.
