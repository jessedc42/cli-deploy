# CLI deploy

`deploy-cli.sh` is a shared, manifest-driven workflow for building small
command-line utilities as local Debian packages and deploying them to compatible
machines. The first utility manifest is for `command-complete`.

Releases use the stable subset of Semantic Versioning 2.0.0: `MAJOR.MINOR.PATCH`
with no leading zeroes (for example, `0.2.0`). Git tags add the `v` prefix,
such as `v0.2.0`. Prerelease and build metadata identifiers are not supported by
this initial workflow. Releases come only from committed, annotated Git tags.
The package version must match the version declared by the utility at that tag.
The script builds from the tag's archive, so uncommitted working-tree files are
excluded.

The package is a low-profile `.deb`, not an APT repository. The current
`command-complete` manifest permits Ubuntu 24.04, which is the platform the
utility documents. Other distributions need their own package and compatibility
configuration. The utility uses Python 3.10+ and the standard library. Its shell
integration file is listed for setup documentation and is not part of the
runtime package.

The initial build host and default deployment host are `ubuntu-1`. The build
host stays in the utility manifest. Deploy, status, rollback, and removal accept
a host override, so the same architecture-independent package can be installed
on other compatible machines. All commands accept `--user USER` to select the
SSH login name for remote connections; without it, SSH uses its configured
default. The selected account needs `dpkg-deb` and writable `/tmp` on the build
host, and root or sudo access for package installation or removal. The workflow
checks the host's OS ID and version before it changes package state. Retain
built `.deb` files on the Mac to support rollback; a companion `.commit` file
records the tag's source commit.

The intended interface is:

```bash
cd ~/projects/cli-deploy
./deploy-cli.sh build command-complete v0.2.0
./deploy-cli.sh build command-complete v0.2.0 --user jessedc42
./deploy-cli.sh deploy command-complete v0.2.0
./deploy-cli.sh deploy command-complete v0.2.0 --host another-ubuntu
./deploy-cli.sh deploy command-complete v0.2.0 --user jessedc42
./deploy-cli.sh deploy command-complete v0.2.0 --host another-ubuntu --user jessedc42
./deploy-cli.sh status command-complete
./deploy-cli.sh status command-complete --host another-ubuntu --user jessedc42
./deploy-cli.sh rollback command-complete 0.2.0
./deploy-cli.sh rollback command-complete 0.2.0 --host another-ubuntu --user jessedc42
./deploy-cli.sh remove command-complete --user jessedc42
```

`build` leaves `artifacts/command-complete/0.2.0/command-complete_0.2.0_all.deb`
and its `.commit` record on the Mac. After `deploy`, the status output should
look like:

```text
command-complete 0.2.0
/usr/bin/command-complete
```

Deployment and rollback install the local package through `apt`, using root
access or `sudo`. Rollback accepts the version without the Git tag's `v` prefix.
If package installation fails, the workflow leaves the copied package in
`/tmp` on the target and reports its path. During an upgrade it attempts to
restore the retained package for the previously installed version.

To add another utility, create a key/value manifest in `utilities/`. Use one
`FILE=` line per runtime file. Manifest values are read as data and are never
executed as shell code.

## Commit and release notes

Use one focused commit per logical change. Write a short imperative subject
with a type (`feat:`, `fix:`, `docs:`, `build:`, or `chore:`), then a body that
records the change, its reason, and relevant validation or known limitations.
For example:

```text
fix: reject SemVer components with leading zeroes

Keep accepted release versions within the SemVer 2.0.0 MAJOR.MINOR.PATCH
format supported by Debian package versions in this workflow.
Validation: inspected the version and tag checks; no deployment was run.
```

For a utility release, update its declared version in the same commit as the
release changes. Bump `PATCH` for backward-compatible fixes, `MINOR` for
backward-compatible features, and `MAJOR` for incompatible changes. Create an
annotated tag only after committing the release, and include concise release
notes in the tag message: what changed, any breaking changes, and validation.
Push the commit and tag explicitly so both the change history and its release
notes are available remotely. The commit and tag messages travel with the push;
the deploy workflow does not create or push Git history itself.
