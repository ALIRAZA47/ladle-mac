#!/bin/bash
#
# Installs Ladle, the free download manager for Mac, and sets up its Chrome extension.
#
#   curl -fsSL https://ladle.alirazakhan.me/install.sh | bash
#
# Options go after `bash -s --`, as in `... | bash -s -- --app-only`:
#
#   --app-only        Install Ladle without the Chrome extension.
#   --extension-only  Set up the Chrome extension only.
#   --browser NAME    Where the extension goes: chrome, arc, edge, brave or none. Without it, the
#                     script uses the one you have, or asks when you have several.
#   --dir FOLDER      Install Ladle in FOLDER instead of /Applications.
#   --no-open         Don't open Ladle or the browser at the end.
#
# What it does, from the latest release at https://github.com/ALIRAZA47/ladle-mac/releases:
#
#   1. Downloads Ladle.dmg, copies Ladle into /Applications (once you've quit an older copy),
#      checks its code signature and opens it. Skipped when that version is already installed.
#      macOS asks you to approve apps that a browser downloaded, and nothing here goes through a
#      browser, so Ladle opens straight away.
#   2. Downloads Ladle-Chrome-Extension.zip into ~/Library/Application Support/Ladle, puts that
#      folder's path on the clipboard and opens your browser's extensions page. Browsers only let
#      you add a developer-mode extension yourself, so you finish with Load unpacked.
#
# Run it again to update the extension; Ladle updates itself. It needs macOS 14 Sonoma or later.

set -euo pipefail

REPO="ALIRAZA47/ladle-mac"
DOCS="https://ladle.alirazakhan.me/docs/getting-started"
EXTENSION_DIR="$HOME/Library/Application Support/Ladle/Ladle-Chrome-Extension"
# Once the extension is in the Chrome Web Store, put its listing here, as in
# site/src/config/stores.mjs: the script then opens the store instead of setting up this copy.
CHROME_STORE_URL=""

TMP=""
MOUNT=""
STAGED=""
OLD_APP=""
APP=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	BOLD=$'\033[1m' DIM=$'\033[2m' ACCENT=$'\033[38;5;208m' RED=$'\033[31m' RESET=$'\033[0m'
else
	BOLD="" DIM="" ACCENT="" RED="" RESET=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$ACCENT" "$RESET" "$BOLD" "$*" "$RESET"; }
note() { printf '    %s\n' "$*"; }
ok() { printf '    %s✓%s %s\n' "$ACCENT" "$RESET" "$*"; }
die() {
	printf '\n%sStopped:%s %s\n' "$RED" "$RESET" "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Installs Ladle and sets up its Chrome extension, from the latest release on GitHub.

  curl -fsSL https://ladle.alirazakhan.me/install.sh | bash
  curl -fsSL https://ladle.alirazakhan.me/install.sh | bash -s -- [options]

Options:
  --app-only        Install Ladle without the Chrome extension.
  --extension-only  Set up the Chrome extension only.
  --browser NAME    Where the extension goes: chrome, arc, edge, brave or none.
  --dir FOLDER      Install Ladle in FOLDER instead of /Applications.
  --no-open         Don't open Ladle or the browser at the end.
  -h, --help        Show this.

More: $DOCS/install/#install-from-terminal
EOF
}

# ~/… instead of /Users/name/… in messages.
tildify() {
	case "$1" in
		"$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
		*) printf '%s' "$1" ;;
	esac
}

# Someone is at the keyboard. The script's own input is curl's output, so answers come from the
# terminal.
interactive() { { : < /dev/tty; } 2> /dev/null; }

detach() {
	if [ -n "$MOUNT" ]; then
		hdiutil detach -quiet "$MOUNT" 2> /dev/null || hdiutil detach -quiet -force "$MOUNT" 2> /dev/null || true
		MOUNT=""
	fi
}

cleanup() {
	detach
	if [ -n "$STAGED" ]; then rm -rf "$STAGED"; fi
	# Interrupted while swapping in the new copy: put the old one back.
	if [ -n "$OLD_APP" ] && [ -e "$OLD_APP" ] && [ ! -e "$APP" ]; then mv "$OLD_APP" "$APP"; fi
	if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}

