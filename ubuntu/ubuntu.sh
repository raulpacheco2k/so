#!/bin/bash

# Salva logs
exec > >(tee -i environment_configuration_log.txt)
exec 2>&1

# Informações sobre o usuário
read -p "Informe seu e-mail: " EMAIL
read -p "Informe seu username: " USERNAME

# Arquivos de configurações
## Arquivo original da instação do Ubutu em /etc/skel/.bashrc
## Estudar a possibilidade de link simbolico p.ex.: ln -sf $PWD/.bashrc ~/.bashrc
cp .bashrc ~/.bashrc
cp .gitconfig ~/.gitconfig
mkdir -p ~/.config/i3 && cp .config/i3/config ~/.config/i3/config
mkdir -p ~/.unison && cp .unison/sync.prf ~/.unison/sync.prf

# Configurando SSH
ssh-keygen -t ed25519 -C "$EMAIL"
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# Configurando Git
sudo apt-get install git
git config --global core.editor "nano"
git config --global credential.helper store
git config --global user.email "$EMAIL"
git config --global user.name "$USERNAME"
git config --global gpg.format ssh
git config --global user.signingKey "$(cat ~/.ssh/id_ed25519.pub)"
git config --global commit.gpgsign true
git config --global tag.gpgsign true

# Atualizando o sistema
sudo add-apt-repository universe -y
sudo add-apt-repository ppa:agornostal/ulauncher -y
sudo apt-get update -y
sudo apt-get --fix-broken install
sudo apt-get upgrade -y

# Configurando interface Gnome
gsettings set org.gnome.desktop.interface enable-animations true
gsettings set org.gnome.nautilus.preferences default-sort-order 'type'

# Instalando pacotes APT
sudo apt-get install -y bleachbit
sudo apt-get install -y curl
sudo apt-get install -y fastfetch
sudo apt-get install -y lazygit
sudo apt-get install -y gnome-snapshot
sudo apt-get install -y net-tools
sudo apt-get install -y nvtop
sudo apt-get install -y p7zip-full
sudo apt-get install -y prelink
sudo apt-get install -y preload
sudo apt-get install -y software-properties-common
sudo apt-get install -y tree
sudo apt-get install -y ubuntu-drivers-common
sudo apt-get install -y unison
sudo apt-get install -y unison-gtk
sudo apt-get install -y vim
sudo apt-get install -y wget
sudo apt-get install -y $(ubuntu-drivers devices | grep recommended | awk '{print $3}')
sudo apt-get install -y vulkan-tools mesa-utils nvidia-cuda-toolkit
# Pacotes para i3wm
sudo apt-get install -y i3
sudo apt-get install -y xserver-xorg-input-all
sudo apt-get install -y xinput
sudo apt-get install -y pulseaudio-utils
sudo apt-get install -y playerctl
sudo apt-get install -y alacritty
sudo apt-get install -y kitty
sudo apt-get install -y ulauncher
sudo apt-get install -y feh

# Instalando pacotes SNAP
## Gerenciamento de senha
sudo snap install keepassxc
sudo snap install 1password
sudo snap install authenticator --edge
sudo snap install 2fa
sudo snap install nordpass
sudo snap connect nordpass:password-manager-service
sudo snap install nordvpn
## Rede
sudo snap install ngrok
## Estudos e notas
sudo snap install anki-desktop
sudo snap install notion-snap-reborn
sudo snap install obsidian --classic
sudo snap install xmind
sudo snap install kbruch
## Comunicação
sudo snap install discord
## Utilitários
sudo snap install btop
sudo snap install fast
sudo snap install firefox
sudo snap install libreoffice
sudo snap install spotify
sudo snap install thunderbird
sudo snap install wethr
sudo snap install teleprompter
sudo snap install vlc
sudo snap install gimp
sudo snap install blender --classic
sudo snap install audacity
sudo snap install foobar2000
sudo snap install gnome-boxes
## Jogos e lives
sudo snap install obs-studio
sudo snap install steam
## Desenvolvimento
### Essenciais
sudo snap install code --classic
sudo snap install docker
sudo snap install sublime-text --classic
### Complementares
sudo snap install aws-cli --classic
sudo snap install beekeeper-studio
sudo snap install dbeaver-ce
sudo snap install drawio
sudo snap install eclipse --classic
sudo snap install fx
sudo snap install heidisql-wine
sudo snap install insomnia
sudo snap install mysql-workbench-community
sudo snap install netbeans --classic
sudo snap install notepad-plus-plus
sudo snap install onefetch
sudo snap install postman
sudo snap install sublime-merge --classic
sudo snap install termius-app   
sudo snap install waveterm --classic
sudo snap install weka
### JetBrains
sudo snap install android-studio --classic
sudo snap install clion --classic
sudo snap install datagrip --classic
sudo snap install dataspell --classic
sudo snap install goland --classic
sudo snap install intellij-idea-ultimate --classic
sudo snap install phpstorm --classic
sudo snap install pycharm-professional --classic
sudo snap install rider --classic
sudo snap install rubymine --classic
sudo snap install rustrover --classic
sudo snap install space
sudo snap install webstorm --classic

# Instalando pacotes NPM
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash
\. "$HOME/.nvm/nvm.sh"
nvm install 24
npm install -g @google/gemini-cli
npm install -g @anthropic-ai/claude-code
npm install -g @github/copilot
npm install -g @openai/codex

# Lazydocker
curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash

# Definindo a placa de vídeo Nvidia como principal
sudo prime-select nvidia

# Configurando ajuste de brilho em hardware Nvidia
GRUB_FILE="/etc/default/grub"
KERNEL_PARAM="acpi_backlight=native"
sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\(\"[^\"]*\)\"/\1 ${KERNEL_PARAM}\"/" "${GRUB_FILE}"
update-grub

# Configurando Docker para funcionar sem permissão sudo
sudo addgroup --system docker
sudo adduser $USER docker

# Instalando Google Chrome
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo dpkg -i ./google-chrome-stable_current_amd64.deb
rm google-chrome-stable_current_amd64.deb

# Instalando Electrum
sudo apt-get install python3-pyqt6 libsecp256k1-dev python3-cryptography
wget https://download.electrum.org/4.6.2/Electrum-4.6.2.tar.gz
sudo apt-get install python3-setuptools python3-pip
python3 -m pip install --break-system-packages --user Electrum-4.6.2.tar.gz
rm Electrum-4.6.2.tar.gz

# Instalando Ollama
curl -fsSL https://ollama.com/install.sh | sh
ollama pull kimi-k2:1t-cloud
ollama pull minimax-m2:cloud
ollama pull gpt-oss:120b-cloud
ollama pull deepseek-v3.1:671b-cloud
ollama pull qwen3-coder:480b-cloud

# Limpeza do sistema 
sudo apt-get autoremove --purge -y
sudo apt-get autoclean
sudo apt-get clean
sudo journalctl --vacuum-size=1G
sudo bleachbit --clean system.cache system.trash system.tmp
sudo fstrim -av

clear
fastfetch

read -p "Configuração concluída. Deseja reiniciar o computador agora? [S/N]: " option
if [ "$option" == "S" ] || [ "$option" == "s" ]; then
sudo reboot
fi

exit 0
