# Ubuntu CLI Package Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable manifest-driven workflow that packages tagged CLI utilities as local Debian packages and deploys them to configurable compatible hosts.

**Architecture:** Keep the shared workflow in the sibling project `projects/cli-deploy`, with one manifest per utility. It will stage files from an immutable commit resolved from an annotated Git tag, build an `Architecture: all` `.deb` using Ubuntu's `dpkg-deb`, retain the artifact and source commit on the Mac, and install it on a selected compatible host with a stable command entry.

**Tech Stack:** Bash 3.2-compatible shell script on macOS, SSH/SCP, Git, Ubuntu `dpkg-deb` and `apt`, Debian package control metadata.

**Spec:** [2026-11-21-ubuntu-cli-package-workflow-design.md](../specs/2026-11-21-ubuntu-cli-package-workflow-design.md)

## Global Constraints

- The initial default deploy target is `ubuntu-1`; the target must be selectable at deploy time.
- The workflow accepts a committed annotated version tag and checks that its version matches the utility's version.
- The manifest identifies the package name, version source, command name, and runtime files.
- The `.deb` targets Debian-family systems; `command-complete` currently documents Ubuntu 24.04 support.
- Keep the prior `.deb` on the Mac as the rollback artifact.
- Do not add a public/private APT repository or third-party runtime dependencies.
- Preserve existing uncommitted edits in `command-complete/README.md`, `command-complete/test_terminal.py`, and `command-complete/test-ubuntu.sh`.
- Do not add or run tests as part of this plan unless Jesse asks for verification.

## Review Focus

- Working-tree edits must never leak into a release package; build only from the selected tag archive.
- A tag whose version disagrees with the version declared by the utility must be rejected.
- A manifest path must not escape its utility source directory or include unlisted files.
- A transient SSH or dpkg query failure must not be interpreted as an absent installation.
- A transferred `.deb` must match the configured package name, selected version, and `Architecture: all` before apt installs it.
- A failed transfer must not change package state; when an apt upgrade fails, attempt to restore the retained package for the previously installed version.
- An incompatible OS must be identified before package state changes; `command-complete` targets Ubuntu 24.04.
- Package transfer and build must preserve the `/usr/bin` symlink and set package file ownership to root.

---

## File map

- Create `deploy-cli.sh`: shared build, transfer, install, inspect, rollback, and removal entry points; preserve Bash 3.2 compatibility.
- Create `utilities/command-complete.conf`: package identity, source repository path, tag/version source, executable entry point, runtime files, package maintainer and description, supported OS ID/version, Ubuntu 24.04 build host (`ubuntu-1`), and default deployment host (`ubuntu-1`).
- Create `README.md`: command examples, release prerequisites, host override, install inspection, rollback, removal, and adding a future utility manifest.
- Create `.gitignore`: ignore retained build artifacts and temporary staging directories.
- Modify `command-complete/docs/superpowers/specs/2026-11-21-ubuntu-cli-package-workflow-design.md` only if implementation choices require a material design change.

### Task 1: Define the shared workflow interface and first manifest

**Files:**
- Create: `deploy-cli.sh`
- Create: `utilities/command-complete.conf`
- Create: `README.md`

**Interfaces:**
- `deploy-cli.sh build <utility> <tag>` builds the package artifact from the named utility's committed tag and stores it locally.
- `deploy-cli.sh deploy <utility> <tag> [--host HOST]` builds or reuses the matching artifact, transfers it, and installs it; `ubuntu-1` is the default host.
- `deploy-cli.sh status <utility> [--host HOST]` prints the installed package version and command path.
- `deploy-cli.sh rollback <utility> <version> [--host HOST]` reinstalls a retained local package version.
- `deploy-cli.sh remove <utility> [--host HOST]` removes the package through `apt`.
- Manifests use dependency-free, shell-readable key/value records; the script parses values as data and never sources the manifest. The build host is fixed by the manifest; the deployment host can be overridden per invocation.

- [ ] Create the three files with the command interface and manifest fields above; document that the package is tagged-release-only and host override is per invocation.
- [ ] In `command-complete.conf`, list `command_complete.py`, `catalog.json.gz`, and `catalog-ubuntu.json.gz`; record `shell-integration.sh` as optional documentation/setup content, not a runtime file for the package.

### Task 2: Build a self-contained versioned `.deb`

**Files:**
- Modify: `deploy-cli.sh`
- Modify: `utilities/command-complete.conf`

**Interfaces:**
- Consumes the `build <utility> <tag>` interface and manifest from Task 1.
- Produces a local artifact named `<package>_<version>_all.deb`, an adjacent `.commit` file recording its source commit, and package metadata identifying the version and Ubuntu 24.04/Python 3.10+ runtime requirement.
- Installs payload files beneath `/usr/lib/<package>/<version>/` and provides the stable command under `/usr/bin/` as a symlink to the versioned executable.

- [ ] Resolve the annotated tag object and commit once; require exactly one top-level literal X.Y.Z assignment matching the tag version, and use the immutable commit for every source read.
- [ ] Stage only manifest-listed regular files, generate package control metadata and a versioned `/usr/bin` symlink, then archive the staging tree without following symlinks.
- [ ] Build on the configured Ubuntu host with `dpkg-deb --root-owner-group --build`; return the artifact and source commit record to the Mac.
- [ ] Publish the `.deb` and `.commit` together by atomically renaming a prepared artifact directory; never overwrite a retained version.

### Task 3: Deploy, inspect, roll back, and remove

**Files:**
- Modify: `deploy-cli.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes the locally retained `.deb` from Task 2.
- Deploy, status, rollback, and removal accept `--host HOST`; omitted target resolves to `ubuntu-1`. Builds use the manifest's fixed build host.
- Deploy installs with `apt` and reports package version and stable command path.

- [ ] Add target selection and validate that the selected host resolves through SSH before changing its package state.
- [ ] Copy the artifact to temporary storage, install it through `apt`, and clean up the temporary file only after successful installation.
- [ ] Read the transferred `.deb` control fields and require its package name, expected version, and architecture to match the manifest before installation.
- [ ] Distinguish an absent package from SSH/dpkg errors and refuse to upgrade from a non-installed dpkg state.
- [ ] Before upgrading an installed version, require its retained local `.deb`; if the new apt install fails, attempt to reinstall that prior package and report whether restoration succeeded.
- [ ] After install or restoration, require dpkg's `installed` state, the expected version, and `/usr/bin/<command>` to resolve to that version's payload.
- [ ] Ensure the stable command resolves through the active versioned payload, and package upgrade/removal keeps package-managed command links consistent.
- [ ] Implement `status`, `rollback`, and `remove` using the package database and retained local artifacts.
- [ ] Document examples for first deployment to `ubuntu-1`, deployment to a second compatible host, checking the active version, rolling back, and removing the utility.

## Manual handoff

After implementation, provide Jesse with the exact commands to build and deploy the first tagged release and the expected package/version/command output. Do not execute behavioral tests or deploy to a host unless Jesse asks for that verification.