download() { # url file
	if [ -t 2 ]; then
		curl -fL --progress-bar --retry 3 --retry-delay 2 -o "$2" "$1"
	else
		curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"
	fi
}

# The latest release's download folder, like https://github.com/ALIRAZA47/ladle-mac/releases/download/v1.2.0.
release_base() {
	if [ -n "${LADLE_DOWNLOAD_BASE:-}" ]; then
		# For tests: a folder (file:// or https://) with a release's Ladle.dmg and Ladle-Chrome-Extension.zip.
		printf '%s\n' "${LADLE_DOWNLOAD_BASE%/}"
		return
	fi
	local answer code url
	# github.com/…/releases/latest redirects to the newest release's page, which ends in its tag.
	answer=$(curl -sSL -o /dev/null -w '%{http_code} %{url_effective}' "https://github.com/$REPO/releases/latest") \
		|| die "Couldn't reach GitHub. Check your internet connection, then try again."
	code=${answer%% *}
	url=${answer#* }
	case "$code ${url##*/}" in
		"200 v"[0-9]*) printf 'https://github.com/%s/releases/download/%s\n' "$REPO" "${url##*/}" ;;
		*) die "Couldn't find Ladle's latest release on GitHub (it answered $code). See https://github.com/$REPO/releases" ;;
	esac
}

app_version() { plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2> /dev/null || true; }

ladle_running() { pgrep -x Ladle > /dev/null 2>&1; }

wait_for_quit() {
	ladle_running || return 0
	interactive || die "Ladle is open. Quit it, then run this again."
	note "Ladle is open. Quit it (Ladle › Quit Ladle, or ⌘Q) and the install carries on."
	local waited=0
	while ladle_running; do
		sleep 1
		waited=$((waited + 1))
		[ "$waited" -lt 300 ] || die "Ladle is still open. Quit it, then run this again."
	done
	ok "Ladle quit"
}

