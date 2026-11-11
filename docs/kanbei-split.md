# Kanbei split: threat model and accepted residuals

The #509 split moves the private data into a NIC-less `kanbei` VM and the
home-infra agent into a `cluster` VM. The host keeps only plumbing and the
human's own tools. This file records what the host boundary does **not** stop,
so a later review can re-open a residual on purpose rather than by accident.
Operator steps live in `docs/manual-steps.md` (`host/smortress`); the design
itself is `smores56/sdlc#509`.

## What is trusted

- Host root reads everything: every guest disk, `/dev/vfio`, swtpm state,
  relay sockets and `kanbei`'s logs. Root on the host is outside the bar.
- `maki` runs unsandboxed as `smores`, who is in `wheel`. A touch of the
  YubiKey is the human authorization for sudo, and one touch grants root for
  that command.
- Guests that escape their VM (or a kernel/hypervisor 0-day) reach the host and
  therefore everything. Physical separation is the upgrade path.

## Host hardening that ships

`modules/nixos/host-hardening.nix`, enabled only on `smortress`:

- `Defaults timestamp_timeout=0,use_pty`: every sudo spends its own touch, and
  the command runs on a fresh pty so a process left in the caller's terminal
  cannot type into it. Without this a single touch bought 15 minutes
  (`modules/nixos/ssh.nix`).
- `kernel.yama.ptrace_scope=2`: only a parent or `CAP_SYS_PTRACE` may attach,
  so one process of `smores` cannot read another's memory or environment.
- `/proc` remounted `hidepid=2,gid=proc`: other users' process entries (and
  thus their command lines and environment) are invisible. `smores`' login
  shells see only `smores` and root-owned entries the kernel still allows.
- `td` and `v` invoke `/run/wrappers/bin/sudo` (and the wrapper binaries
  themselves) by absolute path, so a `sudo` planted earlier on `PATH` is never
  the binary that receives the touch.
- maki's prompt (`modules/features/ai/agent-context.nix`) tells it to never run
  anything that needs superuser rights and to ask the human instead.

### The `proc` group

`gid=proc` is the kernel's allow-list: a process in group `proc` sees every
`/proc` entry regardless of `hidepid`. NixOS removed
`security.hideProcessInformation` because its remount does not survive cgroups
v2, so the module owns the remount and adds only the units upstream requires:
`systemd-logind.service` and the `user@.service` template (systemd#12955).
Their children — every systemd *user* service of `smores` — inherit the group
and therefore the wider view; interactive login shells do not.

A monitoring agent that must enumerate all processes has to be added to the
group explicitly, e.g. `systemd.services.<name>.serviceConfig.SupplementaryGroups
= [ "proc" ]`. No monitoring agent runs on `smortress` today, so the only
members are the two systemd units above. The first switch remounts `/proc`
right away, but a `user@` instance already running predates its drop-in; reboot
(or `loginctl terminate-user smores`) once before trusting user services.

Verify on the host after a switch:

```sh
cat /proc/1/cmdline >/dev/null && echo "hidepid not active"
ps -eo user,pid,args            # as smores: no other user's processes
sudo -v; sudo -v                # each prompts for a fresh touch
```

## Accepted residuals

### A later human touch runs whatever the unattended maki planted

Decision 47. sudo's touch is not bound to a command: `pam_rssh` authorizes
"this process may become root now", not "this argv may run". An unattended maki
session (as `smores`) can therefore:

- shadow `sudo` with a wrapper in an rc file (`~/.zshrc`, `~/.config/fish`), a
  `PATH` directory (`~/.local/bin`), or a shell function/alias, or
- drop a payload in a place the owner's next session executes (a shell startup
  file, a systemd user unit, a zsh/fish completion script),

and the payload runs with host root on the owner's next touch, because the
owner's `sudo` resolves the plant first. Absolute `/run/wrappers/bin/sudo` in
`td` and `v` closes that path only for those two commands; a human typing
`sudo ...` by hand still resolves through their own shell's config. From host
root, everything in the threat model is reachable, including `kanbei`.

Why accepted: the alternative is a separate UID or command-bound authorization
for maki (a `sudo` rule per command, or a privileged helper that only accepts
an allow-list). The owner chose the touch residual over running maki as its own
user, and the restated goal is "unattended maki cannot reach Kanbei **without a
later human touch**". Revisit if maki ever gets a separate UID or sudo gains a
command-bound approval flow.

### Proc-group members keep a wider process view

`systemd-logind.service` and `user@.service` are in group `proc` (see above).
Their children — `smores`' user services — can read every process entry,
including root's. This is what keeps user managers and D-Bus session services
working; removing it needs a systemd version that no longer reads other users'
`/proc` entries. A monitoring agent added to the group deliberately widens it
further.

### Same-UID capture while `td` or a vault session is open

`v` mounts the vault for one foreground session as root-assisted bindfs, and
`td` runs tuxedo as `vault`. Any other process of `smores` can read the
terminal (pty, scrollback) while either is open; `hidepid` does not hide
terminals of the same UID. The window is the session's lifetime by design.

### Exfiltration channels that remain

- The `search` VM's capped queries leak a few dozen bits each to TinyFish;
  DLP, the length cap and the Guardian judge bound the rate, not the fact.
- `nanobot` (Neuralwatt) sees cluster metadata and allowlisted log fields;
  Graphiti's extraction inputs go to Neuralwatt under a no-training policy.
- Prompt-injected model output reaches the owner's browser only through the
  CSP-locked, JSON-only UI shell; a browser or terminal escape from another
  window is out of scope.
