#!/bin/bash
# install.sh
#	This script installs my basic setup for a archlinux laptop.
#	Forked from @jessfraz
tempdir="$(mktemp -d)"
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

check_is_sudo() {
	if [ "$EUID" -ne 0 ]; then
		echo "Please run as root."
		exit
	fi
}
setup_chroot() {
	  "$(pwd)"/arch-bootstrap /mnt
    cat <<-EOF
	# Install base and base-devel packages
	pacstrap /mnt base base-devel btrfs-progs

        # Chroot into the new environment
        arch-chroot /mnt
	 
	# Setup Time zone 
	ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
	hwclock --systohc        

	# Generate locales
       
	sed -i -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' -e  's/^#de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8' /etc/locale.gen
	echo "LANG=de_DE.UTF-8" > /etc/locale.conf
	locale-gen
	cat <<-EOFF > /etc/vconsole.conf
	FONT=lat1-14
	FONT_MAP=8859-1
	EOFF

	# Set date using ntp
	timedatectl set-ntp true

	# Set Hostname
	echo "myhostname" > /etc/hostname
	cat <<-EOFF > /etc/hosts 
	127.0.0.1 localhost
	::1 localhost 
	127.0.1.1 thor.localdomain thor
	EOFF

	# Configuring mkinitcpio

	sed -i -e 's/MODULES=()/MODULES=\(vfat\)/' \
	    -e 's#BINARIES=()#BINARIES=\(/usr/bin/btrfs\)#' \
	    -e 's#HOOKS=\(.*\)\(keyboard\)\(.*\)#HOOKS=\1\2 keymap encrypt\3#' \
	    /etc/mkinitcpio.conf
	mkinitcpio -p linux


	# Set root password
	
	passwd

	# CPU microcode (for intel)

	pacman -S intel-ucode

	# Configure Bootloader (systemd-boot)

	bootctl --path=/boot install

	cat <<-EOFF > /boot/loader/entries/arch.conf
	title Arch Linux
	linux /vmlinuz-linux
	initrd /initramfs-linux.img
	options cryptdevice=/dev/sdb2:crypt root=/dev/mapper/crypt rootflags=subvol=@ rw quiet	
	EOFF

	## Create keyfile (avoid typing password for GRUB)
	
	- Plugin the external usb thumb drive

	mkdir /tmp/usb
	mount /dev/disk/by-label/<usb key label> /tmp/usb
	dd bs=512 count=4 if=/dev/urandom of=/tmp/usb/keys/thor.bin
	chmod 600 /tmp/usb/keys/thor.bin 

	## Add keyfile as LUKS key 

	cryptsetup luksAddKey /dev/sdb2 /tmp/usb/keys/thor.bin

	# Configure networking

	pacman -S wpa_supplicant dialog

	# Edit fstab

	cat <<-EOFF > /etc/fstab
	UUID=5DC8-B8EF /boot vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro 0 2
	UUID=a5ce3900-5885-4eed-b568-761ecb624145 / btrfs rw,defaults,noatime,compress=lzo,ssd,space_cache,subvol=/@ 0 0
	UUID=a5ce3900-5885-4eed-b568-761ecb624145 /home btrfs rw,defaults,noatime,compress=lzo,ssd,space_cache,subvol=/@home 0 0
	UUID=a5ce3900-5885-4eed-b568-761ecb624145 /.snapshots btrfs rw,defaults,noatime,compress=lzo,ssd,space_cache,subvol=/@snapshots 0 0
	UUID=a5ce3900-5885-4eed-b568-761ecb624145 /var/cache/pacman/pkg btrfs rw,defaults,noatime,compress=lzo,ssd,space_cache,subvol=/@/var/cache/pacman/pkg 0 0
	UUID=a5ce3900-5885-4eed-b568-761ecb624145 /var/tmp btrfs rw,defaults,noatime,compress=lzo,ssd,space_cache,subvol=/@/var/tmp 0 0
	UUID=bf366161-7917-4d35-84ac-28d3dc46ea75 none swap defaults 0 0
	EOFF

	EOF
}
	

