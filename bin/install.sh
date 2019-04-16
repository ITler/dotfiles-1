#!/usr/bin/env bash
# install.sh
#	This script installs my basic setup for a archlinux laptop.
#	Forked from @jessfraz
user_name=${2:-sd}
machine_name=${3:-thor}
disc=${4:-sdb}
tempdir="$(mktemp -d)"
hist="${tempdir}/history"
touch $hist
cleanup() {
    rm -rf "${tempdir}"
}
trap cleanup 0
error() {
    local parent_lineno="$1"
    local message="$2"
    local code="${3:-1}"
    if [[ -n "$message" ]] ; then
        echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
    else
        echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
    fi
    exit "${code}"
}
trap 'error ${LINENO}' ERR

setup_partitions() {
    local btrfs_partition=/dev/${disc}2
    local esp_partition=/dev/${disc}1
    local swap_partition=/dev/${disc}3
    local btrfs_label=${machine_name}
    cat <<-EOF
# Disk partioning for btrfs subvolumes with swap #

       +--------------------------+--------------------------+--------------------------+
       |ESP                       |System partition          |Swap partition            |
       |unencrypted               |LUKS-encrypted            |plain-encrypted           |
       |                          |                          |                          |
       |/boot/efi                 |/                         |[SWAP]                    |
       |/dev/${disc}1                 |/dev/${disc}2                 |/dev/${disc}3                 |
       |--------------------------+--------------------------+--------------------------+

## Create LUKS container
EOF
    ask cryptsetup -v --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-urandom --verify-passphrase luksFormat ${btrfs_partition}
    echo '## Unlock LUKS container'
    ask cryptsetup open ${btrfs_partition} crypt
    echo '## Format mapped device'
    ask mkfs.btrfs -L ${btrfs_label} /dev/mapper/crypt
    echo '## Mount mapped device'
    ask mount /dev/mapper/crypt /mnt
    cat <<-EOF
# Create btrfs subvolumes

- We will be using the following layout here

subvolid=5 (/dev/${disc}2)
      |
      ├── @ (mounted as /)
      |       |
      |       ├── /bin (directory)
      |       |
      |       ├── /home (mounted @home subvolume)
      |       |
      |       ├── /usr (directory)
      |       |
      |       ├── /.snapshots (mounted @snapshots subvolume)
      |       |
      |       ├── /var/cache/pacman/pkg (nested subvolume)
      |       |
      |       ├── ... (other directories and nested subvolumes)
      |
      ├── @snapshots (mounted as /.snapshots)
      |
      ├── @home (mounted as /home)
      |
      └── @... (additional subvolumes you wish to use as mount points)
EOF
  echo '## Create top-level subvolumes'
  ask btrfs subvolume create /mnt/@
	ask btrfs subvolume create /mnt/@snapshots
	ask btrfs subvolume create /mnt/@home
  echo '## Mount top-level subvolumes'
	ask umount /mnt
	ask mount -o compress=lzo,subvol=@ /dev/mapper/crypt /mnt
	ask mkdir /mnt/home
	ask mount -o compress=lzo,subvol=@home /dev/mapper/crypt /mnt/home
	ask mkdir /mnt/.snapshots
	ask mount -o compress=lzo,subvol=@snapshots /dev/mapper/crypt /mnt/.snapshots
  echo '## Create nested subvolumes'
  ask mkdir -p /mnt/var/cache/pacman
	ask btrfs subvolume create /mnt/var/cache/pacman/pkg
	ask mkdir -p /mnt/var
	ask btrfs subvolume create /mnt/var/tmp
  echo '## Mount ESP'
  ask mkdir /mnt/boot
	ask mkfs.fat -F32 ${esp_partition}
	ask mount ${esp_partition} /mnt/boot
	echo '## Install base and base-devel packages'
	ask pacstrap /mnt base base-devel btrfs-progs
  echo '## Chrooting into the new environment, continue with ./install.sh chroot'
  ask cp ./bin/install.sh /mnt/
  ask arch-chroot /mnt
}
chroot() {
  local hostname=${machine_name}
  local btrfs_partition=/dev/${disc}2
  local crypt_vol="${btrfs_partition}"
  local btrfs_label=${machine_name}
  local boot_uuid=$(blkid | grep /dev/${disc}1 | grep -o "UUID\S*" | head -1 | tr -d '"' | awk -F= '{print $NF}')
  local username=${user_name}
	echo '## Setup Time zone'
	ask ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
	ask hwclock --systohc
	echo '## Generate locales'
	ask sed -i -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' -e  's/^#de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
	ask sed -i '$ a LANG=de_DE.UTF-8' /etc/locale.conf
	ask locale-gen
	ask sed -i '$ a FONT=lat1-14' /etc/vconsole.conf
	ask sed -i '$ a FONT_MAP=8859-1' /etc/vconsole.conf
	echo '## Configuring mkinitcpio'
	ask sed -i -e 's/MODULES=()/MODULES=\(vfat\)/' \
	    -e 's#BINARIES=()#BINARIES=\(/usr/bin/btrfs\)#' \
	    -e 's#HOOKS=\(.*\)\(keyboard\)\(.*\)#HOOKS=\1\2 keymap encrypt\3#' \
	    /etc/mkinitcpio.conf
	ask mkinitcpio -p linux
	echo '## Set root password'
	ask passwd
	echo '## Add new user then update password'
  ask useradd -m -G users,wheel,video ${username}
  ask passwd ${username}
	setup_sudo
	echo '## install other neccessary packages'
  ask pacman -S vim git sudo
	echo '## Configure Bootloader (using systemd-boot)'
	ask bootctl --path=/boot install
  ask mkdir -p /boot/loader/entries
  ask touch /boot/loader/entries/arch.conf
	ask sed -i '$ a title Arch Linux' /boot/loader/entries/arch.conf
	ask sed -i '$ a linux /vmlinuz-linux' /boot/loader/entries/arch.conf
	ask sed -i '$ a initrd /initramfs-linux.img' /boot/loader/entries/arch.conf
	ask sed -i "$ a options cryptdevice=${crypt_vol}:crypt root=/dev/mapper/crypt rootflags=subvol=@ rw quiet" /boot/loader/entries/arch.conf
  echo '## Install wireless networking tools (wifi-menu)'
  ask pacman -S wpa_supplicant dialog
  echo '## Update fstab (using btrfs_label)'
	ask sed -i "$ a UUID=${boot_uuid} /boot vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro 0 2" /etc/fstab
	ask sed -i "$ a LABEL=${btrfs_label} / btrfs rw,defaults,noatime,compress=lzo,ssd,space_cache,subvol=/@ 0 0" /etc/fstab
	ask sed -i "$ a LABEL=${btrfs_label} /home btrfs rw,defaults,noatime,compress=lzo,ssd,space_cache,subvol=/@home 0 0" /etc/fstab
	ask sed -i "$ a LABEL=${btrfs_label} /.snapshots btrfs rw,defaults,noatime,compress=lzo,ssd,space_cache,subvol=/@snapshots 0 0" /etc/fstab
  echo '## Finished in chroot Chrooting. Please reboot then continue with ./install.sh desktop'
}

