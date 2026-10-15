# ACE Modern

Modernização de AirRivals/Ace Online para **macOS (Apple Silicon e Intel)** e **Windows x64**, com Godot **4.7.2**. A versão **0.9.0** amplia o jogo local e a sala PvE autoritativa: quatro classes GEAR, progressão online com XP recuperado do servidor legado, pouso/decolagem com duração, armas de NPC e posições nativas de inimigos nos casos suportados.

[Baixar versão 0.9](https://github.com/gbmlima-bot/AceOnline-ep43/releases/tag/ace-modern-v0.9.0) · [O que baixar e como jogar](docs/README-entrega-v0.9.md) · [Configurar o servidor](docs/ONLINE-PVE.md) · [Cobertura e limites](docs/gameplay-status.json)

Esta é uma reconstrução parcial. O jogo local tem exploração, missões, combate, inventário e serviços; o online oferece uma sala cooperativa no mapa 3002. **Não há servidor público hospedado.** A execução nativa dos aplicativos em macOS e Windows ainda precisa ser confirmada; os testes de runtime, renderização e servidor são feitos em Linux.

## Instalar no Mac

No Terminal do Mac, cole o comando abaixo. Ele baixa o pacote macOS 0.9, verifica seus arquivos e instala o jogo. Não precisa baixar o pacote Windows, os fontes ou o servidor para jogar sozinho.

```sh
ace_setup=$(mktemp /tmp/ace-modern-v09.XXXXXX) &&
curl --fail --location 'https://raw.githubusercontent.com/gbmlima-bot/AceOnline-ep43/ace-modern/tools/install_macos_v09.sh' -o "$ace_setup" &&
bash "$ace_setup"
```

O app é universal arm64/x86_64; o M4 usa arm64. Requer macOS 13+ em Apple Silicon ou macOS 11+ em Intel. A assinatura é ad-hoc, sem notarização Apple. Se a abertura do app verificado for bloqueada, confira **Ajustes do Sistema → Privacidade e Segurança**. A instalação prepara o cliente local; multiplayer depende de configurar um servidor.

## Downloads manuais

| Para fazer isto | Baixe |
| --- | --- |
| Jogar sozinho no Mac, inclusive M4 | `ace-modern-online-macos-v0.9.zip` |
| Jogar sozinho no Windows x64 | `ace-modern-online-windows-v0.9.zip` |
| Criar uma sala online | Pacote do seu sistema **e** `ace-completion-source-kit-v0.9.zip`, que contém `server-bundle/` |
| Editar o projeto no Godot | Fontes completos 0.8 **e** o kit incremental de fontes 0.9 |

Para jogar sozinho, basta o pacote do seu sistema. Extraia o ZIP inteiro e abra o aplicativo; no Windows, mantenha juntos os arquivos extraídos. O nome “online” do pacote também inclui o modo local, com Godot já incluído. O Windows usa x64 e não tem assinatura Authenticode.

Os ZIPs grandes são divididos em partes por causa do limite de tamanho do GitHub. Na [Release 0.9](https://github.com/gbmlima-bot/AceOnline-ep43/releases/tag/ace-modern-v0.9.0), baixe **o manifesto `.parts.json`, todas as partes `.part-001`, `.part-002` etc. do pacote escolhido e `release_parts.py`** para a mesma pasta. Com Python 3.11 ou mais recente:

```sh
python3 release_parts.py restore ace-modern-online-macos-v0.9.zip.parts.json --output ace-modern-online-macos-v0.9.zip
```

No Windows, use `py -3` no lugar de `python3` se necessário e troque `macos` por `windows`. A ferramenta verifica os tamanhos e os hashes SHA256 das partes e do ZIP completo. O kit de fontes/servidor é um ZIP único. Consulte [o guia da entrega](docs/README-entrega-v0.9.md) para requisitos e instruções.

## O que mudou na versão 0.9

- **Dados recuperados:** 44 tabelas estáticas e 199.751 linhas de um backup SQL legado, com proveniência, hashes e conferência das contagens. Contas, credenciais e personagens não fazem parte dessa exportação. Os dados atuais do cliente, incluindo HP dos monstros, são preservados; valores de versões diferentes só são combinados quando a compatibilidade é comprovada.
- **Mundo local:** 2.255 posições DAT de inimigos comuns em 95 mapas passam pelos requisitos suportados, com coordenadas e tempos nativos. Outros 1.243 registros DAT e cinco regiões SMA permanecem bloqueados por estados ou regras ainda não portados. Isso não representa a população completa de todos os mapas.
- **Combate e progressão:** armas nativas de NPC nos casos compatíveis, projéteis hostis, recompensas sem duplicação e XP de monstros recuperado. O Hornian concede 82 XP; no online, esse valor é dividido pelo dano efetivo, com frações persistidas. Os 10 SPI por contribuinte na sala continuam sendo uma regra local explícita.
- **Física e sistemas locais:** transições de pouso/decolagem, 280 níveis efetivos de habilidade suportados entre 557 definições, efeitos de 71 consumíveis de recuperação interpretados e lojas ligadas aos NPCs originais: dez lojas, 121 associações e 47 itens compatíveis. Catálogo não concede posse nem ignora requisitos.
- **Online:** B/M/A/I-GEAR selecionável na criação do piloto, equipamento possuído, atributos e uso/atribuição de habilidades validados pelo servidor. O protocolo `ace-pve/2` exige cliente e servidor 0.9.

O [estado de cobertura](docs/gameplay-status.json) separa dados recuperados, comportamentos implementados, adaptações e limitações. As 541 missões com sintaxe suportada entre 597 definições ainda dependem dos mapas, atores, níveis e pré-requisitos necessários. As 280 definições de habilidade suportadas incluem níveis da mesma habilidade; não são 280 mecânicas distintas.

## Servidor local e hospedagem

Um processo Godot headless executa a sala; SQLite/WAL persiste os pilotos e Caddy pode publicar `wss://SEU-DOMINIO/play`. O servidor lê dados numéricos de terreno, colisões, itens e monstros, sem precisar carregar a arte do cliente ou usar GPU.

Para testar na mesma máquina, instale Docker com Compose e abra o terminal dentro de `server-bundle/` do kit 0.9:

```sh
cp .env.example .env
export COMPOSE_FILE=compose.yaml:compose.local.yaml
docker compose build game
docker compose up -d game
curl --fail http://127.0.0.1:9081/readyz
./scripts/create-pilot.sh "Piloto1"
```

No cliente 0.9, abra **M → Online PvE**, informe `ws://127.0.0.1:9080/play`, a credencial criada e a classe desejada para o primeiro acesso. Clique em **Conectar ao servidor**. A classe do piloto fica vinculada ao perfil online; o inventário offline não é importado.

O servidor é Linux amd64. No Mac M4, o Docker Desktop pode precisar emular essa arquitetura. A configuração local publica portas somente em loopback; para outra pessoa conectar pela rede, prepare domínio/TLS e um endereço acessível conforme [o guia de operação](docs/ONLINE-PVE.md). O antigo modo de presença/chat LAN é separado do combate online autoritativo.

Ainda não há VPS ou domínio configurados. Um ponto de partida para hospedar é **Linux amd64, 2 vCPU, 4 GB de RAM e SSD**, com Docker Compose e TCP 80/443 liberados. Comece com dois pilotos; o limite configurável de oito não representa capacidade comprovada por teste de carga.

## Fontes e atualização

O código está na branch `ace-modern`; a branch `main` do código legado foi preservada:

```sh
git clone --single-branch --branch ace-modern https://github.com/gbmlima-bot/AceOnline-ep43.git ace-modern
```

O Git contém código, ferramentas e dados numéricos selecionados. Os gigabytes de arte ficam nos pacotes da Release. Para editar o cliente gráfico, extraia os **fontes completos 0.8** e aplique o **kit incremental 0.9** sobre uma cópia limpa, conforme [o guia](docs/README-entrega-v0.9.md). O kit verifica os arquivos da base e preserva modelos, texturas e áudio. Ele atualiza o projeto Godot; não modifica um `.app` ou `.exe` 0.8 já exportado.

## Limites e materiais históricos

Campanha online, economia compartilhada, PvP, guildas, formações completas, múltiplos mapas persistentes e compatibilidade com o protocolo/servidores oficiais continuam pendentes. Também faltam estados especiais de monstros, regras de spawn bloqueadas, habilidades não suportadas, efeitos de instância/encantamento e partes do renderizador, animações e trajetórias originais. Não foi comprovada equivalência integral com o jogo original.

A [Release 0.8](https://github.com/gbmlima-bot/AceOnline-ep43/releases/tag/ace-modern-v0.8.0), seus manifestos e o [instalador Mac fixado da versão 0.8](https://github.com/gbmlima-bot/AceOnline-ep43/blob/e133d8fc9720a6e7307d753c4c37233197d95363/tools/install_macos.sh) permanecem como materiais históricos. Esse instalador baixa **0.8**, não 0.9. A [prévia online 0.8](docs/preview-online-v0.8.png) foi capturada com os recursos do pacote Mac executados por Godot em Linux.

Relatórios e evidências públicos ficam em [verification/](verification/). Avisos e proveniência de Godot, godot-sqlite, Noto e ferramentas estão em [third_party/](third_party/). Os avisos das dependências não concedem uma licença geral aos recursos originais de Ace Online/AirRivals.
