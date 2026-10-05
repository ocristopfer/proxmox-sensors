#!/usr/bin/perl
# patch-nodes-pm.pl — patches PVE/API2/Nodes.pm
#
#   patch-nodes-pm.pl <file> patch  <with_graph 0|1>
#   patch-nodes-pm.pl <file> revert
#
# Contract (shared with patch-pvemanagerlib.pl):
#   - strip() removes ALL of our blocks
#   - patch = strip() + re-insert (that's why running again updates the series)
#   - before writing, checks that strip(new) == strip(original). If it doesn't
#     match exactly, abort without writing — this is the proof that the patch
#     is a pure insertion and 100% reversible.
#   - writes to .tmp and does an atomic rename(), preserving owner and mode
use strict; use warnings;
my ($file, $mode, $with_graph) = @ARGV;
$with_graph = 0 if !defined $with_graph;

open(my $fh, '<', $file) or die "could not read $file: $!\n";
my $c = do { local $/; <$fh> }; close $fh;

sub strip {
    my ($t) = @_;
    $t =~ s/[ \t]*# PVE-SENSORS-MOD-BEGIN\n.*?# PVE-SENSORS-MOD-END\n//sg;
    $t =~ s/[ \t]*# PVE-SENSORS-RRD-BEGIN\n.*?# PVE-SENSORS-RRD-END\n//sg;
    return $t;
}

sub save {
    my ($f, $t) = @_;
    my @st = stat($f) or die "could not stat $f: $!\n";
    my $tmp = "$f.pve-sensors.tmp.$$";
    open(my $out, '>', $tmp) or die "could not write $tmp: $!\n";
    print $out $t or die "error writing $tmp: $!\n";
    close($out)   or die "error closing $tmp: $!\n";
    chmod($st[2] & 07777, $tmp);
    chown($st[4], $st[5], $tmp);
    rename($tmp, $f) or do { unlink $tmp; die "could not replace $f: $!\n" };
}

my $base = strip($c);

if ($mode eq 'revert') {
    if ($base eq $c) { print "SKIP  not patched\n"; exit 0; }
    save($file, $base);
    print "DONE  patches removed\n";
    exit 0;
}

my $new = $base;

# ---- patch A: thermalstate in GET /nodes/{node}/status -----------------
$new =~ /description\s*=>\s*"Read node status\.?"/
    or die "anchor not found in $file (description => \"Read node status\").\n"
         . "Your PVE version changed the file — not touching it blindly.\n";
pos($new) = $+[0];
$new =~ /\G.*?\n(?=([ \t]*)return \$res;)/sg
    or die "could not find the 'return \$res;' of the status method in $file\n";
{
    my $at  = $+[0];
    my $ind = $1;
    # 'timeout 5': a stuck sensor must never hold a pveproxy worker
    substr($new, $at, 0) =
          "${ind}# PVE-SENSORS-MOD-BEGIN\n"
        . "${ind}\$res->{thermalstate} = `timeout 5 /usr/bin/sensors -j 2>/dev/null`;\n"
        . "${ind}# PVE-SENSORS-MOD-END\n";
    print "OK    thermalstate -> GET /nodes/{node}/status\n";
}

# ---- patch B: temperature series in GET /nodes/{node}/rrddata ----------
if ($with_graph) {
    # The node RRD name changes between PVE versions ("pve2-node/" on 7/8,
    # "pve-node-9.0/" on 9). We capture whatever is in the file and reuse it
    # verbatim, instead of guessing a fixed name.
    $new =~ /^([ \t]*)return\s+PVE::RRD::create_rrd_data\(\s*"([^"\n]*\$param->\{node\}[^"\n]*)"/m
        or die "could not find the create_rrd_data(...\$param->{node}...) call in $file\n"
             . "Your PVE version changed the rrddata method — not touching it blindly.\n";
    my $ind     = $1;
    my $rrdname = $2;
    print "OK    node RRD detected: $rrdname\n";
    # PURE insertion, before the original return — which is left unreachable
    # on purpose. That way the revert is a clean removal and the file goes
    # back byte by byte. If the require/merge fails, the eval swallows it and
    # the API keeps going.
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
    print "OK    temperature merge -> GET /nodes/{node}/rrddata\n";
}

# ---- proof of reversibility --------------------------------------------
strip($new) eq $base
    or die "CHECK FAILED: the patch of $file is not reversible. Nothing was written.\n";

save($file, $new);
print "DONE  $file patched (reversibility verified)\n";