install_app() { # base folder
	local base=$1 dir=$2 tag installed version
	if [ -z "$dir" ]; then
		dir=/Applications
		if [ ! -w "$dir" ]; then
			dir="$HOME/Applications"
			note "This account can't add apps to /Applications, so Ladle goes in ~/Applications."
		fi
	fi
	mkdir -p "$dir" 2> /dev/null || die "Couldn't create $(tildify "$dir")."
	[ -w "$dir" ] || die "This account can't add apps to $(tildify "$dir")."
	APP="$dir/Ladle.app"

	tag=${base##*/}
	installed=$(app_version "$APP")
	if [ -n "$installed" ] && [ "v$installed" = "$tag" ]; then
		step "Ladle"
		ok "Ladle $installed is already in $(tildify "$dir") and up to date"
		return
	fi

	step "Downloading Ladle"
	download "$base/Ladle.dmg" "$TMP/Ladle.dmg" \
		|| die "Couldn't download Ladle.dmg. Check your internet connection, then try again."

	step "Installing Ladle in $(tildify "$dir")"
	MOUNT="$TMP/mount"
	mkdir "$MOUNT"
	if ! hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$TMP/Ladle.dmg" > /dev/null; then
		MOUNT=""
		die "Couldn't open Ladle.dmg, so the download may be damaged. Try again."
	fi
	[ -d "$MOUNT/Ladle.app" ] || die "Ladle.dmg doesn't have Ladle in it."

	wait_for_quit

	STAGED="$dir/.Ladle-installing.app"
	rm -rf "$STAGED"
	ditto "$MOUNT/Ladle.app" "$STAGED" || die "Couldn't copy Ladle into $(tildify "$dir")."
	detach
	# curl doesn't mark what it downloads as quarantined, which is why macOS has nothing to ask
	# on the first launch. Clear the mark anyway, in case something else added it.
	xattr -dr com.apple.quarantine "$STAGED" 2> /dev/null || true
	codesign --verify --deep --strict "$STAGED" 2> /dev/null \
		|| die "Ladle's code signature didn't check out, so it wasn't installed. Try again."

	if [ -e "$APP" ]; then
		OLD_APP="$dir/.Ladle-old.app"
		rm -rf "$OLD_APP"
		mv "$APP" "$OLD_APP" || die "Couldn't replace $(tildify "$APP"). Move it to the Trash, then run this again."
	fi
	mv "$STAGED" "$APP"
	STAGED=""
	if [ -n "$OLD_APP" ]; then
		rm -rf "$OLD_APP" 2> /dev/null || note "Couldn't remove the old copy at $(tildify "$OLD_APP"); move it to the Trash."
		OLD_APP=""
	fi
	version=$(app_version "$APP")
	ok "Installed Ladle${version:+ $version} in $(tildify "$dir")"
}

install_extension() { # base
	local version
	step "Downloading the Chrome extension"
	download "$1/Ladle-Chrome-Extension.zip" "$TMP/extension.zip" \
		|| die "Couldn't download Ladle-Chrome-Extension.zip. Check your internet connection, then try again."
	mkdir "$TMP/extension"
	ditto -x -k "$TMP/extension.zip" "$TMP/extension" || die "Couldn't unzip the Chrome extension."
	[ -f "$TMP/extension/Ladle-Chrome-Extension/manifest.json" ] \
		|| die "The Chrome extension's zip doesn't hold a Ladle-Chrome-Extension folder."
	mkdir -p "$(dirname "$EXTENSION_DIR")"
	# The same folder every time, so a browser that loaded it picks up the new version on reload.
	rm -rf "$EXTENSION_DIR"
	mv "$TMP/extension/Ladle-Chrome-Extension" "$EXTENSION_DIR"
	version=$(plutil -extract version raw -o - "$EXTENSION_DIR/manifest.json" 2> /dev/null || true)
	ok "Put the extension${version:+ $version} in $(tildify "$EXTENSION_DIR")"
}

browser_app() {
	case "$1" in
		chrome) echo "Google Chrome" ;;
		arc) echo "Arc" ;;
		edge) echo "Microsoft Edge" ;;
		brave) echo "Brave Browser" ;;
	esac
}

browser_page() {
	case "$1" in
		chrome) echo "chrome://extensions" ;;
		arc) echo "arc://extensions" ;;
		edge) echo "edge://extensions" ;;
		brave) echo "brave://extensions" ;;
	esac
}

has_browser() {
	local name
	name=$(browser_app "$1")
	[ -d "/Applications/$name.app" ] || [ -d "$HOME/Applications/$name.app" ]
}

# Prints chrome, arc, edge, brave or none.
pick_browser() {
	local found="" count=0 b i answer
	for b in chrome arc edge brave; do
		if has_browser "$b"; then
			found="$found $b"
			count=$((count + 1))
		fi
	done
	found=${found# }
	if [ "$count" -eq 0 ]; then
		echo none
		return
	fi
	if [ "$count" -eq 1 ] || ! interactive; then
		echo "${found%% *}"
		return
	fi
	{
		printf '\n    Which browser should get the extension?\n'
		i=1
		for b in $found; do
			printf '      %d) %s\n' "$i" "$(browser_app "$b")"
			i=$((i + 1))
		done
		printf '      %d) None for now\n' "$i"
		printf '    Type a number and press Return [1]: '
	} > /dev/tty
	read -r answer < /dev/tty || answer=""
	case "${answer:-1}" in
		*[!0-9]*) echo "${found%% *}" ;;
		*)
			if [ "${answer:-1}" -ge 1 ] && [ "${answer:-1}" -le "$count" ]; then
				echo "$found" | cut -d ' ' -f "${answer:-1}"
			else
				echo none
			fi
			;;
	esac
}

