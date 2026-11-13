#!/usr/bin/env bash
# camsim - simulador de câmeras IP (RTSP) para testar a central sem câmera física.
#
# Cada câmera é um container Docker do MediaMTX que gera, com ffmpeg, uma
# imagem de teste H264. A central puxa o vídeo pela URL:
#   rtsp://<IP desta máquina>:<porta>/cam
#
# Uso:
#   ./camsim.sh start [N...]    cria/recria as câmeras (padrão: 1 2 3 4)
#   ./camsim.sh offline N...    derruba a câmera N (simula câmera fora do ar)
#   ./camsim.sh online N...     religa a câmera N
#   ./camsim.sh status          lista as câmeras, o estado e as URLs
#   ./camsim.sh logs N          mostra o log do container da câmera N
#   ./camsim.sh down            remove todas as câmeras do simulador
#
# Sem permissão no Docker, rode com sudo. Para mudar alguma opção abaixo,
# passe a variável antes do script (com sudo: sudo CAMSIM_IP=... ./camsim.sh start).
#   CAMSIM_IP          IP exibido nas URLs (padrão: IP da rota principal)
#   CAMSIM_BASE_PORT   porta da câmera 1; as outras usam +1, +2... (padrão: 18554)
#   CAMSIM_USER        se informado, as câmeras exigem usuário e senha
#   CAMSIM_PASS        senha usada junto com CAMSIM_USER
#   CAMSIM_IMAGE       imagem Docker (padrão: bluenviron/mediamtx:1.17.1-ffmpeg)
#
# Mais detalhes no README.md, na mesma pasta.

set -euo pipefail

IMAGE="${CAMSIM_IMAGE:-bluenviron/mediamtx:1.17.1-ffmpeg}"
# Fica longe da 8554, que o MediaMTX da central usa
BASE_PORT="${CAMSIM_BASE_PORT:-18554}"
CAM_USER="${CAMSIM_USER:-}"
CAM_PASS="${CAMSIM_PASS:-}"
DEFAULT_CAMS=(1 2 3 4)
MAX_CAMS=50
# Padrões de imagem do ffmpeg; a câmera N usa o item N (repete depois do último)
PATTERNS=(testsrc2 smptebars testsrc rgbtestsrc smptehdbars pal75bars yuvtestsrc pal100bars)
PREFIX="camsim"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$DIR/config"

die() {
  echo "$*" >&2
  exit 1
}

host_ip() {
  if [[ -n "${CAMSIM_IP:-}" ]]; then
    echo "$CAMSIM_IP"
    return
  fi

  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  echo "${ip:-$(hostname -I | awk '{print $1}')}"
}

name_of() { echo "$PREFIX$1"; }
port_of() { echo $((BASE_PORT + $1 - 1)); }
pattern_of() { echo "${PATTERNS[$((($1 - 1) % ${#PATTERNS[@]}))]}"; }

# Coloca um valor entre aspas simples para o YAML
yaml_quote() { printf "'%s'" "${1//\'/\'\'}"; }

check_index() {
  [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= MAX_CAMS)) || die "Câmera inválida: '$1' (use 1 a $MAX_CAMS)"
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker não encontrado. Instale o Docker antes de usar o camsim."
  docker info >/dev/null 2>&1 ||
    die "Sem acesso ao Docker. Rode com sudo ou adicione seu usuário ao grupo docker (sudo usermod -aG docker \$USER e entre de novo na sessão)."
}

check_auth() {
  if [[ -n "$CAM_USER" && -z "$CAM_PASS" ]] || [[ -z "$CAM_USER" && -n "$CAM_PASS" ]]; then
    die "Informe CAMSIM_USER e CAMSIM_PASS juntos."
  fi

  # Caracteres que o MediaMTX aceita em usuário e senha. As letras são listadas
  # uma a uma porque "A-Z" inclui acentuadas quando o sistema está em português.
  local allowed='^[]abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!$()*+.;<=>^_@#&[-]+$'
  local value
  for value in "$CAM_USER" "$CAM_PASS"; do
    if [[ -n "$value" && ! "$value" =~ $allowed ]]; then
      die "Usuário e senha só podem ter letras sem acento, números e os caracteres ! \$ ( ) * + . ; < = > [ ] ^ _ - @ # &"
    fi
  done
}