setup_sudo() {
    get_user
	  echo '## add user to sudoers'
	  ask "gpasswd -a ${TARGET_USER} wheel"
	  echo '## add user to systemd groups'
	  ask "gpasswd -a ${TARGET_USER} systemd-journal"
	  ask "gpasswd -a ${TARGET_USER} systemd-network"
    ask sed -i "$ a ${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" /etc/sudoers
    ask sed -i "$ a ${TARGET_USER} ALL=NOPASSWD: /sbin/ifconfig, /sbin/ifup, /sbin/ifdown, /sbin/ifquery" /etc/sudoers
	  echo '## setup downloads folder as tmpfs'
	  ask mkdir -p "/home/$TARGET_USER/Downloads"
	  ask sed -i "$ a tmpfs  /home/${TARGET_USER}/Downloads  tmpfs  nodev,nosuid,size=2G  0  0" /etc/fstab
}
desktop() {
	echo '## install CPU microcode (for intel)'
	ask pacman -S intel-ucode
	echo '## Set date using ntp'
	ask timedatectl set-ntp true
	echo '## Set Hostname'
  ask hostnamectl set-hostname "${hostname}"
	ask sudo pacman -S zsh
	ask curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh > "${tempdir}/oh-my-zsh.sh"

	ask sh "${tempdir}/oh-my-zsh.sh"
	echo '## Install aurman'
  echo 'import the GPG key of aurman maintainer'
  ask gpg --recv-key 0x465022E743D71E39
  ask curl -fsSL https://aur.archlinux.org/cgit/aur.git/snapshot/aurman.tar.gz | tar -v -C "${tempdir}" -xz
  ask cd "${tempdir}"/aurman && makepkg -s PKGBUILD
  ask sudo pacman -U aurman*tar.xz
	local pkgs=(
		acpi
		aspell-de
		aspell-en
		avahi
		bluez
		bluez-libs
		bluez-utils
		emacs
		fasd
		feh
		gtk2
		nss-mdns
		openssh
		pass
		pavucontrol
		pulseaudio
		pulseaudio-bluetooth
		python-pip
		python-virtualenv
		qutebrowser
		rofi
		rofi-pass
		rsync
		sysstat
		termite
		the_silver_searcher
		xdotool
		xorg-server
		xorg-server-xwayland
		xorg-xinit
		zathura
		zathura-pdf-poppler
    grim-git
    keybase
    mako
    npm
    plantuml
    slurp-git
    spotify
    sway-git
    waybar-git
	)
	ask aurman -s "${pkgs[@]}"
  install_fonts
  local gopkgs=(
      github.com/golang/lint/golint
      # for command autocompletion
      github.com/nsf/gocode
      # for analysing symbols
      github.com/rogpeppe/godef
      golang.org/x/review/git-codereview
      golang.org/x/tools/cmd/cover
      # for automatic imports
      golang.org/x/tools/cmd/goimports
      golang.org/x/tools/cmd/gorename
      golang.org/x/tools/cmd/guru
  )
  ask go get "${gopkgs[@]}"
  ask pip install virtualenvwrapper
  symlink_dotfiles
  install_spacemacs
}
symlink_dotfiles() {
    ask make
}
install_spacemacs() {
    local pkgs=(
		    ack
		    emacs
		    isync
		    mu
		    nodejs
		    npm
        # ghostscript is for Docview
        ghostscript
        # graphviz for plantuml
        graphviz
    )
    local npm_modules=(
        babel-eslint
        eslint
        eslint-plugin-react
        js-beautify
        tern
    )
	  ask cp .spacemacs "$HOME"/
	  ask git clone https://github.com/syl20bnr/spacemacs ~/.emacs.d
	  ask sudo pacman -S "$pkgs[@]"
	  ask npm install -g "$npm_modules[@]"
	  cat <<-EOF
# General

- now after loading spacemacs and letting it install all the necessary
packages run the following commands:

:spacemacs/recompile-elpa

# IRC (aka. ERC)

- Also, the erc layer requires that you have a `.authinfo.gpg` file in
your home directory specifying the connection parameters for IRC
servers (or IRC bouncer) you want to connect to. It looks something
like this:

chine smtp.gmail.com login foo.bar@example.com port 587 password superSecret!


# Email

- Make sure you edit your ~/.mbsyncrc file accordingly

- After this fetch your email from the IMAP Server
> mbsync -a

- Don't forget to update the mu database by running the following command
> mu index --maildir ~/q/mail/Personal

# PDF Tools

- Make sure to run `pdf-tools-install` to properly install pdf-tools
EOF
}