setup_partitions() {
	cat <<-EOF
	# Disk partioning for btrfs subvolumes with swap #
	
        +--------------------------+--------------------------+--------------------------+
        |ESP                       |System partition          |Swap partition            |
        |unencrypted               |LUKS-encrypted            |plain-encrypted           |
        |                          |                          |                          |
        |/boot/efi                 |/                         |[SWAP]                    |
        |/dev/sdb1                 |/dev/sdb2                 |/dev/sdb3                 |
        |--------------------------+--------------------------+--------------------------+

	## Create LUKS container

	cryptsetup -v --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-urandom --verify-passphrase luksFormat /dev/sdb2


	## Unlock LUKS container

	cryptsetup open /dev/sdb2 crypt

	## Format mapped device

	mkfs.btrfs -L <label> /dev/mapper/crypt

	## Mount mapped device

	mount /dev/mapper/crypt /mnt

	# Create btrfs subvolumes

	- We will be using the following layout here

	subvolid=5 (/dev/sdb2)
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

	## Create top-level subvolumes

	btrfs subvolume create /mnt/@
	btrfs subvolume create /mnt/@snapshots
	btrfs subvolume create /mnt/@home

	## Mount top-level subvolumes

	umount /mnt
	mount -o compress=lzo,subvol=@ /dev/mapper/crypt /mnt
	mkdir /mnt/home
	mount -o compress=lzo,subvol=@home /dev/mapper/crypt /mnt/home
	mkdir /mnt/.snapshots
	mount -o compress=lzo,subvol=@snapshots /dev/mapper/crypt /mnt/.snapshots

	## Create nested subvolumes
	mkdir -p /mnt/var/cache/pacman
	btrfs subvolume create /mnt/var/cache/pacman/pkg
	mkdir -p /var
	btrfs subvolume create /mnt/var/tmp	
	
	## Mount ESP
	mkdir /mnt/boot 
	mkfs.fat -F32 /dev/sd1
	mount /dev/sdb1 /mnt/boot

	Now continue on with ./install.sh chroot
	EOF
}

# sets up archlinux mirrorlist
setup_sources() {
	rankmirrors -n 6 /etc/pacman.d/mirrorlist
}

# setup sudo for a user
# because fuck typing that shit all the time
# just have a decent password
# and lock your computer when you aren't using it
# if they have your password they can sudo anyways
# so its pointless
# i know what the fuck im doing ;)
setup_sudo() {
	# add user to sudoers
	gpasswd -a "$TARGET_USER" wheel

	# add user to systemd groups
	# then you wont need sudo to view logs and shit
	gpasswd -a "$TARGET_USER" systemd-journal
	gpasswd -a "$TARGET_USER" systemd-network

	# add go path to secure path
	{ \
		echo -e "Defaults	secure_path=\"/usr/local/go/bin:/home/${USERNAME}/.go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\""; \
		echo -e 'Defaults	env_keep += "ftp_proxy http_proxy https_proxy no_proxy GOPATH EDITOR"'; \
		echo -e "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL"; \
		echo -e "${TARGET_USER} ALL=NOPASSWD: /sbin/ifconfig, /sbin/ifup, /sbin/ifdown, /sbin/ifquery"; \
	} >> /etc/sudoers

	# setup downloads folder as tmpfs
	# that way things are removed on reboot
	# i like things clean but you may not want this
	mkdir -p "/home/$TARGET_USER/Downloads"
	echo -e "\\n# tmpfs for downloads\\ntmpfs\\t/home/${TARGET_USER}/Downloads\\ttmpfs\\tnodev,nosuid,size=2G\\t0\\t0" >> /etc/fstab
}


# installs base packages
base() {

	pacman -Syu

	pacman -S \
		vim \
		git \
		sudo

	setup_sudo

	#install_docker
}

