#!/bin/bash
# ACE Modern 0.8.0 — instalador do cliente local para macOS.
# Bash 3.2 e ferramentas incluídas no macOS. Não requer Python, Homebrew ou sudo.
set -euo pipefail
umask 077

RELEASE_URL='https://github.com/gbmlima-bot/AceOnline-ep43/releases/download/ace-modern-v0.8.0'
ZIP_NAME='ace-modern-online-macos-v0.8.zip'
ZIP_SHA='5de3a098c210b78e3a10b8160fbf8f03bd18c630802c985765dd83d1a55d3db4'
ZIP_BYTES=3362117557
PART_NAMES=(
  "$ZIP_NAME.part-001"
  "$ZIP_NAME.part-002"
  "$ZIP_NAME.part-003"
)
PART_HASHES=(
  '30f8255015bacf9652cb0a653c4613ed7a39bbe697537a3f045532153800a041'
  'ea5c0cf61b0ddae372822f13c990abfa9efff438c5b76140bff81f4d4ce9ce2c'
  '145d599a8147c0bc5ee9bf323f10f7d5b62fa3e16f4dc50f102cdc9b610edeb6'
)
PART_SIZES=(1500000000 1500000000 362117557)
APP_FILES=(
  'Contents/Info.plist'
  'Contents/MacOS/ACE Modern'
  'Contents/PkgInfo'
  'Contents/Resources/ACE Modern.pck'
  'Contents/Resources/PrivacyInfo.xcprivacy'
  'Contents/Resources/icon.icns'
  'Contents/_CodeSignature/CodeResources'
)
APP_HASHES=(
  '1b75f104cfa373c003b1abbe64b2d2878017722230dcb4763e5c61edfc510a03'
  '77b510ab86dc841db6562ba95131883f21aa5e705be763f86bc48ed5f75e29a1'
  '7e50a30efad50208a173203ced60818d693bb61266b75aa10927d1a2adce80cb'
  'dfab5cc36833c46bab4f2a366b43bbe414234f6c0c5c6d148af365d9d049d2e0'
  '0535353bb08c25b8ce5ed9ac7e442a5994f402e0f6cbc4bed668cfc63c2ceac3'
  '71b13e0a862281769f3efb1cae362b0449c96b7f20d522eb21a55db6c8f9f4f9'
  '6dd32c5236ebf85733ef67978d2a52ec571b296de468ca2718fe86b47b3e08f5'
)
APP_SIZES=(1777 170963648 9 3810974296 229 443068 3177)

STAGE=''
LOCK=''
LOCK_HELD=0

fail() { printf '\nErro: %s\n' "$*" >&2; exit 1; }
notice() { printf '%s\n' "$*"; }

cleanup() {
  if [[ -n "$STAGE" && -d "$STAGE" && ! -L "$STAGE" ]]; then
    rm -rf -- "$STAGE"
  fi
  if [[ "$LOCK_HELD" -eq 1 ]]; then rmdir -- "$LOCK" 2>/dev/null || true; fi
}

# Os arquivos já baixados são aproveitados somente se tamanho E SHA-256 conferem.
verify_file() {
  local path="$1" expected_sha="$2" expected_bytes="$3" bytes actual
  [[ -f "$path" && ! -L "$path" ]] || return 1
  bytes=$(wc -c < "$path") || return 1
  [[ "$bytes" -eq "$expected_bytes" ]] || return 1
  actual=$(shasum -a 256 "$path") || return 1
  actual=${actual%% *}
  [[ "$actual" == "$expected_sha" ]]
}

