# divisi

*divisi* (musical: "divide into separate parts") splits one machine into
isolated, per-identity contexts for running AI coding agents. One laptop, but
work and personal never touch: separate credentials, separate git identities,
separate file trees, separate agent session logs. The host becomes a neutral
zone where agents are blocked from running at all.

It is rootless `podman` plus bash. No daemon, no SaaS, nothing leaves your
machine. Built for people who run several coding agents (Claude Code, Codex,
Gemini, ...) across employer and personal work on the same box.

## Why

Run agents heavily on one machine and the messes pile up: the wrong git
identity on a commit, an agent reading employer code while you meant to be on a
side project, API keys in plaintext dotfiles, every secret you ever echoed
sitting in one shell history, `gh` silently switched to the wrong account.
None of these are exotic attacks. They are accidents, and the fix for
accidents is structure: make the wrong thing impossible, not just discouraged.

divisi gives each context its own container HOME, so:

- **Credentials can't bleed.** The work container holds only the work token.
  There is no personal credential there to leak, and vice versa.
- **Data can't bleed.** Each context mounts only its own tree. An agent in
  `personal` literally cannot open employer code; it isn't in the filesystem.
- **Identity can't slip.** One git/gh identity per context, enforced by
  absence of the others.
- **The host stays clean.** Agent CLIs are shimmed to refuse to run on the
  host, with a deliberate, logged override for the rare exception.

## What it is not

Containers share the host kernel. divisi stops *accidents* with very high
confidence; it is not a sandbox against a hostile agent exploiting a kernel
bug. For that you want microVMs (see `docs/GUIDE.md` roadmap). Think of divisi
as seatbelts and lane markers, not a bank vault.

## Quick start

```sh
git clone <this-repo> && cd divisi
ln -s "$PWD/bin/divisi" ~/.local/bin/divisi     # or put bin/ on PATH

divisi init       # answer prompts; writes ~/.config/divisi/divisi.conf
divisi apply      # build image, create contexts, install host guard shims
divisi check      # verify the walls
divisi audit      # scan the host for leaked agent secrets / exposure
```

Then, one-time per context, do the logins divisi can't do for you:

```sh
divisi enter work
  gh auth login              # the ONE account for this context
  claude   # /login if prompted
  exit
```

Daily use:

```sh
divisi enter personal       # or just: divisi personal
```

## Commands

| command | does |
|---|---|
| `divisi init` | interactive config; nothing hardcoded |
| `divisi apply` | build image, (re)create every context, install shims + launchers |
| `divisi enter <name>` | shell into a context (alias: `divisi <name>`) |
| `divisi run <name> <cmd>` | run one command in a context |
| `divisi check` | verify isolation, distinct identities, host shims |
| `divisi audit` | read-only host security scan |
| `divisi enforce` | (re)install host guard shims (run after `npm -g` changes) |
| `divisi relabel` | fix SELinux labels after moving files into a context home |
| `divisi status` | list contexts and running state |

## How it works

`divisi apply` builds one image (`Containerfile`) and creates one rootless
container per context. Each container runs as your uid (`--userns=keep-id`)
with its own bind-mounted HOME under `$DIVISI_STATE`, optionally mounting one
host directory, and joins host networking so agent OAuth callbacks work. The
context's `.bashrc` carries a colored prompt, the right git identity, a secret
vault at `~/.secrets`, and the correct claude auth (Vertex / Claude.ai / API
key / none). Real agent binaries on the host are quarantined and replaced with
guard shims.

Config and all state live **outside** this repo (`~/.config/divisi/` and
`$DIVISI_STATE`). The repo is generic and safe to share or open-source.

See `docs/GUIDE.md` for startup-after-reboot, maintenance, and the roadmap.

## Requirements

- Linux with rootless `podman` (developed on Fedora; SELinux handled).
- `ripgrep` on the host for `divisi audit`.
- Subuid/subgid range for your user (Fedora sets this up by default).

## License

Apache-2.0. See `LICENSE`.
