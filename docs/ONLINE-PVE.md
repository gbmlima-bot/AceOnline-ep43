# Online PvE 0.8

A versão 0.8 permite que dois pilotos joguem no mesmo mapa, enfrentem os mesmos inimigos e recebam resultados confirmados por um servidor dedicado. A sala usa o mapa 3002 e I-GEAR. O cliente envia comandos; o servidor calcula voo, colisões, disparos, dano, consumo de munição, habilidades e recompensas. O antigo modo de visita/chat em LAN continua sendo uma função separada.

```text
Cliente macOS/Windows 0.8 ── WSS /play ── Caddy :443
                                          │
                              Godot 4.7.2 / sala 3002
                              física 120 Hz; snapshots 15 Hz
                                          │
                                    SQLite / WAL
```

O servidor lê os dados numéricos nativos de terreno e colisão, sem carregar cenas GLB, texturas, áudio ou executáveis do jogo original. Há um único processo e uma única sala. O encontro de três inimigos, suas posições e a recompensa de **10 SPI por inimigo para cada piloto que contribuiu**, sem XP, são uma política local explícita. Esses valores não foram recuperados de um banco de servidor original.

Comece com **2 pilotos**. A configuração aceita até 8, mas isso é um limite de software, sem benchmark comprovando oito jogadores. Monitore latência, memória e tempo de tick antes de aumentar a população.

## Pacotes e cliente compatível

O kit `ace-online-kit-v0.8.zip` contém o servidor independente e um pequeno overlay de fontes do cliente e servidor. Não repete os gigabytes de arte da base 0.7. Os aplicativos gráficos 0.8 para macOS e Windows são distribuídos separadamente; o aplicativo antigo 0.7 não possui conexão com este PvE.

O cliente macOS é universal, com arm64 para M4 e x86_64; sua assinatura é local ad-hoc, sem notarização Apple. Confira o hash publicado do arquivo. Se o Gatekeeper bloquear a abertura, use **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim** para o aplicativo que verificou. O cliente Windows é x64. A inspeção dos cabeçalhos e a integridade dos ZIPs são verificadas em Linux; isso não substitui executar os aplicativos em macOS e Windows. O servidor do kit é Linux amd64/x86_64. Docker em um Mac M4 pode precisar emular amd64 no teste local.

No cliente 0.8, abra **M → Online PvE**, preencha a URL `wss://SEU-DOMINIO/play` e a credencial privada do piloto, e pressione **Conectar ao servidor**. Use **Desconectar** para sair. O campo de credencial é limpo ao conectar e não é salvo neste computador. O cliente verifica o certificado e o nome do servidor. `ws://` sem TLS só é aceito em loopback para desenvolvimento.

O progresso online pertence ao servidor e não é importado do perfil offline. Durante a conexão, a viagem local, troca local de classe/perfil e atalhos de salvar/carregar offline ficam bloqueados. Isso evita que um perfil local substitua o estado confirmado pelo servidor.

## Atualizar as fontes preservando os assets

Preserve o ZIP original `ace-modern-systems-fontes-v0.7.zip`:

```text
SHA256 bc5d9a6755e14f44a59bb307d7b75a1b881a60be5334a425314f7c48667705e8
```

Extraia uma cópia nova da base 0.7 e extraia o kit em **outra pasta**. Feche o editor e use Python 3.11 ou mais recente. No terminal, dentro da pasta do kit:

```sh
python3 apply-update.py --base /caminho/ace-modern --dry-run
python3 apply-update.py --base /caminho/ace-modern
```

Opcionalmente, acrescente `--base-source-zip /caminho/ace-modern-systems-fontes-v0.7.zip` para conferir também o ZIP original completo. A verificação normal já confere nome/versão do projeto e hashes dos arquivos listados no manifesto da base inteira, incluindo os assets. Pode levar alguns minutos para ler esses arquivos.

O atualizador recusa arquivos da base modificados, destinos novos em conflito, caminhos fora da pasta e links simbólicos. Use uma extração nova caso tenha alterado a base. Ele verifica os manifestos antes de escrever, guarda as fontes substituídas em `.online-update-backups`, escreve cada arquivo atomicamente e deixa `client/project.godot` por último. Se uma escrita falhar durante a execução, tenta restaurar os arquivos escritos. Não apaga assets, perfis ou userdata. Uma interrupção externa ainda exige conferir o resultado ou restaurar o backup das fontes. Uma segunda aplicação completa apenas verifica o resultado.

Abra `client/project.godot` da base atualizada com **Godot 4.7.2**; a primeira abertura pode reimportar os assets preservados. O overlay inclui todos os arquivos textuais do cliente (`.gd`, `.godot`, cenas, recursos, shaders, configurações e UIDs), `server/`, configurações/scripts de `deploy/`, README, documentação em Markdown/texto/JSON e ferramentas Python. Inclui também a extensão SQLite Linux x86_64, seus arquivos de plugin/licença e o manifesto `third_party/GODOT-SQLITE.json`. As duas bibliotecas `.so` são os únicos binários adicionados pelo overlay: seus tamanhos e hashes devem corresponder à proveniência. Arquivos `.env` reais, backups, logs, caches e userdata ficam fora da atualização. Prévias HTML históricas e imagens da documentação permanecem na base.

As fontes atualizadas permitem reconstruir o servidor, incluindo seus dados numéricos preservados da base e scripts de implantação:

```sh
cd /caminho/ace-modern
python3 tools/build_server_bundle.py --output build/server-bundle --godot /caminho/kit/server-bundle/runtime/godot
```

Use uma pasta de saída nova; o binário Godot precisa corresponder ao SHA256 oficial exigido pelo gerador. O `server-bundle/` já pronto no kit continua independente dessa extração do cliente.

Os manifestos detectam corrupção; não são uma assinatura digital. Confira também o SHA256 do kit por um canal de distribuição confiável. O atualizador não baixa dados antigos nem apaga os pacotes 0.7 preservados.

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

O combate e o mundo da sala são compartilhados e autoritativos. Ainda faltam os sistemas de um MMO completo: campanha online, economia compartilhada, PvP, guildas, facções, múltiplas salas/mapas persistentes e os serviços/protocolos originais. Dados do cliente não recuperam o banco original de spawns, drops e contas. A versão 0.8 usa regras locais identificadas onde esse banco está ausente.

O relatório `validation.json` do kit registra os testes aprovados no congelamento da versão. Os logs e relatórios JSON explicitamente citados nele também ficam no kit, em seus caminhos relativos, com hashes conferidos; não são aplicados sobre os relatórios da base pelo updater. Ele inclui os resultados de testes headless, persistência, integração e Docker indicados no relatório de origem. Isso não comprova carga de oito pilotos, execução nativa em Mac/Windows ou operação em um VPS público.

Para gerar o kit após congelar os fontes, reconstruir `build/server-bundle` e concluir o relatório `reports/online-validation-v08.json`:

```sh
python3 tools/package_online_kit.py --output /caminho/ace-online-kit-v0.8.zip
```

O gerador exige resultados aprovados e logs referenciados sem erros de script/engine, confere o SHA256 do ZIP-base, os dados/engine do servidor e a correspondência do bundle com os fontes atuais. Depois verifica CRC, tamanhos e hashes do ZIP gerado. Não inclui credenciais, perfis ou uma segunda cópia dos assets gráficos.
