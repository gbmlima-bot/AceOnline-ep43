Framing offline da fundação ACE Modern

Escopo e estágio aceito

Este módulo monta e recompõe somente envelopes com o cabeçalho ORIGINAL de quatro bytes e o bit de codificação 0x80 desativado. Os corpos são bytes opacos. Não há sockets, login, banco, interpretação de MessageType, desserialização de structs, cliente de replay ou decodificação de proteção. Envelopes com o bit 0x80 ativado são rejeitados expressamente como unsupported_encoded_frame.

Um corpo já decodificado pelo legado é outro estágio do processamento: não contém necessariamente seu cabeçalho original nem os bytes auxiliares originais. Ele NÃO pode ser passado a feed() como se fosse tráfego enquadrado. Também não se deve apagar o bit de codificação de um envelope codificado e repassá-lo ao parser. Nada aqui valida ou transforma esse corpo.

Perfil de cabeçalho

Offsets 0..1: comprimento do CORPO, uint16 little-endian. Offset 2: flags brutas, uint8. Offset 3: sequência bruta, uint8. O comprimento exclui os quatro bytes de cabeçalho. Os bits inferiores das flags são preservados quando o bit 0x80 está desativado, como no ramo sem codificação do receptor legado.

Little-endian é um perfil explícito inferido das leituras/escritas nativas do código Windows x86. Não foi confirmado por captura autorizada de tráfego nem pela compilação do ABI legado. As fixtures são sintéticas, sem mensagens de jogo ou dados reais; elas documentam e testam esta interpretação da fonte, não demonstram compatibilidade binária completa com um cliente existente.

Limites e escolhas deliberadas

O emissor CSendPacket::SetPacket aceita corpos de 1 a 1492 bytes. O seu ramo sem codificação escreve flags=0 e sequência=0. Por isso encode_unencoded() sempre normaliza esses dois bytes para zero, sem aceitar parâmetros de sessão.

O receptor CRecvPacket::AddTail aplica o teto 1492+3+1=1496 ao comprimento do corpo antes de examinar a codificação. A API de recepção aceita corpos de 1 a 1496 bytes, inclusive 1493..1496 sem codificação; isso não muda o limite de emissão. Um frame recebido tem no máximo 1500 bytes incluindo o cabeçalho. O buffer pendente de cada parser nunca cresce além desse tamanho.

Corpo de comprimento zero vira invalid_length imediatamente. Na fonte, RecvCompleted() exige comprimento diferente de zero, portanto esse caso nunca completa normalmente; a rejeição explícita evita reproduzir esse estado incompleto. Um corpo de um byte é aceito pelo framing, mas não é validado como mensagem de jogo. Uma mensagem declarada sem payload ainda requer seus dois bytes de tipo; essa camada não extrai tipos nem presume que um corpo seja uma única mensagem.

A sequência recebida é exposta como raw_sequence sem validação, avanço, geração ou significado de sessão. O ramo TCP sem codificação do IOCP passa ao handler uma sequência mantida na conexão, enquanto a biblioteca de framing consegue ler o byte bruto. Preservar esse byte não equivale a reconstruir a semântica da conexão.

API Python, sem dependências externas

from protocol import PlainFrameParser, encode_unencoded
parser = PlainFrameParser()
frames = parser.feed(encode_unencoded(b"opaque-demo"))
parser.finish()

Frame contém payload: bytes, raw_sequence: int e raw_flags: int. feed() recebe bytes, bytearray ou memoryview e devolve uma lista dos frames completos. Um fragmento vazio não altera o estado. pending_size informa os bytes da mensagem parcial, incluindo cabeçalho. finish() sinaliza truncated_frame quando a fonte offline termina com cabeçalho ou corpo incompleto. reset() descarta os dados parciais e a falha anterior.

FrameError.code fornece invalid_length, unsupported_encoded_frame, truncated_frame ou parser_failed. A primeira falha de framing é terminal até reset(); chamadas posteriores a feed() ou finish() geram parser_failed, inclusive com entrada vazia. Cada chamada feed() é atômica para seus resultados: se um frame posterior daquela mesma chamada falhar, nenhum dos frames daquela chamada é devolvido. Frames devolvidos em chamadas anteriores continuam válidos. O chamador deve decidir o que fazer com a fonte offline ao receber o erro.

Adaptador GDScript

client/scripts/protocol/plain_framing.gd segue os mesmos limites e fixtures. Como GDScript não usa exceções para esse fluxo, feed(), finish() e encode_unencoded() retornam Dictionary com ok e error; feed() também retorna frames, e encode_unencoded() retorna bytes. Frame é um Dictionary com payload: PackedByteArray, raw_sequence: int e raw_flags: int. pending_size() é um método. Não há autoload nem alteração na cena de voo.

Testes reproduzíveis

Na raiz ace-modern:
python -m unittest discover -s protocol/tests -v

Para os testes headless do adaptador, use seu executável Godot:
godot --headless --path client --script res://tests/test_protocol.gd

Os dois testes leem protocol/fixtures/framing.json. O teste Godot resolve esse arquivo relativamente à pasta do projeto; por isso o checkout com a pasta irmã protocol deve estar presente. As fixtures NÃO são assets de runtime e não devem ser incluídas em uma exportação do jogo. Os testes cobrem fronteiras de cabeçalho/corpo, leitura byte a byte, concatenação, metadados, limites diferentes de emissão/recepção, flag de codificação não suportada, truncamento no fim da fonte e recuperação explícita após reset. Não fazem chamadas de rede nem executam o alvo legado.

Proveniência

Repositório fonte local: /workspace/targets/ace-online-ep35.
Commit fonte: 7c3e47ac47844e5c415d356a94d6201a0b9a38c4.
Os hashes SHA-256 abaixo identificam os arquivos da fonte lidos, não implementam criptografia de protocolo. As mesmas referências estão nos metadados das fixtures.

Server/Common/SocketHeader.h:23-32,73-77. Define USHORT para tipo, quatro bytes de cabeçalho, limites e diagrama do envelope.
SHA-256: 11c59a3dc1c97f2dad574c12e1e30f308098d109341d40eec7e80d943ecbe1f7.

Server/Common/WinPacket.h:105-127. Limite de envio, escrita nativa do comprimento e flags/sequência zeradas no ramo sem codificação. Linhas 244-346: recomposição, teto de recepção, bit de codificação, byte bruto de sequência e critério de conclusão.
SHA-256: bb3785aaf8331f580b34d5207a076b9382ca9cdc3ea74827861583defce9656b.

Server/Common/IOCPSocket.cpp:828-841,861-902. Reagrupamento do stream, separação entre ramos sem codificação e codificado, despacho para handlers. A implementação moderna não executa esses handlers nem implementa o ramo codificado.
SHA-256: 98d5b052db19bf2a4070cf3d6da15223f9db75d9c15e3a00395241d5d05e4e01.

Limitações

Não há validação do ABI/packing/endianness real por captura, dos structs de personagem/inventário, dos procedimentos de banco ou da compatibilidade com variantes por distribuidor. A codificação legada, checksum, preenchimento e progressão de sequência não foram implementados. A foundation offline não declara wire compatibility, servidor jogável ou integração com o cliente legado.
