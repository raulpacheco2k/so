# Instalação 

Para realizar a instalação é possível seguir com o arquivo *autounattend.xml* ou *unattend.iso*.

* *autounattend.xml*: Inclua esse arquivo dentro de um pen-drive bootável onde esteja o instalador do Windows.
* *unattend.iso*: Para usar esse arquivo é necessário a utilização do programa *AnyBurn*, onde em vez de incluir um arquivo no pen-drive, você irá injentar diretamente da imagem do Windows.

# Principais Mudanças
**Objetivo**: Otimizar a performance para jogos, aumentar a segurança do ambiente, desativar serviços de telemetria e evitar problemas com dual-boot.
## Automação de Instalação e Bypasses Estruturais
1. Modifica o registro no ambiente de pré-instalação (Windows PE) para ignorar as validações de hardware do Windows 11, especificamente verificações de TPM (BypassTPMCheck), Secure Boot (BypassSecureBootCheck) e memória RAM (BypassRAMCheck).
2. Habilita a flag BypassNRO, permitindo a criação de contas locais sem a obrigatoriedade de conexão com a internet ou vínculo com uma Conta Microsoft.
3. Define o hostname da máquina como *PREDATOR-HELIOS* e cria o usuário administrador local raulpacheco2k (Raul Pacheco), configurando o sistema para executar o login automático sob esta credencial na primeira inicialização.
4. Estabelece o padrão de idioma (pt-BR), layout de teclado (ABNT2 - 0416:00010416) e fuso horário para o horário padrão de Brasília (E. South America Standard Time).

## Otimização de Camada de Rede, I/O e Sistema
1. Desativa o Algoritmo de Nagle injetando os valores TcpAckFrequency=1 e TCPNoDelay=1 nas interfaces de rede via registro. Isso reduz o atraso no envio de pacotes TCP, otimização fundamental para aplicações sensíveis à latência, como jogos multiplayer.
2. Habilita o suporte a caminhos longos (superando o limite de 260 caracteres do Win32).
3. Desativa a atualização do carimbo de "último acesso" (disableLastAccess) para reduzir o overhead de I/O em discos de estado sólido.
3. Força o Windows a interpretar o relógio da placa-mãe em tempo universal coordenado (UTC) via diretiva RealTimeIsUniversal. Esta é a configuração padrão em sistemas Unix, prevenindo dessincronização de horário em ambientes de dual-boot com distribuições Linux.
4. Desativa o recurso de Inicialização Rápida (HiberbootEnabled=0), forçando o kernel a recarregar completamente a cada inicialização para evitar inconsistências de estado.

## Redução de Superfície, Telemetria e Remoção de Componentes (Debloat)
1. Um script PowerShell executa uma varredura para desinstalar dezenas de aplicações nativas e bloatware: 3D Viewer, Bing Search, Clipchamp, Copilot, Cortana, Dev Home, Family, Feedback Hub, Game Assist, Get Help, Internet Explorer, Mail and Calendar, Maps, Math Input Panel, Mixed Reality, Movies &amp; TV, News, Office 365, OneDrive, OneNote, OneSync, Outlook for Windows, Paint 3D, People, Power Automate, PowerShell 2.0, Quick Assist, Recall, Remote Desktop Client, Skype, Solitaire Collection, Steps Recorder, Teams, Tips, To Do, Voice Recorder, Wallet, Weather, Windows Fax and Scan, WordPad, Xbox Apps, Your Phone/Phone Link.
2. Interrompe e desativa serviços intrusivos ou desnecessários para o perfil de uso, como DiagTrack (Telemetria Compartilhada), dmwappushservice, Spooler de Impressão e serviços de autenticação do Xbox.
3. Desativa via políticas de grupo (GPO no registro) o download automático de conteúdo patrocinado, sugestões de aplicativos do consumidor e configuração automática de chat (Teams).

## Modificações de Interface (UI) e Experiência do Usuário (UX)
1. Aplica um XML de modificação de layout que esvazia os ícones fixados na barra de tarefas. Oculta a caixa de pesquisa, o botão de Visão de Tarefas e o painel de Widgets.
2. Força a exibição de extensões de arquivo e pastas ocultas do sistema. Altera o destino de abertura padrão do Explorer de "Acesso Rápido" para "Este Computador".
3. Desativa a "precisão do ponteiro" (aceleração de mouse).
4. Define um comportamento inicial para botões de trava (NumLock ativado, CapsLock/ScrollLock desativados).
5. Desativa as Teclas de Aderência (StickyKeys).
6. Desativa completamente os esquemas de sons do sistema e o som de inicialização do Windows. 
7. Configura os efeitos visuais para privilegiar a performance (desativa animações de janelas, sombreamentos e esmaecimentos), mas preserva a suavização de fontes e a exibição de miniaturas.