install_paperless() {
    local paperless_dir="~/pc/prj/paperless"
    local consumption_dir="~/pc/prj/paperless/inbox"
    local pkgs=(
       # for crappy HP products
       hplip
       python-gobject
       python-pillow
       sane
       tesseract-data-deu
       tesseract-data-eng
       unpaper
    )
    # install project dependencies
    ask sudo pacman -S "${pkgs[@]}"
    ask git clone https://github.com/danielquinn/paperless.git "${paperless_dir}"
    # you might have to run the following
    # to download necessary HP plugins
    ask hp-plugin
    # create project specific virtualenv
    ask mkproject -p python3 paperless
    ask sudo cp "${paperless_dir}"/paperless.conf.example /etc/paperless.conf
    ask sudo sed -i -e 's#PAPERLESS_CONSUMPTION_DIR=""#PAPERLESS_CONSUMPTION_DIR="/home/sd/pc/prj/paperless/inbox"#' /etc/paperless.conf
    # Initialise the SQLite database
    ask "${paperless_dir}"/src/manage.py migrate
    # Create a user for your Paperless instance and follow the prompts
    ask "${paperless_dir}"/src/manage.py createsuperuser
}

install_fonts() {
    local pkgs=(
        adobe-source-code-pro-fonts
        ttf-dejavu
        ttf-font-awesome
        ttf-liberation
        ttf-linux-libertine
        ttf-opensans
    )
    ask aurman -S "${pkgs[@]}"
}
install_latex() {
    local pkgs=(
	      rubber
		    biber
        texlive-core
        texlive-latexextra
        texlive-bibtexextra
        texlive-fontsextra
        texlive-formatsextra
        pygmentize
    )
    ask sudo pacman -S "${pkgs[@]}"
}
ask() {
    (
        cmd="$@"
	      echo "+" "$@"
        echo -e "${cmd}" > "${hist}"
	      read doesNotConsent
	      if [[ ! -z "$doesNotConsent" ]]
	      then
            vi $hist && bash $hist
	      else
            # Assume user consents when enter is pressed
            exec "$@"
	      fi
    )
 }

