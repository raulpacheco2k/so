#!/bin/bash

# Interrompe em erros, variaveis ausentes e falhas dentro de pipelines.
set -Eeuo pipefail
# Mostra a linha e o comando que causaram uma falha antes de sair.
trap 'status=$?; echo "Erro na linha $LINENO (codigo $status): $BASH_COMMAND" >&2; exit "$status"' ERR
# Evita que instaladores do APT parem para perguntas de configuracao.
export DEBIAN_FRONTEND=noninteractive
# Arquivos criados pelo instalador (especialmente logs e temporarios) ficam
# privados por padrao. Arquivos publicos recebem modo explicito mais adiante.
umask 077

# Mantem um log acumulado no HOME, inclusive quando o script e iniciado via curl.
LOG_FILE="$HOME/environment_configuration_log.txt"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

FAILED_INSTALLS=()
FAILURE_REPORT="$HOME/environment_configuration_failures.txt"
REMOTE_DIR="$(mktemp -d)"
REPOSITORY_URL="https://github.com/raulpacheco2k/so.git"
REPOSITORY_DIR="$HOME/so"
SUDO_KEEPALIVE_PID=""
EMAIL="${UBUNTU_SETUP_EMAIL:-}"
USERNAME="${UBUNTU_SETUP_USERNAME:-}"
REBOOT_AFTER_INSTALL="${UBUNTU_SETUP_REBOOT:-false}"
SSH_PASSPHRASE=""
PROJECT_DIR=""
CURRENT_USERNAME="$(id -un)"
APT_UPDATED=false
STEP_NUMBER=0

# O nome digitado para o Git nao altera o usuario real que executa o script.
# Isso evita aplicar grupos, arquivos e permissoes no usuario errado.
INSTALL_USER="$CURRENT_USERNAME"

section() {
    STEP_NUMBER=$((STEP_NUMBER + 1))
    printf '\n[%02d] %s\n' "$STEP_NUMBER" "$1"
}

# Usa a pasta do script, em vez do diretorio de onde ele foi chamado.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    cd "$PROJECT_DIR"
fi
if [[ -n "${UBUNTU_SETUP_REPOSITORY_DIR:-}" ]]; then
    REPOSITORY_DIR="$UBUNTU_SETUP_REPOSITORY_DIR"
