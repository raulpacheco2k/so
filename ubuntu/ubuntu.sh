#!/bin/bash

# Interrompe em erros, variaveis ausentes e falhas dentro de pipelines.
set -Eeuo pipefail
# Mostra a linha e o comando que causaram uma falha antes de sair.
trap 'status=$?; echo "Erro na linha $LINENO (codigo $status): $BASH_COMMAND" >&2; exit "$status"' ERR
# Evita que instaladores do APT parem para perguntas de configuracao.
export DEBIAN_FRONTEND=noninteractive

# Mantem um log acumulado no HOME, inclusive quando o script e iniciado via curl.
LOG_FILE="$HOME/environment_configuration_log.txt"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

FAILED_INSTALLS=()
FAILURE_REPORT="environment_configuration_failures.txt"
REMOTE_DIR="$(mktemp -d)"
REPOSITORY_URL="https://github.com/raulpacheco2k/so.git"
REPOSITORY_DIR="$HOME/so"
SUDO_KEEPALIVE_PID=""
EMAIL="${UBUNTU_SETUP_EMAIL:-}"
USERNAME="${UBUNTU_SETUP_USERNAME:-}"
REBOOT_AFTER_INSTALL="${UBUNTU_SETUP_REBOOT:-false}"
SSH_PASSPHRASE="${UBUNTU_SETUP_SSH_PASSPHRASE:-}"
PROJECT_DIR=""

# Usa a pasta do script, em vez do diretorio de onde ele foi chamado.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    cd "$PROJECT_DIR"
fi
if [[ -n "${UBUNTU_SETUP_REPOSITORY_DIR:-}" ]]; then
    REPOSITORY_DIR="$UBUNTU_SETUP_REPOSITORY_DIR"
fi
trap 'if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; fi; rm -rf "$REMOTE_DIR"' EXIT

record_failure() {
    FAILED_INSTALLS+=("$1")
}

is_apt_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null \
        | grep -Fq 'install ok installed'
}

