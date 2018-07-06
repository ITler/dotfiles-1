#!/bin/bash
# install.sh
#	This script installs my basic setup for a archlinux laptop.
#	Forked from @jessfraz

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
	# Make sure you have bound the proper devices first:

	mount --bind /proc /mnt/proc
	mount --bind /sys /mnt/sys
	mount --bind /dev /mnt/dev

	# Install base and base-devel packages
	pacman -S base base-devel
	 
	# Setup Time zone 
	ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime

	# Generate locales
       
	sed -i -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' -e  's/^#de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8' /etc/locale.gen
	echo "LANG=de_DE.UTF-8" > /etc/locale.conf
	cat <<-EOFF > /etc/vconsole.conf
	FONT=lat1-14
	FONT_MAP=8859-1
	EOFF

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

	sudo pacman -S \
		qutebrowser \
		rsync \
		openssh \
		pass \
		gtk2 \
		rofi \
		xdotool \
		fasd \
		python-virtualenv \
		python-pip \
		zathura \
		zathura-pdf-poppler \
		aspell-en \
		aspell-de \
		lxdm \
		pulseaudio \
		pavucontrol \
                avahi \
                nss-mdns \
                pulseaudio-bluetooth \
                bluez \
                bluez-libs \
                bluez-utils \
				rxvt-unicode

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
# installs docker master
# and adds necessary items to boot params
install_docker() {
	# create docker group
	sudo groupadd docker
	sudo gpasswd -a "$TARGET_USER" docker

	# Include contributed completions
	mkdir -p /etc/bash_completion.d
	curl -sSL -o /etc/bash_completion.d/docker https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/bash/docker


	# get the binary
	local tmp_tar=/tmp/docker.tgz
	local binary_uri="https://download.docker.com/linux/static/edge/x86_64"
	local docker_version
	docker_version=$(curl -sSL "https://api.github.com/repos/docker/docker-ce/releases/latest" | jq --raw-output .tag_name)
	docker_version=${docker_version#v}
	# local docker_sha256
	# docker_sha256=$(curl -sSL "${binary_uri}/docker-${docker_version}.tgz.sha256" | awk '{print $1}')
	(
	set -x
	curl -fSL "${binary_uri}/docker-${docker_version}.tgz" -o "${tmp_tar}"
	# echo "${docker_sha256} ${tmp_tar}" | sha256sum -c -
	tar -C /usr/local/bin --strip-components 1 -xzvf "${tmp_tar}"
	rm "${tmp_tar}"
	docker -v
	)
	chmod +x /usr/local/bin/docker*

	curl -sSL https://raw.githubusercontent.com/jessfraz/dotfiles/master/etc/systemd/system/docker.service > /etc/systemd/system/docker.service
	curl -sSL https://raw.githubusercontent.com/jessfraz/dotfiles/master/etc/systemd/system/docker.socket > /etc/systemd/system/docker.socket

	systemctl daemon-reload
	systemctl enable docker

	# update grub with docker configs and power-saving items
	sed -i.bak 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="cgroup_enable=memory swapaccount=1 apparmor=1 security=apparmor page_poison=1 slab_nomerge vsyscall=none"/g' /etc/default/grub
	echo "Docker has been installed. If you want memory management & swap"
	echo "run update-grub & reboot"
}

install_cli_goodies() {

	# get commandline tools
	(
	set -x
	set +e
	go get github.com/golang/lint/golint
	go get golang.org/x/tools/cmd/cover
	go get golang.org/x/review/git-codereview
	go get golang.org/x/tools/cmd/goimports
	go get golang.org/x/tools/cmd/gorename
	go get golang.org/x/tools/cmd/guru

	go get github.com/genuinetools/amicontained
	go get github.com/genuinetools/apk-file
	go get github.com/genuinetools/audit
	go get github.com/genuinetools/certok
	go get github.com/genuinetools/img
	go get github.com/genuinetools/netns
	go get github.com/genuinetools/pepper
	go get github.com/genuinetools/reg
	go get github.com/genuinetools/udict
	go get github.com/genuinetools/weather

	go get github.com/jessfraz/cliaoke
	go get github.com/jessfraz/junk/sembump
	go get github.com/jessfraz/pastebinit
	go get github.com/jessfraz/tdash

	go get github.com/axw/gocov/gocov
	go get github.com/crosbymichael/gistit
	go get github.com/davecheney/httpstat
	go get honnef.co/go/tools/cmd/staticcheck
	go get github.com/google/gops
	) }

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

# install graphics drivers
install_graphics() {
	local system=$1

	if [[ -z "$system" ]]; then
		echo "You need to specify whether it's intel, geforce or optimus"
		exit 1
	fi

	local pkgs=( xorg xserver-xorg xorg-fonts-encoding xorg-xrandr xorg-font-util xorg-)

	case $system in
		"intel")
			pkgs+=( xf86-video-intel )
			;;
		"geforce")
			pkgs+=( nvidia-driver )
			;;
		"optimus")
			pkgs+=( nvidia-kernel-dkms bumblebee-nvidia primus )
			;;
		*)
			echo "You need to specify whether it's intel, geforce or optimus"
			exit 1
			;;
	esac

	apt install -y "${pkgs[@]}" --no-install-recommends
}

