#!/usr/bin/env bash
# build.sh - build the vendored, patched libimobiledevice stack into a private prefix.
#
#   bash build.sh [--prefix DIR] [--jobs N] [--offline] [--from-forks] [--src DIR] [--only NAME[,NAME...]]
#
# What it does, per component in vendor/refs.env order (dependency order):
#   1. makes sure the source is present in vendor/src/<name> at the pinned base commit
#      (clones from upstream unless --offline; an existing checkout or unpacked tarball is reused;
#      with --from-forks the patched components are cloned from the maintainer's fork branches instead),
#   2. applies vendor/patches/<name>.patch idempotently (checks first, skips when already applied,
#      verifies afterwards),
#   3. autogen + configure + make + make install into the prefix, with exactly the configure flags
#      and order of the proven build.
# Nothing outside this repository and the prefix is written. Nothing is installed system-wide.
# Logs: vendor/build/<name>.log. Root is never needed; --offline never touches the network.
set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PREFIX=${T1R_PREFIX:-$REPO/prefix}
SRC=$REPO/vendor/src
BUILD=$REPO/vendor/build
PATCHES=$REPO/vendor/patches
REFS=$REPO/vendor/refs.env
JOBS=$(nproc 2>/dev/null || echo 2)
OFFLINE=0
FROM_FORK=0
ONLY=""

usage() {
	cat <<EOF
usage: bash build.sh [--prefix DIR] [--jobs N] [--offline] [--from-forks] [--src DIR] [--only NAME[,NAME...]]

  --prefix DIR   install prefix (default: \$T1R_PREFIX or $REPO/prefix)
  --jobs N       make -j N (default: nproc)
  --offline      never touch the network; every source tree must already exist under --src
  --from-forks   clone patched components from <NAME>_FORK_URL branch <NAME>_FORK_BRANCH (refs.env)
                 instead of upstream + vendor/patches; the result is verified to be base+patch
  --src DIR      where component sources live (default: $REPO/vendor/src)
  --only LIST    build only these components (comma separated); dependencies must be installed already
  -h, --help     this text

Components, build order and pinned commits come from vendor/refs.env.
EOF
}

say()  { printf '\033[1;32m=== %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mbuild.sh: %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--prefix)  [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX=$2; shift 2 ;;
		--prefix=*) PREFIX=${1#--prefix=}; shift ;;
		--jobs)    [ $# -ge 2 ] || die "--jobs needs a number"; JOBS=$2; shift 2 ;;
		--jobs=*)  JOBS=${1#--jobs=}; shift ;;
		--src)     [ $# -ge 2 ] || die "--src needs a directory"; SRC=$2; shift 2 ;;
		--src=*)   SRC=${1#--src=}; shift ;;
		--only)    [ $# -ge 2 ] || die "--only needs a list"; ONLY=$2; shift 2 ;;
		--only=*)  ONLY=${1#--only=}; shift ;;
		--offline) OFFLINE=1; shift ;;
		--from-forks|--from-fork) FROM_FORK=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown argument: $1" ;;
	esac
done

[[ $JOBS =~ ^[0-9]+$ ]] && [ "$JOBS" -ge 1 ] || die "--jobs must be a positive integer"
[ -r "$REFS" ] || die "missing $REFS"
# shellcheck source=vendor/refs.env
. "$REFS"
[ -n "${T1R_VENDOR_ORDER:-}" ] || die "T1R_VENDOR_ORDER not set in $REFS"

# Resolve to absolute paths so `cd` into component trees does not bite.
mkdir -p -- "$PREFIX" "$SRC" "$BUILD" || die "cannot create prefix/src/build directories"
PREFIX=$(cd -- "$PREFIX" && pwd -P)
SRC=$(cd -- "$SRC" && pwd -P)
BUILD=$(cd -- "$BUILD" && pwd -P)