check_is_sudo() {
	if [ "$EUID" -ne 0 ]; then
		echo "Please run as root."
		exit
	fi
}


# Choose a user account to use for this installation
get_user() {
	if [ -z "${TARGET_USER-}" ]; then
		mapfile -t options < <(find /home/* -maxdepth 0 -printf "%f\\n" -type d)
		# if there is only one option just use that user
		if [ "${#options[@]}" -eq "1" ]; then
			readonly TARGET_USER="${options[0]}"
			echo "Using user account: ${TARGET_USER}"
			return
		fi

		# iterate through the user options and print them
		PS3='Which user account should be used? '

		select opt in "${options[@]}"; do
			readonly TARGET_USER=$opt
			break
		done
	fi
}

usage() {
  echo -e "install.sh\\n\\tThis script installs my basic setup for an archlinux laptop\\n"
  echo "Usage:"
  echo -e "\\tpartitioning      (Step 1: setup partitioning with btrfs and LUKS)"
  echo -e "\\tchroot            (Step 2: setup bootstrap enviroment to chroot to)"
  echo -e "\\tdesktop           (Step 3: setup desktop and sway window manager)"
}

main() {
	local cmd=$1

	if [[ -z "$cmd" ]]
	then
		usage
		exit 1
	elif [[ $cmd == "partitioning" ]]; then
		setup_partitions
	elif [[ $cmd == "chroot" ]]; then
		get_user
		check_is_sudo
		chroot
  elif [[ $cmd == "desktop" ]]; then
		get_user
		desktop
 	else
		  usage
  fi
}

main "$@"
