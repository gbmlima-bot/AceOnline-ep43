# Online PvE 0.9

A versão 0.9 permite que pilotos joguem no mesmo mapa, enfrentem os mesmos inimigos e recebam resultados confirmados por um servidor dedicado. A sala usa o mapa 3002 e aceita B/M/A/I-GEAR, escolhido na criação do piloto. O cliente envia comandos; o servidor calcula voo, pouso/decolagem, colisões, disparos, dano, consumo de munição, habilidades e recompensas. O antigo modo de visita/chat em LAN continua sendo uma função separada. Ainda não há servidor público hospedado.

```text
Cliente macOS/Windows 0.9 ── WSS /play ── Caddy :443
                                          │
                              Godot 4.7.2 / sala 3002
                              física 120 Hz; snapshots 15 Hz
                                          │
                                    SQLite / WAL
```

O servidor lê dados numéricos de terreno, colisão, itens e monstros, sem carregar cenas GLB, texturas, áudio ou executáveis do jogo original. Há um único processo e uma única sala. O encontro de três inimigos e suas posições continuam sendo uma configuração local. O Hornian usa a arma nativa compatível recuperada e concede **82 XP**, divididos entre os pilotos pelo dano efetivo causado, sem contar dano excedente após a morte. Cada piloto mantém uma fração privada de XP entre mortes e reinícios; o saldo inteiro alimenta nível e pontos de atributo. A recompensa de **10 SPI por inimigo para cada contribuinte** continua sendo uma política local explícita.

O XP e os campos compatíveis foram recuperados de um backup SQL legado. Isso não transforma a sala em reprodução de toda a economia ou população original. O cliente atual e o backup pertencem a versões diferentes: HP e identidade atuais são preservados, e armas ou atributos sem compatibilidade comprovada são bloqueados. Trajetórias e movimentação de NPC usam adaptações locais identificadas.

Comece com **2 pilotos**. A configuração aceita até 8, mas isso é um limite de software, sem benchmark comprovando oito jogadores. Monitore latência, memória e tempo de tick antes de aumentar a população.

## Pacotes e cliente compatível

