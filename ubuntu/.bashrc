# Custom settings for @raulpacheco2k.

alias reboot='sudo reboot'
alias shutdown='sudo shutdown'
alias update='sudo apt update -y'
alias upgrade='sudo apt upgrade -y'
alias up='sudo docker compose up -d'
alias down='sudo docker compose down'
alias f='find . |grep '
alias h='history|grep '
alias ..='cd ..'
alias pg='ping google.com'
alias ports='netstat -tulanp'
alias bashrc='nano ~/.bashrc'

dockerreset() {
  sudo sh -c '
    docker rm -f $(docker ps -aq) 2>/dev/null
    docker rmi -f $(docker images -aq) 2>/dev/null
    docker volume rm $(docker volume ls -q) 2>/dev/null
    docker network rm $(docker network ls -q | grep -vE "^(bridge|host|none)$") 2>/dev/null
    docker secret rm $(docker secret ls -q) 2>/dev/null
    docker config rm $(docker config ls -q) 2>/dev/null
    docker plugin rm -f $(docker plugin ls -q) 2>/dev/null
    docker system prune -af --volumes
  '
 }

d() {
  sudo docker "$@"
}

dockerfixowner() {
  sudo chown -R "$USER:$USER" "${1:-.}"
}

tmux() {
    # Dentro do tmux ou com argumentos, preserve o comportamento original.
    if [[ -n "${TMUX:-}" || $# -gt 0 ]]; then
        command tmux "$@"
        return
    fi

    # Fora do tmux, anexe a uma sessao existente em vez de criar outra.
    if command tmux has-session 2>/dev/null; then
        command tmux attach
        return
    fi

    # Inicie o servidor e aguarde o continuum restaurar o ultimo ambiente.
    command tmux new-session -d -s 0
    local target
    target="$(awk -F '\t' '/^state\t/ {print $2; exit}' \
        "$HOME/.local/share/tmux/resurrect/last" 2>/dev/null)"
    if [[ -n "$target" ]]; then
        for _ in $(seq 1 10); do
            command tmux has-session -t "$target" 2>/dev/null && break
            sleep 1
        done
    fi
    command tmux attach -t "${target:-0}" 2>/dev/null || command tmux attach
}