desktop() {
	 
	# install desktop relevant packages
	sudo pacman -S zsh
	curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh > /tmp/oh-my-zsh.sh

	sh /tmp/oh-my-zsh.sh
	local pkgs=(
		  aspell-de
		  aspell-en
		  avahi
		  bluez
		  bluez-libs
		  bluez-utils
		  dunst
		  fasd
		  feh
		  gtk2
		  i3
		  i3lock
		  i3status
		  lxdm
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
		  rsync
		  rxvt-unicode
		  scrot
		  sysstat acpi
		  xdotool
		  xorg-server
		  xorg-xinit
		  zathura
		  zathura-pdf-poppler
  )
  sudo pacman -S "${pkgs[@]}"
  pip install virtualenvwrapper
  # enable display manager
  systemctl enable lxdm
  sed -i -e 's/#autologin=.*$/autologin=sd/'
  sed -i -e 's;#session=.*$;session=/usr/bin/i3;'
  cat <<-EOFF >> /etc/lxdm/PostLogin
/usr/bin/setxkbmap us altgr-intl -option caps:escape
/usr/bin/xset r rate 200 50
EOFF
	install_fonts
	install_keybase
	install_rofi_pass
}
install_utils() {
    # import the GPG key of aurman maintainer
    gpg --recv-key 0x465022E743D71E39
    curl -fsSL https://aur.archlinux.org/cgit/aur.git/snapshot/aurman.tar.gz | tar -v -C "${tempdir}" -xz
    cd "${tempdir}"/aurman && makepkg -s PKGBUILD
    sudo pacman -U aurman*tar.xz
}
install_goodies() {
    local pkgs=( spotify )
    local gopkgs=(
        github.com/golang/lint/golint
	      golang.org/x/tools/cmd/cover
	      golang.org/x/review/git-codereview
	      golang.org/x/tools/cmd/goimports
	      golang.org/x/tools/cmd/gorename
	      golang.org/x/tools/cmd/guru
    )
    go get "${pkgs[@]}"
    aurman -s "${pkgs[@]}"
}
install_rofi_pass() {
	curl -fSL https://github.com/carnager/rofi-pass/archive/2.0.1.tar.gz > /tmp/rofi-pass.tar.gz
	cd /tmp && tar xvf rofi-pass.tar.gz
	cp /tmp/rofi-pass*/rofi-pass ~/bin/
}
# install keybase
install_keybase() {
	curl -fSsl https://aur.archlinux.org/cgit/aur.git/snapshot/keybase-bin.tar.gz > /tmp/keybase-bin.tar.gz
	cd /tmp && tar xvf keybase-bin.tar.gz \
  	&& cd /tmp/keybase-bin
	makepkg -s PKGBUILD
	sudo pacman -U keybase-bin*tar.xz
}