verify_installation() {
  local folder="$1" app="$1/ACE Modern.app" i version
  [[ -d "$folder" && ! -L "$folder" && -d "$app" && ! -L "$app" ]] || return 1
  for ((i=0; i<${#APP_FILES[@]}; i++)); do
    verify_file "$app/${APP_FILES[$i]}" "${APP_HASHES[$i]}" "${APP_SIZES[$i]}" || return 1
  done
  [[ -x "$app/Contents/MacOS/ACE Modern" ]] || return 1
  [[ -f "$folder/LEIA-ME-ONLINE.txt" && -d "$folder/third_party" ]] || return 1
  [[ -f "$folder/third_party/Godot-LICENSE.txt" && -f "$folder/third_party/Godot-COPYRIGHT.txt" ]] || return 1
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") || return 1
  [[ "$version" == '0.8.0' ]]
}

check_space() {
  local folder="$1" required_kb="$2" available
  available=$(df -Pk "$folder" | awk 'END {print $4}')
  [[ "$available" =~ ^[0-9]+$ ]] || fail "Não consegui consultar o espaço livre em $folder."
  [[ "$available" -ge "$required_kb" ]] || fail "Espaço insuficiente em $folder. Reserve cerca de $((required_kb / 1000000)) GB livres e execute novamente."
}

download_part() {
  local name="$1" sha="$2" bytes="$3" path="$WORK_DIR/$1" partial="$WORK_DIR/$1.download"
  if verify_file "$DOWNLOADS/$name" "$sha" "$bytes"; then
    notice "Aproveitando parte já conferida: $DOWNLOADS/$name"
    PART_PATHS[$PART_COUNT]="$DOWNLOADS/$name"
    PART_COUNT=$((PART_COUNT + 1))
    return
  fi
  if verify_file "$path" "$sha" "$bytes"; then
    notice "Parte já conferida: $name"
    PART_PATHS[$PART_COUNT]="$path"
    PART_COUNT=$((PART_COUNT + 1))
    return
  fi
  [[ ! -e "$path" && ! -L "$path" ]] || fail "O arquivo $path já existe, mas não confere. Ele foi preservado; mova-o para outro local antes de tentar novamente."
  [[ ! -L "$partial" && ( ! -e "$partial" || -f "$partial" ) ]] || fail "Caminho de download inválido: $partial"
  if ! verify_file "$partial" "$sha" "$bytes"; then
    notice "Baixando $name (o download pode ser retomado nesta pasta)..."
    curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 \
      --proto '=https' --proto-redir '=https' --continue-at - \
      --output "$partial" "$RELEASE_URL/$name" || fail "Download interrompido. Execute novamente para retomar. Arquivo preservado: $partial"
  fi
  verify_file "$partial" "$sha" "$bytes" || fail "SHA-256 ou tamanho incorreto em $partial. Nada foi instalado. O arquivo foi preservado para inspeção; remova apenas esse download incompleto para tentar novamente."
  mv -n -- "$partial" "$path"
  verify_file "$path" "$sha" "$bytes" || fail "Não foi possível confirmar a parte em $path."
  PART_PATHS[$PART_COUNT]="$path"
  PART_COUNT=$((PART_COUNT + 1))
}

launch_app() {
  local folder="$1"
  notice ""
  notice "Cliente instalado e arquivos conferidos: $folder/ACE Modern.app"
  notice "As licenças e o guia estão na mesma pasta. Nenhuma instalação anterior foi substituída."
  notice "Vou solicitar a abertura do app. A execução nativa ainda precisa ser confirmada neste Mac."
  notice "Se o macOS bloquear a abertura, confira o aviso em Ajustes do Sistema > Privacidade e Segurança."
  notice "O Gatekeeper continua ativo. Este instalador não remove quarentena nem altera a assinatura."
  notice "O modo local pode ser testado agora; o multiplayer ainda depende de hospedar e configurar o servidor."
  if ! open "$folder/ACE Modern.app"; then
    notice "O macOS não aceitou o pedido de abertura. Abra a pasta pelo Finder e confira o aviso do sistema."
  fi
}

publish_installation() {
  local staging="$1" destination="$2"
  # mkdir reserva o destino sem a semântica de mv que poderia mesclar pastas.
  mkdir -- "$destination" || fail "O destino passou a existir e foi preservado: $destination"
  mv -n -- "$staging/ACE Modern.app" "$staging/LEIA-ME-ONLINE.txt" "$staging/third_party" "$destination/"
  rmdir -- "$staging" || fail "A instalação ficou incompleta em $destination. Os arquivos existentes foram preservados."
}

main() {
  [[ $# -eq 0 ]] || fail 'Uso: bash install_macos.sh (sem argumentos).'
  [[ "$(uname -s)" == 'Darwin' ]] || fail 'Execute este instalador no Terminal do seu Mac. Nenhum download foi iniciado.'
  local cpu macos_major
  cpu=$(uname -m)
  case "$cpu" in arm64|x86_64) ;; *) fail 'Esta versão requer Mac com Apple Silicon ou Intel de 64 bits.' ;; esac
  macos_major=$(sw_vers -productVersion)
  macos_major=${macos_major%%.*}
  [[ "$macos_major" =~ ^[0-9]+$ ]] || fail 'Não foi possível identificar a versão do macOS.'
  if [[ "$cpu" == 'arm64' ]]; then
    [[ "$macos_major" -ge 13 ]] || fail 'O cliente Apple Silicon requer macOS 13 ou posterior.'
  else
    [[ "$macos_major" -ge 11 ]] || fail 'O cliente Intel requer macOS 11 ou posterior.'
  fi
  [[ -n "${HOME:-}" && -d "$HOME" ]] || fail 'Não foi possível localizar a pasta do usuário.'
  local tool i zip_path zip_partial required_kb
  for tool in curl shasum ditto df awk wc open mktemp mkdir mv cat rm rmdir; do
    command -v "$tool" >/dev/null 2>&1 || fail "Ferramenta do macOS não encontrada: $tool"
  done
  DOWNLOADS="$HOME/Downloads"
  WORK_DIR="$DOWNLOADS/ACE-Modern-v0.8-macos"
  INSTALL_ROOT="$HOME/Applications"
  DESTINATION="$INSTALL_ROOT/ACE Modern 0.8"
  [[ ! -L "$DESTINATION" ]] || fail "A instalação de destino é um link e foi preservada: $DESTINATION"
  if [[ -e "$DESTINATION" ]]; then
    notice 'Conferindo a instalação existente...'
    verify_installation "$DESTINATION" || fail "Já existe conteúdo diferente em $DESTINATION. Ele foi preservado. Mova ou renomeie essa pasta antes de instalar."
    launch_app "$DESTINATION"
    return
  fi
  [[ ! -L "$WORK_DIR" ]] || fail "A pasta de trabalho é um link e foi preservada: $WORK_DIR"
  mkdir -p -- "$WORK_DIR" "$INSTALL_ROOT"
  LOCK="$WORK_DIR/.installer-lock"
  mkdir -- "$LOCK" 2>/dev/null || fail "Outro instalador pode estar usando $WORK_DIR. Se nenhum estiver aberto, remova somente a pasta vazia .installer-lock e tente novamente."
  LOCK_HELD=1
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  zip_path=''
  required_kb=12000000
  if verify_file "$DOWNLOADS/$ZIP_NAME" "$ZIP_SHA" "$ZIP_BYTES"; then
    zip_path="$DOWNLOADS/$ZIP_NAME"
    required_kb=5000000
  elif verify_file "$WORK_DIR/$ZIP_NAME" "$ZIP_SHA" "$ZIP_BYTES"; then
    zip_path="$WORK_DIR/$ZIP_NAME"
    required_kb=5000000
  fi
  check_space "$WORK_DIR" "$required_kb"
  check_space "$INSTALL_ROOT" 5000000
  if [[ -z "$zip_path" ]]; then
    [[ ! -e "$WORK_DIR/$ZIP_NAME" && ! -L "$WORK_DIR/$ZIP_NAME" ]] || fail "ZIP existente não confere e foi preservado: $WORK_DIR/$ZIP_NAME"
    PART_PATHS=()
    PART_COUNT=0
    for ((i=0; i<${#PART_NAMES[@]}; i++)); do
      download_part "${PART_NAMES[$i]}" "${PART_HASHES[$i]}" "${PART_SIZES[$i]}"
    done
    zip_partial="$WORK_DIR/$ZIP_NAME.assembling"
    [[ ! -e "$zip_partial" && ! -L "$zip_partial" ]] || fail "Já existe uma montagem incompleta preservada: $zip_partial. Mova esse arquivo antes de tentar novamente."
    notice 'Recompondo e conferindo o ZIP completo...'
    (set -o noclobber; cat "${PART_PATHS[@]}" > "$zip_partial")
    verify_file "$zip_partial" "$ZIP_SHA" "$ZIP_BYTES" || fail "O ZIP recomposto não confere. Arquivo preservado: $zip_partial"
    mv -n -- "$zip_partial" "$WORK_DIR/$ZIP_NAME"
    zip_path="$WORK_DIR/$ZIP_NAME"
    verify_file "$zip_path" "$ZIP_SHA" "$ZIP_BYTES" || fail 'Não foi possível confirmar o ZIP final.'
  fi
  notice 'Extraindo o app e preservando as licenças...'
  STAGE=$(mktemp -d "$INSTALL_ROOT/.ace-modern-v0.8.XXXXXX")
  ditto -x -k "$zip_path" "$STAGE"
  verify_installation "$STAGE" || fail 'A conferência do app extraído falhou. Nenhuma instalação anterior foi alterada.'
  publish_installation "$STAGE" "$DESTINATION"
  STAGE=''
  launch_app "$DESTINATION"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
