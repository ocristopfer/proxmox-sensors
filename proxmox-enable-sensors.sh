#!/usr/bin/env bash
# proxmox-enable-sensors.sh — Temperaturas (CPU / GPU / NVMe / HDD) no Proxmox VE:
#                             linha no Summary + GRÁFICO histórico igual aos de CPU/Rede
#
# ═══════════════════════════════════════════════════════════════
#  COMO EXECUTAR
# ═══════════════════════════════════════════════════════════════
#
#  No host Proxmox, como root:
#    bash proxmox-enable-sensors.sh
#
#  Remotamente (da sua máquina):
#    ssh root@<IP-PROXMOX> "bash -s" < proxmox-enable-sensors.sh
#
#  Ver o que seria alterado, sem alterar NADA (mostra o diff):
#    bash proxmox-enable-sensors.sh --dry-run
#
#  Ver o estado atual (patcheado? coletor rodando? quais séries?):
#    bash proxmox-enable-sensors.sh --status
#
#  Só a linha de texto, sem o gráfico:
#    bash proxmox-enable-sensors.sh --no-graph
#
#  Desfazer tudo (mantém o histórico do RRD):
#    bash proxmox-enable-sensors.sh --revert
#  Desfazer tudo e apagar o histórico:
#    bash proxmox-enable-sensors.sh --revert --purge
#
# ═══════════════════════════════════════════════════════════════
#  PRÉ-REQUISITO
# ═══════════════════════════════════════════════════════════════
#   apt install -y lm-sensors && sensors-detect --auto
#   modprobe drivetemp && echo drivetemp >> /etc/modules   # temp de SATA
#   sensors -j    # tem que devolver JSON com os chips
#
# ═══════════════════════════════════════════════════════════════
#  O QUE FAZ
# ═══════════════════════════════════════════════════════════════
#  TEXTO (linha "Temperatures" no Summary, valor instantâneo)
#   - Nodes.pm       → 'thermalstate' em GET /nodes/{node}/status
#   - pvemanagerlib  → linha "Temperatures" logo abaixo de "CPU(s)"
#
#  GRÁFICO (histórico, junto dos gráficos de CPU/Rede/RAM)
#   - /usr/local/bin/pve-sensors-collect  → daemon que lê 'sensors -j' de
#     minuto em minuto e grava num RRD próprio em /var/lib/pve-sensors
#   - /usr/share/perl5/PVE/SensorsRRD.pm  → lê esse RRD
#   - Nodes.pm       → GET /nodes/{node}/rrddata passa a devolver também as
#     séries de temperatura (t_cpu, t_nvme0, ...) junto com cpu/netin/etc
#   - pvemanagerlib  → painel 'Temperatures' na tela Summary do nó
#
#   O PVE guarda o histórico num RRD de schema fixo (pmxcfs) onde NÃO dá para
#   acrescentar métrica. Por isso o script mantém um RRD paralelo e faz o
#   merge na resposta da API — o front-end nem percebe a diferença.
#
# ═══════════════════════════════════════════════════════════════
#  SEGURANÇA — como este script evita quebrar o Proxmox
# ═══════════════════════════════════════════════════════════════
#   1. BACKUP dos 2 arquivos originais antes de qualquer alteração,
#      em /root/pve-sensors-mod/<data-hora>/
#   2. Todo o patch acontece em CÓPIAS temporárias. Nada em /usr é tocado
#      enquanto a validação não passa.
#   3. PROVA DE REVERSIBILIDADE: a cópia patcheada é revertida e comparada
#      byte a byte com o original. Se não bater exatamente, aborta.
#   4. 'perl -c' no Nodes.pm patcheado ANTES de instalar. Perl inválido =
#      pvedaemon não sobe = UI morta; então isso é bloqueante.
#   5. Instalação ATÔMICA (escreve .tmp e faz rename), preservando dono e
#      permissões. Um Ctrl+C no meio nunca deixa arquivo truncado.
#   6. Depois do restart, confere se pvedaemon e pveproxy subiram. Se não
#      subiram, RESTAURA o backup sozinho e reinicia de novo.
#   7. Qualquer erro/interrupção depois do backup dispara ROLLBACK automático.
#   8. Os patches são inserções puras delimitadas por marcadores; nenhuma
#      linha original é removida ou reescrita (a única exceção é o 'height:'
#      do painel, que guarda o valor antigo no próprio comentário).
#
#   É IDEMPOTENTE: rodar de novo regenera os blocos (inclusive atualiza as
#   séries do gráfico se você trocou de hardware).
#
#   ATENÇÃO: todo 'apt upgrade' que atualizar o pacote pve-manager sobrescreve
#   Nodes.pm e pvemanagerlib.js e remove os patches. Basta rodar de novo — o
#   histórico do RRD NÃO se perde.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# =============================================================================
# CONFIGURAÇÃO
# =============================================================================
PM_FILE="${PM_FILE:-/usr/share/perl5/PVE/API2/Nodes.pm}"
JS_FILE="${JS_FILE:-/usr/share/pve-manager/js/pvemanagerlib.js}"
MOD_FILE="${MOD_FILE:-/usr/share/perl5/PVE/SensorsRRD.pm}"
COLLECTOR="${COLLECTOR:-/usr/local/bin/pve-sensors-collect}"
UNIT_NAME="pve-sensors-collect.service"
UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/$UNIT_NAME}"
DATA_DIR="${DATA_DIR:-/var/lib/pve-sensors}"
SENSORS_BIN="${SENSORS_BIN:-/usr/bin/sensors}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/pve-sensors-mod}"

MODE="patch"
WITH_GRAPH=1
PURGE=0
PANEL_HEIGHT=""
for arg in "$@"; do
  case "$arg" in
    --revert)   MODE="revert" ;;
    --dry-run)  MODE="dry-run" ;;
    --status)   MODE="status" ;;
    --no-graph) WITH_GRAPH=0 ;;
    --purge)    PURGE=1 ;;
    --panel-height=*) PANEL_HEIGHT="${arg#*=}" ;;
    -h|--help)  awk 'NR==1{next} /^set -euo pipefail$/{exit} {print}' "$0"; exit 0 ;;
    *) echo "Argumento desconhecido: $arg (use --help)" >&2; exit 1 ;;
  esac
done

# =============================================================================
# Helpers
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

TMP="$(mktemp -d)"
BACKUP_DIR=""
ARMED=0              # 1 = já mexemos em /usr; um erro daqui pra frente = rollback
INSTALLED_COLLECTOR=0

# ---------------------------------------------------------------- rollback
rollback() {
  echo ""
  echo -e "${RED}━━━ ROLLBACK AUTOMÁTICO ━━━${NC}" >&2
  if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    [ -f "$BACKUP_DIR/Nodes.pm" ]         && cp -a "$BACKUP_DIR/Nodes.pm"         "$PM_FILE" && echo "  restaurado: $PM_FILE" >&2
    [ -f "$BACKUP_DIR/pvemanagerlib.js" ] && cp -a "$BACKUP_DIR/pvemanagerlib.js" "$JS_FILE" && echo "  restaurado: $JS_FILE" >&2
  fi
  rm -f "$PM_FILE.pve-sensors.staging" "$JS_FILE.pve-sensors.staging" 2>/dev/null || true
  if [ "$INSTALLED_COLLECTOR" -eq 1 ]; then
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE" "$COLLECTOR" "$MOD_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo "  removido: coletor" >&2
  fi
  systemctl restart pvedaemon pveproxy >/dev/null 2>&1 || true
  echo -e "${YELLOW}  O Proxmox foi devolvido ao estado anterior.${NC}" >&2
  [ -n "$BACKUP_DIR" ] && echo "  Backup preservado em: $BACKUP_DIR" >&2
  echo "" >&2
}

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$ARMED" -eq 1 ]; then rollback; fi
  rm -rf "$TMP"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

