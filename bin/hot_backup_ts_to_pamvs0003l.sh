#!/bin/bash
###############################################################################
# hot_backup_ts_to_pamvs0003l.sh
#  - Hot backup por tablespace com rsync paralelo e path translation
#  - BEGIN BACKUP -> rsync -> END BACKUP para cada TS
#  - Mapeamento flexível de filesystem (ex: /u05 -> /u15)
#  - Reentrancia total: completa-se onde parou
###############################################################################

# ============================================================================
# CONFIGURAÇÃO
# ============================================================================

ORACLE_SID=dbprod
export ORACLE_SID

# Destino (standby)
DEST_HOST="pamvs0003l.friosulense.com.br"
DEST_USER="oracle"

# Mapeamento de prefixos de filesystem (PROD -> DR)
# Estrutura: chave=origem, valor=destino
declare -A PATH_MAP=(
  ["/u05"]="/u15"
  # Adicione mais mapeamentos conforme necessário
)

# Parâmetros de cópia
PARALLEL=4
RSYNC_OPTS="-avzP --append-verify"

# Diretórios locais
BASE="/home/oracle/.alkdba/new"
TMP_DIR="${BASE}/tmp"
LOG_DIR="${BASE}/log"
STATE_DIR="${BASE}/state"

mkdir -p "${TMP_DIR}" "${LOG_DIR}" "${STATE_DIR}"

MAIN_LOG="${LOG_DIR}/hot_backup_ts_to_pamvs0003l.out"
TS_LIST="${TMP_DIR}/ts_list.$$.txt"

# Tablespaces a excluir
EXCLUDE_TS="^TEMP$"

# Core tablespaces (deixar por último)
CORE_TS="(^SYSTEM$|^SYSAUX$|^UNDOTBS|^UNDO)"

# ============================================================================
# FUNÇÕES
# ============================================================================

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${MAIN_LOG}"
}

translate_path() {
  local src_path="$1"
  local result="${src_path}"
  
  # Tenta casar com os mapeamentos definidos
  for src_prefix in "${!PATH_MAP[@]}"; do
    if [[ "${src_path}" == "${src_prefix}"* ]]; then
      local dst_prefix="${PATH_MAP[${src_prefix}]}"
      result="${dst_path/${src_prefix}/${dst_prefix}}"
      break
    fi
  done
  
  echo "${result}"
}

begin_backup_ts() {
  local ts="$1"
  log_msg "BEGIN BACKUP para TS \"${ts}\""
  sqlplus -s "/ as sysdba" <<EOF >> "${MAIN_LOG}" 2>&1
ALTER TABLESPACE "${ts}" BEGIN BACKUP;
EOF
}

end_backup_ts() {
  local ts="$1"
  log_msg "END BACKUP para TS \"${ts}\""
  sqlplus -s "/ as sysdba" <<EOF >> "${MAIN_LOG}" 2>&1
ALTER TABLESPACE "${ts}" END BACKUP;
EOF
}

copy_ts_files() {
  local ts="$1"
  local ts_log="${LOG_DIR}/ts_${ts}.log"
  local count=0
  
  # Prepara lista de datafiles dessa TS
  local ts_file_list="${TMP_DIR}/ts_files_${ts}.$$.txt"
  : > "${ts_file_list}"
  
  while IFS='|' read file_entry; do
    [ -z "${file_entry}" ] && continue
    echo "${file_entry}" >> "${ts_file_list}"
    count=$((count + 1))
  done < <(grep "^${ts}|" "${TS_LIST}")
  
  if [ ${count} -eq 0 ]; then
    log_msg "TS \"${ts}\": nenhum datafile encontrado"
    return 0
  fi
  
  log_msg "TS \"${ts}\": iniciando rsync de ${count} datafiles"
  
  # rsync paralelo com xargs
  cat "${ts_file_list}" | cut -d'|' -f3 | \
    xargs -P"${PARALLEL}" -I{} sh -c '
      src_file="$1"
      dst_file=$(translate_path "${src_file}")
      echo "[$(date +%Y-%m-%d\ %H:%M:%S)] rsync ${src_file} -> '"${DEST_HOST}"':${dst_file}" >> "'"${ts_log}"'"
      rsync '"${RSYNC_OPTS}"' "${src_file}" "'"${DEST_USER}"'@'"${DEST_HOST}"':{dst_file}/" >> "'"${ts_log}"'" 2>&1
      rc=$?
      if [ ${rc} -ne 0 ]; then
        echo "[$(date +%Y-%m-%d\ %H:%M:%S)] ERRO rsync (rc=${rc}): ${src_file}" >> "'"${ts_log}"'"
      fi
    ' sh {}
  
  rm -f "${ts_file_list}"
  log_msg "TS \"${ts}\": rsync concluído"
}

