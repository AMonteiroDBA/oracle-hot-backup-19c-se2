#!/bin/bash
###############################################################################
# orquestra_dr.sh
#  - Orquestrador tmux para hot backup DR
#  - 3 janelas: archivelog shipper, hot backup, monitor
###############################################################################

BASE="/home/oracle/.alkdba/new"
BIN_DIR="${BASE}/bin"
LOG_DIR="${BASE}/log"

# Scripts
ARCH_SCRIPT="${BIN_DIR}/copy_archivelog_to_pamvs0003l.sh"
HOT_SCRIPT="${BIN_DIR}/hot_backup_ts_to_pamvs0003l.sh"

TMUX_SESSION="DR_DBPROD"

mkdir -p "${LOG_DIR}"

# Valida scripts
if [ ! -x "${ARCH_SCRIPT}" ]; then
  echo "ERRO: ${ARCH_SCRIPT} não existe ou não é executável"
  exit 1
fi
if [ ! -x "${HOT_SCRIPT}" ]; then
  echo "ERRO: ${HOT_SCRIPT} não existe ou não é executável"
  exit 1
fi

# Cria ou reutiliza sessão tmux
if ! tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Criando sessão tmux ${TMUX_SESSION}..."
  tmux new-session -d -s "${TMUX_SESSION}" -n "archivelog"
else
  echo "Sessão tmux ${TMUX_SESSION} já existe; usando a mesma"
fi

# Janela 0: archivelog shipper
echo "Iniciando archivelog shipper..."
tmux send-keys -t "${TMUX_SESSION}:archivelog" "cd ${BASE}" C-m
tmux send-keys -t "${TMUX_SESSION}:archivelog" "echo 'Iniciando copy_archivelog_to_pamvs0003l.sh...'; ${ARCH_SCRIPT} >> ${LOG_DIR}/orquestra_dr.archivelog.log 2>&1" C-m

# Janela 1: hot backup
echo "Iniciando hot backup..."
tmux new-window -t "${TMUX_SESSION}" -n "hot_backup"
tmux send-keys -t "${TMUX_SESSION}:hot_backup" "cd ${BASE}" C-m
tmux send-keys -t "${TMUX_SESSION}:hot_backup" "echo 'Iniciando hot_backup_ts_to_pamvs0003l.sh...'; ${HOT_SCRIPT} >> ${LOG_DIR}/orquestra_dr.hot_backup.log 2>&1" C-m

# Janela 2: monitor
echo "Criando janela de monitor..."
tmux new-window -t "${TMUX_SESSION}" -n "monitor"
tmux send-keys -t "${TMUX_SESSION}:monitor" "cd ${LOG_DIR}" C-m
tmux send-keys -t "${TMUX_SESSION}:monitor" "echo 'Janela de monitor. Use: tail -f <logfile>' && bash" C-m

echo ""
echo "Orquestração iniciada!"
echo "Sessão tmux: ${TMUX_SESSION}"
echo ""
echo "Use: tmux attach -t ${TMUX_SESSION}"
echo "Navegação entre janelas (após attach):"
echo "  Ctrl+b 0  = archivelog window"
echo "  Ctrl+b 1  = hot_backup window"
echo "  Ctrl+b 2  = monitor window"
echo ""
echo "Logs:"
echo "  Archivelog: ${LOG_DIR}/copy_archivelog_to_pamvs0003l.log"
echo "  Hot backup: ${LOG_DIR}/hot_backup_ts_to_pamvs0003l.out"
echo "  Per-TS logs: ${LOG_DIR}/ts_*.log"
