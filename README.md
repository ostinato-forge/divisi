# divisi

Divisi runs AI coding agents in separate, rootless Podman containers. Each
context has its own home directory, credentials, git config, and optional
workspace mount. Host command guards direct supported agent CLIs into a
context. The containers share the host kernel and network.

## Purpose and limits

Separate contexts reduce accidental use of the wrong account or project files.
Divisi rejects shared or overlapping workspace mounts. It checks that each
configured container starts and can run commands. It also checks that context
git email addresses differ.

A user can still add another account inside a context. Host GUI apps and IDE
extensions bypass the command guards. Containers are not a boundary against a
hostile process or a kernel exploit. Host networking allows a container to
reach services on the host. See `docs/PLAN-egress.md` for a proposed network
change that is not implemented.

## Quick start

```sh
git clone https://github.com/ostinato-forge/divisi.git
cd divisi
mkdir -p ~/.local/bin
ln -s "$PWD/bin/divisi" ~/.local/bin/divisi
export PATH="$HOME/.local/bin:$PATH"

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
key / none). Host agent binaries stay in place. Guard shims in
`~/.local/bin` must come first on `PATH`.

Config and all state live **outside** this repo (`~/.config/divisi/` and
`$DIVISI_STATE`). The repo contains code and an example config. Keep real config and state out of it.

See `docs/GUIDE.md` for startup-after-reboot, maintenance, and the roadmap.

## Supported hosts and requirements

The host target is RHEL 9, RHEL 10, or Fedora 40 or newer. Run divisi as a
regular user. Install Podman and Git with your distribution packages. Install
ripgrep if you want to use `divisi audit`. Rootless Podman needs entries for
your user in `/etc/subuid` and `/etc/subgid`. Check it with `podman info`.
`divisi apply` checks these requirements before it builds an image. The image
uses Fedora 43 by default, regardless of the host release. Building it needs
access to the Fedora registry and npm package registry.

Put `~/.local/bin` before other agent CLI directories on `PATH`, and make that
change in your shell startup file. Divisi creates guard shims there. If another
copy of a guarded CLI comes first, `divisi apply` stops with an error. The
shims do not change system binaries. Context names must be unique. Mounted
trees must exist and cannot overlap another context's tree or the state tree.

Existing installations with containers created before managed labels were
added need a one-time migration. See [the operator guide](docs/GUIDE.md).

The host support checks have offline tests. A real Podman run on each target
release is still needed to confirm the full setup.

## License

Apache-2.0. See `LICENSE`.