# install/update golang from source
install_golang() {
	export GO_VERSION
	GO_VERSION=$(curl -sSL "https://golang.org/VERSION?m=text")
	export GO_SRC=/usr/local/go

	# if we are passing the version
	if [[ ! -z "$1" ]]; then
		GO_VERSION=$1
	fi

	# purge old src
	if [[ -d "$GO_SRC" ]]; then
		sudo rm -rf "$GO_SRC"
		sudo rm -rf "$GOPATH"
	fi

	GO_VERSION=${GO_VERSION#go}

	# subshell
	(
	kernel=$(uname -s | tr '[:upper:]' '[:lower:]')
	curl -sSL "https://storage.googleapis.com/golang/go${GO_VERSION}.${kernel}-amd64.tar.gz" | sudo tar -v -C /usr/local -xz
	local user="$USER"
	# rebuild stdlib for faster builds
	sudo chown -R "${user}" /usr/local/go/pkg
	CGO_ENABLED=0 /usr/local/go/bin/go install -a -installsuffix cgo std
	)
  # for analysing symbols
  go get -u github.com/rogpeppe/godef
  # dependency management tool
  go get -u github.com/tools/godep
  # for command autocompletion
  go get -u github.com/nsf/gocode
  # for automatic imports
  go get -u golang.org/x/tools/cmd/goimports
}

install_fonts() {
  local pkgs=(
	  adobe-source-code-pro-fonts
	  ttf-liberation
	  ttf-dejavu
	  ttf-linux-libertine
	  ttf-font-awesome
    ttf-opensans
  )
  aurman -S "${pkgs[@]}"
}
# install stuff for i3 window manager
install_wmapps() {
	local pkgs=( feh i3 i3lock i3status scrot xorg-xinit xorg-server sysstat acpi )
	pacman -S "${pkgs[@]}"
	install_dotfiles
}

install_dotfiles() {
	# enable dbus for the user session
	# systemctl --user enable dbus.socket

	# sudo systemctl enable "i3lock@${TARGET_USER}"
        # sudo systemctl enable suspend-sedation.service

	cd "$HOME"
	make
	rm -rf $HOME/.i3/
}

install_spacemacs() {
	cp .spacemacs "$HOME"/
	git clone https://github.com/syl20bnr/spacemacs ~/.emacs.d
	sudo pacman -S \
		emacs \
		nodejs \
		mu \
		npm \
		isync \
		ack \
    # graphviz for plantuml
    graphviz \
    # ghostscript is for Docview
    ghostscript
	npm install -g tern eslint babel-eslint eslint-plugin-react js-beautify
	cat <<-EOFF

	# General

	- now after loading spacemacs and letting it install all the necessary
	packages run the following commands:

	:spacemacs/recompile-elpa

	# IRC (aka. ERC)

	- Also, the erc layer requires that you have a `.authinfo.gpg` file in
	your home directory specifying the connection parameters for IRC
	servers (or IRC bouncer) you want to connect to

	# Email

	- Make sure you edit your ~/.mbsyncrc file accordingly

	- After this fetch your email from the IMAP Server
	> mbsync -a

	- Don't forget to update the mu database by running the following command
	> mu index --maildir ~/q/mail/Personal

  # PDF Tools

  - Make sure to run `pdf-tools-install` to properly install pdf-tools
	EOFF
}

install_paperless() {
    git clone https://github.com/danielquinn/paperless.git ~/pc/prj/paperless
    # install project dependencies
    sudo pacman -S \
         sane \
         tesseract-data-eng \
         tesseract-data-deu \
         unpaper \
         # for crappy HP products
         hplip \
         python-gobject \
         python-pillow
    # you might have to run the following
    # to download necessary HP plugins
    hp-plugin
    # create project specific virtualenv
    mkproject -p python3 paperless
    sudo cp ~/q/software/paperless/paperless.conf.example /etc/paperless.conf
    sudo sed -i -e 's#PAPERLESS_CONSUMPTION_DIR=""#PAPERLESS_CONSUMPTION_DIR="/home/sd/pc/prj/paperless/inbox"#' /etc/paperless.conf
    #sudo sed -i -e "s#PAPERLESS_PASSPHRASE=\"[^\"]+\"#PAPERLESS_PASSPHRASE=\"$(pass -c paperless)\"#" /etc/paperless.conf
    # Initialise the SQLite database
    ~/q/software/paperless/src/manage.py migrate
    # Create a user for your Paperless instance and follow the prompts
    ~/q/software/paperless/src/manage.py createsuperuser
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
    sudo pacman -S "${pkgs[@]}"
}

usage() {
	echo -e "install.sh\\n\\tThis script installs my basic setup for a debian laptop\\n"
	echo "Usage:"
	echo "  chroot                              - setup bootstrap enviroment to chroot to"
	echo "  partitioning                        - setup partitioning with btrfs and LUKS"
	echo "  base                                - setup sources & install base pkgs"
	echo "  desktop                             - setup desktop and window manager"
	echo "  utils                               - setup desktop and window manager"
	echo "  dotfiles                            - get dotfiles"
	echo "  latex                               - install latex and all its wonderfullness"
	echo "  golang                              - install golang and packages"
	echo "  spacemacs                           - install spacemacs (emacs in god mode)"
}

main() {
	local cmd=$1

	if [[ -z "$cmd" ]]; then
		usage
		exit 1
	fi

	if [[ $cmd == "chroot" ]]; then
		check_is_sudo
		setup_chroot
	elif [[ $cmd == "desktop" ]]; then
		desktop
	elif [[ $cmd == "utils" ]]; then
		install_utils
	elif [[ $cmd == "latex" ]]; then
		install_latex
	elif [[ $cmd == "partitioning" ]]; then
		setup_partitions
	elif [[ $cmd == "base" ]]; then
		get_user
		base
	elif [[ $cmd == "wm" ]]; then
		install_wmapps
	elif [[ $cmd == "dotfiles" ]]; then
		get_user
		install_dotfiles
	elif [[ $cmd == "golang" ]]; then
		install_golang "$2"
	elif [[ $cmd == "spacemacs" ]]; then
		install_spacemacs
	else
		usage
	fi
}

main "$@"
