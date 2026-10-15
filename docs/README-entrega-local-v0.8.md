# ACE Modern 0.8 — sala PvE online

Cliente Godot para macOS e Windows, com um servidor dedicado Linux para uma sala cooperativa. O modo offline e os mapas já recuperados continuam disponíveis.

A sala online inicial usa o mapa 3002 e I-GEAR. O servidor calcula voo, colisão, inimigos, projéteis, dano, munição, habilidades e recompensas. O cliente envia controles; os perfis offline não são aceitos como progresso online. Os dois modos têm progresso separado.

O deploy usa um processo Godot 4.7.2, SQLite e Caddy, com Docker Compose em uma única VPS. Comece com dois pilotos. A configuração aceita até oito, sem afirmar capacidade de produção para esse limite.

- [Instalação, arquitetura e limites](docs/ONLINE-PVE.md)
- [Comandos de operação, backup e restauração](deploy/OPERACAO.txt)
- [Funcionamento e cobertura anteriores, versão 0.7](docs/gameplay.txt)

No cliente compatível 0.8, abra M e a aba Online. Informe o endereço wss://SEU-DOMINIO/play e a credencial individual criada pelo operador. Para desenvolvimento na mesma máquina, use ws://127.0.0.1:9080/play.

O servidor precisa de Linux x86_64, Docker Engine e Compose. O Mac M4 executa o cliente universal; a imagem Linux amd64 foi preparada para a VPS e pode precisar de emulação se testada no Mac.

Esta entrega é uma sala PvE inicial. Campanha online completa, economia compartilhada, PvP, guildas e compatibilidade com o protocolo/servidores oficiais não estão implementados. Os dados recuperados não incluem o banco original de spawns e drops. A recompensa online de 10 SPI por inimigo derrotado para cada piloto que contribuiu é uma regra explícita desta reconstrução.

Nenhuma hospedagem pública foi criada. O guia inclui o procedimento para publicar quando houver uma VPS e um domínio.