# install custom scripts/binaries
install_scripts() {
	# install speedtest
	curl -sSL https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py  > /usr/local/bin/speedtest
	chmod +x /usr/local/bin/speedtest

	# install icdiff
	curl -sSL https://raw.githubusercontent.com/jeffkaufman/icdiff/master/icdiff > /usr/local/bin/icdiff
	curl -sSL https://raw.githubusercontent.com/jeffkaufman/icdiff/master/git-icdiff > /usr/local/bin/git-icdiff
	chmod +x /usr/local/bin/icdiff
	chmod +x /usr/local/bin/git-icdiff

	# install lolcat
	curl -sSL https://raw.githubusercontent.com/tehmaze/lolcat/master/lolcat > /usr/local/bin/lolcat
	chmod +x /usr/local/bin/lolcat


	local scripts=( have light )

	for script in "${scripts[@]}"; do
		curl -sSL "https://misc.j3ss.co/binaries/$script" > "/usr/local/bin/${script}"
		chmod +x "/usr/local/bin/${script}"
	done
}

# install syncthing
install_syncthing() {
	# download syncthing binary
	if [[ ! -f /usr/local/bin/syncthing ]]; then
		curl -sSL https://misc.j3ss.co/binaries/syncthing > /usr/local/bin/syncthing
		chmod +x /usr/local/bin/syncthing
	fi

	syncthing -upgrade

	curl -sSL https://raw.githubusercontent.com/jessfraz/dotfiles/master/etc/systemd/system/syncthing@.service > /etc/systemd/system/syncthing@.service

	systemctl daemon-reload
	systemctl enable "syncthing@${TARGET_USER}"
}

# install wifi drivers
install_wifi() {
	local system=$1

	if [[ -z "$system" ]]; then
		echo "You need to specify whether it's broadcom or intel"
		exit 1
	fi

	if [[ $system == "broadcom" ]]; then
		local pkg="broadcom-sta-dkms"

		apt install -y "$pkg" --no-install-recommends
	else
		update-iwlwifi
	fi
}