fi
REPOSITORY_DIR="${REPOSITORY_DIR/#\~/$HOME}"
if [[ "$REPOSITORY_DIR" != /* ]]; then
    REPOSITORY_DIR="$PWD/$REPOSITORY_DIR"
fi
trap 'if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; fi; rm -rf "$REMOTE_DIR"' EXIT

record_failure() {
    FAILED_INSTALLS+=("$1")
}

is_apt_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null \
        | grep -Fq 'install ok installed'
}

apt_update() {
    if [[ "$APT_UPDATED" == true ]]; then
        return 0
    fi

    sudo apt-get -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 update
    APT_UPDATED=true
}

apt_update_force() {
    sudo apt-get -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 update
    APT_UPDATED=true
}

apt_install() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get \
        -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 install -y "$@"
}

apt_upgrade() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get \
        -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 upgrade -y
}

apt_package_has_candidate() {
    local package="$1"

    apt-cache policy "$package" 2>/dev/null \
        | grep -Eq '^ Candidate: [^ (]'
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

    if apt_install "${pending[@]}"; then
        return 0
    fi

    # Tenta individualmente apenas para identificar quais pacotes falharam.
    for package in "${pending[@]}"; do
        if ! is_apt_package_installed "$package"; then
            if apt_install "$package"; then
                continue
            fi
            record_failure "APT: $package"
        fi
    done
}

project_files_are_present() {
    local required_file

    [[ -n "$PROJECT_DIR" ]] || return 1
    for required_file in .bashrc .gitconfig .codex/config.toml \
        .config/alacritty/alacritty.toml \
        .config/i3/config .config/i3/lock.sh .config/i3/keyboard.sh \
        .config/i3/monitor-hotplug.sh \
        .config/i3/dot-hands.jpg \
        .config/i3/success-delay.sh .config/i3/vol.sh \
        .config/i3/audio-lib.sh .config/i3/audio-menu.sh \
        .config/i3/wifi-menu.sh .config/i3/bluetooth-menu.sh \
        .config/i3/walker-service.sh \
        .config/i3/walker-close-on-blur.sh \
        .config/autostart/nm-applet.desktop \
        .config/i3status/config .config/i3status/i3status_filter.py \
        .config/i3status/status_command.sh \
        .config/picom/picom.conf .config/dunst/dunstrc \
        .config/tmux/tmux.conf \
        .config/walker/config.toml .config/btop/btop.conf \
        .config/walker/themes/vantablack/layout.xml \
        .config/walker/themes/vantablack/style.css \
        .config/btop/themes/grayscale.theme \
        .config/wireplumber/wireplumber.conf.d/51-ubuntu-bluetooth.conf \
        .unison/sync.prf; do
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
    apt_update
    apt_install git
    command -v git >/dev/null 2>&1
}

# Instala um Snap somente quando ele ainda nao estiver instalado.
install_snap_package() {
    local package="$1"
    shift

    if sudo snap list "$package" >/dev/null 2>&1; then
        printf '  - Snap %s ja instalado.\n' "$package"
        return 0
    fi

    printf '  - Instalando Snap %s...\n' "$package"
    if ! sudo snap install "$package" "$@"; then
        printf '    falhou; a instalacao continuara.\n'
        record_failure "Snap: $package"
    else
        printf '    concluido.\n'
    fi
}

# Instala um grupo de Snaps em uma unica transacao. Se algum nome invalido
# fizer a transacao falhar, volta ao modo individual para preservar o relatorio
# preciso e instalar os demais pacotes.
install_snap_group() {
    local group_name="$1"
    local option="${2:-}"
    shift 2
    local package
    local pending=()
    local snap_options=(--transaction=all-snaps)

    if [[ -n "$option" ]]; then
        snap_options+=("$option")
    fi

    for package in "$@"; do
        if ! sudo snap list "$package" >/dev/null 2>&1; then
            pending+=("$package")
        fi
    done

    if ((${#pending[@]} == 0)); then
        printf '  - Snaps %s ja instalados.\n' "$group_name"
        return 0
    fi

    printf '  - Instalando grupo de Snaps %s (%d itens)...\n' \
        "$group_name" "${#pending[@]}"
    if sudo snap install "${snap_options[@]}" "${pending[@]}"; then
        printf '    grupo concluido.\n'
        return 0
    fi

    printf '    grupo falhou; tentando os itens individualmente.\n'
    for package in "${pending[@]}"; do
        if [[ -n "$option" ]]; then
            install_snap_package "$package" "$option"
        else
            install_snap_package "$package"
        fi
    done
}

# Executa uma etapa opcional sem interromper as demais instalacoes.
run_optional() {
    local description="$1"
    shift

    printf '  - %s...\n' "$description"
    if ! "$@"; then
        printf '    falhou; a instalacao continuara.\n'
        record_failure "$description"
    else
        printf '    concluido.\n'
    fi
}

# Baixa somente por HTTPS e exige uma resposta HTTP bem-sucedida e nao vazia.
download_remote() {
    local description="$1"
    local url="$2"
    local output="$3"

    if [[ "$url" != https://* ]]; then
        record_failure "$description (non-HTTPS URL)"
        return 1
    fi

    local curl_options=(
        --fail --location --retry 3
        --connect-timeout 15 --proto '=https' --tlsv1.2
    )
    # retry-all-errors nao existe em versoes antigas do curl ainda presentes
    # em algumas imagens Ubuntu.
    if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
        curl_options+=(--retry-all-errors)
    fi
    if [[ -r /dev/tty ]]; then
        curl_options+=(--progress-bar)
    else
        curl_options+=(--silent --show-error)
    fi

    if ! curl "${curl_options[@]}" "$url" --output "$output"; then
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

# Cria a entrada de launcher do Zen para aparecer no menu de aplicacoes.
write_zen_desktop_entry() {
    mkdir -p "$HOME/.local/share/applications"
    cat > "$HOME/.local/share/applications/zen.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Zen
GenericName=Web Browser
Comment=Zen Browser
Exec=$HOME/.local/bin/zen %U
Terminal=false
Categories=Network;WebBrowser;
Keywords=zen;browser;internet;
EOF
    chmod 644 "$HOME/.local/share/applications/zen.desktop"
}

install_zen_browser() {
    local archive="${1:-}"
    local staging_dir="$REMOTE_DIR/zen-extracted"
    local install_dir="$HOME/.local/opt/zen"
    local bin_link="$HOME/.local/bin/zen"

    # Idempotente: com o binario instalado e funcional, apenas garante o
    # launcher e encerra sem baixar o TAR novamente.
    if [[ -x "$bin_link" ]] && "$bin_link" --version >/dev/null 2>&1; then
        write_zen_desktop_entry
        return 0
    fi

    if [[ -z "$archive" ]]; then
        echo "Zen Browser: binario ausente e nenhum arquivo fornecido" >&2
        record_failure "Zen Browser (missing archive)"
        return 1
    fi

    # O arquivo da release contem o diretorio zen na raiz do TAR.
    if ! tar -tJf "$archive" >/dev/null 2>&1; then
        echo "Zen Browser: arquivo invalido" >&2
        record_failure "Zen Browser (invalid archive)"
        return 1
    fi

    rm -rf "$staging_dir"
    mkdir -p "$staging_dir"
    if ! tar -xJf "$archive" -C "$staging_dir"; then
        echo "Zen Browser: falha ao extrair o TAR" >&2
        record_failure "Zen Browser (extract failed)"
        return 1
    fi
    if [[ ! -x "$staging_dir/zen/zen" ]]; then
        echo "Zen Browser: executaivel nao encontrado no TAR" >&2
        record_failure "Zen Browser (executable not found)"
        return 1
    fi

    rm -rf "$install_dir"
    if ! mv "$staging_dir/zen" "$install_dir"; then
        echo "Zen Browser: falha ao mover para $install_dir" >&2
        record_failure "Zen Browser (move failed)"
        return 1
    fi
    ln -sfn "$install_dir/zen" "$bin_link"
    chmod 755 "$install_dir/zen" "$bin_link"
    if [[ ! -x "$bin_link" ]]; then
        echo "Zen Browser: link $bin_link invalido" >&2
        record_failure "Zen Browser (link failed)"
        return 1
    fi

    write_zen_desktop_entry
    "$bin_link" --version >/dev/null 2>&1
}

install_walker() {
    local archive="$1"
    local staging_dir="$REMOTE_DIR/walker-extracted"
    local install_dir="$HOME/.local/opt/walker"

    # O arquivo da release contem o binario walker na raiz do TAR.
    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        record_failure "Walker (invalid archive)"
        return 1
    fi

    mkdir -p "$staging_dir" "$HOME/.local/bin" "$(dirname "$install_dir")"
    tar -xzf "$archive" -C "$staging_dir"
    if [[ ! -x "$staging_dir/walker" ]]; then
        record_failure "Walker (executable not found)"
        return 1
    fi

    rm -rf "$install_dir"
    if ! mv "$staging_dir/walker" "$install_dir"; then
        record_failure "Walker (move failed)"
        return 1
    fi
    chmod 755 "$install_dir"
    ln -sfn "$install_dir" "$HOME/.local/bin/walker"
    chmod 755 "$HOME/.local/bin/walker"
    [[ -x "$HOME/.local/bin/walker" ]]
}

install_elephant_component() {
    local archive="$1"
    local component="$2"
    local destination="${3:-$component}"
    local staging_dir="$REMOTE_DIR/elephant-${component}-extracted"
    local source

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        record_failure "Elephant ${component} (invalid archive)"
        return 1
    fi

    rm -rf "$staging_dir"
    mkdir -p "$staging_dir" "$HOME/.local/bin" "$HOME/.config/elephant"
    tar -xzf "$archive" -C "$staging_dir"
    # Aceita nome exato ou com sufixo (ex.: "elephant-linux-amd64" para a
    # release do binario principal) e evita arquivos de exemplo/leitura.
    source="$(find "$staging_dir" -type f \( -name "$component" \
        -o -name "${component}*" \) -print -quit)"
    if [[ -z "$source" ]]; then
        record_failure "Elephant ${component} (file not found)"
        return 1
    fi

    if [[ "$destination" == "elephant" ]]; then
        install -m 755 "$source" "$HOME/.local/bin/elephant"
        chmod 755 "$HOME/.local/bin/elephant"
    else
        install -m 644 "$source" "$HOME/.config/elephant/$destination"
        chmod 644 "$HOME/.config/elephant/$destination"
    fi
}

install_local_configs() {
    mkdir -p "$HOME/.config" "$HOME/.codex"

    install -m 600 .codex/config.toml "$HOME/.codex/config.toml"
    cp -a .config/. "$HOME/.config/"

    # Configuracoes de usuario nao sao executaveis; scripts usados pelo i3 e
    # pelo filtro recebem modo explicito para nao depender do umask do host.
    chmod 600 "$HOME/.codex/config.toml" \
        "$HOME/.config/btop/btop.conf"
    chmod 644 "$HOME/.config/btop/themes/grayscale.theme"
    chmod 755 "$HOME/.config/i3/lock.sh" \
        "$HOME/.config/i3/keyboard.sh" \
        "$HOME/.config/i3/monitor-hotplug.sh" \
        "$HOME/.config/i3/success-delay.sh" \
        "$HOME/.config/i3/vol.sh" \
        "$HOME/.config/i3/audio-menu.sh" \
        "$HOME/.config/i3/wifi-menu.sh" \
        "$HOME/.config/i3/bluetooth-menu.sh" \
        "$HOME/.config/i3/walker-service.sh" \
        "$HOME/.config/i3/walker-close-on-blur.sh" \
        "$HOME/.config/i3status/i3status_filter.py" \
        "$HOME/.config/i3status/status_command.sh"

    # O binding do i3 (vol up/down/mute) resolve 'vol' pelo PATH.
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$HOME/.config/i3/vol.sh" "$HOME/.local/bin/vol"
    chmod 755 "$HOME/.local/bin/vol"
}

stop_nm_applet() {
    if pgrep -x nm-applet >/dev/null 2>&1; then
        echo "Encerrando o nm-applet; a bandeja continuara disponivel para outros aplicativos."
        pkill -x nm-applet || true
    fi
}

detect_gpu_vendor() {
    local gpu_info

    GPU_VENDOR="unknown"
    if ! command -v lspci >/dev/null 2>&1; then
        return 0
    fi

    gpu_info="$(lspci -nn | awk '/VGA compatible controller|3D controller|Display controller/')"
    if [[ -z "$gpu_info" ]]; then
        return 0
    fi

    if grep -Eiq 'NVIDIA|GeForce|\[10de:' <<<"$gpu_info"; then
        GPU_VENDOR="nvidia"
    elif grep -Eiq 'AMD|ATI|Advanced Micro Devices|\[1002:' <<<"$gpu_info"; then
        GPU_VENDOR="amd"
    elif grep -Eiq 'Intel' <<<"$gpu_info"; then
        GPU_VENDOR="intel"
    fi
}

# Normaliza a arquitetura do host antes de baixar binarios de releases. Os
# pacotes APT continuam sendo resolvidos pelo proprio apt; esta informacao so
# e usada para impedir que um binario x86 seja instalado em outro host.
detect_host_arch() {
    local dpkg_arch=""
    local machine=""

    if command -v dpkg >/dev/null 2>&1; then
        dpkg_arch="$(dpkg --print-architecture 2>/dev/null || true)"
    fi
    machine="$(uname -m 2>/dev/null || true)"

    case "$dpkg_arch" in
        amd64|arm64|armhf)
            HOST_ARCH="$dpkg_arch"
            ;;
        *)
            case "$machine" in
                x86_64) HOST_ARCH=amd64 ;;
                aarch64|arm64) HOST_ARCH=arm64 ;;
                armv7l|armv6l) HOST_ARCH=armhf ;;
                *) HOST_ARCH=unknown ;;
            esac
            ;;
    esac
}

validate_host() {
    # Valida os pre-requisitos do host antes de solicitar credenciais.
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
}

validate_environment() {
    # Valida os arquivos do projeto depois do bootstrap.
    if ! project_files_are_present; then
        echo "Os arquivos de configuracao do projeto nao foram encontrados." >&2
        exit 1
    fi

    local script
    for script in "$PROJECT_DIR"/.config/i3/*.sh; do
        if ! bash -n "$script"; then
            echo "Sintaxe invalida no script de i3: $script" >&2
            exit 1
        fi
    done
}

bootstrap_project() {
    # Quando o script veio pelo curl, baixa o repositorio que contem os arquivos
    # de configuracao e continua a partir dele no mesmo processo. Isso evita
    # transportar senhas por ambiente durante uma reexecucao.
    if project_files_are_present; then
        return 0
    fi

    echo "Arquivos do projeto ausentes. Preparando o repositorio."

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
}

collect_user_input() {
    local input
    local sudo_password
    local reboot_confirmation
    local system_username="$CURRENT_USERNAME"

    if [[ ! -r /dev/tty ]]; then
        echo "Este script precisa de um terminal para receber os dados iniciais." >&2
        echo "Execute-o em um terminal interativo." >&2
        exit 1
    fi

    # A ordem desta funcao e intencional: username, e-mail, passphrase SSH,
    # senha do sudo e decisao de reinicio. Nenhum segredo e exportado.
    if [[ -z "$USERNAME" ]]; then
        read -r -p "Informe seu username [${system_username}]: " input </dev/tty
        USERNAME="${input:-$system_username}"
    fi

    if [[ -z "$EMAIL" ]]; then
        read -r -p "Informe seu e-mail: " EMAIL </dev/tty
    fi

    if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
        read -r -s -p "Informe a senha da chave SSH (vazio para sem senha): " SSH_PASSPHRASE </dev/tty
        printf '\n'
    else
        echo "Chave SSH existente: a passphrase nao sera alterada."
    fi

    read -r -s -p "Informe a senha do sudo: " sudo_password </dev/tty
    printf '\n'
    if [[ -n "$sudo_password" ]]; then
        if ! printf '%s\n' "$sudo_password" | sudo -S -p '' -v; then
            unset sudo_password
            echo "Nao foi possivel autenticar no sudo." >&2
            exit 1
        fi
    elif ! sudo -n -v; then
        unset sudo_password
        echo "A senha do sudo nao pode ser vazia neste sistema." >&2
        exit 1
    fi
    # Nao manter a senha em variavel depois da autenticacao do timestamp sudo.
    unset sudo_password

    read -r -p "Reiniciar o computador ao terminar? [s/N]: " reboot_confirmation </dev/tty
    if [[ "$reboot_confirmation" =~ ^[SsYy]$ ]]; then
        REBOOT_AFTER_INSTALL=true
    else
        REBOOT_AFTER_INSTALL=false
    fi

    if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        echo "Informe um e-mail valido." >&2
        exit 1
    fi
    if [[ -z "$USERNAME" ]]; then
        echo "O username nao pode ser vazio." >&2
        exit 1
    fi

    printf '\nConfiguracao: usuario Git %s | e-mail %s | reinicio ao final: %s\n' \
        "$USERNAME" "$EMAIL" "$REBOOT_AFTER_INSTALL"

    # Mantem a credencial sudo valida durante instalacoes longas.
    (
        while sleep 60; do
            sudo -n -v >/dev/null 2>&1 || exit 0
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
        chmod 600 "$FAILURE_REPORT"
        echo "Alguns itens falharam. Consulte: $FAILURE_REPORT"
    else
        rm -f "$FAILURE_REPORT"
        echo "Todos os itens opcionais foram instalados ou configurados."
    fi
}

# Todas as perguntas ficam no inicio para que a instalacao possa prosseguir
# sem depender de novas confirmações durante as etapas demoradas.
section "Coletando os dados iniciais"
validate_host
collect_user_input
bootstrap_project "$@"
validate_environment

section "Configurando a chave SSH"
# Cria a chave SSH apenas quando ela ainda nao existe.
SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_PUBLIC="$SSH_KEY.pub"
mkdir -p -m 700 "$HOME/.ssh"
if [[ ! -O "$HOME/.ssh" ]]; then
    echo "O diretorio ~/.ssh nao pertence ao usuario atual; permissoes nao serao alteradas." >&2
    exit 1
fi
chmod 700 "$HOME/.ssh"
if [[ -L "$SSH_KEY" || -L "$SSH_PUBLIC" ]]; then
    echo "Por seguranca, os arquivos da chave SSH nao podem ser links simbolicos." >&2
    exit 1
fi
if [[ -e "$SSH_KEY" && ! -O "$SSH_KEY" ]] \
    || [[ -e "$SSH_PUBLIC" && ! -O "$SSH_PUBLIC" ]]; then
    echo "Os arquivos da chave SSH nao pertencem ao usuario atual." >&2
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$SSH_KEY" -N "$SSH_PASSPHRASE"
fi
if [[ ! -f "$SSH_PUBLIC" ]]; then
    if ! ssh-keygen -y -f "$SSH_KEY" </dev/null > "$SSH_PUBLIC"; then
        rm -f "$SSH_PUBLIC"
        record_failure "SSH public key (unable to derive)"
    fi
fi
chmod 600 "$SSH_KEY"
if [[ -f "$SSH_PUBLIC" ]]; then
    chmod 644 "$SSH_PUBLIC"
fi
unset SSH_PASSPHRASE

# Chaves protegidas por passphrase nao sao solicitadas novamente nem gravadas
# em ambiente/arquivo. O usuario pode adiciona-las manualmente com ssh-add;
# chaves sem passphrase recebem um lifetime limitado no agente.
if [[ -f "$SSH_PUBLIC" ]]; then
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        if ! eval "$(ssh-agent -s)"; then
            record_failure "SSH agent (unable to start)"
        fi
    fi
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        if ssh-keygen -y -f "$SSH_KEY" </dev/null >/dev/null 2>&1; then
            if ! ssh-add -t 8h "$SSH_KEY" </dev/null; then
                record_failure "SSH agent (key not added)"
            fi
        else
            echo "Chave SSH protegida por passphrase; ela nao sera adicionada automaticamente ao agente."
        fi
    fi
fi
section "Preparando o APT e as dependencias basicas"
apt_update
install_apt_packages \
    ca-certificates curl git pciutils snapd software-properties-common \
    ubuntu-drivers-common

# Universe ja vem habilitado na maioria das instalacoes atuais. So altera as
# fontes e atualiza novamente quando o catalogo nao oferecer btop.
if ! apt_package_has_candidate btop; then
    if command -v add-apt-repository >/dev/null 2>&1; then
        if sudo add-apt-repository universe -y; then
            apt_update_force
        else
            record_failure "APT universe (unable to enable)"
        fi
    else
        record_failure "APT universe (add-apt-repository unavailable)"
    fi
fi

# O PPA so e adicionado quando o Ubuntu nao oferece Ulauncher. Isso reduz uma
# atualizacao de indices e evita uma fonte externa desnecessaria.
if ! apt_package_has_candidate ulauncher; then
    if sudo add-apt-repository ppa:agornostal/ulauncher -y; then
        apt_update_force
    else
        record_failure "Ulauncher PPA"
    fi
fi

if dpkg --audit 2>/dev/null | grep -q .; then
    run_optional "APT (corrigir dependencias quebradas)" apt_install --fix-broken
fi

detect_gpu_vendor
printf 'GPU detectada: %s\n' "$GPU_VENDOR"
detect_host_arch
printf 'Arquitetura detectada: %s\n' "$HOST_ARCH"
NVIDIA_DRIVER_INSTALLED=false
if [[ "$GPU_VENDOR" == nvidia ]]; then
    # ubuntu-drivers so e consultado apenas em hardware NVIDIA; AMD usa o
    # driver amdgpu do kernel e Mesa, sem pacotes proprietarios ou prime-select.
    if command -v ubuntu-drivers >/dev/null 2>&1; then
        NVIDIA_DRIVER="$(ubuntu-drivers devices \
            | awk '$1 == "driver" && /recommended/ {sub(/.*: /, ""); sub(/ .*/, ""); print; exit}')"
        if [[ -n "$NVIDIA_DRIVER" ]]; then
            install_apt_packages "$NVIDIA_DRIVER"
            if is_apt_package_installed "$NVIDIA_DRIVER"; then
                NVIDIA_DRIVER_INSTALLED=true
            fi
        else
            run_optional "NVIDIA driver (automatic)" sudo ubuntu-drivers install
            if command -v nvidia-smi >/dev/null 2>&1; then
                NVIDIA_DRIVER_INSTALLED=true
            else
                record_failure "NVIDIA driver (recommended package not found)"
            fi
        fi
    else
        record_failure "Ubuntu drivers (command not available)"
    fi
