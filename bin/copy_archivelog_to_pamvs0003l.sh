#!/bin/bash
###############################################################################
# copy_archivelog_to_pamvs0003l.sh
#  - Copia contínua de archivelogs thread#1 da PROD para o DR
#  - Captura SCN de corte no início
#  - Valida uso via lsof antes de copiar
#  - State file para retomada segura
###############################################################################

ORACLE_SID=dbprod
export ORACLE_SID

DEST_HOST="pamvs0003l.friosulense.com.br"
DEST_USER="oracle"
DEST_ARCHLOG_DIR="/u12/flash_recovery_area/DBPROD/archivelog"

BASE="/home/oracle/.alkdba/new"
TMP_DIR="${BASE}/tmp"
LOG_DIR="${BASE}/log"
STATE_DIR="${BASE}/state"

mkdir -p "${TMP_DIR}" "${LOG_DIR}" "${STATE_DIR}"

LOG_FILE="${LOG_DIR}/copy_archivelog_to_pamvs0003l.log"
SCN_FILE="${STATE_DIR}/scn_cutoff.${ORACLE_SID}"
SEQ_FILE="${STATE_DIR}/last_arch_seq_thread1.${ORACLE_SID}"

# Sleep interval entre iterações
SLEEP_INTERVAL=60

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

is_file_in_use() {
  local file="$1"
  lsof "${file}" > /dev/null 2>&1
  return $?
}

# Captura SCN inicial se não existir
if [ ! -f "${SCN_FILE}" ]; then
  log_msg "Capturando SCN de corte da produção..."
  SCN=$(sqlplus -s "/ as sysdba" <<EOF | tr -d ' '
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT CURRENT_SCN FROM V\\$DATABASE;
EOF
  )
  echo "${SCN}" > "${SCN_FILE}"
  log_msg "SCN de corte: ${SCN}"
fi

SCN=$(cat "${SCN_FILE}")

# Inicializa sequence
if [ ! -f "${SEQ_FILE}" ]; then
  log_msg "Inicializando sequence inicial (SCN >= ${SCN})..."
  sqlplus -s "/ as sysdba" <<EOF > "${SEQ_FILE}"
SET HEADING OFF FEEDBACK OFF PAGES 0
SELECT NVL(MIN(SEQUENCE#),0)
FROM   V\\$ARCHIVED_LOG
WHERE  THREAD# = 1
  AND  ARCHIVED = 'YES'
  AND  FIRST_CHANGE# >= ${SCN};
EOF
fi

log_msg "Início do loop de cópia de archives..."

while true; do
  LAST_SEQ=$(tr -d '[:space:]' < "${SEQ_FILE}")
  [ -z "${LAST_SEQ}" ] && LAST_SEQ=0

  # Log da iteração
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] LAST_SEQ=${LAST_SEQ}" >> "${LOG_FILE}"

  TMP_LIST="${TMP_DIR}/arch_list.$$.txt"

  # Query archivelogs
  sqlplus -s "/ as sysdba" <<EOF > "${TMP_LIST}"
SET HEADING OFF FEEDBACK OFF PAGES 0 LINES 400
SELECT LTRIM(SEQUENCE#) || '|' || NAME
FROM   V\\$ARCHIVED_LOG
WHERE  THREAD# = 1
  AND  ARCHIVED = 'YES'
  AND  FIRST_CHANGE# >= ${SCN}
  AND  SEQUENCE# > ${LAST_SEQ}
ORDER  BY SEQUENCE#;
EOF

  NEW_LAST=${LAST_SEQ}

  # Garante diretório no destino
  ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '${DEST_ARCHLOG_DIR}'" 2>>/dev/null

  # Processa cada archivelog
  while IFS='|' read SEQ NAME; do
    [ -z "${SEQ}" ] && continue
    [ -z "${NAME}" ] && continue

    # Verifica se está em uso
    if is_file_in_use "${NAME}"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP (in use): ${NAME}" >> "${LOG_FILE}"
      continue
    fi

    # Arquivo existe?
    if [ ! -f "${NAME}" ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP (not found): ${NAME}" >> "${LOG_FILE}"
      continue
    fi

    # rsync
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] rsync seq=${SEQ}: ${NAME}" >> "${LOG_FILE}"
    rsync -aP --append-verify "${NAME}" "${DEST_USER}@${DEST_HOST}:${DEST_ARCHLOG_DIR}/" >> "${LOG_FILE}" 2>&1
    rc=$?

    if [ ${rc} -eq 0 ]; then
      NEW_LAST=${SEQ}
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK seq=${SEQ}" >> "${LOG_FILE}"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO rsync (rc=${rc}) seq=${SEQ}" >> "${LOG_FILE}"
    fi
  done < "${TMP_LIST}"

  # Atualiza state
  echo "${NEW_LAST}" > "${SEQ_FILE}"
  rm -f "${TMP_LIST}"

  # Sleep
  sleep ${SLEEP_INTERVAL}
done
