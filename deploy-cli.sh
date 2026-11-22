#!/usr/bin/env bash
# Build and install small tagged command-line utility releases as local .deb packages.

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MANIFEST_DIR="$SCRIPT_DIR/utilities"
DEFAULT_HOST=ubuntu-1

usage() {
    cat <<'USAGE'
Usage:
  deploy-cli.sh build <utility> <tag>
  deploy-cli.sh deploy <utility> <tag> [--host HOST]
  deploy-cli.sh status <utility> [--host HOST]
  deploy-cli.sh rollback <utility> <version> [--host HOST]
  deploy-cli.sh remove <utility> [--host HOST]
  deploy-cli.sh --help

Build a tagged utility release as a local .deb, deploy it to a compatible
Debian-family host, inspect the installed version, restore a retained version,
or remove the package. The default deployment host is ubuntu-1.
USAGE
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

load_manifest() {
    utility=$1
    case "$utility" in
        ''|*[!a-z0-9-]*) fail "invalid utility name: $utility" ;;
    esac

    manifest="$MANIFEST_DIR/$utility.conf"
    [ -f "$manifest" ] || fail "no manifest for utility: $utility"

    PACKAGE=
    COMMAND=
    REPO=
    VERSION_FILE=
    VERSION_NAME=
    ENTRYPOINT=
    TAG_PREFIX=
    BUILD_HOST=
    DEFAULT_HOST=$DEFAULT_HOST
    ARCHITECTURE=
    PYTHON_DEPENDENCY=
    SUPPORTED_SYSTEM=
    OS_ID=
    OS_VERSION_ID=
    MAINTAINER=
    DESCRIPTION=
    SETUP_FILE=
    FILES=()

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            *=*) key=${line%%=*}; value=${line#*=} ;;
            *) fail "invalid manifest line in $manifest" ;;
        esac
        case "$key" in
            PACKAGE) PACKAGE=$value ;;
            COMMAND) COMMAND=$value ;;
            REPO) REPO=$value ;;
            VERSION_FILE) VERSION_FILE=$value ;;
            VERSION_NAME) VERSION_NAME=$value ;;
            ENTRYPOINT) ENTRYPOINT=$value ;;
            TAG_PREFIX) TAG_PREFIX=$value ;;
            BUILD_HOST) BUILD_HOST=$value ;;
            DEFAULT_HOST) DEFAULT_HOST=$value ;;
            ARCHITECTURE) ARCHITECTURE=$value ;;
            PYTHON_DEPENDENCY) PYTHON_DEPENDENCY=$value ;;
            SUPPORTED_SYSTEM) SUPPORTED_SYSTEM=$value ;;
            OS_ID) OS_ID=$value ;;
            OS_VERSION_ID) OS_VERSION_ID=$value ;;
            MAINTAINER) MAINTAINER=$value ;;
            DESCRIPTION) DESCRIPTION=$value ;;
            SETUP_FILE) SETUP_FILE=$value ;;
            FILE) FILES[${#FILES[@]}]=$value ;;
            *) fail "unknown key '$key' in $manifest" ;;
        esac
    done < "$manifest"

    [ -n "$PACKAGE" ] || fail "manifest is missing PACKAGE"
    [ -n "$COMMAND" ] || fail "manifest is missing COMMAND"
    [ -n "$REPO" ] || fail "manifest is missing REPO"
    [ -n "$VERSION_FILE" ] || fail "manifest is missing VERSION_FILE"
    [ -n "$VERSION_NAME" ] || fail "manifest is missing VERSION_NAME"
    [ -n "$ENTRYPOINT" ] || fail "manifest is missing ENTRYPOINT"
    [ -n "$TAG_PREFIX" ] || fail "manifest is missing TAG_PREFIX"
    [ -n "$BUILD_HOST" ] || fail "manifest is missing BUILD_HOST"
    [ -n "$DEFAULT_HOST" ] || fail "manifest is missing DEFAULT_HOST"
    [ -n "$ARCHITECTURE" ] || fail "manifest is missing ARCHITECTURE"
    [ -n "$PYTHON_DEPENDENCY" ] || fail "manifest is missing PYTHON_DEPENDENCY"
    [ -n "$SUPPORTED_SYSTEM" ] || fail "manifest is missing SUPPORTED_SYSTEM"
    [ -n "$OS_ID" ] || fail "manifest is missing OS_ID"
    [ -n "$OS_VERSION_ID" ] || fail "manifest is missing OS_VERSION_ID"
    [ -n "$MAINTAINER" ] || fail "manifest is missing MAINTAINER"
    [ -n "$DESCRIPTION" ] || fail "manifest is missing DESCRIPTION"
    [ "${#FILES[@]}" -gt 0 ] || fail "manifest needs at least one FILE"

    utility_dir=$(cd -- "$(dirname "$manifest")" && pwd -P)
    case "$REPO" in
        /*) REPO_DIR=$REPO ;;
        *) REPO_DIR=$(cd -- "$utility_dir/$REPO" && pwd -P) || fail "repository path does not exist: $REPO" ;;
    esac
    validate_manifest_metadata
}

validate_relative_path() {
    path_to_check=$1
    case "$path_to_check" in
        ''|/*|-*|.|..|./*|../*|*/./*|*/../*|*/..|*\\*|*[!A-Za-z0-9._/-]*)
            fail "unsafe relative path: $path_to_check"
            ;;
    esac
}