# ============================================================================
# MAIN
# ============================================================================

echo "" | tee -a "${MAIN_LOG}"
log_msg "========================================"
log_msg "Início do hot backup"
log_msg "ORACLE_SID=${ORACLE_SID}, DEST_HOST=${DEST_HOST}"
log_msg "========================================"

# Gera lista de TS x datafiles
log_msg "Gerando lista de tablespaces e datafiles..."
sqlplus -s "/ as sysdba" <<EOF > "${TS_LIST}"
SET HEADING OFF FEEDBACK OFF PAGES 0 LINES 400
SELECT t.name || '|' || d.file# || '|' || d.name
FROM   v\$tablespace t
JOIN   v\$datafile d ON t.ts# = d.ts#
ORDER  BY t.name, d.file#;
EOF

if [ ! -s "${TS_LIST}" ]; then
  log_msg "ERRO: Lista de TS vazia"
  exit 1
fi

TOTAL_TS=$(cut -d'|' -f1 "${TS_LIST}" | sort -u | wc -l)
TOTAL_DF=$(wc -l < "${TS_LIST}")
log_msg "Encontrados ${TOTAL_TS} tablespaces com ${TOTAL_DF} datafiles"

# Separa TS core das demais
CORE_LIST=$(cut -d'|' -f1 "${TS_LIST}" | sort -u | grep -E "${CORE_TS}" | sort)
NON_CORE_LIST=$(cut -d'|' -f1 "${TS_LIST}" | sort -u | grep -vE "${CORE_TS}|${EXCLUDE_TS}" | sort)

log_msg "Non-core TS: $(echo ${NON_CORE_LIST} | tr '\n' ' ')"
log_msg "Core TS (último): $(echo ${CORE_LIST} | tr '\n' ' ')"

# Garante diretório no destino
ssh "${DEST_USER}@${DEST_HOST}" "mkdir -p '/u15/oradata/dbprod/datafile/DBPROD'" 2>>/dev/null

# Processa TS não-core primeiro
for ts in ${NON_CORE_LIST}; do
  # Checa se já foi feito
  if [ -f "${STATE_DIR}/ts_${ts}.done" ]; then
    log_msg "TS \"${ts}\": já processada, pulando"
    continue
  fi
  
  begin_backup_ts "${ts}"
  copy_ts_files "${ts}"
  end_backup_ts "${ts}"
  
  # Marca como completa
  touch "${STATE_DIR}/ts_${ts}.done"
  log_msg "TS \"${ts}\": concluída"
done

# Processa TS core por último
for ts in ${CORE_LIST}; do
  if [ -f "${STATE_DIR}/ts_${ts}.done" ]; then
    log_msg "TS \"${ts}\": já processada, pulando"
    continue
  fi
  
  begin_backup_ts "${ts}"
  copy_ts_files "${ts}"
  end_backup_ts "${ts}"
  
  touch "${STATE_DIR}/ts_${ts}.done"
  log_msg "TS \"${ts}\": concluída"
done

rm -f "${TS_LIST}"

log_msg "========================================"
log_msg "Hot backup finalizado com sucesso"
log_msg "========================================"
echo "Logs em: ${MAIN_LOG}"