guide_extension() { # browser open
	local browser=$1 open_it=$2 name page
	if [ "$browser" = none ]; then
		step "Add the extension to your browser"
		note "Open your browser's extensions page (chrome://extensions in Chrome), turn on"
		note "Developer mode, click Load unpacked and choose this folder:"
		note "$(tildify "$EXTENSION_DIR")"
		return
	fi
	name=$(browser_app "$browser")
	page=$(browser_page "$browser")
	printf '%s' "$EXTENSION_DIR" | pbcopy 2> /dev/null || true
	if [ "$open_it" = 1 ]; then open -a "$name" "$page" 2> /dev/null || open -a "$name" 2> /dev/null || true; fi
	step "Add the extension to $name"
	note "1. On $page, turn on Developer mode."
	note "2. Click Load unpacked. Press ⌘⇧G, then ⌘V to paste the folder (it's on your"
	note "   clipboard), press Return and click Select."
	note "Already added? Click the reload button on Ladle's card to use this version."
}

store_extension() { # browser open
	local name
	if [ "$1" = none ]; then
		step "Add the extension to your browser"
		note "Get it from the Chrome Web Store: $CHROME_STORE_URL"
		return
	fi
	name=$(browser_app "$1")
	if [ "$2" = 1 ]; then open -a "$name" "$CHROME_STORE_URL" 2> /dev/null || true; fi
	step "Add the extension to $name"
	note "On its Chrome Web Store page, click Add to Chrome: $CHROME_STORE_URL"
}

main() {
	local want_app=1 want_extension=1 browser="" dir="" open_it=1 base
	while [ $# -gt 0 ]; do
		case "$1" in
			--app-only) want_extension=0 ;;
			--extension-only) want_app=0 ;;
			--browser)
				[ $# -ge 2 ] || die "--browser needs a name: chrome, arc, edge, brave or none."
				browser=$2
				shift
				;;
			--browser=*) browser=${1#*=} ;;
			--dir)
				[ $# -ge 2 ] || die "--dir needs a folder."
				dir=$2
				shift
				;;
			--dir=*) dir=${1#*=} ;;
			--no-open) open_it=0 ;;
			-h | --help)
				usage
				return 0
				;;
			*) die "There's no $1 option. Run it with --help to see the options." ;;
		esac
		shift
	done
	[ "$want_app$want_extension" != 00 ] || die "Use --app-only or --extension-only, not both."
	case "$browser" in
		"" | chrome | arc | edge | brave | none) ;;
		*) die "--browser takes chrome, arc, edge, brave or none, not $browser." ;;
	esac

	[ "$(uname -s)" = Darwin ] || die "Ladle is a Mac app, so this script runs on macOS."
	local macos
	macos=$(sw_vers -productVersion)
	[ "${macos%%.*}" -ge 14 ] 2> /dev/null || die "Ladle needs macOS 14 Sonoma or later, and this Mac has macOS $macos."

	TMP=$(mktemp -d "${TMPDIR:-/tmp}/ladle-install.XXXXXX")
	trap cleanup EXIT
	trap 'exit 130' INT TERM

	printf '%sLadle%s %s· the free download manager for Mac%s\n' "$BOLD$ACCENT" "$RESET" "$DIM" "$RESET"
	base=$(release_base)
	case "${base##*/}" in v[0-9]*) note "Latest release: ${base##*/}" ;; esac

	if [ "$want_app" = 1 ]; then install_app "$base" "$dir"; fi
	if [ "$want_extension" = 1 ] && [ -z "$CHROME_STORE_URL" ]; then install_extension "$base"; fi

	if [ "$want_app" = 1 ] && [ "$open_it" = 1 ]; then open "$APP" 2> /dev/null || true; fi
	if [ "$want_app" = 0 ] && [ ! -d /Applications/Ladle.app ] && [ ! -d "$HOME/Applications/Ladle.app" ]; then
		note "The extension hands downloads to Ladle, so install Ladle too: run this without --extension-only."
	fi

	if [ "$want_extension" = 1 ]; then
		if [ -z "$browser" ]; then browser=$(pick_browser); fi
		if [ -n "$CHROME_STORE_URL" ]; then
			store_extension "$browser" "$open_it"
		else
			guide_extension "$browser" "$open_it"
		fi
	fi

	step "Done"
	if [ "$want_app" = 1 ]; then note "Ladle updates itself. Run this again any time to update the extension too."; fi
	note "Help: $DOCS/install/"
}

main ${1+"$@"}
