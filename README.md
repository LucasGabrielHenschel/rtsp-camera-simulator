# camsim: simulador de câmeras IP

Sobe câmeras IP de mentira (RTSP, H264) na sua máquina, para testar o cadastro e o uso de câmeras na central sem precisar de câmera física.

Cada câmera mostra uma imagem de teste diferente (barras coloridas, padrões em movimento), o que facilita saber qual é qual no "Visualizar".

## Requisitos

- Linux com **Docker**. Se o seu usuário não estiver no grupo `docker`, rode os comandos com `sudo`.
- A central precisa alcançar a sua máquina pela rede nas portas TCP das câmeras (padrão: **18554** a **18557**). Se houver firewall, libere essas portas.

Na primeira vez, o Docker baixa a imagem `bluenviron/mediamtx:1.17.1-ffmpeg`.

## Início rápido

```bash
./camsim.sh start      # sobe as câmeras 1 a 4
./camsim.sh status     # mostra o estado e a URL de cada uma
```

Saída do `start`:

```
Câmera 1   testsrc2     rtsp://192.168.0.20:18554/cam
Câmera 2   smptebars    rtsp://192.168.0.20:18555/cam
Câmera 3   testsrc      rtsp://192.168.0.20:18556/cam
Câmera 4   rgbtestsrc   rtsp://192.168.0.20:18557/cam
```

Para conferir se o vídeo chega, rode na central:

```bash
ffprobe -rtsp_transport tcp rtsp://192.168.0.20:18554/cam
```

A saída deve mostrar um stream `h264` em 640x360.

## Cadastrar na central

Em **Câmeras → Adicionar câmera**:

1. Escolha **RTSP**.
2. Cole a URL que o `start` mostrou, por exemplo `rtsp://192.168.0.20:18554/cam`.
3. Deixe usuário e senha em branco. Se subiu o simulador com senha, use a senha configurada (veja [Opções](#opções)).
4. Siga as etapas normais do cadastro.

## Comandos

| Comando | O que faz |
|---|---|
| `start [N...]` | Cria ou recria as câmeras. Sem número, cria de 1 a 4. Com número, só as informadas. Exemplos: `start 2`, `start $(seq 1 8)`. |
| `offline N...` | Derruba a câmera, como se tivesse saído da rede. Serve para testar a detecção de câmera offline. |
| `online N...` | Liga a câmera de novo. |
| `status` | Lista as câmeras criadas, o estado (`running` ou `exited`) e a URL. |
| `logs N` | Mostra o log da câmera. Use quando o vídeo não chegar. |
| `down` | Remove todas as câmeras do simulador. |

As câmeras voltam sozinhas se a máquina ou o Docker reiniciar. Só não voltam as que você derrubou com `offline` ou removeu com `down`.

## Opções

As opções são variáveis colocadas antes do comando. **Com `sudo`, elas vão depois do `sudo`**. Se ficarem antes, o `sudo` as descarta.

```bash
sudo CAMSIM_USER=admin CAMSIM_PASS=Senha_123 ./camsim.sh start
```

| Variável | Para que serve | Padrão |
|---|---|---|
| `CAMSIM_IP` | IP exibido nas URLs. Use quando a máquina tem mais de uma placa de rede e o IP mostrado não é o da rede da central. | IP da rota principal |
| `CAMSIM_BASE_PORT` | Porta da câmera 1. As próximas usam +1, +2... | `18554` |
| `CAMSIM_USER` e `CAMSIM_PASS` | Exigem usuário e senha nas câmeras, para testar o cadastro com credenciais. Use as duas juntas. | sem senha |
| `CAMSIM_IMAGE` | Imagem Docker usada. | `bluenviron/mediamtx:1.17.1-ffmpeg` |

Sobre usuário e senha:
- Só aceitam letras sem acento, números e os caracteres `! $ ( ) * + . ; < = > [ ] ^ _ - @ # &`. Essa é uma limitação do MediaMTX, e o script avisa antes de subir.
- As opções valem para as câmeras criadas naquele `start`. Para mudar, rode o `start` de novo.

Para conferir uma câmera com senha:

```bash
ffprobe -rtsp_transport tcp rtsp://admin:Senha_123@192.168.0.20:18554/cam
```

## Como funciona

Cada câmera é um container Docker com o [MediaMTX](https://github.com/bluenviron/mediamtx), que é um servidor RTSP, e o ffmpeg:

1. O MediaMTX sobe um servidor RTSP dentro do container, na porta 8554.
2. Ao iniciar, o MediaMTX roda o ffmpeg. O ffmpeg gera uma imagem de teste sintética, sem precisar de nenhum arquivo de vídeo, codifica em H264 (640x360, 15 fps) e publica no próprio servidor, no caminho `/cam`. Se o ffmpeg cair, o MediaMTX o reinicia.
3. O Docker liga a porta 8554 de cada container a uma porta da máquina (18554, 18555...).

```
sua máquina                                             central
┌─────────────────────────────────────────┐
│ container camsim1                       │
│   ffmpeg (imagem de teste, H264)        │
│        │ publica                        │
│        ▼                                │
│   MediaMTX :8554/cam ── porta 18554 ◄───┼── API (cadastro e monitor)
│                                         │   MediaMTX da central (vídeo)
│ container camsim2 ───── porta 18555 ◄───┼── ...
└─────────────────────────────────────────┘
```

A configuração de cada câmera fica em `config/camN.yml`, ao lado do script, e é recriada a cada `start`. Ela define duas coisas:
- **Só TCP:** o Docker só expõe a porta TCP, então o vídeo não pode depender de UDP.
- **Protocolos desligados:** RTMP, HLS, WebRTC e SRT ficam desligados, porque não são necessários.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| `Sem acesso ao Docker` | Rode com `sudo`, ou entre no grupo docker: `sudo usermod -aG docker $USER` e depois saia e entre de novo na sessão. |
| `port is already allocated` ou `address already in use` no `start` | A porta já está em uso. Use outra faixa, por exemplo `sudo CAMSIM_BASE_PORT=19554 ./camsim.sh start`. |
| O MediaMTX local da central não sobe (`address already in use` na 8554) | Alguma câmera do simulador está usando a 8554. Recrie com a porta padrão (18554) com `./camsim.sh start`. |
| O `ffprobe` da central não conecta | Confira se a central alcança a sua máquina (ping), se a porta está liberada no firewall e se o IP da URL é o da rede da central (veja `CAMSIM_IP`). |
| A câmera aparece como `exited` no `status` | Rode `./camsim.sh logs N` para ver o erro. |

## Limitações

- **Só RTSP.** Não simula ONVIF: o cadastro por ONVIF ainda precisa de câmera física.
- **Só vídeo,** sem áudio.
- **No máximo 50 câmeras.** Os padrões de imagem se repetem a partir da 9ª.