install_fonts() {
	pacman -S \
		adobe-source-code-pro-fonts \
		ttf-liberation \
		ttf-dejavu \
		ttf-linux-libertine \
		ttf-font-awesome
  # and ttf-opensans from AUR
}
# install stuff for i3 window manager
install_wmapps() {
	local pkgs=( feh i3 i3lock i3status scrot xorg-xinit xorg-server sysstat acpi )

	pacman -S "${pkgs[@]}"

#	# update clickpad settings
	# update clickpad settings
#	curl -sSL https://raw.githubusercontent.com/jessfraz/dotfiles/master/etc/X11/xorg.conf.d/50-synaptics-clickpad.conf > /etc/X11/xorg.conf.d/50-synaptics-clickpad.conf
#
#	# add xorg conf
#	curl -sSL https://raw.githubusercontent.com/jessfraz/dotfiles/master/etc/X11/xorg.conf > /etc/X11/xorg.conf
#
#	# get correct sound cards on boot
#	curl -sSL https://raw.githubusercontent.com/jessfraz/dotfiles/master/etc/modprobe.d/intel.conf > /etc/modprobe.d/intel.conf
#
#	# pretty fonts
#	curl -sSL https://raw.githubusercontent.com/jessfraz/dotfiles/master/etc/fonts/local.conf > /etc/fonts/local.conf
#
#	echo "Fonts file setup successfully now run:"
#	echo "	dpkg-reconfigure fontconfig-config"
#	echo "with settings: "
#	echo "	Autohinter, Automatic, No."
#	echo "Run: "
#	echo "	dpkg-reconfigure fontconfig"
}

get_dotfiles() {
	# create subshell
	(
	cd "$HOME"

	# install dotfiles from repo
	git clone git@github.com:jessfraz/dotfiles.git "${HOME}/dotfiles"
	cd "${HOME}/dotfiles"

	# installs all the things
	make

	# enable dbus for the user session
	# systemctl --user enable dbus.socket

	sudo systemctl enable "i3lock@${TARGET_USER}"
	sudo systemctl enable suspend-sedation.service

	cd "$HOME"
	)

	install_vim;
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

	- Don't forget to update the mu database by running the following command
	> mu index --maildir ~/q/mail/Personal

  # PDF Tools

  - Make sure to run `pdf-tools-install` to properly install pdf-tools
	EOFF
}

install_vim() {
	# create subshell
	(
	cd "$HOME"

	# install .vim files
	git clone --recursive git@github.com:jessfraz/.vim.git "${HOME}/.vim"
	ln -snf "${HOME}/.vim/vimrc" "${HOME}/.vimrc"
	sudo ln -snf "${HOME}/.vim" /root/.vim
	sudo ln -snf "${HOME}/.vimrc" /root/.vimrc

	# alias vim dotfiles to neovim
	mkdir -p "${XDG_CONFIG_HOME:=$HOME/.config}"
	ln -snf "${HOME}/.vim" "${XDG_CONFIG_HOME}/nvim"
	ln -snf "${HOME}/.vimrc" "${XDG_CONFIG_HOME}/nvim/init.vim"
	# do the same for root
	sudo mkdir -p /root/.config
	sudo ln -snf "${HOME}/.vim" /root/.config/nvim
	sudo ln -snf "${HOME}/.vimrc" /root/.config/nvim/init.vim

	# update alternatives to neovim
	sudo update-alternatives --install /usr/bin/vi vi "$(which nvim)" 60
	sudo update-alternatives --config vi
	sudo update-alternatives --install /usr/bin/vim vim "$(which nvim)" 60
	sudo update-alternatives --config vim
	sudo update-alternatives --install /usr/bin/editor editor "$(which nvim)" 60
	sudo update-alternatives --config editor

	# install things needed for deoplete for vim
	sudo apt update

	sudo apt install -y \
		python3-pip \
		python3-setuptools \
		--no-install-recommends

	pip3 install -U \
		setuptools \
		wheel \
		neovim
	)
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
	sudo pacman -S \
		rubber \
		biber \
    texlive-core \
    texlive-latexextra \
    texlive-bibtexextra \
    texlive-fontsextra \
    texlive-formatsextra \
    pygmentize
}