elif [[ "$GPU_VENDOR" == amd ]]; then
    echo "AMD: mantendo amdgpu/Mesa do Ubuntu; nenhuma configuracao NVIDIA sera aplicada."
elif [[ "$GPU_VENDOR" == intel ]]; then
    echo "Intel: mantendo o driver/Mesa do Ubuntu."
else
    echo "GPU nao identificada; seguindo com pacotes graficos genericos."
fi

# Uma unica transacao para o conjunto principal reduz locks e reprocessamento
# do APT. Se houver falha, install_apt_packages identifica os pacotes isolados.
install_apt_packages \
    alacritty bluez bleachbit btop brightnessctl build-essential ca-certificates \
    autoconf automake libtool pkg-config \
    libpam0g-dev libcairo2-dev libfontconfig1-dev \
    libxcb1-dev libxcb-util-dev libxcb-icccm4-dev libxcb-keysyms1-dev \
    libxcb-randr0-dev libxcb-xinerama0-dev libxcb-xrm-dev \
    libxcb-composite0-dev libxcb-cursor-dev libxcb-image0-dev \
    libxcb-render-util0-dev libev-dev libxkbcommon-dev libxkbcommon-x11-dev \
    libjpeg-dev libgif-dev libsecp256k1-dev \
    feh fastfetch flameshot gnome-snapshot i3 i3status jq kitty lazygit \
    dunst libgtk4-layer-shell0 mesa-utils net-tools nvtop p7zip-full picom \
    libnotify-bin playerctl pulseaudio-utils python3-cryptography python3-pil python3-pip \
    python3-pyqt6 python3-setuptools tmux tree unison unison-gtk unzip vim \
    rfkill suckless-tools vulkan-tools wget x11-xkb-utils x11-xserver-utils xdotool xserver-xorg-input-all \
    xss-lock

