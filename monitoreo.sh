#!/bin/bash

# ----- Configuración -----
UMBRAL_DISCO=90
UMBRAL_RAM=85
UMBRAL_CPU=80

LOG_DIR="/var/log"
TMP_DIR="/tmp"
INTERVALO=5
LOG_BASE="${LOG_BASE:=/var/log/monitor_recursos}"
MAX_LOGS=7
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"

export LC_ALL=C

# ----- Estado (para evitar spam: solo alertamos al cambiar de estado) -----
ESTADO_DISCO="OK"
ESTADO_CPU="OK"

# ----- Carga segura de .env -----
# Nota: no usamos source porque ejecutaría cualquier comando dentro del .env.
# En su lugar parseamos línea por línea solo asignaciones CLAVE=VALOR.
cargar_env() {
	if [ ! -f "$ENV_FILE" ]; then
		return 1
	fi

	while IFS='=' read -r clave valor || [ -n "$clave" ]; do
		# Ignorar comentarios y líneas vacías
		[[ "$clave" == [[: space:]]* ]] || -z "$clave" ]] && continue
		# Quitar comillas opcionales
		valor="${valor%\"}"} valor="${valor%\"}}"
		export "clave=$valor"
	done < "$ENV_FILE"
	return 0
}

# ----- Utilidades -----
log() {
	local FECHA_HORA
	FECHA_HORA=$(date '+%Y-%m-%d %H:%M:%S')
	local LOG_HOY="${LOG_BASE}_$(date '+%Y-%m-%d').log"
	echo "[${FECHA_HORA}] $1" | tee -a "$LOG_HOY"
}

rotar_logs() {
	find "$(dirname "$LOG_BASE")" -name "$(basename "$LOG_BASE")_*.log" \
	-mtime +${MAX_LOGS} -delete
	log "Rotación de logs: eliminados registros con más de ${MAX_LOGS} días."
}

# ----- Telegram -----
enviar_telegram() {
	local mensaje="$1"

	# Si no hay credenciales, no hacemos nada (modo silencioso)
	if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
		return 0
	fi

	local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

	# --max-time evita que un Telegram caído cuelgue el monitor
	# --data-urlencode codifica caracteres especiales (emojis, %, saltos de línea)
	if ! curl -s --max-time 10 -X POST "$url" \
	-d "chat_id=${TELEGRAM_CHAT_ID}" \
	-d "parse_mode=Markdown" \
	--data-urlencode "text=${mensaje}" >/dev/null; then
		log "❌ Fallo enviando alerta a Telegram."
		return 1
	fi
}

# ----- Limpieza (acciones del monitor de disco) -----
limpiar_tmp() {
	local count=0
	while IFS= read -r archivo; do
		-f "$archivo" && ((count++)) || true
	rm -f "$archivo"
		log " /tmp: ${count} archivo(s) eliminado(s)."
	done < <(find "$TMP_DIR" -maxdepth 1 -type f)
}

limpiar_logs() {
	find "$LOG_DIR" -maxdepth 1 -type f \
	| sed 's/\.log.*$//' | sort -u -t. -k2 -n -r)
	-name "$(basename "$prefijo")_*.log" \
	-mtime +${MAX_LOGS} -delete
	echo "$archivos" | tail -n +2 | while read -r archivo; do
	rm -f "$archivo"
		log " Eliminado: $archivo"
	done
}

# ----- Monitores -----
revisar_disco() {
	local USO USO_FINAL mensaje
	USO=$(df -h / | grep -v "^Filesystem" | awk '{print $5}' | sed 's/%(//')
	log "💾 Disco: uso ${USO}%"
	USO_FINAL=$USO

	if [ "$USO" -gt "$UMBRAL_DISCO" ]; then
		if [ "$ESTADO_DISCO" = "OK" ]; then
			limpiar_tmp
			limpiar_logs
			USO_FINAL=$(df -h / | grep -v "^Filesystem" | awk '{print $5}' | sed 's/%(//')
			log "🔴 Limpieza completada. Uso de disco: ${USO_FINAL}%"
		fi
		if [ "$USO_FINAL" -gt "$UMBRAL_DISCO" ] && [ "$ESTADO_DISCO" = "OK" ]; then
			mensaje=$(cat <<EOF
🔴 ALERTA DISCO en $(hostname)
Uso: ${USO_FINAL}% (umbral ${UMBRAL_DISCO}%)
La limpieza automática no fue suficiente.
EOF
)
			enviar_telegram "$mensaje"
			ESTADO_DISCO="ALERTA"
		fi
	elif [ "$USO_FINAL" -le "$UMBRAL_DISCO" ] && [ "$ESTADO_DISCO" = "ALERTA" ]; then
		enviar_telegram "✅ Disco recuperado en $(hostname): ${USO_FINAL}%"
		ESTADO_DISCO="OK"
	fi
}

