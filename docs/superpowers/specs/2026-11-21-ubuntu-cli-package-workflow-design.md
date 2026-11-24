# Ubuntu CLI package workflow design

## Intent

Create a small, repeatable workflow for deploying versioned command-line utilities from the Mac development workspace to `ubuntu-1`. Each utility describes its package inputs in a small manifest. The workflow produces a local Debian package (`.deb`) that can be copied to the host and installed with `apt` using root access.

## Goals

- Build a low-profile, self-contained `.deb` for a utility such as `command-complete`.
- Use the utility's existing version and committed Git tag as the package version.
- Install a stable command name and keep program files in a version-specific directory.
- Make upgrades repeatable and rollback possible by reinstalling a retained previous `.deb`.
- Keep the workflow reusable across small utilities through per-utility manifests.
- Avoid running a package repository or adding third-party runtime dependencies.

## Non-goals

- Publish packages to a public or private APT repository.
- Automatically deploy on every commit or tag.
- Deploy untagged working copies in the initial workflow.
- Change the utility's application behavior or existing release/versioning policy.

## Constraints and known project details

- `command-complete` is a Python 3.10+ standard-library application.
- Its runtime consists of `command_complete.py` and both compressed catalogs. `shell-integration.sh` is an optional separate file for shell setup.
- Its version is recorded in `version.py`; `command_complete.py` imports both `version.py` and `terminal_keys.py` at runtime. Release notes use annotated Git tags such as `v0.2.0`.
- `command-search` is a separate command and package sharing the `command-complete` source repository and version. It uses the completion module, shared terminal/version modules, and a platform catalog with its prebuilt search database.
- The project currently contains uncommitted edits in `README.md`, `test_terminal.py`, and `test-ubuntu.sh`; these must be preserved.
- The initial default deploy target is `ubuntu-1`, and the user has root access there. The target must be selectable at deploy time so the same package can be installed on additional compatible hosts.

## Approaches considered

1. **One reusable manifest-driven workflow that builds local `.deb` files (selected).** It shares package construction, transfer, install, and version handling while keeping configuration per utility small. It has a little initial workflow setup and packages require root to install.
2. **A separate deploy script in each utility.** It is easy to tailor initially, but repeats transfer and version logic and may drift across projects.
3. **A managed APT repository.** It enables ordinary repository-based upgrades, but requires repository hosting and signing setup that is unnecessary for a few personal utilities.

## Proposed package behavior

- The manifest identifies the package name, version source, command name, and runtime files. The deploy command accepts a target host, defaulting to `ubuntu-1`; the host is not embedded in the package.
- The workflow accepts a committed annotated version tag, verifies that its version matches the utility's version, and stages only the files listed by the manifest.
- The package owns the utility's files and exposes a stable command in the system PATH. Version-specific payload paths allow the installed command to point at the active release.
- The workflow builds a standalone `.deb`, copies it to `ubuntu-1`, installs it with `apt`, and reports the installed package version and command path.
- Keep the prior `.deb` on the Mac as the rollback artifact. Rollback consists of copying and installing that package again.
- Package removal should remove package-managed files and the command entry.
- The `.deb` targets Debian-family systems. The current `command-complete` application documents Ubuntu 24.04 support; extending it to other Ubuntu releases or Linux distributions is a separate compatibility change.

## Decisions left to the builder

- Choose a simple Debian package staging layout and package-building command available in the existing Mac/Ubuntu workflow.
- Decide whether the per-utility manifest should be shell-readable key/value data or another dependency-free format.
- Determine the safest way to update the stable command entry during package upgrades and removal.
- Document the commands to build, deploy, inspect the installed version, roll back, and remove a package.