# Conclui a atualizacao antes de editar configuracoes e reiniciar servicos.
apt_upgrade

# Permite que brightnessctl altere o backlight sem sudo, quando existir esse
# grupo no host. Em desktops sem backlight a ativacao e apenas ignorada.
if ! id -nG "$INSTALL_USER" | grep -qw video; then
    sudo usermod -aG video "$INSTALL_USER"
fi
run_optional "Backlight udev" sudo udevadm trigger --subsystem-match=backlight

# Instala o backend de audio que corresponde ao host. O cliente pactl funciona
# com PulseAudio e com pipewire-pulse; o PipeWire nativo e coberto pelo wpctl.
# O pacote de Bluetooth certo e escolhido conforme o backend, sem nomes de
# hardware, e os servicos de sessao sao habilitados para o proximo login.
install_audio_stack() {
    local backend=""
    local server_info=""
    local package
    local packages=()
    local installable=()

    if command -v pactl >/dev/null 2>&1; then
        server_info="$(pactl info 2>/dev/null || true)"
    fi
    if grep -qi 'PipeWire' <<<"$server_info" \
        || systemctl --user is-active --quiet pipewire-pulse 2>/dev/null; then
        backend=pipewire
    elif grep -qi 'PulseAudio' <<<"$server_info" \
        || systemctl --user is-active --quiet pulseaudio 2>/dev/null; then
        # PulseAudio classico nao fornece BAP/LE Audio. Se o Ubuntu oferecer
        # PipeWire, prepara-lo para o proximo login em vez de manter um backend
        # que so exporia A2DP/HFP.
        if apt_package_has_candidate pipewire \
            && apt_package_has_candidate pipewire-pulse \
            && apt_package_has_candidate wireplumber; then
            backend=pipewire
        else
            backend=pulseaudio
        fi
    elif is_apt_package_installed pipewire \
        || is_apt_package_installed wireplumber; then
        backend=pipewire
    elif is_apt_package_installed pulseaudio; then
        backend=pulseaudio
    elif apt_package_has_candidate pipewire \
        && apt_package_has_candidate pipewire-pulse \
        && apt_package_has_candidate wireplumber; then
        backend=pipewire
    elif apt_package_has_candidate pulseaudio; then
        backend=pulseaudio
    else
        echo "Nenhum backend de audio compativel foi encontrado."
        return 1
    fi

    if [[ "$backend" == pipewire ]]; then
        packages=(pipewire pipewire-pulse wireplumber)
        if apt_package_has_candidate pipewire-audio; then
            packages+=(pipewire-audio)
        fi
        if apt_package_has_candidate libspa-0.2-bluetooth; then
            packages+=(libspa-0.2-bluetooth)
        else
            record_failure "Audio Bluetooth: libspa-0.2-bluetooth (no APT candidate)"
        fi
    else
        packages=(pulseaudio)
        if apt_package_has_candidate pulseaudio-module-bluetooth; then
            packages+=(pulseaudio-module-bluetooth)
        else
            record_failure "Audio Bluetooth: pulseaudio-module-bluetooth (no APT candidate)"
        fi
    fi

    for package in "${packages[@]}"; do
        if apt_package_has_candidate "$package"; then
            installable+=("$package")
        else
            record_failure "Audio: $package (no APT candidate)"
        fi
    done
    if ((${#installable[@]} > 0)); then
        install_apt_packages "${installable[@]}"
    fi

    # Os servicos de sessao sobem no login; habilita-los agora garante o
    # proximo boot sem intervencao, sem reiniciar a sessao em execucao.
    if [[ "$backend" == pipewire ]]; then
        systemctl --user enable pipewire.socket pipewire-pulse.socket \
            wireplumber >/dev/null 2>&1 || true
        systemctl --user enable pipewire pipewire-pulse >/dev/null 2>&1 || true
        systemctl --user disable pulseaudio.socket pulseaudio.service \
            >/dev/null 2>&1 || true
    else
        systemctl --user enable pulseaudio.socket >/dev/null 2>&1 || true
    fi

    AUDIO_BACKEND="$backend"
    printf 'Backend de audio: %s\n' "$backend"
}

# Confirma que a sessao de audio respondeu apos a instalacao, em vez de
# considerar apenas pacotes instalados como sucesso.
validate_audio_stack() {
    if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
        return 0
    fi
    if command -v wpctl >/dev/null 2>&1 && wpctl status >/dev/null 2>&1; then
        return 0
    fi
    echo "Nenhum servidor de audio respondeu apos a instalacao." >&2
    return 1
}

# Edita somente a secao [General], preservando comentarios e demais opcoes.
# KernelExperimental so e adicionado quando o arquivo da versao instalada
# conhece essa chave; isso evita escrever configuracoes invalidas em releases
# antigas, sem impedir LE Audio em BlueZ atual.
configure_bluetooth_main_conf() {
    local conf=/etc/bluetooth/main.conf
    local staged="$REMOTE_DIR/bluetooth-main.conf"
    local backup=/etc/bluetooth/main.conf.ubuntu.bak
    local kernel_supported=false

    if [[ -r "$conf" ]] \
        && grep -Eq '^[[:space:]]*#?[[:space:]]*KernelExperimental[[:space:]]*=' "$conf"; then
        kernel_supported=true
    fi

    if [[ -r "$conf" ]]; then
        awk -v kernel_supported="$kernel_supported" '
            function append_missing() {
                if (in_general && !experimental_seen) {
                    print "Experimental = true"
                    experimental_seen = 1
                }
                if (in_general && kernel_supported == "true" && !kernel_seen) {
                    print "KernelExperimental = true"
                    kernel_seen = 1
                }
            }
            BEGIN {
                in_general = 0
                general_seen = 0
                experimental_seen = 0
                kernel_seen = 0
            }
            /^[[:space:]]*\[/ {
                if ($0 != "[General]" && in_general)
                    append_missing()
                in_general = ($0 == "[General]")
                if (in_general)
                    general_seen = 1
            }
            {
                if (in_general && $0 ~ /^[[:space:]]*#?[[:space:]]*Experimental[[:space:]]*=/) {
                    if (!experimental_seen) {
                        print "Experimental = true"
                        experimental_seen = 1
                    }
                    next
                }
                if (in_general && kernel_supported == "true" \
                    && $0 ~ /^[[:space:]]*#?[[:space:]]*KernelExperimental[[:space:]]*=/) {
                    if (!kernel_seen) {
                        print "KernelExperimental = true"
                        kernel_seen = 1
                    }
                    next
                }
                print
            }
            END {
                if (in_general)
                    append_missing()
                if (!general_seen) {
                    print ""
                    print "[General]"
                    print "Experimental = true"
                    if (kernel_supported == "true")
                        print "KernelExperimental = true"
                }
            }
        ' "$conf" >"$staged"
    else
        {
            printf '[General]\n'
            printf 'Experimental = true\n'
            if [[ "$kernel_supported" == true ]]; then
                printf 'KernelExperimental = true\n'
            fi
        } >"$staged"
    fi

    if cmp -s "$staged" "$conf" 2>/dev/null; then
        BLUETOOTH_CONFIG_CHANGED=false
        return 0
    fi
    if [[ ! -e "$backup" ]]; then
        sudo cp "$conf" "$backup" 2>/dev/null || true
    fi
    sudo install -m 644 "$staged" "$conf"
    BLUETOOTH_CONFIG_CHANGED=true
}

configure_bluetooth_stack() {
    local attempt

    configure_bluetooth_main_conf
    sudo systemctl enable bluetooth >/dev/null 2>&1
    if [[ "${BLUETOOTH_CONFIG_CHANGED:-false}" == true ]]; then
        sudo systemctl restart bluetooth
    else
        sudo systemctl start bluetooth
    fi

    for ((attempt = 0; attempt < 10; attempt++)); do
        if bluetoothctl show 2>/dev/null \
            | grep -Eq '^[[:space:]]*Controller[[:space:]]+'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Gera a regra a partir do controlador hci presente no host, sem depender de
# nome de produto, VID/PID conhecido ou da topologia USB de uma maquina.
configure_bluetooth_power_policy() {
    local rules=/etc/udev/rules.d/99-bluetooth-autosuspend.rules
    local staged="$REMOTE_DIR/bluetooth-autosuspend.rules"
    local hci usb_device hci_real usb_real vendor product key
    local found=0
    declare -A usb_ids=()

    for hci in /sys/class/bluetooth/hci*; do
        [[ -e "$hci" ]] || continue
        hci_real="$(readlink -f "$hci")"

        if [[ -e "$hci/power/control" ]]; then
            printf 'on\n' | sudo tee "$hci/power/control" >/dev/null || true
        fi
        for usb_device in /sys/bus/usb/devices/*; do
            [[ -f "$usb_device/idVendor" && -f "$usb_device/idProduct" ]] || continue
            usb_real="$(readlink -f "$usb_device")"
            case "$hci_real" in
                "$usb_real"/*)
                    vendor="$(<"$usb_device/idVendor")"
                    product="$(<"$usb_device/idProduct")"
                    key="$vendor:$product"
                    usb_ids["$key"]=1
                    found=1
                    if [[ -e "$usb_device/power/control" ]]; then
                        printf 'on\n' | sudo tee "$usb_device/power/control" >/dev/null || true
                    fi
                    break
                    ;;
            esac
        done
    done

    if ((found == 0)); then
        echo "Nenhum controlador Bluetooth com politica de energia configuravel foi detectado."
        return 0
    fi

    printf '# Gerenciado pelo ubuntu.sh; IDs detectados em tempo de instalacao.\n' >"$staged"
    for key in "${!usb_ids[@]}"; do
        IFS=: read -r vendor product <<<"$key"
        printf 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="%s", ATTR{idProduct}=="%s", ATTR{power/control}="on"\n' \
            "$vendor" "$product"
    done | sort >>"$staged"

    if ! cmp -s "$staged" "$rules" 2>/dev/null; then
        sudo install -D -m 644 "$staged" "$rules"
    fi
    sudo udevadm control --reload-rules

    for key in "${!usb_ids[@]}"; do
        IFS=: read -r vendor product <<<"$key"
        for usb_device in /sys/bus/usb/devices/*; do
            [[ -f "$usb_device/idVendor" && -f "$usb_device/idProduct" ]] || continue
            [[ "$(<"$usb_device/idVendor")" == "$vendor" \
                && "$(<"$usb_device/idProduct")" == "$product" ]] || continue
            if [[ -e "$usb_device/power/control" ]] \
                && [[ "$(<"$usb_device/power/control")" != on ]]; then
                return 1
            fi
        done
    done
}

run_optional "Audio stack (backend)" install_audio_stack
run_optional "Audio stack (validacao)" validate_audio_stack
run_optional "Bluetooth LE Audio (BlueZ)" configure_bluetooth_stack
run_optional "Bluetooth power policy (udev)" configure_bluetooth_power_policy


# CUDA e opcional e fica fora da instalacao padrao por ser grande e nao ser
# necessaria para a maioria dos usuarios NVIDIA. Ative com
# UBUNTU_SETUP_INSTALL_CUDA=true quando realmente precisar dela.
if [[ "$NVIDIA_DRIVER_INSTALLED" == true \
    && "${UBUNTU_SETUP_INSTALL_CUDA:-false}" == true ]]; then
    install_apt_packages nvidia-cuda-toolkit
fi

section "Aplicando configuracoes locais"
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
if [[ ! -e "$HOME/.gitconfig" ]]; then
    install -m 600 .gitconfig "$HOME/.gitconfig"
elif ! cmp -s .gitconfig "$HOME/.gitconfig"; then
    echo "Preservando ~/.gitconfig existente; as configuracoes de identidade serao atualizadas abaixo."
fi
install_local_configs
stop_nm_applet
mkdir -p ~/.unison && cp .unison/sync.prf ~/.unison/sync.prf

# ---------------------------------------------------------------------------
# Lock screen estilo Vantablack (Omarchy) via i3lock-color
# ---------------------------------------------------------------------------
section "Instalando e configurando o bloqueio de tela"

# Compila e instala o i3lock-color em ~/.local/bin/i3lock (idempotente).
install_i3lock_color() {
    local build_dir
    local repo_dir

    if [[ -x "$HOME/.local/bin/i3lock" ]]; then
        echo "i3lock-color ja instalado em ~/.local/bin/i3lock"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        record_failure "i3lock-color (git indisponivel)"
        return 1
    fi

    build_dir="$(mktemp -d)"
    # ${build_dir:-} evita que a trap dispare com variavel nao definida fora do
    # contexto da funcao (bash 5.3 + set -u executa a trap RETURN em sources
    # posteriores, como o do nvm.sh, abortando o script).
    trap 'rm -rf "${build_dir:-}"' RETURN

    repo_dir="$build_dir/i3lock-color"
    if ! git clone --depth 1 https://github.com/Raymo111/i3lock-color.git "$repo_dir" >/dev/null 2>&1; then
        record_failure "i3lock-color (clone)"
        return 1
    fi

    if ! (cd "$repo_dir" && autoreconf -fi >/dev/null 2>&1) \
        || ! mkdir -p "$repo_dir/build" \
        || ! (cd "$repo_dir/build" \
            && ../configure --prefix="$HOME/.local" >/dev/null 2>&1) \
        || ! (cd "$repo_dir/build" && make -j"$(nproc)" >/dev/null 2>&1) \
        || ! (cd "$repo_dir/build" && make install >/dev/null 2>&1); then
        record_failure "i3lock-color (build)"
        return 1
    fi

    if [[ -x "$HOME/.local/bin/i3lock" ]]; then
        echo "i3lock-color instalado em ~/.local/bin/i3lock"
    else
        record_failure "i3lock-color (binario ausente apos build)"
        return 1
    fi
}

install_i3lock_color || true

if [[ ! -x "$HOME/.local/bin/i3lock" ]]; then
    echo "AVISO: i3lock-color nao instalado; o lock via \$mod+Shift+l nao funcionara." >&2
fi

# Escreve o stack PAM do locker: sem faildelay (feedback de senha errada
# imediato) e com pam_exec segurando o anel verde no desbloqueio correto.
LOCK_USER="$INSTALL_USER"
LOCK_HOME="$(getent passwd "$LOCK_USER" | cut -d: -f6)"
LOCK_HOME="${LOCK_HOME:-$HOME}"
if [[ -f /etc/pam.d/i3lock && ! -f /etc/pam.d/i3lock.bak ]]; then
    sudo cp /etc/pam.d/i3lock /etc/pam.d/i3lock.bak
fi
printf '%s\n' \
    "#" \
    "# PAM configuration file for the i3lock screen locker." \
    "# Instalado pelo ubuntu.sh (projeto so)." \
    "# - Sem pam_faildelay / pam_sss: feedback de senha errada imediato." \
    "# - pam_unix requisite: falha para na hora (sem delay no erro)." \
    "# - pam_exec: so roda no sucesso, segurando o anel verde ~0.4s." \
    "#" \
    "auth required pam_env.so" \
    "auth requisite pam_unix.so nullok nodelay" \
    "auth [success=ok default=ignore] pam_exec.so ${LOCK_HOME}/.config/i3/success-delay.sh" \
    | sudo tee /etc/pam.d/i3lock >/dev/null

# Avisa se o sistema depender de autenticacao via SSSD/LDAP (stack local).
if systemctl is-active sssd >/dev/null 2>&1; then
    echo "AVISO: SSSD esta ativo; se a autenticacao for de dominio, adicione 'auth sufficient pam_sss.so use_first_pass' ao /etc/pam.d/i3lock." >&2
fi

# Recarrega o i3 e reinicia o xss-lock para aplicar o novo lock/caminho.
if command -v i3-msg >/dev/null 2>&1; then
    i3-msg reload >/dev/null 2>&1 || true
fi
if pgrep -x xss-lock >/dev/null 2>&1; then
    pkill -x xss-lock >/dev/null 2>&1 || true
    setsid xss-lock --transfer-sleep-lock -- ~/.config/i3/lock.sh \
        >/dev/null 2>&1 &
fi

# Configura assinatura SSH e um arquivo que permite validar essa assinatura.
if command -v git >/dev/null 2>&1; then
    # Uma entrada inválida no arquivo copiado não pode interromper as demais instalações.
    if ! git config --global core.editor "nano"; then
        record_failure "Git configuration (invalid ~/.gitconfig)"
    else
        git config --global user.email "$EMAIL"
        git config --global user.name "$USERNAME"
        if [[ -s "$SSH_PUBLIC" ]]; then
            GIT_ALLOWED_SIGNERS="$HOME/.config/git/allowed_signers"
            mkdir -p -m 700 "$(dirname "$GIT_ALLOWED_SIGNERS")"
            printf '%s namespaces="git" %s\n' "$EMAIL" "$(awk '{print $1, $2}' "$SSH_PUBLIC")" \
                > "$GIT_ALLOWED_SIGNERS"
            chmod 600 "$GIT_ALLOWED_SIGNERS"
            git config --global gpg.format ssh
            git config --global user.signingKey "$SSH_PUBLIC"
            git config --global gpg.ssh.allowedSignersFile "$GIT_ALLOWED_SIGNERS"
            git config --global commit.gpgsign true
            git config --global tag.gpgsign true
        else
            record_failure "Git signing (public SSH key unavailable)"
        fi
    fi
else
    record_failure "Git (not installed)"
fi

section "Instalando aplicativos Snap"
# Garante que o servico Snap esteja pronto antes de instalar os aplicativos.
if ! command -v snap >/dev/null 2>&1; then
    run_optional "Snapd" apt_install snapd
fi
if command -v snap >/dev/null 2>&1; then
    run_optional "Snapd (socket)" sudo systemctl enable --now snapd.socket
    run_optional "Snapd (seed)" sudo snap wait system seed.loaded

    # Os arrays agrupam os pacotes conforme as opcoes necessarias para instala-los.
    STANDARD_SNAPS=(
        keepassxc 1password 2fa nordpass nordvpn ngrok
        anki-desktop notion-snap-reborn xmind kbruch discord
        fast firefox libreoffice spotify thunderbird wethr
        vlc gimp audacity foobar2000 gnome-boxes
        obs-studio steam docker beekeeper-studio drawio
        fx heidisql-wine insomnia mysql-workbench-community
        notepad-plus-plus onefetch postman weka space
    )
    EDGE_SNAPS=(authenticator)
    CLASSIC_SNAPS=(
        obsidian blender code sublime-text aws-cli eclipse dbeaver-ce
        netbeans sublime-merge waveterm
        android-studio clion datagrip dataspell goland
        intellij-idea-ultimate phpstorm pycharm-professional rider
        rubymine rustrover webstorm
    )

    install_snap_group "standard" "" "${STANDARD_SNAPS[@]}"
    install_snap_group "edge" --edge "${EDGE_SNAPS[@]}"
    install_snap_group "classic" --classic "${CLASSIC_SNAPS[@]}"

    if sudo snap list nordpass >/dev/null 2>&1 \
        && ! sudo snap connections nordpass | grep -Fq 'password-manager-service'; then
        if ! sudo snap connect nordpass:password-manager-service; then
            record_failure "Snap connection: nordpass:password-manager-service"
        fi
    fi
else
    record_failure "Snapd (command not available)"
fi

# Instala os plugins de persistencia do tmux para que sessoes, janelas e panes
# sejam restauradas mesmo apos um encerramento brusco do servidor.
install_tmux_plugins() {
    local plugin_dir="$HOME/.tmux/plugins"

    mkdir -p "$plugin_dir"

    if [[ ! -d "$plugin_dir/tmux-resurrect/.git" ]]; then
        git clone --depth 1 https://github.com/tmux-plugins/tmux-resurrect \
            "$plugin_dir/tmux-resurrect"
    fi
    if [[ ! -d "$plugin_dir/tmux-continuum/.git" ]]; then
        git clone --depth 1 https://github.com/tmux-plugins/tmux-continuum \
            "$plugin_dir/tmux-continuum"
    fi

    [[ -d "$plugin_dir/tmux-resurrect/.git" \
        && -d "$plugin_dir/tmux-continuum/.git" ]]
}

run_optional "Tmux plugins (resurrect + continuum)" install_tmux_plugins

# Adiciona o usuario ao grupo Docker para permitir seu uso sem sudo.
if ! getent group docker >/dev/null; then
    sudo addgroup --system docker
fi
if ! id -nG "$INSTALL_USER" | grep -qw docker; then
    sudo usermod -aG docker "$INSTALL_USER"
    echo "O grupo docker foi adicionado; ele ficara ativo apos novo login ou reinicio."
fi

section "Instalando ferramentas externas do usuario"
# Instala o NVM em um diretorio do usuario e usa esse ambiente para o Node.js.
NVM_INSTALLER="$REMOTE_DIR/nvm-install.sh"
if download_remote "NVM" "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh" "$NVM_INSTALLER"; then
    run_remote_script "NVM (install)" "$NVM_INSTALLER"
fi

if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "$HOME/.nvm/nvm.sh"
    run_optional "Node.js 24" nvm install 24
    # Uma unica transacao do npm reduz downloads repetidos e o tempo de
    # resolucao das dependencias dos CLIs.
    run_optional "CLIs de IA (npm)" npm install -g \
        @google/gemini-cli @anthropic-ai/claude-code \
        @github/copilot @openai/codex
else
    record_failure "NVM (not installed)"
fi

# Baixa o instalador do Zed antes de executa-lo, assim como os demais scripts
# remotos, e valida sua sintaxe no arquivo local.
ZED_INSTALLER="$REMOTE_DIR/zed-install.sh"
if download_remote "Zed" "https://zed.dev/install.sh" "$ZED_INSTALLER"; then
    run_remote_script "Zed (install)" "$ZED_INSTALLER"
fi

# Baixa o instalador para um arquivo temporario antes de executa-lo.
LAZYDOCKER_INSTALLER="$REMOTE_DIR/lazydocker-install.sh"
if download_remote "Lazydocker" "https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh" "$LAZYDOCKER_INSTALLER"; then
    run_remote_script "Lazydocker (install)" "$LAZYDOCKER_INSTALLER"
fi

# O Zen Browser publica TARs Linux para amd64 e arm64. Se o binario ja estiver
# funcional, nao rebaixa o arquivo novamente.
if [[ -x "$HOME/.local/bin/zen" ]] && "$HOME/.local/bin/zen" --version >/dev/null 2>&1; then
    run_optional "Zen Browser (install)" install_zen_browser
else
    case "$HOST_ARCH" in
        amd64)
            ZEN_ASSET="zen.linux-x86_64.tar.xz"
            ;;
        arm64)
            ZEN_ASSET="zen.linux-aarch64.tar.xz"
            ;;
        *)
            ZEN_ASSET=""
            ;;
    esac
    if [[ -n "$ZEN_ASSET" ]]; then
        ZEN_ARCHIVE="$REMOTE_DIR/$ZEN_ASSET"
        if download_remote "Zen Browser" \
            "https://github.com/zen-browser/desktop/releases/download/1.21.12b/$ZEN_ASSET" \
            "$ZEN_ARCHIVE"; then
            run_optional "Zen Browser (install)" install_zen_browser "$ZEN_ARCHIVE"
        fi
    else
        record_failure "Zen Browser (no Linux asset for architecture: $HOST_ARCH)"
    fi
fi

# O Walker publica a release atual somente para x86_64. Em outra arquitetura
# ele e omitido com diagnostico, sem instalar um binario incorreto; dmenu segue
# sendo o caminho principal dos menus X11.
if [[ "$HOST_ARCH" == amd64 ]]; then
    WALKER_ASSET="walker-v2.17.0-x86_64-unknown-linux-gnu.tar.gz"
    WALKER_ARCHIVE="$REMOTE_DIR/$WALKER_ASSET"
    if download_remote "Walker" \
        "https://github.com/abenz1267/walker/releases/download/v2.17.0/$WALKER_ASSET" \
        "$WALKER_ARCHIVE"; then
        run_optional "Walker (install)" install_walker "$WALKER_ARCHIVE"
    fi
else
    record_failure "Walker (no Linux asset for architecture: $HOST_ARCH)"
fi

# Instala o Elephant e os providers usados pela configuracao do Walker. A
# release atual publica somente amd64; nao tenta executar binarios de outra
# arquitetura e deixa o fallback dmenu disponivel.
# Os binarios sao baixados por release e nao ficam versionados no repositorio.
ELEPHANT_VERSION="v2.22.0"
ELEPHANT_BASE_URL="https://github.com/abenz1267/elephant/releases/download/${ELEPHANT_VERSION}"
if [[ "$HOST_ARCH" == amd64 ]]; then
    ELEPHANT_ARCHIVE="$REMOTE_DIR/elephant-linux-amd64.tar.gz"
    if download_remote "Elephant" \
        "${ELEPHANT_BASE_URL}/elephant-linux-amd64.tar.gz" "$ELEPHANT_ARCHIVE"; then
        run_optional "Elephant (install)" \
            install_elephant_component "$ELEPHANT_ARCHIVE" elephant elephant
    fi
    for provider in calc desktopapplications providerlist runner; do
        PROVIDER_ARCHIVE="$REMOTE_DIR/elephant-${provider}-linux-amd64.tar.gz"
        if download_remote "Elephant provider: ${provider}" \
            "${ELEPHANT_BASE_URL}/${provider}-linux-amd64.tar.gz" "$PROVIDER_ARCHIVE"; then
            run_optional "Elephant provider: ${provider} (install)" \
                install_elephant_component "$PROVIDER_ARCHIVE" "${provider}-linux-amd64.so"
        fi
    done
else
    record_failure "Elephant (no Linux asset for architecture: $HOST_ARCH)"
    for provider in calc desktopapplications providerlist runner; do
        record_failure "Elephant provider: ${provider} (no Linux asset for architecture: $HOST_ARCH)"
    done
fi
if [[ -x "$HOME/.local/bin/elephant" ]]; then
    run_optional "Elephant service" "$HOME/.local/bin/elephant" service enable

    # O unit gerado pelo elephant usa 'ExecStart=elephant', que o systemd user
    # nao resolve em ~/.local/bin (falha 203/EXEC). Garante o caminho absoluto
    # e que o servico suba no login (default.target), antes do i3 mapear a tela.
    ELEPHANT_UNIT="$HOME/.config/systemd/user/elephant.service"
    if [[ -f "$ELEPHANT_UNIT" ]] \
        && ! grep -Eq '^ExecStart=/' "$ELEPHANT_UNIT"; then
        sed -i "s|^ExecStart=.*|ExecStart=$HOME/.local/bin/elephant|" "$ELEPHANT_UNIT"
    fi
    if [[ -f "$ELEPHANT_UNIT" ]] \
        && grep -q 'WantedBy=graphical-session.target' "$ELEPHANT_UNIT"; then
        sed -i 's|WantedBy=graphical-session.target|WantedBy=default.target|' "$ELEPHANT_UNIT"
    fi
    systemctl --user daemon-reload
    systemctl --user disable elephant.service >/dev/null 2>&1 || true
    # O servico pode ser instalado enquanto o script ja roda dentro do i3;
    # importa o ambiente grafico antes do primeiro start para que o provider
    # desktopapplications consiga abrir as janelas selecionadas.
    systemctl --user import-environment \
        DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_DATA_DIRS \
        >/dev/null 2>&1 || true
    run_optional "Elephant service (enable)" systemctl --user enable elephant.service
    # 'enable --now' nao reinicia uma instancia que ja estava ativa sem o
    # ambiente grafico; restart garante que o import acima chegue ao processo.
    run_optional "Elephant service (start)" systemctl --user restart elephant.service
fi

# Instala a JetBrainsMono Nerd Font, usada pelos icones da barra do i3.
# Se a fonte ja estiver instalada (registrada no fontconfig OU com arquivos
# presentes em ~/.local/share/fonts), o passo e considerado sucesso.
install_jetbrains_nerd_font() {
    local font_dir="$HOME/.local/share/fonts"
    local archive="$REMOTE_DIR/jetbrains-mono-nerd.zip"

    font_is_installed() {
        fc-list 2>/dev/null | grep -qi 'JetBrainsMono Nerd Font' \
            || [[ -n "$(find "$font_dir" -maxdepth 1 -iname '*.ttf' -print -quit 2>/dev/null)" ]]
    }

    if font_is_installed; then
        return 0
    fi
    if ! download_remote "JetBrainsMono Nerd Font" \
        "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip" \
        "$archive"; then
        return 1
    fi

    mkdir -p "$font_dir"
    unzip -oq "$archive" -d "$font_dir" '*.ttf' || true
    fc-cache -f "$font_dir" >/dev/null 2>&1 || true

    # Sucesso somente se a fonte terminar instalada; falhas intermediarias
    # do unzip/fc-cache nao podem registrar falsa falha.
    font_is_installed
}
run_optional "JetBrainsMono Nerd Font (install)" install_jetbrains_nerd_font

# Verifica se o download e um arquivo TAR valido antes de chama-lo pelo pip.
ELECTRUM_ARCHIVE="$REMOTE_DIR/Electrum-4.6.2.tar.gz"
if download_remote "Electrum" "https://download.electrum.org/4.6.2/Electrum-4.6.2.tar.gz" "$ELECTRUM_ARCHIVE"; then
    if tar -tzf "$ELECTRUM_ARCHIVE" >/dev/null 2>&1; then
        run_optional "Electrum (install)" python3 -m pip install --break-system-packages --user "$ELECTRUM_ARCHIVE"
    else
        record_failure "Electrum (invalid archive)"
    fi
fi

section "Finalizando e gerando o relatorio"
# A limpeza e opcional: uma falha aqui nao impede o relatorio final.
run_optional "APT autoremove" sudo apt-get autoremove --purge -y
run_optional "APT autoclean" sudo apt-get autoclean
run_optional "APT clean" sudo apt-get clean
run_optional "Journal cleanup" sudo journalctl --vacuum-size=1G
run_optional "BleachBit cleanup" sudo bleachbit --clean system.cache system.trash system.tmp
run_optional "Filesystem trim" sudo fstrim -av

run_optional "Fastfetch" fastfetch
write_failure_report
printf '\nInstalacao finalizada. Log completo: %s\n' "$LOG_FILE"

if [[ "$REBOOT_AFTER_INSTALL" == true ]]; then
    echo "Reiniciando o computador..."
    sudo reboot
fi

exit 0
