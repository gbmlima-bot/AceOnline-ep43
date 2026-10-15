# ACE Modern 0.9 — download e configuração

A entrega inclui o jogo local para macOS/Windows e um servidor dedicado Linux para a sala PvE online. É uma reconstrução parcial do Ace Online/AirRivals, com interface azul e recursos recuperados do cliente. Ainda não há servidor público disponível.

## Para jogar sozinho

No Mac, o [comando de instalação no README](../README.md#instalar-no-mac) baixa e configura o cliente 0.9. Para baixar manualmente, na [Release 0.9](https://github.com/gbmlima-bot/AceOnline-ep43/releases/tag/ace-modern-v0.9.0), escolha somente o pacote do seu computador:

| Computador | Pacote |
| --- | --- |
| Mac M1/M2/M3/M4 ou Intel | `ace-modern-online-macos-v0.9.zip` |
| Windows x64 | `ace-modern-online-windows-v0.9.zip` |

Baixe o `.parts.json` e **todas** as partes `.part-001`, `.part-002` etc. desse pacote, mais `release_parts.py`. Guarde tudo na mesma pasta. Não misture partes de versões ou sistemas diferentes. Com Python 3.11+:

```sh
python3 release_parts.py restore ace-modern-online-macos-v0.9.zip.parts.json --output ace-modern-online-macos-v0.9.zip
```

Para Windows, substitua `macos` por `windows`; `py -3` pode substituir `python3`. A ferramenta confere tamanhos e SHA256 e só disponibiliza o ZIP recomposto se a verificação passar.

Extraia o ZIP inteiro e abra o aplicativo. Mantenha juntos os arquivos extraídos do pacote Windows. O Godot já acompanha o aplicativo exportado: não precisa baixar os fontes ou o kit do servidor para o modo local. Reserve espaço para as partes, o ZIP e a pasta extraída ao mesmo tempo; os manifestos da Release registram os tamanhos exatos.

O app Mac é universal arm64/x86_64: o M4 usa arm64. Requer macOS 13+ em Apple Silicon ou macOS 11+ em Intel. A assinatura é ad-hoc, sem notarização Apple; se a abertura for bloqueada após conferir o pacote, veja **Ajustes do Sistema → Privacidade e Segurança**. O app Windows é x64, sem assinatura Authenticode. A execução nativa nos dois sistemas ainda precisa ser confirmada; a validação disponível usa Godot em Linux.

No modo local, **M** abre os mapas, missões, serviços, habilidades e atributos; **I** abre o inventário, **F1** mostra os controles e **F5/F9** salva/carrega. Os perfis 0.9 usam `progress-v09.json`; uma leitura inicial compatível pode migrar o antigo `progress.json`, preservando o arquivo anterior. Progresso local e online são separados.

## Para criar uma sala online

Além do cliente 0.9 do seu sistema, baixe **`ace-completion-source-kit-v0.9.zip`** e extraia. A pasta **`server-bundle/`** contém o servidor independente, seu runtime Godot e os arquivos de Docker Compose. Você não precisa extrair os fontes completos para usar esse servidor.

O servidor requer **Linux amd64/x86_64**. Pode ser testado no Mac M4 com Docker Desktop e emulação amd64; ele não é um servidor nativo macOS. No Windows, use um ambiente de contêineres Linux compatível. Dentro de `server-bundle/`, no terminal com shell compatível:

```sh
cp .env.example .env
export COMPOSE_FILE=compose.yaml:compose.local.yaml
docker compose build game
docker compose up -d game
curl --fail http://127.0.0.1:9081/readyz
./scripts/create-pilot.sh "Piloto1"
```

O último comando fornece a credencial privada do piloto. No cliente, abra **M → Online PvE**, use **`ws://127.0.0.1:9080/play`**, a credencial e a classe desejada. A classe só é escolhida na criação do perfil online; ela permanece vinculada ao piloto.

Essa configuração permite conexão no mesmo computador. O `ws://` sem TLS é restrito a loopback; não basta substituir `127.0.0.1` pelo IP da máquina para liberar acesso pela rede. Para convidar jogadores remotos, será necessário hospedar o servidor e configurar um domínio com TLS/WSS. Ainda não há VPS ou domínio provisionados. O [guia Online PvE](ONLINE-PVE.md) contém o procedimento, as credenciais individuais e o backup/restauração.

Cliente e servidor precisam ser **0.9**, protocolo `ace-pve/2`. Os aplicativos 0.8 e o cliente oficial não conectam a essa sala. Comece com dois pilotos; oito é o limite configurável, sem teste de carga comprovando essa capacidade.

## Para editar ou exportar o projeto

Esta etapa é opcional. Baixe os **fontes completos `ace-modern-fontes-v0.8.zip`** da [Release 0.8](https://github.com/gbmlima-bot/AceOnline-ep43/releases/tag/ace-modern-v0.8.0) e o **kit incremental `ace-completion-source-kit-v0.9.zip`** da Release 0.9. O kit não repete os gigabytes de arte.

O ZIP completo da base 0.8 preservado tem SHA256:

```text
1d8acfa14f0a9fa9c6782c5811cab72172fba83a4001527b8b042f603c696f1c
```

Recomponha e extraia os fontes 0.8 em uma pasta nova. Extraia o kit 0.9 em outra pasta e feche o Godot. No terminal, dentro da pasta do kit:

```sh
python3 apply-update.py --base /caminho/ace-modern --dry-run
python3 apply-update.py --base /caminho/ace-modern
```

Acrescente `--base-source-zip /caminho/ace-modern-fontes-v0.8.zip` para conferir também o hash do ZIP-base inteiro. O aplicador confere os hashes dos arquivos substituídos e dos manifestos nativos, além da presença e do tamanho dos assets preservados. Não calcula um novo hash individual de toda a arte. Recusa arquivos modificados, destinos em conflito e links simbólicos; use uma extração limpa.

As fontes anteriores ficam em `.online-update-backups/v0.9-*/`. Escritas são atômicas e falhas detectadas durante a aplicação acionam restauração; preserve o ZIP original para recuperação de uma interrupção externa. Perfis e userdata não são apagados.

Instale **Godot 4.7.2**, abra `client/project.godot` da base atualizada e execute o projeto principal. A primeira importação dos assets pode demorar. O kit altera fontes e dados estáticos revisados, sem substituir modelos, texturas ou áudio. **Ele não atualiza aplicativos `.app` ou `.exe` 0.8**; para jogar a versão exportada, baixe o pacote desktop 0.9.

O código público está na branch `ace-modern`; `main` conserva o projeto legado. Clonar só o Git não baixa toda a arte.

## Cobertura da entrega

O jogo local mantém os mapas e a arte já recuperados e acrescenta posições DAT e armas de NPC verificadas, XP/drops suportados, pouso/decolagem com duração, consumíveis e lojas vinculadas aos NPCs. O backup legado permitiu exportar 44 tabelas estáticas e 199.751 linhas. Os dados pertencem a versões diferentes: a integração mantém HP e identidade do cliente atual e bloqueia combinações sem compatibilidade comprovada.

Há 2.255 posições DAT suportadas em 95 mapas; 1.243 outras posições e cinco regiões SMA ficam bloqueadas. As 541 missões com sintaxe suportada entre 597 definições ainda dependem de seus requisitos e recursos. Há 280 níveis efetivos de habilidade suportados entre 557 definições; bases/protótipos também entram nessa contagem total. Os efeitos de 71 consumíveis de recuperação são interpretados; seu uso é local e depende de posse, recursos, classe, nível, modo e recarga originais. Três dessas definições são exclusivas de Infinity e permanecem bloqueadas na sessão comum.

O online compartilha combate na sala 3002, com quatro GEAR, equipamento, atributos e habilidades suportadas. O Hornian concede 82 XP, dividido pelo dano efetivo; as frações persistem. A recompensa de 10 SPI por contribuinte é uma regra local. Aprender novas habilidades, usar consumíveis, viajar pela campanha e operar uma economia global ainda não fazem parte do online.

PvP, guildas, formações completas, todos os estados de NPC, todas as habilidades, encantamentos, animações, efeitos e equivalência integral com o jogo original continuam pendentes. Veja [o estado de cobertura](gameplay-status.json) e os relatórios em [verification/](../verification/). Nenhum teste em Linux comprova por si só execução nativa em Mac/Windows ou operação de uma VPS pública.