# Câmeras existentes (inclusive paradas), em ordem numérica
existing_cams() {
  docker ps -a --format '{{.Names}}' | sed -n "s/^$PREFIX\([0-9][0-9]*\)$/\1/p" | sort -n
}

write_config() {
  local n=$1 pattern
  pattern=$(pattern_of "$n")
  mkdir -p "$CONF_DIR"

  {
    cat <<EOF
logLevel: info
# Só TCP: o Docker expõe apenas a porta TCP, então o vídeo não pode depender do UDP
rtspTransports: [tcp]
rtmp: no
hls: no
webrtc: no
srt: no
EOF

    if [[ -n "$CAM_USER" ]]; then
      cat <<EOF
authInternalUsers:
  # O ffmpeg dentro do container publica sem senha, só pelo localhost
  - user: any
    ips: ['127.0.0.1', '::1']
    permissions:
      - action: publish
  # Quem assiste (a central) precisa de usuário e senha
  - user: $(yaml_quote "$CAM_USER")
    pass: $(yaml_quote "$CAM_PASS")
    permissions:
      - action: read
EOF
    fi

    cat <<EOF
paths:
  cam:
    runOnInit: >-
      ffmpeg -hide_banner -loglevel error -re
      -f lavfi -i ${pattern}=size=640x360:rate=15
      -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -g 30
      -f rtsp -rtsp_transport tcp rtsp://localhost:\$RTSP_PORT/\$MTX_PATH
    runOnInitRestart: yes
EOF
  } > "$CONF_DIR/cam$n.yml"

  # Com sudo, devolve a pasta ao usuário que chamou o script
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER": "$CONF_DIR"
  fi
}

url_of() {
  local n=$1 port=$2 user=$3
  local credentials=""
  [[ -n "$user" ]] && credentials="(usuário: $user)"
  echo "rtsp://$(host_ip):$port/cam $credentials"
}

start_one() {
  local n=$1 name port
  name=$(name_of "$n")
  port=$(port_of "$n")
  write_config "$n"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --restart unless-stopped \
    -p "$port:8554" \
    --label "camsim.user=$CAM_USER" \
    -v "$CONF_DIR/cam$n.yml:/mediamtx.yml:ro" \
    "$IMAGE" >/dev/null
  printf 'Câmera %-3s %-12s %s\n' "$n" "$(pattern_of "$n")" "$(url_of "$n" "$port" "$CAM_USER")"
}

status() {
  local cams n name state port user
  cams=$(existing_cams)
  [[ -n "$cams" ]] || { echo "Nenhuma câmera criada. Use: $0 start"; return; }

  for n in $cams; do
    name=$(name_of "$n")
    state=$(docker inspect -f '{{.State.Status}}' "$name")
    # Porta real do container, mesmo que CAMSIM_BASE_PORT tenha mudado depois
    port=$(docker inspect -f '{{with index .HostConfig.PortBindings "8554/tcp"}}{{(index . 0).HostPort}}{{end}}' "$name")
    user=$(docker inspect -f '{{index .Config.Labels "camsim.user"}}' "$name")
    printf 'Câmera %-3s %-10s %s\n' "$n" "$state" "$(url_of "$n" "$port" "$user")"
  done
}

need_cams() {
  (($# > 0)) || die "Informe a câmera. Exemplo: $0 $cmd 1"
  for n in "$@"; do check_index "$n"; done
}

cmd=${1:-}
shift || true

case "$cmd" in
  start)
    check_docker
    check_auth
    cams=("$@")
    ((${#cams[@]})) || cams=("${DEFAULT_CAMS[@]}")
    for n in "${cams[@]}"; do check_index "$n"; done
    for n in "${cams[@]}"; do start_one "$n"; done
    echo
    echo "Aguarde uns 5 segundos e confira com: $0 status"
    ;;
  offline)
    check_docker
    need_cams "$@"
    for n in "$@"; do docker stop "$(name_of "$n")" >/dev/null && echo "Câmera $n fora do ar"; done
    ;;
  online)
    check_docker
    need_cams "$@"
    for n in "$@"; do docker start "$(name_of "$n")" >/dev/null && echo "Câmera $n no ar"; done
    ;;
  status)
    check_docker
    status
    ;;
  logs)
    check_docker
    need_cams "$@"
    docker logs --tail 50 "$(name_of "$1")"
    ;;
  down)
    check_docker
    for n in $(existing_cams); do docker rm -f "$(name_of "$n")" >/dev/null; done
    echo "Simulador removido"
    ;;
  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