node_name() { hostname | cut -d. -f1; }

# Rodando por stdin (ssh ... "bash -s"), $0 e literalmente "bash" — o relatorio
# final imprimia "bash bash --revert". Usa um nome util nesse caso.
case "$0" in
  bash|-bash|sh|-sh|-|/dev/stdin) SELF="proxmox-enable-sensors.sh" ;;
  *)                              SELF="$0" ;;
esac

# =============================================================================
# MODO --status — só lê, não altera nada
# =============================================================================
if [ "$MODE" = "status" ]; then
  echo ""
  echo "━━━ Estado do mod de temperaturas ━━━"
  echo ""
  for f in "$PM_FILE" "$JS_FILE"; do
    if [ ! -f "$f" ]; then echo "  [ausente]   $f"
    elif grep -q "PVE-SENSORS" "$f" 2>/dev/null; then
      echo "  [PATCHEADO] $f"
      grep -o "PVE-SENSORS-[A-Z]*-BEGIN" "$f" | sed 's/^/                └ /'
    else echo "  [original]  $f"; fi
  done
  for f in "$MOD_FILE" "$COLLECTOR" "$UNIT_FILE"; do
    [ -f "$f" ] && echo "  [instalado] $f" || echo "  [ausente]   $f"
  done
  echo ""
  if systemctl list-unit-files "$UNIT_NAME" >/dev/null 2>&1; then
    echo "  Coletor: $(systemctl is-active $UNIT_NAME 2>/dev/null) / $(systemctl is-enabled $UNIT_NAME 2>/dev/null)"
  else
    echo "  Coletor: não instalado"
  fi
  if [ -f "$DATA_DIR/sensors.rrd" ]; then
    echo "  RRD:     $DATA_DIR/sensors.rrd ($(du -h "$DATA_DIR/sensors.rrd" | cut -f1))"
  fi
  [ -x "$COLLECTOR" ] && { echo "  Séries:"; "$COLLECTOR" --list 2>/dev/null | sed 's/^/            /'; }
  echo ""
  echo "  Backups: $BACKUP_ROOT"
  ls -1 "$BACKUP_ROOT" 2>/dev/null | sed 's/^/            /' || echo "            (nenhum)"
  echo ""
  exit 0
fi

# =============================================================================
# PRÉ-CHECAGENS
# =============================================================================
[ "$(id -u)" -eq 0 ] || die "Execute como root no host Proxmox"
command -v pveversion &>/dev/null || die "'pveversion' não encontrado — execute no host Proxmox"
command -v systemctl  &>/dev/null || die "'systemctl' não encontrado"
[ -f "$PM_FILE" ] || die "Não encontrei $PM_FILE"
[ -f "$JS_FILE" ] || die "Não encontrei $JS_FILE"
[ -w "$PM_FILE" ] || die "Sem permissão de escrita em $PM_FILE"
[ -w "$JS_FILE" ] || die "Sem permissão de escrita em $JS_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Proxmox — Temperaturas no Summary do nó"
echo "  Modo:     $MODE$([ $WITH_GRAPH -eq 0 ] && echo ' (sem gráfico)')"
echo "  Nó:       $(node_name)"
echo "  Versão:   $(pveversion | head -1)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# 1. DEPENDÊNCIAS
# =============================================================================
if [ "$MODE" != "revert" ]; then
  step "Validando dependências"

  [ -x "$SENSORS_BIN" ] || die "'$SENSORS_BIN' não existe. Rode antes: apt install -y lm-sensors && sensors-detect --auto"

  if ! "$SENSORS_BIN" -j 2>/dev/null | perl -MJSON::PP -e 'local $/; decode_json(<STDIN>);' 2>/dev/null; then
    die "'sensors -j' não devolveu JSON válido. Confira a saída de: sensors -j"
  fi

  CHIPS="$("$SENSORS_BIN" -j 2>/dev/null | perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); print join(", ", sort keys %$d);')"
  ok "Chips detectados: ${CHIPS:-nenhum}"
  [ -n "$CHIPS" ] || warn "Nenhum chip — a linha vai aparecer como N/A até o sensors-detect achar algo"

  if [ $WITH_GRAPH -eq 1 ] && ! perl -MRRDs -e1 2>/dev/null; then
    if [ "$MODE" = "dry-run" ]; then
      warn "módulo perl RRDs ausente — o script instalaria o pacote 'librrds-perl'"
    else
      log "Instalando librrds-perl (necessário para o gráfico)..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y librrds-perl >/dev/null 2>&1 \
        || die "falhou instalar librrds-perl (repositório indisponível?).
        Nada foi alterado. Rode com --no-graph para instalar só a linha de texto."
      ok "librrds-perl instalado"
    fi
  fi
fi

# =============================================================================
# 2. PAYLOADS — coletor, módulo perl, unit, snippet JS e os patchers
# =============================================================================
cat > "$TMP/pve-sensors-collect" <<'COLLECTEOF'
#!/usr/bin/perl
# pve-sensors-collect — gerado por proxmox-enable-sensors.sh. NÃO EDITE À MÃO.
#
#   --list     imprime "slot<TAB>rótulo" das séries com leitura no momento
#   --once     faz uma coleta e sai
#   --daemon   coleta a cada minuto (alinhado ao minuto cheio)
use strict;
use warnings;
use JSON::PP;
# RRDs so e carregado quando vamos mexer no RRD, para que '--list' funcione
# mesmo num host onde o librrds-perl ainda nao foi instalado (e portanto para
# que o --dry-run consiga mostrar as series que seriam plotadas).

my $DATA_DIR   = '/var/lib/pve-sensors';
my $RRD        = "$DATA_DIR/sensors.rrd";
my $SENSORS    = '/usr/bin/sensors';
my $NVIDIA_SMI = '/usr/bin/nvidia-smi';
my $STEP       = 60;

# Schema fixo. Mudar esta lista exige recriar o RRD (perde histórico).
my @DS = qw(
    cpu cpu_max board
    gpu0 gpu1
    nvme0 nvme1 nvme2 nvme3
    disk0 disk1 disk2 disk3 disk4 disk5 disk6 disk7
);

# Faixa plausivel, em graus C. Chips super-I/O (nct*, it87*) publicam canais
# nao conectados com lixo -- num nct6779 real: CPUTIN=-125, AUXTIN2=107,
# PCH_CHIP_TEMP=0. Leitura fora desta faixa e descartada.
my $T_MIN = 5;
my $T_MAX = 105;

# ---------------------------------------------------------------- leitura
sub read_sensors {
    # timeout: um sensor travado não pode travar o coletor pra sempre
    my $json = `timeout 10 $SENSORS -j 2>/dev/null`;
    return {} if !defined $json || $json !~ /\S/;
    # alguns lm-sensors emitem vírgula sobrando antes de } ou ]
    $json =~ s/,\s*([}\]])/$1/g;
    my $d = eval { decode_json($json) };
    return ref($d) eq 'HASH' ? $d : {};
}

