#!/bin/bash

UMBRAL=90
LOG_DIR="/var/log"
TMP_DIR="/tmp"
INTERVALO=60
LOG_BASE="/var/log/monitor_disco"
MAX_LOGS=7

log() {
    local FECHA_HORA
    FECHA_HORA=$(date '+%Y-%m-%d %H:%M:%S')

    local LOG_HOY="${LOG_BASE}_$(date '+%Y-%m-%d').log"

    echo "[${FECHA_HORA}] $1" | tee -a "$LOG_HOY"
}

rotar_logs() {
    find "$(dirname "$LOG_BASE")" -name "monitor_disco_*.log" \
        -mtime +${MAX_LOGS} -delete

    log "Rotación de logs: eliminados registros con más de ${MAX_LOGS} días."
}

limpiar_tmp() {
    local count=0

    while IFS= read -r archivo; do
        rm -f "$archivo" && ((count++))
    done < <(find "$TMP_DIR" -maxdepth 1 -type f)

    log "/tmp: ${count} archivo(s) eliminado(s)."
}

limpiar_logs() {

    find "$LOG_DIR" -maxdepth 1 -type f \
        | sed 's/\.[0-9]*$//' \
        | sed 's/\.log.*$//' \
        | sort -u \
        | while read -r prefijo; do

        local archivos total

        archivos=$(find "$LOG_DIR" -maxdepth 1 -type f \
            -name "$(basename "$prefijo")*" \
            | sort -t. -k2 -n -r)

        total=$(echo "$archivos" | grep -c .)

        if [ "$total" -le 1 ]; then
            continue
        fi

        echo "$archivos" | tail -n +2 | while read -r archivo; do
            rm -f "$archivo"

            log "Eliminado: $archivo"
        done
    done
}

log "-----------------------------------------"
log "Monitor iniciado | PID: $$ | Umbral: ${UMBRAL}%"
log "-----------------------------------------"

ULTIMO_DIA=$(date '+%Y-%m-%d')

while true; do

    DIA_ACTUAL=$(date '+%Y-%m-%d')

    if [ "$DIA_ACTUAL" != "$ULTIMO_DIA" ]; then
        log "Nuevo día detectado. Ejecutando rotación de logs..."

        rotar_logs

        ULTIMO_DIA="$DIA_ACTUAL"
    fi

    USO=$(df -h / | grep -v "^Filesystem" | awk '{print $5}' | sed 's/%//')

    log "Revisión de disco: uso actual ${USO}%"

    # CORREGIDO: UMBAL -> UMBRAL
    if [ "$USO" -gt "$UMBRAL" ]; then

        log "Alerta: uso supera el ${UMBRAL}%. Iniciando limpieza..."

        limpiar_tmp
        limpiar_logs

        # CORREGIDO: comillas y pipe roto
        USO_POST=$(df -h / | grep -v "^Filesystem" | awk '{print $5}' | sed 's/%//')

        log "Limpieza completada. Uso después: ${USO_POST}%"

    else
        log "Uso dentro del límite. Sin acción requerida."
    fi

    # CORREGIDO: eb -> en
    log "Próxima revisión en ${INTERVALO} segundos."
    log "-------------------------------------------"

    sleep "$INTERVALO"

done