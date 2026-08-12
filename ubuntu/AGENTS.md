# Princípios e particularidades do projeto

## Objetivo

Este repositório versiona a configuração pessoal de um ambiente Ubuntu focado em produtividade, com sessão gráfica X11, i3wm e ferramentas de terminal. O objetivo é tornar a instalação reproduzível sem perder os ajustes específicos do computador principal.

## Fonte de verdade

- Os arquivos deste repositório são a fonte de verdade do projeto.
- A pasta `.config/` é copiada para `~/.config/` pelo `ubuntu.sh`.
- Alterações feitas diretamente em `~/.config/` devem ser replicadas no repositório se forem permanentes.
- Não sobrescrever ou descartar alterações existentes sem verificar se são do usuário.

## Componentes

- `ubuntu.sh`: bootstrap do sistema, instalação de dependências, configuração dos serviços e aplicação dos arquivos locais.
- `.config/alacritty/alacritty.toml`: terminal, fonte e cores.
- `.config/btop/`: monitor de recursos e tema grayscale alinhado ao Vantablack.
- `.config/i3/config`: atalhos, regras de janelas, monitores, barra, serviços de inicialização e wallpaper.
- `.config/i3/*.sh`: bloqueio de tela, volume, menus de áudio, Bluetooth e Wi-Fi, atraso de sucesso e integração do Walker com o Elephant.
- `.config/i3/audio-lib.sh`: camada comum de áudio (detecção do backend `pactl`/`wpctl`, descoberta, aplicação, volume e notificações) usada pelo menu de áudio, pelo `vol` e pelo filtro do i3status.
- `.config/wireplumber/wireplumber.conf.d/51-ubuntu-bluetooth.conf`: perfis Bluetooth A2DP, HFP/HSP e LE Audio BAP habilitados por capacidade, sem nomes ou endereços de hardware.
- `.config/i3/dot-hands.jpg`: wallpaper versionado junto da configuração.
- `.config/i3status/config` e `i3status_filter.py`: status da rede, volume, disco, CPU, memória, bateria, data e hora.
- `.config/picom/picom.conf`: composição, sombras, transparência e fade.
- `.config/tmux/tmux.conf`: multiplexador, aparência e persistência de sessões.
- `.config/walker/`: launcher, ações e tema Vantablack do Walker.

O repositório contém configurações adaptadas para i3wm. O tema Vantablack do Omarchy é usado como referência visual e de paleta; não se deve presumir que as configurações oficiais de outros componentes, especialmente Wayland, possam ser copiadas literalmente para este ambiente X11.

## Princípios visuais: Vantablack

A identidade visual deve permanecer escura, monocromática e de baixo contraste agressivo, usando preto como base, branco para informação principal e cinzas para hierarquia e estados secundários. A paleta de referência é:

```text
background             #000000
foreground             #ffffff
accent                 #8d8d8d
selection_foreground   #000000
selection_background   #ffffff
color0                 #404040
color1                 #a4a4a4
color2                 #b6b6b6
color3                 #cecece
color4                 #8d8d8d
color5                 #9b9b9b
color6                 #b0b0b0
color7                 #ececec
color8                 #5c5c5c
color9                 #a4a4a4
color10                #b6b6b6
color11                #cecece
color12                #8d8d8d
color13                #9b9b9b
color14                #b0b0b0
color15                #ffffff
```

As cores semânticas vivas atualmente usadas pelo lock screen e pelo filtro do i3status são exceções funcionais para sucesso, erro, bateria e alertas. Elas não devem ser removidas incidentalmente; convertê-las para uma versão estritamente monocromática é uma decisão visual separada.

## Particularidades de execução

### i3 e Walker

- `$mod+d` inicia o Walker por `$HOME/.local/bin/walker`.
- O Walker deve ser uma janela flutuante, centralizada e sobreposta às demais; a regra depende da classe de janela `walker`.
- `walker-service.sh` prepara o serviço residente do Elephant, importa `DISPLAY`, `XAUTHORITY` e variáveis da sessão, e aguarda o socket antes de iniciar o Walker. Isso evita a mensagem “Waiting for elephant...” e mantém as ações de abrir aplicativos funcionando.
- `walker-close-on-blur.sh` fecha o launcher quando ele perde o foco ou quando há clique fora dele. A proteção com lock evita múltiplas instâncias do observador.
- O wallpaper deve ser referenciado por `~/.config/i3/dot-hands.jpg`. A extensão `.jpg` é intencional, pois o `feh` precisa reconhecer o formato do arquivo.

### i3status