# devolve ( [rótulo, valor], ... ) das features de temperatura de um chip
sub chip_temps {
    my ($feats) = @_;
    my @out;
    foreach my $label (sort keys %$feats) {
        my $f = $feats->{$label};
        next if ref($f) ne 'HASH';
        foreach my $k (sort keys %$f) {
            next if $k !~ /^temp\d+_input$/;
            my $v = $f->{$k};
            next if !defined $v || $v !~ /^-?\d+(\.\d+)?$/;
            $v += 0;
            next if $v < $T_MIN || $v > $T_MAX;
            push @out, [ $label, $v ];
            last;
        }
    }
    return @out;
}

sub classify {
    my ($chip) = @_;
    return 'cpu'   if $chip =~ /^(coretemp|k10temp|k8temp|zenpower)/;
    return 'gpu'   if $chip =~ /^(amdgpu|radeon|nouveau|i915|xe)/;
    return 'nvme'  if $chip =~ /^nvme/;
    return 'disk'  if $chip =~ /^drivetemp/;
    return 'board' if $chip =~ /^(acpitz|nct|it8|w836|jc42|smsc)/;
    return undef;
}

sub nvidia_temps {
    return () if !-x $NVIDIA_SMI;
    my $out = `timeout 10 $NVIDIA_SMI --query-gpu=name,temperature.gpu --format=csv,noheader,nounits 2>/dev/null`;
    return () if !defined $out;
    my @g;
    foreach my $line (split /\n/, $out) {
        next if $line !~ /^\s*(.+?)\s*,\s*(\d+)\s*$/;
        push @g, [ $1, $2 + 0 ];
    }
    return @g;
}

# Monta { slot => valor } e { slot => rótulo } a partir da leitura atual.
sub collect {
    my $data = read_sensors();
    my (%val, %label);

    my (@cpu, @board, @gpu, @nvme, @disk);
    foreach my $chip (sort keys %$data) {
        my $feats = $data->{$chip};
        next if ref($feats) ne 'HASH';
        my $kind = classify($chip);
        next if !defined $kind;
        my @t = chip_temps($feats);
        next if !@t;
        push @cpu,   [ $chip, \@t ] if $kind eq 'cpu';
        push @board, [ $chip, \@t ] if $kind eq 'board';
        push @gpu,   [ $chip, \@t ] if $kind eq 'gpu';
        push @nvme,  [ $chip, \@t ] if $kind eq 'nvme';
        push @disk,  [ $chip, \@t ] if $kind eq 'disk';
    }

    # CPU: 'cpu' = Package/Tctl/Tdie (senão o maior); 'cpu_max' = maior de todos
    if (@cpu) {
        my (@pkg, @all);
        foreach my $c (@cpu) {
            foreach my $t (@{ $c->[1] }) {
                push @all, $t->[1];
                push @pkg, $t->[1] if $t->[0] =~ /^(Package id|Tctl|Tdie)/i;
            }
        }
        my @src = @pkg ? @pkg : @all;
        $val{cpu}       = (sort { $b <=> $a } @src)[0];
        $val{cpu_max}   = (sort { $b <=> $a } @all)[0];
        # rotulos curtos: eles viram a legenda do grafico, que fica numa
        # unica linha e corta o que nao couber
        $label{cpu}     = 'CPU';
        $label{cpu_max} = 'CPU max';
    }

    if (@board) {
        my @cand = map { @{ $_->[1] } } @board;
        # num nct6779/it87 o sensor da placa e o SYSTIN; os AUXTIN* costumam
        # ser canais sem nada ligado. Prefere o nomeado quando existir.
        my @pref = grep { $_->[0] =~ /^(SYSTIN|System|MB|Motherboard|board)/i } @cand;
        @cand = @pref if @pref;
        $val{board}   = (sort { $b <=> $a } map { $_->[1] } @cand)[0];
        $label{board} = 'Placa-mãe';
    }

    # GPU: Nvidia primeiro (não aparece no lm-sensors), depois amdgpu/etc
    my $gi = 0;
    foreach my $n (nvidia_temps()) {
        last if $gi > 1;
        $val{"gpu$gi"}   = $n->[1];
        $label{"gpu$gi"} = "GPU $gi";
        $gi++;
    }
    foreach my $c (@gpu) {
        last if $gi > 1;
        my @all = map { $_->[1] } @{ $c->[1] };
        $val{"gpu$gi"}   = (sort { $b <=> $a } @all)[0];
        $label{"gpu$gi"} = "GPU $gi";
        $gi++;
    }

    # NVMe: prefere a feature 'Composite'
    my $ni = 0;
    foreach my $c (@nvme) {
        last if $ni > 3;
        my @comp = grep { $_->[0] =~ /^Composite/i } @{ $c->[1] };
        my @src  = @comp ? @comp : @{ $c->[1] };
        $val{"nvme$ni"}   = (sort { $b <=> $a } map { $_->[1] } @src)[0];
        $label{"nvme$ni"} = "NVMe $ni";
        $ni++;
    }

    my $di = 0;
    foreach my $c (@disk) {
        last if $di > 7;
        my $short = $c->[0];
        $short =~ s/^drivetemp-//;
        $val{"disk$di"}   = (sort { $b <=> $a } map { $_->[1] } @{ $c->[1] })[0];
        $label{"disk$di"} = $short;
        $di++;
    }

    return (\%val, \%label);
}

# ---------------------------------------------------------------- RRD
sub ensure_rrd {
    require RRDs;
    return if -f $RRD;
    mkdir $DATA_DIR if !-d $DATA_DIR;
    my @args = ($RRD, '--step', $STEP);
    # GAUGE, heartbeat 2x o step, faixa 0..200 °C descarta leitura absurda
    push @args, map { "DS:$_:GAUGE:" . ($STEP * 2) . ":0:200" } @DS;
    # Mesmas resoluções que o RRD do PVE, para o merge bater timestamp a timestamp
    foreach my $cf (qw(AVERAGE MAX)) {
        push @args,
            "RRA:$cf:0.5:1:1500",       # ~25 h  @ 1 min
            "RRA:$cf:0.5:30:1500",      # ~31 d  @ 30 min
            "RRA:$cf:0.5:180:1500",     # ~187 d @ 3 h
            "RRA:$cf:0.5:720:1500",     # ~2 a   @ 12 h
            "RRA:$cf:0.5:10080:400";    # ~7 a   @ 1 sem
    }
    RRDs::create(@args);
    my $err = RRDs::error();
    die "erro criando $RRD: $err\n" if $err;
}

sub update_rrd {
    my ($val) = @_;
    require RRDs;
    ensure_rrd();
    my @present = grep { defined $val->{$_} } @DS;
    return if !@present;
    RRDs::update($RRD, '--template', join(':', @present),
        'N:' . join(':', map { $val->{$_} } @present));
    my $err = RRDs::error();
    warn "erro atualizando $RRD: $err\n" if $err;
}

# ---------------------------------------------------------------- main
my $mode = $ARGV[0] // '--once';