validate_host() {
    host_to_check=$1
    case "$host_to_check" in
        ''|-*|*[!A-Za-z0-9_.@-]*) fail "invalid SSH host: $host_to_check" ;;
    esac
}

validate_manifest_metadata() {
    case "$PACKAGE" in [!a-z0-9]*|*[!a-z0-9+.-]*) fail "invalid Debian package name: $PACKAGE" ;; esac
    case "$COMMAND" in ''|*/*|*[!A-Za-z0-9_.+-]*) fail "invalid command name: $COMMAND" ;; esac
    case "$VERSION_NAME" in [!A-Za-z_]*|*[!A-Za-z0-9_]*) fail "invalid version variable name: $VERSION_NAME" ;; esac
    case "$TAG_PREFIX" in ''|*[!A-Za-z0-9._+-]*) fail "invalid tag prefix: $TAG_PREFIX" ;; esac
    case "$OS_ID" in ''|*[!a-z0-9]*) fail "invalid OS_ID in manifest: $OS_ID" ;; esac
    case "$OS_VERSION_ID" in ''|*[!0-9.]*) fail "invalid OS_VERSION_ID in manifest: $OS_VERSION_ID" ;; esac
    case "$PYTHON_DEPENDENCY$MAINTAINER$DESCRIPTION" in *$'\r'*) fail "package metadata must be single-line text" ;; esac
    validate_relative_path "$VERSION_FILE"
    validate_relative_path "$ENTRYPOINT"
    validate_host "$BUILD_HOST"
    validate_host "$DEFAULT_HOST"
}

check_compatible_host() {
    host_to_check=$1
    validate_host "$host_to_check"
    ssh "$host_to_check" "test -r /etc/os-release && . /etc/os-release && test \"\$ID\" = '$OS_ID' && test \"\$VERSION_ID\" = '$OS_VERSION_ID'" || fail "$host_to_check must be $SUPPORTED_SYSTEM and reachable over SSH"
}

build_package() {
    tag=$1

    validate_host "$BUILD_HOST"
    [ "$ARCHITECTURE" = all ] || fail "only Architecture: all packages are supported by this workflow"

    case "$tag" in
        "$TAG_PREFIX"*) version=${tag#"$TAG_PREFIX"} ;;
        *) fail "tag must start with '$TAG_PREFIX'" ;;
    esac
    case "$version" in
        ''|*[!0-9.]*|.*|*..*|*.) fail "tag must have a numeric X.Y.Z version: $tag" ;;
    esac
    valid_version=$(printf '%s\n' "$version" | awk -F. 'NF == 3 && $1 ~ /^(0|[1-9][0-9]*)$/ && $2 ~ /^(0|[1-9][0-9]*)$/ && $3 ~ /^(0|[1-9][0-9]*)$/ { print "yes"; exit }')
    [ "$valid_version" = yes ] || fail "tag must have a numeric X.Y.Z version: $tag"

    command -v git >/dev/null 2>&1 || fail "git is required"
    command -v ssh >/dev/null 2>&1 || fail "ssh is required"
    command -v scp >/dev/null 2>&1 || fail "scp is required"
    command -v tar >/dev/null 2>&1 || fail "tar is required"
    command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"
    tag_object=$(git -C "$REPO_DIR" rev-parse --verify "refs/tags/$tag" 2>/dev/null) || fail "tag does not exist: $tag"
    tag_type=$(git -C "$REPO_DIR" cat-file -t "$tag_object" 2>/dev/null) || fail "tag object is unavailable: $tag"
    [ "$tag_type" = tag ] || fail "tag must be annotated: $tag"
    commit=$(git -C "$REPO_DIR" rev-parse "$tag_object^{commit}" 2>/dev/null) || fail "tag does not point to a commit: $tag"

    validate_relative_path "$VERSION_FILE"
    for file in "${FILES[@]}"; do
        validate_relative_path "$file"
    done

    declared_version=$(git -C "$REPO_DIR" show "$commit:$VERSION_FILE" 2>/dev/null | awk -v name="$VERSION_NAME" '
        $0 ~ ("^" name "[[:space:]]*=") {
            count++
            if ($0 !~ ("^" name "[[:space:]]*=[[:space:]]*\"(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\"([[:space:]]*#.*)?$")) {
                invalid = 1
            } else {
                value = $0
                sub("^" name "[[:space:]]*=[[:space:]]*\"", "", value)
                sub("\"([[:space:]]*#.*)?$", "", value)
            }
        }
        END {
            if (invalid || count != 1) exit 1
            print value
        }
    ') || fail "expected exactly one top-level literal $VERSION_NAME X.Y.Z assignment in $tag:$VERSION_FILE"
    [ "$declared_version" = "$version" ] || fail "tag version $version does not match $VERSION_NAME=$declared_version in $tag"

    entrypoint_listed=0
    for file in "${FILES[@]}"; do
        [ "$file" = "$ENTRYPOINT" ] && entrypoint_listed=1
        mode=$(git -C "$REPO_DIR" ls-tree "$commit" -- "$file" | awk 'NR == 1 { print $1 }')
        case "$mode" in
            100644|100755) ;;
            *) fail "tagged runtime file is missing or is not a regular file: $file" ;;
        esac
    done
    [ "$entrypoint_listed" -eq 1 ] || fail "ENTRYPOINT must appear in a FILE entry"
    entry_mode=$(git -C "$REPO_DIR" ls-tree "$commit" -- "$ENTRYPOINT" | awk 'NR == 1 { print $1 }')
    [ "$entry_mode" = 100755 ] || fail "entry point must be executable in the tag: $ENTRYPOINT"

    artifacts_parent="$SCRIPT_DIR/artifacts/$PACKAGE"
    artifacts_dir="$artifacts_parent/$version"
    artifact="$artifacts_dir/${PACKAGE}_${version}_${ARCHITECTURE}.deb"
    if [ -e "$artifacts_dir" ] || [ -L "$artifacts_dir" ]; then
        [ -d "$artifacts_dir" ] && [ ! -L "$artifacts_dir" ] || fail "artifact release path is not a regular directory: $artifacts_dir"
        [ -f "$artifact" ] && [ ! -L "$artifact" ] || fail "release directory has no regular package artifact: $artifacts_dir"
        [ -f "$artifact.commit" ] && [ ! -L "$artifact.commit" ] || fail "artifact has no regular source commit record: $artifact"
        recorded_commit=$(cat "$artifact.commit")
        [ "$recorded_commit" = "$commit" ] || fail "tag $tag now points to a different commit; retained artifact was not replaced"
        printf 'Using existing %s\n' "$artifact"
        return 0
    fi
    check_compatible_host "$BUILD_HOST"
    ssh "$BUILD_HOST" 'command -v dpkg-deb >/dev/null 2>&1' || fail "dpkg-deb is not installed on build host $BUILD_HOST"
    command -v python3 >/dev/null 2>&1 || fail "python3 is required to publish artifacts atomically"
    mkdir -p "$artifacts_parent"
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cli-deploy.XXXXXX") || fail "could not create staging directory"
    prepared_dir=
    remote_stage=
    cleanup_build() {
        if [ -n "$tmpdir" ]; then
            rm -rf "$tmpdir" || :
            tmpdir=
        fi
        if [ -n "$prepared_dir" ]; then
            rm -rf "$prepared_dir" || :
            prepared_dir=
        fi
        if [ -n "$remote_stage" ]; then
            ssh "$BUILD_HOST" "rm -rf '$remote_stage'" >/dev/null 2>&1 || :
            remote_stage=
        fi
    }
    trap cleanup_build EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    prepared_dir=$(mktemp -d "$artifacts_parent/.${version}.XXXXXX") || fail "could not create prepared artifact directory"

    mkdir -p "$tmpdir/source" "$tmpdir/package/usr/lib/$PACKAGE/$version" "$tmpdir/package/usr/bin" "$tmpdir/package/DEBIAN"
    git -C "$REPO_DIR" archive --format=tar "$commit" -- "${FILES[@]}" > "$tmpdir/source.tar" || fail "could not archive runtime files from $tag"
    tar -xf "$tmpdir/source.tar" -C "$tmpdir/source" || fail "could not unpack tagged runtime files"
    for file in "${FILES[@]}"; do
        [ -f "$tmpdir/source/$file" ] && [ ! -L "$tmpdir/source/$file" ] || fail "tagged runtime file is missing or not regular: $file"
        mkdir -p "$tmpdir/package/usr/lib/$PACKAGE/$version/$(dirname "$file")"
        cp "$tmpdir/source/$file" "$tmpdir/package/usr/lib/$PACKAGE/$version/$file"
    done
    find "$tmpdir/package/usr/lib/$PACKAGE/$version" -type d -exec chmod 755 {} \;
    find "$tmpdir/package/usr/lib/$PACKAGE/$version" -type f -exec chmod 644 {} \;
    chmod 755 "$tmpdir/package/usr/lib/$PACKAGE/$version/$ENTRYPOINT"
    chmod 755 "$tmpdir/package" "$tmpdir/package/usr" "$tmpdir/package/usr/bin" "$tmpdir/package/usr/lib" "$tmpdir/package/usr/lib/$PACKAGE" "$tmpdir/package/usr/lib/$PACKAGE/$version" "$tmpdir/package/DEBIAN"
    ln -s "../lib/$PACKAGE/$version/$ENTRYPOINT" "$tmpdir/package/usr/bin/$COMMAND"
    cat > "$tmpdir/package/DEBIAN/control" <<CONTROL
Package: $PACKAGE
Version: $version
Section: utils
Priority: optional
Architecture: $ARCHITECTURE
Depends: $PYTHON_DEPENDENCY
Maintainer: $MAINTAINER
Description: $DESCRIPTION
CONTROL
    chmod 644 "$tmpdir/package/DEBIAN/control"

    package_archive="$tmpdir/package.tar"
    tar -cpf "$package_archive" -C "$tmpdir" package || fail "could not archive staged package"
    remote_stage_candidate=$(ssh "$BUILD_HOST" 'mktemp -d /tmp/cli-deploy.XXXXXX') || fail "could not create build directory on $BUILD_HOST"
    case "$remote_stage_candidate" in
        /tmp/cli-deploy.*)
            remote_suffix=${remote_stage_candidate#/tmp/cli-deploy.}
            case "$remote_suffix" in ''|*[!A-Za-z0-9]*) fail "unexpected build directory from $BUILD_HOST" ;; esac
            ;;
        *) fail "unexpected build directory from $BUILD_HOST" ;;
    esac
    remote_stage=$remote_stage_candidate
    scp "$package_archive" "$BUILD_HOST:$remote_stage/package.tar" || fail "could not transfer staged package to $BUILD_HOST"
    ssh "$BUILD_HOST" "tar -xpf '$remote_stage/package.tar' -C '$remote_stage' && dpkg-deb --root-owner-group --build '$remote_stage/package' '$remote_stage/${PACKAGE}_${version}_${ARCHITECTURE}.deb'" || fail "dpkg-deb failed on $BUILD_HOST"

    prepared_artifact="$prepared_dir/${PACKAGE}_${version}_${ARCHITECTURE}.deb"
    scp "$BUILD_HOST:$remote_stage/${PACKAGE}_${version}_${ARCHITECTURE}.deb" "$prepared_artifact" || fail "could not retrieve package artifact from $BUILD_HOST"
    printf '%s\n' "$commit" > "$prepared_artifact.commit"
    if ! python3 - "$prepared_dir" "$artifacts_dir" <<'PUBLISH'
import os
import sys

try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError as error:
    print(error, file=sys.stderr)
    sys.exit(1)
PUBLISH
    then
        if [ -f "$artifact" ] && [ -f "$artifact.commit" ] && [ "$(cat "$artifact.commit")" = "$commit" ]; then
            cleanup_build
            trap - EXIT HUP INT TERM
            printf 'Using existing %s\n' "$artifact"
            return 0
        fi
        fail "could not publish artifact directory without replacing existing data: $artifacts_dir"
    fi
    prepared_dir=
    cleanup_build
    trap - EXIT HUP INT TERM
    printf 'Built %s\n' "$artifact"
}

select_host() {
    target_host=$DEFAULT_HOST
    case "$#" in
        0) ;;
        2)
            [ "$1" = --host ] || fail "expected --host HOST"
            target_host=$2
            ;;
        *) fail "expected optional --host HOST" ;;
    esac
    validate_host "$target_host"
}

validate_version() {
    version_to_check=$1
    case "$version_to_check" in
        ''|*[!0-9.]*|.*|*..*|*.) fail "version must have a SemVer MAJOR.MINOR.PATCH form: $version_to_check" ;;
    esac
    valid_version=$(printf '%s\n' "$version_to_check" | awk -F. 'NF == 3 && $1 ~ /^(0|[1-9][0-9]*)$/ && $2 ~ /^(0|[1-9][0-9]*)$/ && $3 ~ /^(0|[1-9][0-9]*)$/ { print "yes"; exit }')
    [ "$valid_version" = yes ] || fail "version must have a SemVer MAJOR.MINOR.PATCH form: $version_to_check"
}

query_installed_package() {
    host_to_query=$1
    installed_version=
    if ! ssh "$host_to_query" 'test -r /var/lib/dpkg/status' >/dev/null 2>&1; then
        fail "dpkg status database is unavailable on $host_to_query"
    fi
    if query_result=$(ssh "$host_to_query" "if dpkg-query -s '$PACKAGE' >/dev/null 2>&1; then dpkg-query -W -f='\${db:Status-Status}|\${Version}' '$PACKAGE'; else query_status=\$?; if [ \"\$query_status\" -eq 1 ]; then printf '%s' '__CLI_DEPLOY_ABSENT__'; else exit \"\$query_status\"; fi; fi"); then
        if [ "$query_result" = __CLI_DEPLOY_ABSENT__ ]; then
            return 0
        fi
        query_state=${query_result%%|*}
        query_version=${query_result#*|}
        case "$query_state" in
            installed)
                validate_version "$query_version"
                installed_version=$query_version
                ;;
            config-files|not-installed) installed_version= ;;
            *) fail "$PACKAGE is in dpkg state '$query_state' on $host_to_query; repair it before continuing" ;;
        esac
    else
        query_status=$?
        fail "could not query dpkg on $host_to_query (ssh/dpkg status $query_status)"
    fi
}

show_status() {
    expected_version=${1-}
    check_compatible_host "$target_host"
    query_installed_package "$target_host"
    [ -n "$installed_version" ] || fail "$PACKAGE is not fully installed on $target_host"
    if [ -n "$expected_version" ] && [ "$installed_version" != "$expected_version" ]; then
        fail "expected $PACKAGE $expected_version on $target_host, found $installed_version"
    fi
    expected_command_path="/usr/lib/$PACKAGE/$installed_version/$ENTRYPOINT"
    resolved_command_path=$(ssh "$target_host" "readlink -f '/usr/bin/$COMMAND'") || fail "could not resolve /usr/bin/$COMMAND on $target_host"
    [ "$resolved_command_path" = "$expected_command_path" ] || fail "/usr/bin/$COMMAND resolves to $resolved_command_path; expected $expected_command_path"
    printf '%s %s\n/usr/bin/%s\n' "$PACKAGE" "$installed_version" "$COMMAND"
}

install_artifact() {
    artifact_path=$1
    allow_downgrade=$2
    expected_version=$3
    [ -f "$artifact_path" ] || fail "package artifact does not exist: $artifact_path"

    ssh "$target_host" 'command -v dpkg-deb >/dev/null 2>&1' || fail "dpkg-deb is not available on $target_host"
    remote_package=$(ssh "$target_host" 'mktemp --suffix=.deb /tmp/cli-deploy.XXXXXX') || fail "could not create a temporary package path on $target_host"
    case "$remote_package" in
        /tmp/cli-deploy.*.deb)
            remote_suffix=${remote_package#/tmp/cli-deploy.}
            remote_suffix=${remote_suffix%.deb}
            case "$remote_suffix" in ''|*[!A-Za-z0-9]*) fail "unexpected temporary package path from $target_host" ;; esac
            ;;
        *) fail "unexpected temporary package path from $target_host" ;;
    esac
    scp "$artifact_path" "$target_host:$remote_package" || fail "could not copy package to $target_host; temporary file: $remote_package"
    package_metadata=$(ssh "$target_host" "dpkg-deb -f '$remote_package' Package Version Architecture") || fail "could not read transferred package metadata; retained file: $remote_package"
    actual_package=$(printf '%s\n' "$package_metadata" | awk -F': ' '$1 == "Package" { print $2; exit }')
    actual_version=$(printf '%s\n' "$package_metadata" | awk -F': ' '$1 == "Version" { print $2; exit }')
    actual_architecture=$(printf '%s\n' "$package_metadata" | awk -F': ' '$1 == "Architecture" { print $2; exit }')
    [ "$actual_package" = "$PACKAGE" ] || fail "transferred package name '$actual_package' does not match $PACKAGE; retained file: $remote_package"
    [ "$actual_version" = "$expected_version" ] || fail "transferred package version '$actual_version' does not match $expected_version; retained file: $remote_package"
    [ "$actual_architecture" = "$ARCHITECTURE" ] || fail "transferred package architecture '$actual_architecture' does not match $ARCHITECTURE; retained file: $remote_package"

    apt_options=-y
    if [ "$allow_downgrade" = yes ]; then
        apt_options='-y --allow-downgrades'
    fi
    if ! ssh -t "$target_host" "if [ \"\$(id -u)\" -eq 0 ]; then apt install $apt_options '$remote_package'; else sudo apt install $apt_options '$remote_package'; fi"; then
        printf 'error: package installation failed on %s; retained file: %s\n' "$target_host" "$remote_package" >&2
        return 1
    fi
    if ! ssh "$target_host" "rm -f '$remote_package'"; then
        printf 'warning: installed package, but could not remove temporary file %s on %s\n' "$remote_package" "$target_host" >&2
    fi
}

deploy_release() {
    release_tag=$1
    check_compatible_host "$target_host"
    build_package "$release_tag"
    release_version=${release_tag#"$TAG_PREFIX"}
    release_artifact="$SCRIPT_DIR/artifacts/$PACKAGE/$release_version/${PACKAGE}_${release_version}_${ARCHITECTURE}.deb"
    query_installed_package "$target_host"
    current_version=$installed_version
    previous_artifact=
    if [ -n "$current_version" ] && [ "$current_version" != "$release_version" ]; then
        previous_artifact="$SCRIPT_DIR/artifacts/$PACKAGE/$current_version/${PACKAGE}_${current_version}_${ARCHITECTURE}.deb"
        [ -f "$previous_artifact" ] || fail "cannot safely upgrade $PACKAGE $current_version; retain its package first: $previous_artifact"
        [ -f "$previous_artifact.commit" ] || fail "previous package has no source commit record: $previous_artifact"
    fi
    if ! install_artifact "$release_artifact" no "$release_version"; then
        if [ -n "$previous_artifact" ]; then
            printf 'Attempting to restore %s %s on %s\n' "$PACKAGE" "$current_version" "$target_host" >&2
            if install_artifact "$previous_artifact" yes "$current_version"; then
                show_status "$current_version"
                fail "upgrade failed; restored $PACKAGE $current_version"
            fi
            fail "upgrade failed and restoring $PACKAGE $current_version also failed; inspect the retained package files on $target_host"
        fi
        fail "installation failed on $target_host; no previous installed version was available for restoration"
    fi
    show_status "$release_version"
}

rollback_release() {
    release_version=$1
    validate_version "$release_version"
    rollback_artifact="$SCRIPT_DIR/artifacts/$PACKAGE/$release_version/${PACKAGE}_${release_version}_${ARCHITECTURE}.deb"
    [ -f "$rollback_artifact" ] || fail "no retained package for version $release_version: $rollback_artifact"
    [ -f "$rollback_artifact.commit" ] || fail "retained package has no source commit record: $rollback_artifact"
    check_compatible_host "$target_host"
    query_installed_package "$target_host"
    current_version=$installed_version
    current_artifact=
    if [ -n "$current_version" ] && [ "$current_version" != "$release_version" ]; then
        current_artifact="$SCRIPT_DIR/artifacts/$PACKAGE/$current_version/${PACKAGE}_${current_version}_${ARCHITECTURE}.deb"
        [ -f "$current_artifact" ] || fail "cannot safely roll back; retain the currently installed package first: $current_artifact"
        [ -f "$current_artifact.commit" ] || fail "currently installed package has no source commit record: $current_artifact"
    fi
    if ! install_artifact "$rollback_artifact" yes "$release_version"; then
        if [ -n "$current_artifact" ]; then
            printf 'Attempting to restore %s %s on %s\n' "$PACKAGE" "$current_version" "$target_host" >&2
            if install_artifact "$current_artifact" yes "$current_version"; then
                show_status "$current_version"
                fail "rollback failed; restored $PACKAGE $current_version"
            fi
            fail "rollback and restoration of $PACKAGE $current_version both failed; inspect retained package files on $target_host"
        fi
        fail "rollback installation failed on $target_host"
    fi
    show_status "$release_version"
}

remove_package() {
    check_compatible_host "$target_host"
    ssh -t "$target_host" "if [ \"\$(id -u)\" -eq 0 ]; then apt remove -y '$PACKAGE'; else sudo apt remove -y '$PACKAGE'; fi" || fail "could not remove $PACKAGE on $target_host"
    query_installed_package "$target_host"
    [ -z "$installed_version" ] || fail "$PACKAGE is still installed on $target_host"
    ssh "$target_host" "test ! -e '/usr/bin/$COMMAND' && test ! -L '/usr/bin/$COMMAND'" || fail "/usr/bin/$COMMAND remains after removing $PACKAGE on $target_host"
    printf 'Removed %s from %s\n' "$PACKAGE" "$target_host"
}

if [ "$#" -eq 0 ]; then
    usage >&2
    exit 2
fi

case "$1" in
    --help|-h)
        usage
        exit 0
        ;;
    build|deploy|status|rollback|remove)
        command_name=$1
        shift
        ;;
    *)
        usage >&2
        fail "unknown command: $1"
        ;;
esac

[ "$#" -ge 1 ] || fail "a utility name is required"
utility_name=$1
shift
load_manifest "$utility_name"

case "$command_name" in
    build)
        [ "$#" -eq 1 ] || fail "usage: build <utility> <tag>"
        build_package "$1"
        ;;
    deploy)
        [ "$#" -ge 1 ] || fail "usage: deploy <utility> <tag> [--host HOST]"
        release_tag=$1
        shift
        select_host "$@"
        deploy_release "$release_tag"
        ;;
    status)
        select_host "$@"
        show_status
        ;;
    rollback)
        [ "$#" -ge 1 ] || fail "usage: rollback <utility> <version> [--host HOST]"
        release_version=$1
        shift
        select_host "$@"
        rollback_release "$release_version"
        ;;
    remove)
        select_host "$@"
        remove_package
        ;;
esac
