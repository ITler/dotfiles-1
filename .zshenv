typeset -U path

path=(
/bin
/sbin
/usr/bin
/usr/bin/vendor_perl
/usr/sbin
/usr/local/bin
"$HOME"/pc/code/go/bin
"$HOME"/bin
"$HOME"/.npm-global/bin
"$SNAP_PATH"
"$path")

export PATH
# Load the shell dotfiles, and then some:
# * ~/.path can be used to extend `$PATH`.
# * ~/.extra can be used for other settings you don’t want to commit.
for file in ~/.{aliases,functions,extra,exports}; do
	  if [[ -r "$file" ]] && [[ -f "$file" ]]; then
		    # shellcheck source=/dev/null
		    source "$file"
	  fi
done
unset file