Na [Release 0.9](https://github.com/gbmlima-bot/AceOnline-ep43/releases/tag/ace-modern-v0.9.0), o kit `ace-completion-source-kit-v0.9.zip` contém o servidor independente em `server-bundle/` e um overlay de fontes sobre a base completa 0.8. Os aplicativos gráficos 0.9 para macOS e Windows são distribuídos separadamente. Para jogar sozinho, baixe apenas o pacote do seu sistema; para criar uma sala, acrescente o kit. Veja [quais arquivos baixar](README-entrega-v0.9.md).

Cliente e servidor 0.9 usam **`ace-pve/2`**. O cliente 0.8 (`ace-pve/1`), os aplicativos anteriores e o cliente oficial não conectam a este servidor. O overlay atualiza fontes de um projeto Godot; ele não altera um aplicativo 0.8 já exportado.

O cliente macOS é universal, com arm64 para M4 e x86_64; sua assinatura é local ad-hoc, sem notarização Apple. Confira o hash publicado do arquivo. Se o Gatekeeper bloquear a abertura, use **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim** para o aplicativo que verificou. O cliente Windows é x64. A inspeção dos cabeçalhos e a integridade dos ZIPs são verificadas em Linux; isso não substitui executar os aplicativos em macOS e Windows. O servidor do kit é Linux amd64/x86_64. Docker em um Mac M4 pode precisar emular amd64 no teste local.

No cliente 0.9, abra **M → Online PvE**, preencha a URL `wss://SEU-DOMINIO/play`, a credencial privada do piloto e a classe desejada para o primeiro acesso, e pressione **Conectar ao servidor**. A classe fica vinculada ao perfil online e não pode ser trocada por uma nova conexão. Use **Desconectar** para sair. O campo de credencial é limpo ao conectar e não é salvo neste computador. O cliente verifica o certificado e o nome do servidor. `ws://` sem TLS só é aceito em loopback para desenvolvimento.

O progresso online pertence ao servidor e não é importado do perfil offline. Equipar itens possuídos, distribuir pontos de atributo e atribuir/usar habilidades suportadas são comandos validados pelo servidor. Aprender novas habilidades depende de escola nativa e ainda fica bloqueado nesta sala; consumíveis online também não foram portados. Durante a conexão e sua preparação, viagem local, comércio local, missões locais, troca de classe/perfil e salvar/carregar offline ficam bloqueados.

## Atualizar as fontes preservando os assets

Preserve o ZIP original **`ace-modern-fontes-v0.8.zip`**, disponível na Release 0.8:

```text
SHA256 1d8acfa14f0a9fa9c6782c5811cab72172fba83a4001527b8b042f603c696f1c
```

Extraia uma cópia nova dos fontes completos 0.8 e extraia o kit 0.9 em **outra pasta**. Feche o editor e use Python 3.11 ou mais recente. No terminal, dentro da pasta do kit:

```sh
python3 apply-update.py --base /caminho/ace-modern --dry-run
python3 apply-update.py --base /caminho/ace-modern
```

Opcionalmente, acrescente `--base-source-zip /caminho/ace-modern-fontes-v0.8.zip` para conferir também o hash do ZIP original completo. A verificação normal confere a versão do projeto, hashes dos arquivos substituídos e dos manifestos nativos, além da presença e do tamanho dos assets preservados. Ela não recalcula o hash individual de cada arquivo de arte.

O atualizador recusa arquivos da base modificados, destinos novos em conflito, caminhos fora da pasta e links simbólicos. Use uma extração nova caso tenha alterado a base. Ele verifica os manifestos antes de escrever, guarda as fontes substituídas em `.online-update-backups/v0.9-*/`, escreve cada arquivo atomicamente e deixa `client/project.godot` por último. Se uma escrita falhar durante a execução, tenta restaurar os arquivos escritos. Não apaga perfis ou userdata nem substitui arte, texturas ou áudio. Uma interrupção externa ainda exige conferir o resultado ou restaurar o backup das fontes. Uma segunda aplicação completa apenas verifica o resultado.

Abra `client/project.godot` da base atualizada com **Godot 4.7.2**; a primeira abertura pode reimportar os assets preservados. O overlay inclui fontes do cliente/servidor, implantação, documentação e ferramentas, além da extensão SQLite Linux x86_64 verificada. Entre os assets, só atualiza `local_world/mission_support.json`, `local_services/economy.json` e os novos JSONs estáticos revisados de `native_server/` e `legacy_rules/`. Arquivos `.env` reais, bancos de pilotos, backups, caches e userdata ficam fora da atualização. Prévias HTML históricas e imagens da documentação permanecem na base.

As fontes atualizadas permitem reconstruir o servidor, incluindo seus dados numéricos preservados da base e scripts de implantação:

```sh
cd /caminho/ace-modern
python3 tools/build_server_bundle.py --output build/server-bundle --godot /caminho/kit/server-bundle/runtime/godot
```

Use uma pasta de saída nova; o binário Godot precisa corresponder ao SHA256 oficial exigido pelo gerador. O `server-bundle/` já pronto no kit continua independente dessa extração do cliente.

Os manifestos detectam corrupção; não são uma assinatura digital. Confira também o SHA256 do kit por um canal de distribuição confiável. O atualizador não baixa os fontes antigos nem apaga os pacotes anteriores preservados.

## VPS e domínio

Um ponto de partida é um VPS **Linux amd64, 2 vCPU, 4 GB de RAM e SSD**, com Docker Engine e plugin Compose. O Compose limita o jogo a 3 GB/1,75 vCPU e o proxy a 192 MB, reservando capacidade para o sistema. Não há implantação pública feita pelo kit.

Se Docker ainda não estiver instalado, siga o [guia oficial para a distribuição do VPS](https://docs.docker.com/engine/install/). Confirme `docker version` e `docker compose version` no servidor antes de continuar.

Para enviar o servidor pelo Mac ou Windows com OpenSSH, execute na pasta extraída do kit, substituindo usuário e IP:

```sh
scp -r server-bundle usuario@IP:ace-online
ssh usuario@IP
cd ~/ace-online
```

Os comandos seguintes rodam nessa pasta no VPS. Para testes no próprio computador, use diretamente a pasta local `server-bundle/`.

Aponte o registro DNS **A** do domínio para o VPS. Use **AAAA** somente com IPv6 funcionando. Libere TCP **80 e 443**. Mantenha 9080/9081 sem publicação pública; Caddy encaminha as conexões internamente e obtém/renova o certificado TLS.

Dentro de `server-bundle/`:

```sh
cp .env.example .env
# Edite ACE_DOMAIN, ACME_EMAIL e mantenha ACE_MAX_PLAYERS=2.
unset COMPOSE_FILE
docker compose build
docker compose up -d
curl --fail https://SEU-DOMINIO/readyz
```

O endereço do cliente é `wss://SEU-DOMINIO/play`. A rota `/metrics` é interna e não é publicada pelo proxy. Os volumes de Caddy preservam as chaves e o estado de renovação dos certificados. Os contêineres usam UID 10001, raiz somente leitura, `/tmp` em tmpfs e sem capabilities. Os logs têm rotação de 10 MB × 3 por serviço.

Para testar **na mesma máquina**, sem domínio/certificado:

```sh
export COMPOSE_FILE=compose.yaml:compose.local.yaml
docker compose build game
docker compose up -d game
curl --fail http://127.0.0.1:9081/readyz
```

Conecte a `ws://127.0.0.1:9080/play`. As portas do modo local ficam restritas a `127.0.0.1`. Mantenha `COMPOSE_FILE` no terminal ao executar os scripts operacionais; remova a variável quando voltar à configuração pública.

## Credenciais dos pilotos

Crie uma credencial para cada pessoa:

```sh
./scripts/create-pilot.sh "Piloto1"
./scripts/create-pilot.sh "Piloto2"
```

O token aparece no terminal do operador na criação. Entregue-o individualmente. Não o coloque na URL, capturas públicas, logs compartilhados ou arquivos de configuração do cliente. SQLite guarda o hash da credencial; o token não é passado como argumento de inicialização do servidor nem como configuração de Caddy. O log de arquivo do engine fica desativado para não copiar a saída administrativa para um log Godot persistente.

Para substituir uma credencial:

```sh
docker compose exec -T game godot --headless --path /opt/ace/app --log-file /dev/null --script res://admin.gd -- --data-dir=/data rotate-token PILOT_ID
```

A anterior é revogada, inclusive para uma sessão já aberta, em até cinco segundos.

## Persistência, backup e restauração

SQLite em WAL guarda os pilotos e os resultados de transações. Pedidos repetidos recebem o resultado anterior enquanto seus recibos estiverem retidos. A janela persistente é dos **últimos 1024 recibos por piloto**; a arena também tem um cache FIFO de **4096 comandos**. Não há garantia de idempotência eterna depois da remoção dos recibos. IDs e recompensas de combate são definidos pelo servidor.

Comandos, mortes e recompensas são confirmados no banco antes da resposta ou anúncio. Movimento e recursos recebem checkpoints a cada segundo; uma parada abrupta pode voltar ao último checkpoint desses dados. A parada normal confirma o estado final.

Faça um backup consistente, inclusive com a sala funcionando:

```sh
./scripts/backup.sh ./backups/ace-online-manual.sqlite
```

O script usa a API de backup SQLite, verifica integridade e grava arquivo privado com permissão 0600 e SHA256. **Não copie apenas o `.sqlite` enquanto WAL estiver ativo**: transações confirmadas podem estar no arquivo `-wal`. Mantenha cópias externas ao VPS e uma retenção adequada. Os backups contêm dados privados dos pilotos.

Para restaurar:

```sh
./scripts/restore.sh /caminho/absoluto/backup.sqlite
curl --fail https://SEU-DOMINIO/readyz
```

O script verifica e envia o backup privado por stdin, cria uma cópia consistente do estado atual, para o jogo, faz checkpoint offline e restaura atomicamente antes de iniciar. Uma falha após a parada deixa o jogo parado para diagnóstico. A restauração retorna todo o estado ao snapshot escolhido, incluindo os recibos ainda presentes nesse snapshot. Confira `/readyz` antes de reconectar.

Para operar e atualizar:

```sh
docker compose logs --tail 100 game
docker compose logs --tail 100 caddy
docker compose stop --timeout 30
```

O supervisor transforma SIGTERM em pedido privado de encerramento e permite fechar a sala e SQLite; há término forçado após 27 segundos. Antes de atualizar, faça backup e pare o jogo; construa o novo pacote e suba com o mesmo nome de projeto **ace-online**, mantendo os volumes. **Não use `docker compose down -v`**: ele remove os dados persistentes. Migrações são transacionais; para voltar a uma versão antiga, use uma imagem compatível com o schema e seu backup correspondente.

## Alcance desta versão

O combate da sala é compartilhado e autoritativo. Ainda faltam campanha online, economia compartilhada, PvP, guildas, formações completas, múltiplas salas/mapas persistentes e os serviços/protocolos oficiais. O mundo local tem cobertura maior que essa sala; seus mapas, missões, lojas e consumíveis não se tornam online automaticamente.

Foram recuperadas **44 tabelas estáticas e 199.751 linhas** do backup SQL legado, além de spawns DAT/SMA do cliente. Isso corrige a limitação registrada nas entregas antigas que tratavam esses dados como ausentes. Contas, credenciais, personagens e tabelas operacionais não são publicados. Apenas definições e regras verificadas são utilizadas; estados de guerra/Infinity, regiões SMA e combinações incompatíveis continuam bloqueados. O [estado atual](gameplay-status.json) distingue dados recuperados, adaptações e comportamentos implementados.

O relatório `validation.json` do kit registra os testes aprovados no congelamento da versão. Os logs e relatórios JSON explicitamente citados nele também ficam no kit, em seus caminhos relativos, com hashes conferidos; não são aplicados sobre os relatórios da base pelo updater. Somente as verificações listadas nesse relatório pertencem à validação 0.9; evidências antigas de Docker/TLS ou pacotes 0.8 permanecem identificadas como históricas. Isso não comprova carga de oito pilotos, execução nativa em Mac/Windows ou operação em uma VPS pública.

Para gerar o kit após congelar os fontes, reconstruir o bundle e concluir o relatório `reports/completion-validation-v09.json`:

```sh
python3 tools/package_completion_kit.py --source . --server-bundle build/server-bundle --validation-report reports/completion-validation-v09.json --output /caminho/ace-completion-source-kit-v0.9.zip
```

O gerador exige resultados aprovados e logs referenciados sem erros de script/engine, confere o SHA256 do ZIP-base, os dados/engine do servidor e a correspondência do bundle com os fontes atuais. Depois verifica CRC, tamanhos e hashes do ZIP gerado. Não inclui credenciais, perfis ou uma segunda cópia dos assets gráficos.
