#!/bin/sh

downloadsPath="/downloads"
profilePath="/config"
qbtConfigFile="$profilePath/qBittorrent/config/qBittorrent.conf"

if [ ! -f "$qbtConfigFile" ]; then
    mkdir -p "$(dirname $qbtConfigFile)"
    cat << EOF > "$qbtConfigFile"
[BitTorrent]
Session\DefaultSavePath=$downloadsPath
Session\Port=6881
Session\TempPath=$downloadsPath/temp
EOF
fi

confirmLegalNotice=""
_legalNotice=$(echo "$QBT_LEGAL_NOTICE" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
if [ "$_legalNotice" = "confirm" ]; then
    confirmLegalNotice="--confirm-legal-notice"
else
    # for backward compatibility
    # TODO: remove in next major version release
    _eula=$(echo "$QBT_EULA" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [ "$_eula" = "accept" ]; then
        echo "QBT_EULA=accept is deprecated and will be removed soon. The replacement is QBT_LEGAL_NOTICE=confirm"
        confirmLegalNotice="--confirm-legal-notice"
    fi
fi

if [ -z "$QBT_WEBUI_PORT" ]; then
    QBT_WEBUI_PORT=8080
fi

if [ -d "$downloadsPath" ]; then
    chown qbtUser:qbtUser "$downloadsPath"
fi
if [ -d "$profilePath" ]; then
    chown qbtUser:qbtUser -R "$profilePath"
fi

# set umask just before starting qbt
if [ -n "$UMASK" ]; then
    umask "$UMASK"
fi

sudo -u qbtUser \
    qbittorrent-nox \
        "$confirmLegalNotice" \
        --profile="$profilePath" \
        --webui-port="$QBT_WEBUI_PORT" \
        "$@"