if ($mode eq '--list') {
    my ($val, $label) = collect();
    foreach my $ds (@DS) {
        next if !defined $val->{$ds};
        print "$ds\t" . ($label->{$ds} // $ds) . "\n";
    }
    exit 0;
}

if ($mode eq '--once') {
    my ($val) = collect();
    update_rrd($val);
    exit 0;
}

if ($mode eq '--daemon') {
    $SIG{TERM} = $SIG{INT} = sub { exit 0 };
    while (1) {
        my ($val) = collect();
        eval { update_rrd($val); 1 } or warn $@;
        # dorme até o próximo minuto cheio (evita buraco no RRD por drift)
        my $now = time();
        sleep($STEP - ($now % $STEP));
    }
}

die "uso: $0 [--list|--once|--daemon]\n";
COLLECTEOF

cat > "$TMP/SensorsRRD.pm" <<'MODEOF'
package PVE::SensorsRRD;
# gerado por proxmox-enable-sensors.sh. NÃO EDITE À MÃO.
#
# Lê o RRD mantido pelo pve-sensors-collect e injeta as séries de temperatura
# (prefixadas com t_) nas linhas devolvidas por GET /nodes/{node}/rrddata,
# alinhando pelo timestamp.
#
# CONTRATO: nunca lança exceção e nunca remove/altera dado existente. No pior
# caso devolve $res intacto — a API do PVE segue funcionando normalmente
# mesmo que o RRD esteja ausente, corrompido ou sendo escrito neste instante.
use strict;
use warnings;
use RRDs;

my $RRD = '/var/lib/pve-sensors/sensors.rrd';

# mesmas resoluções/contagens que o PVE usa em PVE::RRD
my $SETUP = {
    hour  => [ 60,          70 ],
    day   => [ 60 * 30,     70 ],
    week  => [ 60 * 180,    70 ],
    month => [ 60 * 720,    70 ],
    year  => [ 60 * 10080,  70 ],
};

sub merge {
    my ($res, $timeframe, $cf) = @_;

    return $res if ref($res) ne 'ARRAY' || !@$res;
    return $res if !-f $RRD || !-r $RRD;

    my $setup = $SETUP->{ $timeframe // 'hour' };
    return $res if !$setup;
    my ($reso, $count) = @$setup;

    $cf = 'AVERAGE' if !defined($cf) || $cf !~ /^(AVERAGE|MAX)$/;

    my $end = $res->[-1]->{time};
    $end = time() if !defined $end || $end !~ /^\d+$/;
    my $start = $end - $reso * ($count + 1);

    my ($rstart, $step, $names, $data) = eval {
        RRDs::fetch($RRD, $cf, '-s', $start, '-e', $end, '-r', $reso);
    };
    return $res if $@ || RRDs::error() || !$names || !$data || !$step;

    my %by_time;
    my $t = $rstart + $step;
    foreach my $row (@$data) {
        my %v;
        for my $i (0 .. $#$names) {
            my $val = $row->[$i];
            next if !defined $val;
            $v{ 't_' . $names->[$i] } = $val + 0;
        }
        $by_time{$t} = \%v if %v;
        $t += $step;
    }
    return $res if !%by_time;

    foreach my $row (@$res) {
        next if ref($row) ne 'HASH';
        my $rt = $row->{time};
        next if !defined $rt || $rt !~ /^\d+$/;
        my $v = $by_time{$rt}
             // $by_time{ $rt - ($rt % $step) }
             // $by_time{ $rt - ($rt % $step) + $step };
        next if !$v;
        # só acrescenta; nunca sobrescreve chave que o PVE já tenha posto
        foreach my $k (keys %$v) {
            $row->{$k} = $v->{$k} if !exists $row->{$k};
        }
    }

    return $res;
}

1;
MODEOF

cat > "$TMP/$UNIT_NAME" <<'UNITEOF'
[Unit]
Description=Coleta de temperaturas para os graficos do Proxmox
Documentation=file:///usr/local/bin/pve-sensors-collect
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pve-sensors-collect --daemon
Restart=always
RestartSec=10
Nice=10
IOSchedulingClass=idle
# Nao pode derrubar o host de jeito nenhum
MemoryMax=64M
TasksMax=16
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true
ReadWritePaths=/var/lib/pve-sensors

[Install]
WantedBy=multi-user.target
UNITEOF

cat > "$TMP/sensors-item.js" <<'JSEOF'
	// PVE-SENSORS-MOD-BEGIN
	{
	    itemId: 'thermal',
	    colspan: 2,
	    printBar: false,
	    title: gettext('Temperatures'),
	    textField: 'thermalstate',
	    value: '',
	    renderer: function(value) {
		if (!value) { return 'N/A'; }
		let obj;
		try {
		    // alguns lm-sensors emitem virgula sobrando; toleramos
		    obj = JSON.parse(String(value).replace(/,\s*([}\]])/g, '$1'));
		} catch (e) {
		    return 'N/A';
		}
		let fmt = function(t) { return (Math.round(t * 10) / 10).toFixed(1) + '&deg;C'; };
		let groups = { CPU: [], GPU: [], NVMe: [], Disks: [], Board: [] };
		Object.keys(obj || {}).forEach(function(chip) {
		    let feats = obj[chip];
		    if (!feats || typeof feats !== 'object') { return; }
		    let group;
		    if (/^(coretemp|k10temp|k8temp|zenpower)/.test(chip)) { group = 'CPU'; }
		    else if (/^(amdgpu|radeon|nouveau|i915|xe)/.test(chip)) { group = 'GPU'; }
		    else if (/^nvme/.test(chip)) { group = 'NVMe'; }
		    else if (/^drivetemp/.test(chip)) { group = 'Disks'; }
		    else if (/^(acpitz|nct|it8|w836|jc42|smsc)/.test(chip)) { group = 'Board'; }
		    else { return; }

		    let entries = [];
		    Object.keys(feats).forEach(function(label) {
			let f = feats[label];
			if (!f || typeof f !== 'object') { return; }
			let k = Object.keys(f).find(function(x) { return (/^temp\d+_input$/).test(x); });
			if (k === undefined || typeof f[k] !== 'number') { return; }
			// canal nao conectado: nct6779 publica CPUTIN=-125, AUXTIN2=107, PCH=0
			if (f[k] < 5 || f[k] > 105) { return; }
			entries.push({ label: label, temp: f[k] });
		    });

		    // CPU: se houver Package/Tctl/Tdie mostra so eles, senao vira uma lista enorme de cores
		    if (group === 'CPU') {
			let pref = entries.filter(function(e) { return (/^(Package id|Tctl|Tdie|Tccd)/i).test(e.label); });
			if (pref.length) { entries = pref; }
		    }
		    if (group === 'NVMe') {
			let pref = entries.filter(function(e) { return (/^Composite/i).test(e.label); });
			if (pref.length) { entries = pref; }
		    }
		    if (group === 'Board') {
			let pref = entries.filter(function(e) { return (/^(SYSTIN|System|MB|Motherboard)/i).test(e.label); });
			if (pref.length) { entries = pref; }
		    }

		    let useChipName = (group === 'NVMe' || group === 'Disks');
		    entries.forEach(function(e) {
			// 'drivetemp-scsi-0-0' -> 'scsi-0-0': o painel e estreito e
			// com 6 discos a linha quebra e corta o resto do Summary
			let label = useChipName ? chip.replace(/^drivetemp-/, '') : e.label;
			groups[group].push(Ext.String.htmlEncode(label) + ': <b>' + fmt(e.temp) + '</b>');
		    });
		});
		let out = [];
		Object.keys(groups).forEach(function(g) {
		    if (groups[g].length) {
			out.push('<b>' + g + '</b> &mdash; ' + groups[g].join(' &nbsp;|&nbsp; '));
		    }
		});
		return out.length ? out.join('<br>') : 'N/A';
	    },
	},
	// PVE-SENSORS-MOD-END