# A private prefix never needs root. Container CI runs everything as root, so this warns rather
# than refusing - except for a system prefix, where a stray `make install` would leave the sandbox.
if [ "$(id -u)" -eq 0 ]; then
	case "$PREFIX" in
		/usr|/usr/*|/opt|/opt/*|/bin|/sbin|/lib|/lib64|/etc|/etc/*|/var|/var/*)
			die "refusing to build as root into the system location $PREFIX; use a private prefix" ;;
		*) : ;;
	esac
	warn "running as root: not needed, and only the private prefix $PREFIX is written"
fi

# ref NAME KEY -> value of <NAME>_<KEY> from refs.env (dashes in NAME become underscores)
ref() {
	local var=${1^^}
	var=${var//-/_}_$2
	printf '%s' "${!var-}"
}

# ---------------------------------------------------------------- preflight
preflight() {
	local missing=() tool mod
	local -A pkg=(
		[autoconf]=autoconf [automake]=automake [libtoolize]=libtool [pkg-config]=pkgconf
		[make]=make [cc]=gcc [git]=git [patch]=patch
		[libzip]=libzip [libusb-1.0]=libusb [openssl]=openssl [libcurl]=curl [zlib]=zlib [readline]=readline
	)
	local -a tools=(autoconf automake libtoolize pkg-config make cc patch)
	# git is only needed to fetch or to patch a checkout; --offline over unpacked tarballs (what the
	# Arch package does) uses GNU patch instead, so do not demand it there.
	[ "$OFFLINE" -eq 1 ] || tools+=(git)
	for tool in "${tools[@]}"; do
		command -v "$tool" >/dev/null 2>&1 || missing+=("$tool (package: ${pkg[$tool]})")
	done
	if command -v pkg-config >/dev/null 2>&1; then
		for mod in libzip libusb-1.0 openssl libcurl zlib readline; do
			pkg-config --exists "$mod" 2>/dev/null || missing+=("$mod headers (package: ${pkg[$mod]})")
		done
	fi
	if [ ${#missing[@]} -gt 0 ]; then
		printf 'build.sh: missing build dependencies:\n' >&2
		printf '  - %s\n' "${missing[@]}" >&2
		printf 'Install them (Arch: sudo pacman -S --needed base-devel git libzip libusb openssl curl zlib readline) and rerun.\n' >&2
		exit 1
	fi
}

# ---------------------------------------------------------------- sources
# ensure_source_fork NAME FORK_URL BRANCH BASE_COMMIT: clone the maintainer's fork branch (which must
# contain BASE_COMMIT in its history); apply_patch then verifies the tree is exactly base + patch.
ensure_source_fork() {
	local name=$1 url=$2 branch=$3 commit=$4 dir=$SRC/$1
	if [ -d "$dir/.git" ]; then
		note "source: existing checkout $(git -C "$dir" rev-parse --short HEAD 2>/dev/null) (fork mode: not moved)"
	elif [ -d "$dir" ]; then
		die "$dir exists but is not a git checkout; --from-forks needs one (or drop --from-forks)"
	else
		[ "$OFFLINE" -eq 0 ] || die "--offline: missing source tree $dir"
		note "source: cloning fork $url branch $branch"
		git clone -q --branch "$branch" -- "$url" "$dir" || die "cannot clone $url ($branch)"
	fi
	git -C "$dir" merge-base --is-ancestor "$commit" HEAD 2>/dev/null \
		|| die "$name: fork branch does not contain the pinned base commit $commit"
	[ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || warn "$dir has local modifications"
}

# ensure_source NAME URL COMMIT: leaves $SRC/NAME checked out at COMMIT (or accepts an unpacked tree)
ensure_source() {
	local name=$1 url=$2 commit=$3 dir=$SRC/$1 head
	if [ -d "$dir/.git" ]; then
		head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || die "$dir: not a usable git checkout"
		if [ "$head" = "$commit" ]; then
			note "source: existing checkout at $commit"
			return 0
		fi
		note "source: checkout is at ${head:0:12}, want ${commit:0:12}"
		[ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] \
			|| die "$dir is at the wrong commit and has local changes; move it away and rerun"
		if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
			[ "$OFFLINE" -eq 0 ] || die "--offline: $dir lacks commit $commit"
			git -C "$dir" fetch -q --depth 1 origin "$commit" 2>/dev/null \
				|| git -C "$dir" fetch -q origin \
				|| die "cannot fetch $commit for $name"
		fi
		git -C "$dir" checkout -q --detach "$commit" || die "cannot check out $commit in $dir"
		rm -f -- "$dir/Makefile"   # force a fresh configure after a commit change
		return 0
	fi
	if [ -d "$dir" ]; then
		[ -f "$dir/configure.ac" ] && [ -x "$dir/autogen.sh" ] \
			|| die "$dir exists but is not a $name source tree (no configure.ac/autogen.sh)"
		note "source: unpacked tree (no .git; commit cannot be verified, expected $commit)"
		return 0
	fi
	[ "$OFFLINE" -eq 0 ] || die "--offline: missing source tree $dir (expected $name at $commit)"
	note "source: fetching $url @ ${commit:0:12}"
	git init -q -- "$dir" || die "git init failed for $dir"
	git -C "$dir" remote add origin "$url" || die "git remote add failed for $dir"
	if git -C "$dir" fetch -q --depth 1 origin "$commit" 2>/dev/null; then
		git -C "$dir" checkout -q --detach FETCH_HEAD || die "checkout failed in $dir"
	else
		note "server refused a shallow fetch by commit; full clone"
		git -C "$dir" fetch -q origin || die "fetch failed for $name"
		git -C "$dir" checkout -q --detach "$commit" || die "commit $commit not found in $url"
	fi
	[ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$dir: HEAD is not $commit after checkout"
}

# apply_patch NAME PATCHFILE: idempotent; git apply inside a real checkout, GNU patch otherwise.
# NOTE: never run `git apply` in a non-repo directory that sits inside another repository - git then
# resolves paths against the outer repo and silently applies nothing while reporting success.
apply_patch() {
	local name=$1 patch=$2 dir=$SRC/$1 pf
	[ -n "$patch" ] || { note "patch: none"; return 0; }
	pf=$PATCHES/$patch
	[ -r "$pf" ] || die "missing patch $pf"
	if [ -d "$dir/.git" ]; then
		if git -C "$dir" apply --check -R "$pf" >/dev/null 2>&1; then
			note "patch: $patch already applied"
			return 0
		fi
		git -C "$dir" apply --check "$pf" \
			|| die "$patch does not apply cleanly to $dir (neither applied nor appliable; inspect with: git -C $dir status)"
		git -C "$dir" apply "$pf" || die "git apply failed for $patch"
		git -C "$dir" apply --check -R "$pf" >/dev/null 2>&1 || die "$patch: post-apply verification failed"
	else
		if (cd "$dir" && patch -p1 -R --dry-run -f -s <"$pf") >/dev/null 2>&1; then
			note "patch: $patch already applied"
			return 0
		fi
		(cd "$dir" && patch -p1 -N --dry-run -f -s <"$pf") >/dev/null 2>&1 \
			|| die "$patch does not apply cleanly to $dir"
		(cd "$dir" && patch -p1 -N -s <"$pf") || die "patch failed for $patch"
		(cd "$dir" && patch -p1 -R --dry-run -f -s <"$pf") >/dev/null 2>&1 || die "$patch: post-apply verification failed"
	fi
	note "patch: $patch applied"
}

# ---------------------------------------------------------------- build
# Mirrors the proven build exactly: same environment, same configure flags, same order.
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64"

configure_opts() {
	# prints one option per line for component $1
	case "$1" in
		libplist)         printf '%s\n' --without-cython ;;
		libirecovery)     printf '%s\n' "--with-udevrulesdir=$PREFIX/lib/udev/rules.d" ;;
		libimobiledevice) printf '%s\n' --without-cython --enable-debug-code ;;
		usbmuxd)          printf '%s\n' --without-systemd "--with-udevrulesdir=$PREFIX/lib/udev/rules.d" ;;
		*)                : ;;
	esac
}

build_component() {
	local name=$1 version=$2 dir=$SRC/$1 log=$BUILD/$1.log
	local -a opts=()
	mapfile -t opts < <(configure_opts "$name")
	: >"$log"
	cd -- "$dir" || die "cannot enter $dir"
	# A Makefile configured for another prefix (a previous checkout, a moved tree) must not be
	# reused: make install would silently target the old location and prefix/ would stay empty.
	if [ -f Makefile ]; then
		local configured
		configured=$(sed -n 's/^prefix = //p' Makefile | head -n 1)
		if [ "$configured" != "$PREFIX" ]; then
			note "configure: Makefile targets '${configured:-?}', not $PREFIX - reconfiguring"
			make distclean >>"$log" 2>&1 || true
			rm -f Makefile
		fi
	fi
	if [ ! -f Makefile ]; then
		note "configure: ./autogen.sh --prefix=$PREFIX ${opts[*]}"
		# RELEASE_VERSION feeds git-version-gen so --version matches the proven binaries
		# (a patched worktree would otherwise report -dirty; a tarball would have no version).
		if ! RELEASE_VERSION=$version ./autogen.sh --prefix="$PREFIX" "${opts[@]}" >>"$log" 2>&1; then
			tail -n 30 "$log" >&2
			die "$name: autogen/configure failed (full log: $log)"
		fi
	else
		note "configure: Makefile present, reusing"
	fi
	note "make -j$JOBS"
	if ! make -j"$JOBS" >>"$log" 2>&1; then
		tail -n 30 "$log" >&2
		die "$name: make failed (full log: $log)"
	fi
	if ! make install >>"$log" 2>&1; then
		tail -n 30 "$log" >&2
		die "$name: make install failed (full log: $log)"
	fi
	note "installed"
}

selected() {
	# selected NAME -> 0 if NAME is in --only (or --only unset)
	[ -z "$ONLY" ] && return 0
	case ",$ONLY," in
		*",$1,"*) return 0 ;;
		*) return 1 ;;
	esac
}

report() {
	local b out
	say "built binaries in $PREFIX"
	printf '    %-20s %s\n' "binary" "--version"
	printf '    %-20s %s\n' "--------------------" "---------"
	for b in bin/idevicerestore bin/irecovery bin/plistutil sbin/usbmuxd; do
		if [ -x "$PREFIX/$b" ]; then
			out=$("$PREFIX/$b" --version 2>&1 | head -n 1)
		else
			out="(not built)"
		fi
		printf '    %-20s %s\n' "$b" "$out"
	done
	note "logs: $BUILD/<component>.log"
}

main() {
	local name url commit version patch fork_url fork_branch
	preflight
	say "t1-revive vendored stack -> $PREFIX"
	note "sources: $SRC  jobs: $JOBS  offline: $OFFLINE  from-forks: $FROM_FORK"
	for name in $T1R_VENDOR_ORDER; do
		selected "$name" || continue
		url=$(ref "$name" UPSTREAM_URL); commit=$(ref "$name" BASE_COMMIT)
		version=$(ref "$name" VERSION); patch=$(ref "$name" PATCH)
		[ -n "$url" ] && [ -n "$commit" ] && [ -n "$version" ] || die "incomplete refs.env entry for $name"
		[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "refs.env: $name commit is not a full sha"
		say "$name @ ${commit:0:12} ($version)"
		fork_url=$(ref "$name" FORK_URL); fork_branch=$(ref "$name" FORK_BRANCH)
		if [ "$FROM_FORK" -eq 1 ] && [ -n "$fork_url" ]; then
			ensure_source_fork "$name" "$fork_url" "${fork_branch:-t1}" "$commit"
		else
			ensure_source "$name" "$url" "$commit"
		fi
		# In fork mode this is the verification that the branch is exactly base + patch:
		# "already applied" is the expected outcome; anything else fails loudly.
		apply_patch "$name" "$patch"
		build_component "$name" "$version"
	done
	report
}

main "$@"