- A barra usa `i3status | python3 ~/.config/i3status/i3status_filter.py`.
- O bloco `wireless _first_` é obrigatório para que o sinal e o SSID do Wi-Fi apareçam na barra.
- O filtro também trata volume, brilho, bateria e normalização do CPU. Não remover o filtro ao ajustar apenas um bloco da barra.
- Cliques no ícone de volume abrem `~/.config/i3/audio-menu.sh`, que troca a saída (sink) e a entrada (source) de áudio via `pactl` (PulseAudio ou pipewire-pulse) ou `wpctl` (PipeWire nativo), migra as streams em execução quando o backend suporta e confirma o resultado com notificação. Nenhum nome de hardware é assumido: os alvos são nomes/IDs reportados pelo servidor.
- O menu Bluetooth (`bluetooth-menu.sh`) nunca abre terminal: dispositivos pareados são gerenciados por submenus gráficos com conectar/desconectar e esquecer dispositivo. Esquecer exige confirmação, desconecta antes de remover o vínculo quando necessário e só confirma sucesso depois que o endereço deixa de aparecer como pareado. O pareamento solicita PIN/passkey/autorização por dmenu ou Walker e vínculos rejeitados por falha de autenticação são atualizados automaticamente. Falhas temporárias não removem vínculos. Após conectar, o sink Bluetooth reportado pelo servidor de áudio é definido como padrão quando disponível.
- O menu Bluetooth pode ser aberto a qualquer momento, mesmo durante uma conexão em andamento: apenas a janela do menu é mutuamente exclusiva. Operações que alteram o estado são serializadas por dispositivo (conectar, desconectar, esquecer e reparar um endereço específico), permitindo operar outros dispositivos durante uma conexão; o pareamento (agente único) e ligar/desligar o rádio continuam usando o lock global. Uma operação no mesmo dispositivo em andamento é recusada com notificação "Dispositivo ocupado".
- O menu de áudio enumera todos os sinks e sources expostos pelo servidor. Quando um microfone Bluetooth depende de um perfil HFP/HSP ou BAP ainda inativo, oferece a ativação explícita do perfil; não deve inventar uma source para um dispositivo que não anuncia capacidade de áudio.
- Portas `not available` não aparecem como selecionáveis no menu; portas com disponibilidade desconhecida são mantidas porque muitos dispositivos Linux as reportam assim mesmo funcionando.
- O `vol` aceita `up|down|mute|source-mute`; o atalho `XF86AudioMicMute` usa `vol source-mute`, não `pactl` direto.
- Fones somente LE Audio (ex.: JBL WAVE FLEX-LE) dependem do perfil BAP do bluetoothd: sem `Experimental = true` em `/etc/bluetooth/main.conf` eles conectam mas nunca aparecem como saída de áudio. O `ubuntu.sh` aplica essa configuração.
- Alterações no `order` do i3status devem preservar a coerência com o parser Python e com os ícones/fontes instalados.

### Inicialização e desempenho

- Serviços de longa duração devem ser iniciados uma vez e reutilizados; não transformar o atalho do Walker em uma sequência de inicializações pesadas.
- Evitar comandos bloqueantes em `exec_always` do i3, pois eles atrasam o restart do i3 e a aparição da barra.
- Depois de mudanças simples na configuração, preferir `i3-msg reload` a um restart completo do i3. Reiniciar o compositor ou a sessão somente quando a alteração exigir isso.

## Portabilidade e dependências

Esta configuração contém escolhas específicas do hardware atual, incluindo nomes de monitores, resolução, dispositivo de entrada, backlight e wallpaper. Antes de reutilizá-la em outro computador, revisar `xrandr`, `xinput`, o dispositivo de backlight e os caminhos em `.config/i3/config`.

O ambiente espera, entre outros, `i3`, `i3status`, `i3lock-color`, `xss-lock`, `feh`, `picom`, `tmux`, `python3`, `jq`, `xdotool`, `brightnessctl`, `pactl`, `playerctl`, Walker, Elephant e a fonte JetBrainsMono Nerd Font. O `ubuntu.sh` instala parte dessas dependências e baixa Walker/Elephant de releases externas; os binários não são armazenados no repositório.

## Regras para alterações

- Fazer a menor alteração que resolva o problema e preservar os atalhos e comportamentos já funcionais.
- Manter scripts idempotentes e com caminhos explícitos sempre que possível.
- Não armazenar credenciais, tokens, caches ou binários gerados.
- Não substituir a paleta Vantablack por cores arbitrárias sem justificar a mudança no contexto da configuração.
- Ao alterar um arquivo de configuração, verificar se o arquivo correspondente em `~/.config/` também precisa ser sincronizado para testar o comportamento ao vivo.
- Usar fontes oficiais para downloads e revisar scripts obtidos pela rede antes de executá-los.

## Validação mínima

Após alterações, executar as verificações aplicáveis:

```bash
bash -n ubuntu.sh
bash -n .config/i3/*.sh
python3 -m py_compile .config/i3status/i3status_filter.py
i3 -C -c .config/i3/config
i3status -c .config/i3status/config
git diff --check
```

As validações dependentes de binários ou de uma sessão gráfica devem ser executadas somente quando o respectivo programa estiver instalado. Mudanças no i3 devem ser testadas em uma sessão X11; mudanças no Walker devem confirmar tanto a centralização quanto a abertura de um aplicativo após pressionar Enter.