JSEOF

# ---------------------------------------------------------------------------
# Patchers. Contrato dos dois:
#   - strip() remove TODOS os nossos blocos e desfaz a alteração de 'height'
#   - patch = strip() + reinserir (por isso rodar de novo atualiza as séries)
#   - antes de gravar, verifica que strip(novo) == strip(original). Se não
#     bater exatamente, aborta sem gravar — é a prova de que o patch é uma
#     inserção pura e 100% reversível.
#   - grava em .tmp e faz rename() atômico, preservando dono e permissão
# ---------------------------------------------------------------------------
cat > "$TMP/patch-pm.pl" <<'PERLEOF'
use strict; use warnings;
my ($file, $mode, $with_graph) = @ARGV;
$with_graph = 0 if !defined $with_graph;

open(my $fh, '<', $file) or die "não consegui ler $file: $!\n";
my $c = do { local $/; <$fh> }; close $fh;

sub strip {
    my ($t) = @_;
    $t =~ s/[ \t]*# PVE-SENSORS-MOD-BEGIN\n.*?# PVE-SENSORS-MOD-END\n//sg;
    $t =~ s/[ \t]*# PVE-SENSORS-RRD-BEGIN\n.*?# PVE-SENSORS-RRD-END\n//sg;
    return $t;
}

sub save {
    my ($f, $t) = @_;
    my @st = stat($f) or die "não consegui statar $f: $!\n";
    my $tmp = "$f.pve-sensors.tmp.$$";
    open(my $out, '>', $tmp) or die "não consegui escrever $tmp: $!\n";
    print $out $t or die "erro escrevendo $tmp: $!\n";
    close($out)   or die "erro fechando $tmp: $!\n";
    chmod($st[2] & 07777, $tmp);
    chown($st[4], $st[5], $tmp);
    rename($tmp, $f) or do { unlink $tmp; die "não consegui substituir $f: $!\n" };
}

my $base = strip($c);

if ($mode eq 'revert') {
    if ($base eq $c) { print "SKIP  não está patcheado\n"; exit 0; }
    save($file, $base);
    print "DONE  patches removidos\n";
    exit 0;
}

my $new = $base;

# ---- patch A: thermalstate no GET /nodes/{node}/status -----------------
$new =~ /description\s*=>\s*"Read node status\.?"/
    or die "âncora não encontrada em $file (description => \"Read node status\").\n"
         . "Sua versão do PVE mudou o arquivo — não vou mexer às cegas.\n";
pos($new) = $+[0];
$new =~ /\G.*?\n(?=([ \t]*)return \$res;)/sg
    or die "não encontrei o 'return \$res;' do método status em $file\n";
{
    my $at  = $+[0];
    my $ind = $1;
    # 'timeout 5': um sensor travado nunca pode segurar o worker do pveproxy
    substr($new, $at, 0) =
          "${ind}# PVE-SENSORS-MOD-BEGIN\n"
        . "${ind}\$res->{thermalstate} = `timeout 5 /usr/bin/sensors -j 2>/dev/null`;\n"
        . "${ind}# PVE-SENSORS-MOD-END\n";
    print "OK    thermalstate -> GET /nodes/{node}/status\n";
}