install_virtualbox() {
	# check if we need to install libvpx1
	PKG_OK=$(dpkg-query -W --showformat='${Status}\n' libvpx1 | grep "install ok installed")
	echo "Checking for libvpx1: $PKG_OK"
	if [ "" == "$PKG_OK" ]; then
		echo "No libvpx1. Installing libvpx1."
		jessie_sources=/etc/apt/sources.list.d/jessie.list
		echo "deb http://httpredir.debian.org/debian jessie main contrib non-free" > "$jessie_sources"

		apt update
		apt install -y -t jessie libvpx1 \
			--no-install-recommends

		# cleanup the file that we used to install things from jessie
		rm "$jessie_sources"
	fi

	echo "deb http://download.virtualbox.org/virtualbox/debian vivid contrib" >> /etc/apt/sources.list.d/virtualbox.list

	curl -sSL https://www.virtualbox.org/download/oracle_vbox.asc | apt-key add -

	apt update
	apt install -y \
		virtualbox-5.0 \
	--no-install-recommends
}

install_vagrant() {
	VAGRANT_VERSION=1.8.1

	# if we are passing the version
	if [[ ! -z "$1" ]]; then
		export VAGRANT_VERSION=$1
	fi

	# check if we need to install virtualbox
	PKG_OK=$(dpkg-query -W --showformat='${Status}\n' virtualbox | grep "install ok installed")
	echo "Checking for virtualbox: $PKG_OK"
	if [ "" == "$PKG_OK" ]; then
		echo "No virtualbox. Installing virtualbox."
		install_virtualbox
	fi

	tmpdir=$(mktemp -d)
	(
	cd "$tmpdir"
	curl -sSL -o vagrant.deb "https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}_x86_64.deb"
	dpkg -i vagrant.deb
	)

	rm -rf "$tmpdir"

	# install plugins
	vagrant plugin install vagrant-vbguest
}


usage() {
	echo -e "install.sh\\n\\tThis script installs my basic setup for a debian laptop\\n"
	echo "Usage:"
	echo "  chroot                              - setup bootstrap enviroment to chroot to"
	echo "  partitioning                        - setup partitioning with btrfs and LUKS"
	echo "  base                                - setup sources & install base pkgs"
	echo "  desktop                             - setup desktop and window manager"
	echo "  wifi {broadcom, intel}              - install wifi drivers"
	echo "  graphics {intel, geforce, optimus}  - install graphics drivers"
	echo "  wm                                  - install window manager/desktop pkgs"
	echo "  dotfiles                            - get dotfiles"
	echo "  vim                                 - install vim specific dotfiles"
	echo "  golang                              - install golang and packages"
	echo "  scripts                             - install scripts"
	echo "  spacemacs                           - install spacemacs (emacs in god mode)"
	echo "  syncthing                           - install syncthing"
	echo "  vagrant                             - install vagrant and virtualbox"
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
	elif [[ $cmd == "partitioning" ]]; then
		setup_partitions
	elif [[ $cmd == "base" ]]; then
		check_is_sudo
		get_user

		# setup /etc/pacman.d/mirrorlist
		setup_sources

		base
	elif [[ $cmd == "wifi" ]]; then
		install_wifi "$2"
	elif [[ $cmd == "graphics" ]]; then
		check_is_sudo

		install_graphics "$2"
	elif [[ $cmd == "wm" ]]; then
		check_is_sudo

		install_wmapps
	elif [[ $cmd == "dotfiles" ]]; then
		get_user
		get_dotfiles
	elif [[ $cmd == "vim" ]]; then
		install_vim
	elif [[ $cmd == "golang" ]]; then
		install_golang "$2"
	elif [[ $cmd == "scripts" ]]; then
		install_scripts
	elif [[ $cmd == "spacemacs" ]]; then
		install_spacemacs
	elif [[ $cmd == "syncthing" ]]; then
		get_user
		install_syncthing
	elif [[ $cmd == "vagrant" ]]; then
		install_vagrant "$2"
	else
		usage
	fi
}

main "$@"