# Instala pacotes pendentes em lote e identifica falhas individualmente.
install_apt_packages() {
    local package
    local pending=()

    for package in "$@"; do
        if ! is_apt_package_installed "$package"; then
            pending+=("$package")
        fi
    done

    if ((${#pending[@]} == 0)); then
        return 0
    fi

    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pending[@]}"; then
        return 0
    fi

    # Tenta individualmente apenas para identificar quais pacotes falharam.
    for package in "${pending[@]}"; do
        if ! is_apt_package_installed "$package"; then
            if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
                continue
            fi
            record_failure "APT: $package"
        fi
    done
}

project_files_are_present() {
    local required_file

    [[ -n "$PROJECT_DIR" ]] || return 1
    for required_file in .bashrc .gitconfig .config/i3/config .unison/sync.prf; do
        if [[ ! -f "$PROJECT_DIR/$required_file" ]]; then
            return 1
        fi
    done
}

# Garante que o Git exista tanto no bootstrap quanto na instalacao local.
ensure_git() {
    if command -v git >/dev/null 2>&1; then
        return 0
    fi

    echo "Git nao encontrado. Instalando Git..."
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y git
    command -v git >/dev/null 2>&1
}

# Instala um Snap somente quando ele ainda nao estiver instalado.
install_snap_package() {
    local package="$1"
    shift

    if sudo snap list "$package" >/dev/null 2>&1; then
        return 0
    fi

    if ! sudo snap install "$package" "$@"; then
        record_failure "Snap: $package"
    fi
}

# Executa uma etapa opcional sem interromper as demais instalacoes.
run_optional() {
    local description="$1"
    shift

    if ! "$@"; then
        record_failure "$description"
    fi
}

# Baixa somente por HTTPS e exige uma resposta HTTP bem-sucedida e nao vazia.
download_remote() {
    local description="$1"
    local url="$2"
    local output="$3"

    if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "$url" --output "$output"; then
        record_failure "$description (download)"
        return 1
    fi

    if [[ ! -s "$output" ]]; then
        record_failure "$description (empty download)"
        return 1
    fi
}

# Verifica a sintaxe de scripts baixados antes de executa-los.
run_remote_script() {
    local description="$1"
    local script="$2"

    if ! bash -n "$script"; then
        record_failure "$description (invalid shell script)"
        return 0
    fi

    run_optional "$description" bash "$script"
}

install_zen_browser() {
    local archive="$1"
    local staging_dir="$REMOTE_DIR/zen-extracted"
    local install_dir="$HOME/.local/opt/zen"

    # O arquivo da release contem o diretorio zen na raiz do TAR.
    if ! tar -tJf "$archive" >/dev/null 2>&1; then
        record_failure "Zen Browser (invalid archive)"
        return 1
    fi

    mkdir -p "$staging_dir" "$HOME/.local/bin"
    tar -xJf "$archive" -C "$staging_dir"
    if [[ ! -x "$staging_dir/zen/zen" ]]; then
        record_failure "Zen Browser (executable not found)"
        return 1
    fi

    rm -rf "$install_dir"
    mv "$staging_dir/zen" "$install_dir"
    ln -sfn "$install_dir/zen" "$HOME/.local/bin/zen"
}

validate_environment() {
    # Valida os pre-requisitos antes de alterar o sistema.
    if ((EUID == 0)); then
        echo "Execute este script com um usuario comum, nao como root." >&2
        exit 1
    fi

    if [[ ! -r /etc/os-release ]]; then
        echo "Nao foi possivel identificar o sistema operacional." >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        echo "Este script foi feito para Ubuntu." >&2
        exit 1
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        echo "O comando sudo e necessario." >&2
        exit 1
    fi
    sudo -v

    if ! project_files_are_present; then
        echo "Os arquivos de configuracao do projeto nao foram encontrados." >&2
        exit 1
    fi

    if ! command -v getent >/dev/null 2>&1 \
        || ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
        echo "Nao foi possivel validar a conexao de rede." >&2
        exit 1
    fi
}

bootstrap_project() {
    # Quando o script veio pelo curl, baixa o repositorio que contem os arquivos
    # de configuracao e reexecuta a versao completa a partir dele.
    if project_files_are_present; then
        return 0
    fi

    echo "Arquivos do projeto ausentes. Preparando o repositorio."

    if ((EUID == 0)); then
        echo "Execute este script com um usuario comum, nao como root." >&2
        exit 1
    fi
    if [[ ! -r /etc/os-release ]]; then
        echo "Nao foi possivel identificar o sistema operacional." >&2
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        echo "Este script foi feito para Ubuntu." >&2
        exit 1
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        echo "O comando sudo e necessario." >&2
        exit 1
    fi
    sudo -v

    # O Git e necessario para clonar o repositorio, mas pode nao existir em uma
    # instalacao minima do Ubuntu.
    ensure_git

    if [[ -e "$REPOSITORY_DIR" && ! -d "$REPOSITORY_DIR/.git" ]]; then
        echo "O caminho $REPOSITORY_DIR existe, mas nao e um repositorio Git." >&2
        exit 1
    fi

    # Nao clona novamente se o repositorio ja estiver presente.
    if [[ ! -d "$REPOSITORY_DIR/.git" ]]; then
        git clone --branch main --single-branch "$REPOSITORY_URL" "$REPOSITORY_DIR"
    fi

    cd "$REPOSITORY_DIR/ubuntu"
    PROJECT_DIR="$REPOSITORY_DIR/ubuntu"
    if [[ -r /dev/tty ]]; then
        exec bash "$REPOSITORY_DIR/ubuntu/ubuntu.sh" "$@" </dev/tty
    else
        exec bash "$REPOSITORY_DIR/ubuntu/ubuntu.sh" "$@"
    fi
}

collect_user_input() {
    if [[ -z "$EMAIL" || -z "$USERNAME" || -z "${UBUNTU_SETUP_INPUTS_COLLECTED:-}" ]]; then
        if [[ ! -r /dev/tty ]]; then
            echo "Este script precisa de um terminal para receber os dados iniciais." >&2
            echo "Execute-o em um terminal ou informe UBUNTU_SETUP_EMAIL e UBUNTU_SETUP_USERNAME." >&2
            exit 1
        fi

        read -r -p "Informe seu username: " USERNAME </dev/tty
        read -r -p "Informe seu e-mail: " EMAIL </dev/tty

        if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
            read -r -s -p "Informe a senha da chave SSH (vazio para sem senha): " SSH_PASSPHRASE </dev/tty
            printf '\n'
        fi

        if ! sudo -v; then
            echo "Nao foi possivel autenticar no sudo." >&2
            exit 1
        fi

        if ! project_files_are_present; then
            local repository_input
            read -r -p "Diretorio de instalacao [$REPOSITORY_DIR]: " repository_input </dev/tty
            if [[ -n "$repository_input" ]]; then
                REPOSITORY_DIR="${repository_input/#\~/$HOME}"
            fi
            if [[ "$REPOSITORY_DIR" != /* ]]; then
                REPOSITORY_DIR="$PWD/$REPOSITORY_DIR"
            fi
            printf 'O repositorio sera instalado em: %s\n' "$REPOSITORY_DIR"
        fi

        local reboot_confirmation
        read -r -p "Reiniciar o computador ao terminar? [S/N]: " reboot_confirmation </dev/tty
        if [[ "$reboot_confirmation" =~ ^[Ss]$ ]]; then
            REBOOT_AFTER_INSTALL=true
        else
            REBOOT_AFTER_INSTALL=false
        fi

        export UBUNTU_SETUP_EMAIL="$EMAIL"
        export UBUNTU_SETUP_USERNAME="$USERNAME"
        export UBUNTU_SETUP_SSH_PASSPHRASE="$SSH_PASSPHRASE"
        export UBUNTU_SETUP_REPOSITORY_DIR="$REPOSITORY_DIR"
        export UBUNTU_SETUP_REBOOT="$REBOOT_AFTER_INSTALL"
        export UBUNTU_SETUP_INPUTS_COLLECTED=true
    fi

    # A credencial foi solicitada na ordem definida acima; apenas a valida novamente.
    if ! sudo -v; then
        echo "Nao foi possivel autenticar no sudo." >&2
        exit 1
    fi

    # Mantem a credencial sudo valida durante instalacoes longas.
    (
        while true; do
            sudo -n -v
            sleep 60
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
}

write_failure_report() {
    # Registra as falhas opcionais somente depois que todas as etapas terminaram.
    if ((${#FAILED_INSTALLS[@]} > 0)); then
        {
            printf 'Itens que nao foram instalados ou configurados:\n'
            printf ' - %s\n' "${FAILED_INSTALLS[@]}"
        } > "$FAILURE_REPORT"
        echo "Alguns itens falharam. Consulte: $FAILURE_REPORT"
    else
        rm -f "$FAILURE_REPORT"
        echo "Todos os itens opcionais foram instalados ou configurados."
    fi
}

# Todas as perguntas ficam no início para que a instalação possa prosseguir
# sem depender de novas confirmações durante as etapas demoradas.
collect_user_input
bootstrap_project "$@"
validate_environment
if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Informe um e-mail valido." >&2
    exit 1
fi
if [[ -z "$USERNAME" ]]; then
    echo "O username nao pode ser vazio." >&2
    exit 1
fi

# Cria a chave SSH apenas quando ela ainda nao existe.
SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_PUBLIC="$SSH_KEY.pub"
mkdir -p -m 700 "$HOME/.ssh"
if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$SSH_KEY" -N "$SSH_PASSPHRASE"
fi
if [[ ! -f "$SSH_PUBLIC" ]]; then
    ssh-keygen -y -f "$SSH_KEY" > "$SSH_PUBLIC"
fi
if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    eval "$(ssh-agent -s)"
fi
echo "Adicionando a chave SSH ao agente sem solicitar entrada adicional."
if ! ssh-add "$SSH_KEY" </dev/null; then
    record_failure "SSH agent (chave nao adicionada)"
fi
chmod 600 "$SSH_KEY"
chmod 644 "$SSH_PUBLIC"

# Atualiza os repositorios antes de instalar qualquer pacote.
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
sudo add-apt-repository universe -y
sudo add-apt-repository ppa:agornostal/ulauncher -y
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y

# Instala ferramentas usadas pelas etapas seguintes do script.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl snapd ubuntu-drivers-common
ensure_git

# Instala primeiro o driver recomendado para que CUDA, Vulkan e prime-select
# encontrem o hardware configurado nas etapas seguintes.
NVIDIA_AVAILABLE=false
if command -v ubuntu-drivers >/dev/null 2>&1; then
    NVIDIA_DRIVER="$(ubuntu-drivers devices | awk '/recommended/{print $3; exit}')"
    if [[ -n "$NVIDIA_DRIVER" ]]; then
        install_apt_packages "$NVIDIA_DRIVER"
        if is_apt_package_installed "$NVIDIA_DRIVER"; then
            NVIDIA_AVAILABLE=true
        fi
    fi
else
    record_failure "Ubuntu drivers (command not available)"
fi

# Instala os demais pacotes APT em lote. Se o lote falhar, a funcao tenta
# novamente pacote por pacote para identificar os itens problematicos.
install_apt_packages \
    bleachbit fastfetch lazygit gnome-snapshot net-tools nvtop \
    p7zip-full tree unison unison-gtk vim wget \
    vulkan-tools mesa-utils \
    i3 xserver-xorg-input-all xinput pulseaudio-utils playerctl \
    alacritty kitty ulauncher feh

if [[ "$NVIDIA_AVAILABLE" == true ]]; then
    install_apt_packages nvidia-cuda-toolkit
fi

# Deixa a atualizacao do sistema para depois das instalacoes APT.
sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# So altera o GRUB em computadores nos quais um driver NVIDIA foi instalado.
if [[ "$NVIDIA_AVAILABLE" == true ]]; then
    if command -v prime-select >/dev/null 2>&1; then
        run_optional "NVIDIA Prime" sudo prime-select nvidia
    else
        record_failure "NVIDIA Prime (command not available)"
    fi

    GRUB_FILE="/etc/default/grub"
    KERNEL_PARAM="acpi_backlight=native"
    if ! sudo grep -Fq "${KERNEL_PARAM}" "${GRUB_FILE}"; then
        sudo sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ ${KERNEL_PARAM}\"/" "${GRUB_FILE}"
        sudo update-grub
    fi
fi

# Estas configuracoes dependem de uma sessao grafica do GNOME ativa.
run_optional "GNOME animations" gsettings set org.gnome.desktop.interface enable-animations true
run_optional "GNOME file sorting" gsettings set org.gnome.nautilus.preferences default-sort-order type

# Mantem o ~/.bashrc existente e adiciona as configuracoes do projeto uma vez.
## O script e executado a partir do diretorio do projeto.
BASHRC_FILE="$HOME/.bashrc"
BASHRC_START="# >>> ubuntu project settings >>>"
BASHRC_END="# <<< ubuntu project settings <<<"
if ! grep -Fq "$BASHRC_START" "$BASHRC_FILE" 2>/dev/null; then
    {
        printf '\n%s\n' "$BASHRC_START"
        cat .bashrc
        printf '\n%s\n' "$BASHRC_END"
    } >> "$BASHRC_FILE"
fi
if [[ "$(readlink -f .gitconfig)" != "$(readlink -f ~/.gitconfig)" ]]; then
    cp .gitconfig ~/.gitconfig
fi
mkdir -p ~/.config/i3 && cp .config/i3/config ~/.config/i3/config
mkdir -p ~/.unison && cp .unison/sync.prf ~/.unison/sync.prf

# Configura assinatura SSH e um arquivo que permite validar essa assinatura.
if command -v git >/dev/null 2>&1; then
    GIT_ALLOWED_SIGNERS="$HOME/.config/git/allowed_signers"
    mkdir -p -m 700 "$(dirname "$GIT_ALLOWED_SIGNERS")"
    printf '%s namespaces="git" %s\n' "$EMAIL" "$(awk '{print $1, $2}' "$SSH_PUBLIC")" \
        > "$GIT_ALLOWED_SIGNERS"
    chmod 600 "$GIT_ALLOWED_SIGNERS"

    # Uma entrada inválida no arquivo copiado não pode interromper as demais instalações.
    if ! git config --global core.editor "nano"; then
        record_failure "Git configuration (invalid ~/.gitconfig)"
    else
        git config --global user.email "$EMAIL"
        git config --global user.name "$USERNAME"
        git config --global gpg.format ssh
        git config --global user.signingKey "$SSH_PUBLIC"
        git config --global gpg.ssh.allowedSignersFile "$GIT_ALLOWED_SIGNERS"
        git config --global commit.gpgsign true
        git config --global tag.gpgsign true
    fi
else
    record_failure "Git (not installed)"
fi

# Garante que o servico Snap esteja pronto antes de instalar os aplicativos.
if ! command -v snap >/dev/null 2>&1; then
    run_optional "Snapd" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
fi
if command -v snap >/dev/null 2>&1; then
    run_optional "Snapd (socket)" sudo systemctl enable --now snapd.socket
    run_optional "Snapd (seed)" sudo snap wait system seed.loaded

    # Os arrays agrupam os pacotes conforme as opcoes necessarias para instala-los.
    STANDARD_SNAPS=(
        keepassxc 1password 2fa nordpass nordvpn ngrok
        anki-desktop notion-snap-reborn xmind kbruch discord
        btop fast firefox libreoffice spotify thunderbird wethr
        teleprompter vlc gimp audacity foobar2000 gnome-boxes
        obs-studio steam docker beekeeper-studio dbeaver-ce drawio
        fx heidisql-wine insomnia mysql-workbench-community
        notepad-plus-plus onefetch postman weka space
    )
    EDGE_SNAPS=(authenticator)
    CLASSIC_SNAPS=(
        obsidian blender code sublime-text aws-cli eclipse
        netbeans sublime-merge waveterm
        android-studio clion datagrip dataspell goland
        intellij-idea-ultimate phpstorm pycharm-professional rider
        rubymine rustrover webstorm
    )

    for package in "${STANDARD_SNAPS[@]}"; do
        install_snap_package "$package"
    done
    for package in "${EDGE_SNAPS[@]}"; do
        install_snap_package "$package" --edge
    done
    for package in "${CLASSIC_SNAPS[@]}"; do
        install_snap_package "$package" --classic
    done

    if sudo snap list nordpass >/dev/null 2>&1 \
        && ! sudo snap connections nordpass | grep -Fq 'password-manager-service'; then
        if ! sudo snap connect nordpass:password-manager-service; then
            record_failure "Snap connection: nordpass:password-manager-service"
        fi
    fi
else
    record_failure "Snapd (command not available)"
fi

# Adiciona o usuario ao grupo Docker para permitir seu uso sem sudo.
if ! getent group docker >/dev/null; then
    sudo addgroup --system docker
fi
if ! groups "$USER" | grep -qw docker; then
    sudo adduser "$USER" docker
fi

# Instala o NVM em um diretorio do usuario e usa esse ambiente para o Node.js.
NVM_INSTALLER="$REMOTE_DIR/nvm-install.sh"
if download_remote "NVM" "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh" "$NVM_INSTALLER"; then
    run_remote_script "NVM (install)" "$NVM_INSTALLER"
fi

if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "$HOME/.nvm/nvm.sh"
    run_optional "Node.js 24" nvm install 24
    run_optional "@google/gemini-cli" npm install -g @google/gemini-cli
    run_optional "@anthropic-ai/claude-code" npm install -g @anthropic-ai/claude-code
    run_optional "@github/copilot" npm install -g @github/copilot
    run_optional "@openai/codex" npm install -g @openai/codex
else
    record_failure "NVM (not installed)"
fi

run_optional "Zed" bash -c 'curl -f https://zed.dev/install.sh | sh'

# Baixa o instalador para um arquivo temporario antes de executa-lo.
LAZYDOCKER_INSTALLER="$REMOTE_DIR/lazydocker-install.sh"
if download_remote "Lazydocker" "https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh" "$LAZYDOCKER_INSTALLER"; then
    run_remote_script "Lazydocker (install)" "$LAZYDOCKER_INSTALLER"
fi

# O Zen Browser e distribuido como um arquivo TAR para a arquitetura ARM64.
ZEN_ARCHIVE="$REMOTE_DIR/zen.linux-aarch64.tar.xz"
if download_remote "Zen Browser" "https://github.com/zen-browser/desktop/releases/download/1.21.12b/zen.linux-aarch64.tar.xz" "$ZEN_ARCHIVE"; then
    run_optional "Zen Browser (install)" install_zen_browser "$ZEN_ARCHIVE"
fi

# Verifica se o download e um arquivo TAR valido antes de chama-lo pelo pip.
install_apt_packages python3-pyqt6 libsecp256k1-dev python3-cryptography python3-setuptools python3-pip
ELECTRUM_ARCHIVE="$REMOTE_DIR/Electrum-4.6.2.tar.gz"
if download_remote "Electrum" "https://download.electrum.org/4.6.2/Electrum-4.6.2.tar.gz" "$ELECTRUM_ARCHIVE"; then
    if tar -tzf "$ELECTRUM_ARCHIVE" >/dev/null 2>&1; then
        run_optional "Electrum (install)" python3 -m pip install --break-system-packages --user "$ELECTRUM_ARCHIVE"
    else
        record_failure "Electrum (invalid archive)"
    fi
fi

# Faz o download do instalador antes da execucao e registra falhas dos modelos
# individualmente, permitindo que os demais modelos continuem sendo tentados.
OLLAMA_INSTALLER="$REMOTE_DIR/ollama-install.sh"
if download_remote "Ollama" "https://ollama.com/install.sh" "$OLLAMA_INSTALLER"; then
    run_remote_script "Ollama (install)" "$OLLAMA_INSTALLER"
fi
if command -v ollama >/dev/null 2>&1; then
    run_optional "Ollama: deepseek-v4-pro:cloud" ollama pull deepseek-v4-pro:cloud
    run_optional "Ollama: deepseek-v4-flash:cloud" ollama pull deepseek-v4-flash:cloud
    run_optional "Ollama: glm-5.2:cloud" ollama pull glm-5.2:cloud
    run_optional "Ollama: kimi-k2.7-code:cloud" ollama pull kimi-k2.7-code:cloud
else
    record_failure "Ollama (not installed)"
fi

# A limpeza e opcional: uma falha aqui nao impede o relatorio final.
run_optional "APT autoremove" sudo apt-get autoremove --purge -y
run_optional "APT autoclean" sudo apt-get autoclean
run_optional "APT clean" sudo apt-get clean
run_optional "Journal cleanup" sudo journalctl --vacuum-size=1G
run_optional "BleachBit cleanup" sudo bleachbit --clean system.cache system.trash system.tmp
run_optional "Filesystem trim" sudo fstrim -av

clear
run_optional "Fastfetch" fastfetch
write_failure_report

if [[ "$REBOOT_AFTER_INSTALL" == true ]]; then
    sudo reboot
fi

exit 0
