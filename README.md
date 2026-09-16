# Divisi

Divisi runs AI coding agents in separate rootless Podman containers. Each
context has its own home directory, credentials, git settings, and optional
workspace mount. Host command guards help prevent accidental agent runs outside
a context.

Divisi reduces accidental account and file access across contexts. It does not
isolate a hostile process from the host kernel. Containers use host networking.

## Host requirements

Divisi targets RHEL 9, RHEL 10, and Fedora 40 or newer. Use a regular user
account with rootless Podman. Install Podman and Git from your host's package
repositories:

```sh
sudo dnf install podman git
podman info
```

Rootless Podman needs an entry for your user in both `/etc/subuid` and
`/etc/subgid`. `divisi apply` checks the host release, these entries, and
`podman info` before building the image. If a check fails, fix the reported
prerequisite and run `divisi apply` again.

The container image uses Fedora 43 by default on every host. The first build
needs access to the Fedora image registry and npm. Install `ripgrep` on the host
if you want to use `divisi audit`.

The host checks have offline tests for the listed releases. A full Podman run
on each release remains unverified.

## Install and configure

Cloning the repository currently requires access to the private GitHub project.
Put `~/.local/bin` first on `PATH` so Divisi's guards take priority over host
agent CLIs:

```sh
git clone https://github.com/ostinato-forge/divisi.git
cd divisi
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/bin/divisi" "$HOME/.local/bin/divisi"
export PATH="$HOME/.local/bin:$PATH"
```

Add the `export PATH` line to your shell startup file for future terminals. If
another copy of a guarded CLI comes first on `PATH`, `divisi apply` stops and
reports the conflicting directory. System binaries stay in place.

Create your contexts, then build and check them:

```sh
divisi init
divisi apply
divisi check
```

`divisi init` writes `~/.config/divisi/divisi.conf` by default. Running it again
replaces that file, so copy an existing config first if you need it. Choose a
unique name for each context. A workspace mount is optional, but its host
directory must exist before `apply`. Mounts cannot overlap another
context's mount or the Divisi state directory. For a context without project
files or credentials, leave the mount blank and choose `none` for agent authentication.

If you enter an Anthropic API key during `init`, Divisi writes it to that
context's private `~/.secrets` directory. It does not put the key in the config
file. `CTX_SECRETS` copies other named secret files into the same directory;
the source files remain on the host.

## First login and daily use

Sign in separately inside each context. Use the names you chose during `init`:

```sh
divisi enter work
gh auth login
exit

divisi enter personal
gh auth login
exit

divisi run work git config user.email
divisi status
```

A context home keeps logins and session files across container recreation and
host reboots. `divisi apply` replaces containers but keeps their homes. Run
`divisi check` after changing the config or rebuilding the image.

## Commands

| Command | Action |
| --- | --- |
| `divisi init` | Write an interactive local config. |
| `divisi apply` | Build the image, recreate managed containers, and install guards. |
| `divisi enter <name>` | Open a shell in a context. `divisi <name>` also works. |
| `divisi run <name> <command> [args...]` | Run one command in a context. |
| `divisi check` | Check container access, mounts, git email separation, and host guards. |
| `divisi audit` | Scan host files and settings without changing them. Requires `ripgrep`. |
| `divisi enforce` | Refresh host command guards. |
| `divisi relabel` | Repair SELinux labels on context homes. |
| `divisi status` | Show each configured context's container state. |

## Isolation limits

Each context mounts its own home and, if configured, one host workspace. Divisi
rejects shared and overlapping workspace mounts. `divisi check` fails if a
container is missing, cannot run commands, or cannot verify a path check. It
also checks that configured git email addresses differ. It does not prevent a
user from adding a second account inside a context.

Host guards cover configured command names when `~/.local/bin` comes first on
`PATH`. A direct path to another host binary, GUI app, or IDE extension can
bypass them. The guard log records the tool name and time, without command
arguments. Containers share the host network, so they can reach host services.
Network controls are proposed in [the egress plan](docs/PLAN-egress.md) and are
not implemented.

Config and context state live outside this repository. See
[the operator guide](docs/GUIDE.md) for backups, maintenance, and migration from
earlier Divisi containers. Earlier containers without Divisi labels need a
one-time migration before `apply` can replace them.

## Development checks

```sh
bash tests/test-core.sh
bash -n bin/divisi lib/*.sh tests/test-core.sh
shellcheck -x -S warning bin/divisi tests/test-core.sh
shellcheck -s bash -S error lib/*.sh
```

The ShellCheck commands require ShellCheck on the host. The tests cover failed
container checks, mount validation, API key handling, guard logs, and host
release detection. They do not build or start a real container.

## License

Apache-2.0. See [LICENSE](LICENSE).