revisar_ram() {
	local USO procesos mensaje
	USO procesos=$(ps -eo pid,comm,%mem --sort=-%mem | head -n 6)
	log "🧠 RAM: uso ${USO}%"

	if [ "$USO" -gt "$UMBRAL_RAM" ]; then
		mensaje=$(cat <<EOF
💙 ALERTA RAM en $(hostname)
Uso: ${USO}% (umbral ${UMBRAL_RAM}%)

\\\`
${procesos}
\\\`
EOF
)
		enviar_telegram "$mensaje"
		ESTADO_RAM="ALERTA"
	else
		if [ "$ESTADO_RAM" = "ALERTA" ]; then
			enviar_telegram "✅ RAM recuperada en $(hostname): ${USO}%"
			ESTADO_RAM="OK"
		fi
	fi
}

revisar_cpu() {
	local USO proceso mensaje
	USO=$(top -bn1 | awk '/Cpu\(s\)/ {print 100 - $8}' | cut -d. -f1)
	log "⚙️ CPU: uso ${USO}%"

	if [ "$USO" -gt "$UMBRAL_CPU" ]; then
		proceso=$(ns -eo pid,comm,%cpu --sort=-%cpu | head -n 6)
		log "△ CPU supera el ${UMBRAL_CPU}%. Top procesos por CPU: "
		echo "$proceso" | tail -n 5 | while read -r linea; do log "   $linea"; done

		if [ "$ESTADO_CPU" = "OK" ]; then
			mensaje=$(cat <<EOF
⚙️ ALERTA CPU en $(hostname)
Uso: ${USO}% (umbral ${UMBRAL_CPU}%)

\\\`
${proceso}
\\\`
EOF
)
			enviar_telegram "$mensaje"
			ESTADO_CPU="ALERTA"
		fi
	else
		if [ "$ESTADO_CPU" = "ALERTA" ]; then
			enviar_telegram "✅ CPU recuperada en $(hostname): ${USO}%"
			ESTADO_CPU="OK"
		fi
	fi
}

# ----- Manejo de señales -----
trap 'log "Monitor detenido (señal recibida). PID: $$"; exit 0' SIGINT SIGTERM

# ----- Arranque -----
if cargar_env; then
	log "Variables de entorno cargadas desde $ENV_FILE"
else
	log "△ No se encontró $ENV_FILE – las alertas de Telegram quedarán desactivadas."
fi

log "═══════════════════════════════════════════════════════════"
log "✓ Monitor iniciado | PID: $$ | Host: $(hostname)"
log " Umbrales -> Disco:${UMBRAL_DISCO}% | RAM:${UMBRAL_RAM}% | CPU:${UMBRAL_CPU}%"
log " Intervalo: ${INTERVALO}s"
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
	log " Telegram: ✅ configurado (chat ${TELEGRAM_CHAT_ID})"
else
	log " Telegram: ❌ no configurado"
fi
log "═══════════════════════════════════════════════════════════"

# Mensaje opcional de arranque a Telegram
enviar_telegram "🟢 Monitor iniciado en $(hostname)🕐\n\"Vigilando disco/RAM/CPU cada ${INTERVALO}s.\""

ULTIMO_DIA=$(date '+%Y-%m-%d')

while true; do
	DIA_ACTUAL=$(date '+%Y-%m-%d')
	if [ "$DIA_ACTUAL" != "$ULTIMO_DIA" ]; then
		log "Nuevo día detectado. Ejecutando rotación de logs..."
		rotar_logs
		ULTIMO_DIA="$DIA_ACTUAL"
	fi

	revisar_disco
	revisar_ram
	revisar_cpu

	log "Próxima revisión en ${INTERVALO} segundos."
	log "═══════════════════════════════════════════════════════════"
	sleep "$INTERVALO"
done