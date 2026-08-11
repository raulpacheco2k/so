# Ubuntu

Este repositório contém scripts e configurações pessoais projetados para automatizar a configuração de um ambiente de desenvolvimento e trabalho produtivo baseado no Ubuntu. O objetivo é garantir a automação, reprodutibilidade e eficiência na instalação de ferramentas essenciais e na aplicação de settings personalizados.

> O código foi analisado com `bash -n ubuntu.sh`.

## Execução

O script instala o Git quando necessário, clona este repositório em `~/so` e continua a execução a partir de `~/so/ubuntu`:

```bash
curl --fail --location https://raw.githubusercontent.com/raulpacheco2k/so/main/ubuntu/ubuntu.sh | bash
```

Revise o script antes de executar comandos baixados da internet.

Na primeira execução interativa, as perguntas aparecem nesta ordem: username
(com o usuário atual como padrão), e-mail, senha da chave SSH, senha do sudo e
reinício ao final. As senhas não são gravadas no log nem exportadas para outro
processo durante o bootstrap. Chaves protegidas por passphrase não são
carregadas automaticamente no agente; use `ssh-add ~/.ssh/id_ed25519` quando
quiser disponibilizá-las na sessão.

O instalador detecta a GPU antes de configurar drivers: mantém amdgpu/Mesa em
máquinas AMD e só instala o driver recomendado e componentes específicos em
hardware NVIDIA. CUDA é opcional e pode ser habilitado com
`UBUNTU_SETUP_INSTALL_CUDA=true`.

## Configuracoes graficas

O instalador aplica as configuracoes versionadas para Alacritty, i3, i3status,
Picom, Tmux e Walker a partir de `.config/`. O Elephant e seus providers sao
baixados das releases oficiais durante a instalacao; os binarios nao sao
armazenados neste repositorio.

O `btop` é instalado pelo APT e recebe automaticamente o tema
`.config/btop/themes/grayscale.theme`, alinhado à paleta Vantablack.

O menu de áudio lista todos os sinks e sources fornecidos pelo PipeWire ou
PulseAudio. Perfis Bluetooth A2DP, HFP/HSP e LE Audio BAP são habilitados pelo
WirePlumber quando anunciados pelo dispositivo. Se o microfone depender de um
perfil HFP/HSP ou BAP inativo, a entrada oferece uma ação para ativá-lo; a
troca pode reduzir a qualidade de reprodução em headsets clássicos.

Para gerenciar redes Wi-Fi no X11/i3, o bloco `wireless` do i3status abre um
menu dmenu minimalista com a paleta Vantablack. O menu usa `nmcli`, permite
ativar e desativar o rádio, conectar redes salvas, abrir o editor de conexões
e pedir a senha de uma rede nova dentro do Alacritty. O Walker é usado como
fallback quando dmenu não está disponível.

O bloco `bluetooth` fica sempre visível ao lado dos indicadores de
conectividade. O clique esquerdo abre um menu dmenu com fallback para Walker,
usando `bluetoothctl` (fornecido pelo pacote `bluez`) e `rfkill` para ligar ou
desbloquear o rádio, conectar e desconectar dispositivos pareados, iniciar uma
descoberta e parear novos dispositivos. Nenhuma janela de terminal é aberta:
o pareamento mantém o agente Bluetooth em segundo plano e solicita PIN,
passkey e autorizações graficamente, com cancelamento disponível. Conectar
nunca inicia um novo pareamento; se o vínculo for rejeitado, o menu oferece a
ação explícita `Reparar vínculo`. Após conectar, a saída de áudio Bluetooth
reportada pelo servidor da sessão é selecionada automaticamente como padrão.
Os tempos podem ser ajustados com `BLUETOOTH_SCAN_SECONDS`,
`BLUETOOTH_PAIR_SCAN_SECONDS`, `BLUETOOTH_CONNECT_TIMEOUT` e
`BLUETOOTH_AUDIO_WAIT_SECONDS`.

As configuracoes de i3 dependem de uma sessao X11 e de nomes de dispositivos,
monitores e wallpaper que podem variar entre computadores. Revise
`.config/i3/config` e os caminhos usados pelos scripts antes de executar o
instalador em outro hardware.