# ---- patch B: séries de temperatura no GET /nodes/{node}/rrddata -------
if ($with_graph) {
    # O nome do RRD do nó muda entre versões do PVE ("pve2-node/" no 7/8,
    # "pve-node-9.0/" no 9). Capturamos o que estiver no arquivo e reusamos
    # verbatim, em vez de chutar um nome fixo.
    $new =~ /^([ \t]*)return\s+PVE::RRD::create_rrd_data\(\s*"([^"\n]*\$param->\{node\}[^"\n]*)"/m
        or die "não encontrei a chamada create_rrd_data(...\$param->{node}...) em $file\n"
             . "Sua versão do PVE mudou o método rrddata — não vou mexer às cegas.\n";
    my $ind     = $1;
    my $rrdname = $2;
    print "OK    RRD do nó detectado: $rrdname\n";
    # Inserção PURA, antes do return original — que fica inalcançável de
    # propósito. Assim o revert é uma remoção limpa e o arquivo volta byte a
    # byte ao que era. Se o require/merge falhar, o eval engole e a API segue.
    substr($new, $-[0], 0) =
          "${ind}# PVE-SENSORS-RRD-BEGIN\n"
        . "${ind}{\n"
        . "${ind}    my \$sensors_res = PVE::RRD::create_rrd_data(\n"
        . "${ind}        \"$rrdname\", \$param->{timeframe}, \$param->{cf});\n"
        . "${ind}    eval {\n"
        . "${ind}        require PVE::SensorsRRD;\n"
        . "${ind}        PVE::SensorsRRD::merge(\$sensors_res, \$param->{timeframe}, \$param->{cf});\n"
        . "${ind}    };\n"
        . "${ind}    return \$sensors_res;\n"
        . "${ind}}\n"
        . "${ind}# PVE-SENSORS-RRD-END\n";
    print "OK    merge das temperaturas -> GET /nodes/{node}/rrddata\n";
}

# ---- prova de reversibilidade ------------------------------------------
strip($new) eq $base
    or die "VERIFICAÇÃO FALHOU: o patch de $file não é reversível. Nada foi gravado.\n";

save($file, $new);
print "DONE  $file patcheado (reversibilidade verificada)\n";
PERLEOF

cat > "$TMP/patch-js.pl" <<'PERLEOF'
use strict; use warnings;
my ($file, $mode, $snippet_file, $fields_json, $titles_json, $panel_bump, $panel_abs) = @ARGV;
$panel_bump = 80 if !$panel_bump || $panel_bump !~ /^\d+$/;
$panel_abs  = 0  if !$panel_abs  || $panel_abs  !~ /^\d+$/;

open(my $fh, '<', $file) or die "não consegui ler $file: $!\n";
my $c = do { local $/; <$fh> }; close $fh;

sub strip {
    my ($t) = @_;
    $t =~ s{[ \t]*// PVE-SENSORS-MOD-BEGIN\n.*?// PVE-SENSORS-MOD-END\n}{}sg;
    $t =~ s{[ \t]*// PVE-SENSORS-FIELDS-BEGIN\n.*?// PVE-SENSORS-FIELDS-END\n}{}sg;
    $t =~ s{[ \t]*// PVE-SENSORS-CHART-BEGIN\n.*?// PVE-SENSORS-CHART-END\n}{}sg;
    $t =~ s{(minHeight:[ \t]*)\d+,[ \t]*// PVE-SENSORS-MOD minHeight was (\d+)}{$1$2,}g;
    $t =~ s{(height:[ \t]*)\d+,[ \t]*// PVE-SENSORS-MOD height was (\d+)}{$1$2,}g;
    return $t;
}

sub save {
    my ($f, $t) = @_;
    my @st = stat($f) or die "não consegui statar $f: $!\n";
    my $tmp = "$f.pve-sensors.tmp.$$";
    open(my $out, '>', $tmp) or die "não consegui escrever $tmp: $!\n";
    print $out $t or die "erro escrevendo $tmp: $!\n";
    close($out)   or die "erro fechando $tmp: $!\n";
    chmod($st[2] & 07777, $tmp);
    chown($st[4], $st[5], $tmp);
    rename($tmp, $f) or do { unlink $tmp; die "não consegui substituir $f: $!\n" };
}

my $base = strip($c);

if ($mode eq 'revert') {
    if ($base eq $c) { print "SKIP  não está patcheado\n"; exit 0; }
    save($file, $base);
    print "DONE  patches removidos\n";
    exit 0;
}

my $new = $base;

# ---- patch A: linha de texto no StatusView -----------------------------
open(my $sf, '<', $snippet_file) or die "não consegui ler $snippet_file: $!\n";
my $snippet = do { local $/; <$sf> }; close $sf;

my $sv = index($new, "Ext.define('PVE.node.StatusView'");
die "não encontrei 'PVE.node.StatusView' em $file — versão do PVE incompatível\n" if $sv < 0;

my $status_height = 0;

# cabe a linha nova sem cortar o painel (reversível pelo comentário)
if (substr($new, $sv, 2000) =~ /(\n[ \t]*height:[ \t]*)(\d+)(,)/) {
    my ($pre, $h) = ($1, $2);
    my $start = $sv + $-[0];
    my $len   = $+[0] - $-[0];
    $status_height = $panel_abs ? $panel_abs : $h + $panel_bump;
    substr($new, $start, $len) = $pre . $status_height . ", // PVE-SENSORS-MOD height was $h";
    print "OK    altura do StatusView: $h -> $status_height\n";
} else {
    print "WARN  não achei 'height:' no StatusView — o painel pode cortar a linha nova\n";
}

pos($new) = $sv;
$new =~ /\G.*?\{\s*itemId:\s*'cpus',.*?^[ \t]*\},\n/smg
    or die "não encontrei o item itemId: 'cpus' dentro do StatusView em $file\n"
         . "Sua versão do PVE mudou o arquivo — não vou mexer às cegas.\n";
substr($new, $+[0], 0) = $snippet;
print "OK    linha 'Temperatures' -> Summary\n";

# ---- patch B+C: campos no model + painel de gráfico --------------------
if (defined $fields_json && length $fields_json) {

    # B: campos t_* no model pve-rrd-node (senão a store descarta os valores)
    my $m = index($new, "Ext.define('pve-rrd-node'");
    if ($m < 0) {
        print "WARN  não achei o model 'pve-rrd-node' — gráfico NÃO instalado\n";
    } else {
        pos($new) = $m;
        if ($new =~ /\G.*?fields:\s*\[\n/sg) {
            substr($new, $+[0], 0) =
                  "\t// PVE-SENSORS-FIELDS-BEGIN\n"
                . "\t$fields_json,\n"
                . "\t// PVE-SENSORS-FIELDS-END\n";
            print "OK    campos de temperatura -> model pve-rrd-node\n";

            # C: painel proxmoxRRDChart na tela Summary do nó
            my $su = index($new, "Ext.define('PVE.node.Summary'");
            if ($su < 0) {
                print "WARN  não achei 'PVE.node.Summary' — painel NÃO instalado\n";
            } else {
                pos($new) = $su;
                if ($new =~ /\G.*?\{\s*xtype:\s*'proxmoxRRDChart',.*?^([ \t]*)\},\n/smg) {
                    my $ind = $1;
                    substr($new, $+[0], 0) =
                          "$ind// PVE-SENSORS-CHART-BEGIN\n"
                        . "${ind}{\n"
                        . "$ind    xtype: 'proxmoxRRDChart',\n"
                        . "$ind    title: gettext('Temperatures') + ' (\\u00b0C)',\n"
                        . "$ind    fields: [$fields_json],\n"
                        . "$ind    fieldTitles: [$titles_json],\n"
                        # Sem seriesConfig e sem axes proprios: assim o painel usa
                        # exatamente o estilo padrao do proxmoxRRDChart (areas
                        # preenchidas, opacity 0.6, eixo comecando em zero), igual
                        # aos graficos de CPU Usage / Server Load / Memory usage.
                        . "$ind    store: rrdstore,\n"
                        . "$ind},\n"
                        . "$ind// PVE-SENSORS-CHART-END\n";
                    print "OK    painel 'Temperatures' -> Summary\n";
                } else {
                    print "WARN  não achei proxmoxRRDChart no Summary — painel NÃO instalado\n";
                }

                # O 'itemcontainer' do Summary usa layout 'column' (floats CSS) e
                # TODAS as celulas -- inclusive o proprio StatusView -- herdam o
                # mesmo minHeight. De fabrica o painel (350) cabia na celula (360).
                # Ao cresce-lo para caber as temperaturas ele passa a estourar a
                # celula, as linhas desalinham e sobra um buraco na coluna da
                # esquerda. Igualar o minHeight a altura do painel realinha tudo.
                if ($status_height) {
                    my $su3 = index($new, "Ext.define('PVE.node.Summary'");
                    if ($su3 >= 0 && substr($new, $su3, 8000) =~ /(\n[ \t]*minHeight:[ \t]*)(\d+)(,)/) {
                        my ($pre, $mh) = ($1, $2);
                        if ($status_height > $mh) {
                            my $start = $su3 + $-[0];
                            my $len   = $+[0] - $-[0];
                            substr($new, $start, $len) =
                                $pre . $status_height . ", // PVE-SENSORS-MOD minHeight was $mh";
                            print "OK    minHeight das celulas: $mh -> $status_height (realinha as colunas)\n";
                        }
                    } else {
                        print "WARN  não achei 'minHeight:' no Summary — as colunas podem desalinhar\n";
                    }
                }
            }
        } else {
            print "WARN  não achei 'fields: [' no model — gráfico NÃO instalado\n";
        }
    }
}

# ---- prova de reversibilidade ------------------------------------------
strip($new) eq $base
    or die "VERIFICAÇÃO FALHOU: o patch de $file não é reversível. Nada foi gravado.\n";

save($file, $new);
print "DONE  $file patcheado (reversibilidade verificada)\n";
PERLEOF

# =============================================================================
# 3. DETECTA AS SÉRIES QUE ESTE HARDWARE REALMENTE TEM
# =============================================================================
FIELDS_JS=""
TITLES_JS=""
PANEL_BUMP=80
SLOTS=""
if [ "$MODE" != "revert" ]; then
  step "Detectando séries de temperatura"
  SLOTS="$(perl "$TMP/pve-sensors-collect" --list 2>/dev/null || true)"
  if [ -z "$SLOTS" ]; then
    warn "Nenhuma série detectada — o gráfico será pulado (a linha de texto continua)"
    WITH_GRAPH=0
  else
    echo "$SLOTS" | while IFS=$'\t' read -r slot label; do echo "        $slot  →  $label"; done

    # Estimativa de quantas LINHAS o bloco 'Temperatures' vai ocupar no painel.
    # O StatusView tem altura fixa: se não crescer o suficiente, ele corta as
    # linhas de baixo (Kernel Version, Repository Status...). Cada grupo do
    # texto ocupa 1 linha; com os rótulos curtos cabem ~6 discos/NVMe por linha.
    # Os 24px de base são a folga para o caso de a janela estar mais estreita
    # e uma das listas quebrar em duas linhas.
    L=0
    echo "$SLOTS" | grep -q '^cpu'   && L=$((L+1)) || true
    echo "$SLOTS" | grep -q '^gpu'   && L=$((L+1)) || true
    echo "$SLOTS" | grep -q '^board' && L=$((L+1)) || true
    NV="$(echo "$SLOTS" | grep -c '^nvme' || true)"
    DK="$(echo "$SLOTS" | grep -c '^disk' || true)"
    [ "$NV" -gt 0 ] && L=$((L + (NV + 5) / 6)) || true
    [ "$DK" -gt 0 ] && L=$((L + (DK + 5) / 6)) || true
    PANEL_BUMP=$((24 + 22 * L))
    log "bloco de temperaturas: ~$L linha(s) → painel +${PANEL_BUMP}px"

    if [ $WITH_GRAPH -eq 1 ]; then
      FIELDS_JS="$(echo "$SLOTS" | awk -F'\t' '{printf "%s'\''t_%s'\''", (NR>1 ? ", " : ""), $1}')"
      TITLES_JS="$(echo "$SLOTS" | awk -F'\t' '{gsub(/'\''/,"",$2); printf "%s'\''%s'\''", (NR>1 ? ", " : ""), $2}')"
      ok "$(echo "$SLOTS" | wc -l) série(s) serão plotadas"
    fi
  fi
fi
[ -n "$PANEL_HEIGHT" ] && log "altura do painel forçada para ${PANEL_HEIGHT}px (--panel-height)" || true

# =============================================================================
# 4. PATCH E VALIDAÇÃO — tudo em cópias; /usr ainda intocado
# =============================================================================
apply_to_copies() {
  cp -a "$PM_FILE" "$TMP/Nodes.pm.new"
  cp -a "$JS_FILE" "$TMP/pvemanagerlib.js.new"
  perl "$TMP/patch-pm.pl" "$TMP/Nodes.pm.new" "$1" "$WITH_GRAPH" \
    || die "falhou o patch de $PM_FILE. NADA foi alterado."
  perl "$TMP/patch-js.pl" "$TMP/pvemanagerlib.js.new" "$1" "$TMP/sensors-item.js" "$FIELDS_JS" "$TITLES_JS" "$PANEL_BUMP" "$PANEL_HEIGHT" \
    || die "falhou o patch de $JS_FILE. NADA foi alterado."
}

verify_copies() {
  step "Validando o resultado (nada foi instalado ainda)"

  # 4.1 — perl -c: perl inválido aqui significa pvedaemon morto depois. Bloqueante.
  if perl -c "$PM_FILE" >/dev/null 2>&1; then
    perl -c "$TMP/Nodes.pm.new" >/dev/null 2>&1 \
      || die "o Nodes.pm patcheado NÃO compila. NADA foi alterado.
        Rode: perl -c $TMP/Nodes.pm.new  (para ver o erro)"
    ok "perl -c no Nodes.pm patcheado: passou"
  else
    warn "o Nodes.pm ORIGINAL já não compila neste ambiente — pulando o perl -c"
  fi

  # 4.2 — prova de reversibilidade ponta a ponta.
  #
  # BASE = o arquivo original do PVE, isto é, o que está instalado em /usr com
  # os NOSSOS blocos removidos. Numa reinstalação o arquivo em /usr já está
  # patcheado da rodada anterior; comparar contra ele diretamente daria falso
  # negativo (e o check de tamanho quebraria se os rótulos encolhessem).
  # O invariante correto é: reverter(novo) == reverter(instalado).
  cp -a "$PM_FILE" "$TMP/Nodes.pm.base"
  cp -a "$JS_FILE" "$TMP/pvemanagerlib.js.base"
  perl "$TMP/patch-pm.pl" "$TMP/Nodes.pm.base"         revert >/dev/null \
    || die "não consegui reconstruir o original de $PM_FILE. NADA foi alterado."
  perl "$TMP/patch-js.pl" "$TMP/pvemanagerlib.js.base" revert >/dev/null \
    || die "não consegui reconstruir o original de $JS_FILE. NADA foi alterado."

  cp -a "$TMP/Nodes.pm.new"         "$TMP/Nodes.pm.rt"
  cp -a "$TMP/pvemanagerlib.js.new" "$TMP/pvemanagerlib.js.rt"
  perl "$TMP/patch-pm.pl" "$TMP/Nodes.pm.rt"         revert >/dev/null || die "revert de teste falhou"
  perl "$TMP/patch-js.pl" "$TMP/pvemanagerlib.js.rt" revert >/dev/null || die "revert de teste falhou"

  cmp -s "$TMP/Nodes.pm.rt" "$TMP/Nodes.pm.base" \
    || die "PROVA DE REVERSIBILIDADE FALHOU em $PM_FILE. NADA foi alterado."
  cmp -s "$TMP/pvemanagerlib.js.rt" "$TMP/pvemanagerlib.js.base" \
    || die "PROVA DE REVERSIBILIDADE FALHOU em $JS_FILE. NADA foi alterado."
  ok "reversibilidade provada: --revert devolve os 2 arquivos ao original do PVE, byte a byte"

  # 4.3 — sanidade: o patch só pode ter AUMENTADO o arquivo original
  for pair in "$TMP/Nodes.pm.base:$TMP/Nodes.pm.new" "$TMP/pvemanagerlib.js.base:$TMP/pvemanagerlib.js.new"; do
    local o="${pair%%:*}" n="${pair##*:}"
    [ "$(stat -c%s "$n")" -ge "$(stat -c%s "$o")" ] \
      || die "o arquivo patcheado ficou MENOR que o original do PVE. NADA foi alterado."
  done
  ok "nenhum conteúdo original foi removido"
}

if [ "$MODE" = "dry-run" ]; then
  step "Dry-run — nada será alterado"
  apply_to_copies patch
  verify_copies
  echo ""
  echo "--- diff: $PM_FILE ---"; diff -u "$PM_FILE" "$TMP/Nodes.pm.new" || true
  echo ""
  echo "--- diff: $JS_FILE ---"; diff -u "$JS_FILE" "$TMP/pvemanagerlib.js.new" || true
  echo ""
  echo "--- arquivos que seriam criados (nenhum sobrescreve nada do PVE) ---"
  echo "  $COLLECTOR"
  echo "  $MOD_FILE"
  echo "  $UNIT_FILE"
  echo "  $DATA_DIR/sensors.rrd"
  echo ""
  ok "Dry-run concluído — rode sem --dry-run para aplicar"
  exit 0
fi

# =============================================================================
# 5. BACKUP — a partir daqui, qualquer erro dispara rollback automático
# =============================================================================
step "Backup dos originais"
BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a "$PM_FILE" "$BACKUP_DIR/Nodes.pm"
cp -a "$JS_FILE" "$BACKUP_DIR/pvemanagerlib.js"
cat > "$BACKUP_DIR/RESTAURAR.sh" <<RESTOREEOF
#!/bin/sh
# Restauração manual de emergência. Rode como root se tudo mais falhar.
set -e
cp -a "$BACKUP_DIR/Nodes.pm"         "$PM_FILE"
cp -a "$BACKUP_DIR/pvemanagerlib.js" "$JS_FILE"
systemctl disable --now $UNIT_NAME 2>/dev/null || true
rm -f "$UNIT_FILE" "$COLLECTOR" "$MOD_FILE"
systemctl daemon-reload
systemctl restart pvedaemon pveproxy
echo "Proxmox restaurado."
RESTOREEOF
chmod +x "$BACKUP_DIR/RESTAURAR.sh"
ok "Backup: $BACKUP_DIR"
ok "Restauração manual de emergência: $BACKUP_DIR/RESTAURAR.sh"
ARMED=1

# =============================================================================
# 6. APLICA
# =============================================================================
if [ "$MODE" = "revert" ]; then
  step "Removendo coletor"
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$COLLECTOR" "$MOD_FILE"
  systemctl daemon-reload
  ok "Serviço e arquivos removidos"

  if [ $PURGE -eq 1 ]; then
    # guarda: só apaga se for mesmo o nosso diretório, com o nosso RRD dentro
    case "$DATA_DIR" in
      /var/lib/pve-sensors) [ -f "$DATA_DIR/sensors.rrd" ] && rm -rf "$DATA_DIR" && ok "Histórico apagado" ;;
      *) warn "DATA_DIR='$DATA_DIR' não é o padrão — recusando apagar por segurança" ;;
    esac
  else
    log "Histórico preservado em $DATA_DIR (use --purge para apagar)"
  fi

  step "Revertendo patches"
  perl "$TMP/patch-pm.pl" "$PM_FILE" revert || die "falhou ao reverter $PM_FILE"
  perl "$TMP/patch-js.pl" "$JS_FILE" revert || die "falhou ao reverter $JS_FILE"
else
  apply_to_copies patch
  verify_copies

  if [ $WITH_GRAPH -eq 1 ]; then
    step "Instalando o coletor"
    mkdir -p "$DATA_DIR"
    install -m 0755 "$TMP/pve-sensors-collect" "$COLLECTOR"
    install -m 0644 "$TMP/SensorsRRD.pm"       "$MOD_FILE"
    install -m 0644 "$TMP/$UNIT_NAME"          "$UNIT_FILE"
    INSTALLED_COLLECTOR=1
    "$COLLECTOR" --once || die "o coletor falhou na primeira execução"
    systemctl daemon-reload
    systemctl enable --now "$UNIT_NAME"
    systemctl is-active --quiet "$UNIT_NAME" || die "o serviço $UNIT_NAME não subiu"
    ok "pve-sensors-collect ativo — RRD em $DATA_DIR/sensors.rrd"
  else
    # --no-graph numa instalação que já tinha gráfico: remove o coletor também
    if [ -f "$UNIT_FILE" ]; then
      systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
      rm -f "$UNIT_FILE" "$COLLECTOR" "$MOD_FILE"
      systemctl daemon-reload
      log "Coletor removido (--no-graph). Histórico mantido em $DATA_DIR"
    fi
  fi

  step "Instalando os arquivos patcheados (atômico)"
  install -m "$(stat -c%a "$PM_FILE")" -o "$(stat -c%u "$PM_FILE")" -g "$(stat -c%g "$PM_FILE")" \
    "$TMP/Nodes.pm.new" "$PM_FILE.pve-sensors.staging"
  mv -f "$PM_FILE.pve-sensors.staging" "$PM_FILE"
  install -m "$(stat -c%a "$JS_FILE")" -o "$(stat -c%u "$JS_FILE")" -g "$(stat -c%g "$JS_FILE")" \
    "$TMP/pvemanagerlib.js.new" "$JS_FILE.pve-sensors.staging"
  mv -f "$JS_FILE.pve-sensors.staging" "$JS_FILE"
  ok "$PM_FILE e $JS_FILE atualizados"
fi

# =============================================================================
# 7. RESTART COM VERIFICAÇÃO DE SAÚDE
# =============================================================================
step "Reiniciando pvedaemon e pveproxy"
systemctl restart pvedaemon pveproxy || die "o restart falhou"
sleep 3
for svc in pvedaemon pveproxy; do
  systemctl is-active --quiet "$svc" \
    || die "$svc NÃO subiu depois do patch.
        Últimas linhas do log:
$(journalctl -u "$svc" -n 15 --no-pager 2>/dev/null | sed 's/^/        /')"
done
ok "pvedaemon e pveproxy ativos"

# =============================================================================
# 8. VALIDAÇÃO FUNCIONAL DA API
# =============================================================================
if [ "$MODE" = "patch" ]; then
  step "Validando a API"
  NODE="$(node_name)"

  pvesh get "/nodes/$NODE/status" --output-format json >/dev/null 2>&1 \
    || die "GET /nodes/$NODE/status quebrou depois do patch"
  if pvesh get "/nodes/$NODE/status" --output-format json 2>/dev/null | grep -q '"thermalstate"'; then
    ok "/status devolve 'thermalstate'"
  else
    warn "/status não devolveu 'thermalstate' (a API responde, mas o campo não veio)"
  fi

  pvesh get "/nodes/$NODE/rrddata" --timeframe hour --output-format json >/dev/null 2>&1 \
    || die "GET /nodes/$NODE/rrddata quebrou depois do patch"
  ok "/rrddata responde normalmente"

  if [ $WITH_GRAPH -eq 1 ]; then
    if pvesh get "/nodes/$NODE/rrddata" --timeframe hour --output-format json 2>/dev/null | grep -q '"t_'; then
      ok "/rrddata já devolve séries de temperatura"
    else
      log "/rrddata ainda sem séries t_* — esperado no 1º minuto (o RRD precisa de amostras)"
    fi
  fi
fi

ARMED=0   # deu tudo certo; desarma o rollback automático

# =============================================================================
# 9. RELATÓRIO
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ "$MODE" = "revert" ] && echo "  Patches removidos" || echo "  Temperaturas habilitadas"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ "$MODE" = "patch" ]; then
  echo "  IMPORTANTE: dê um refresh FORTE no navegador (Ctrl+Shift+R),"
  echo "  senão ele continua servindo o pvemanagerlib.js do cache."
  echo ""
  echo "  Datacenter > $(node_name) > Summary"
  echo "    - linha 'Temperatures' logo abaixo de 'CPU(s)'  (valor agora)"
  if [ $WITH_GRAPH -eq 1 ]; then
    echo "    - painel 'Temperatures (°C)' junto dos gráficos de CPU/Rede"
    echo ""
    echo "  O gráfico começa vazio e enche a 1 amostra/minuto — dê ~5 min."
    echo "  Histórico: 25h em 1min, 31d em 30min, 6 meses em 3h, 2 anos em 12h."
    echo ""
    echo "  Coletor:  systemctl status $UNIT_NAME"
    echo "  Séries:   $COLLECTOR --list"
  fi
  echo ""
  echo "  Estado:   bash $SELF --status"
  echo "  Backup:   $BACKUP_DIR"
  echo ""
  echo "  DESFAZER:"
  echo "    bash $SELF --revert            # mantém o histórico"
  echo "    bash $SELF --revert --purge    # apaga o histórico também"
  echo "    $BACKUP_DIR/RESTAURAR.sh    # emergência, sem depender deste script"
  echo ""
  echo "  Trocou de hardware (novo NVMe/GPU)? Rode de novo — os blocos são"
  echo "  regenerados e o gráfico passa a plotar as séries novas."
  echo ""
  echo "  Todo upgrade do pve-manager remove os patches dos 2 arquivos."
  echo "  Rode de novo — o histórico do RRD NÃO se perde."
fi
echo ""
