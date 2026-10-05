#!/usr/bin/perl
# patch-pvemanagerlib.pl — patches pve-manager/js/pvemanagerlib.js
#
#   patch-pvemanagerlib.pl <file> patch <snippet.js> <fields> <titles> <panel_bump> <panel_abs>
#   patch-pvemanagerlib.pl <file> revert
#
# Same contract as patch-nodes-pm.pl; strip() also undoes the 'height' /
# 'minHeight' changes, which keep the original value in their own comment.
use strict; use warnings;
my ($file, $mode, $snippet_file, $fields_json, $titles_json, $panel_bump, $panel_abs) = @ARGV;
$panel_bump = 80 if !$panel_bump || $panel_bump !~ /^\d+$/;
$panel_abs  = 0  if !$panel_abs  || $panel_abs  !~ /^\d+$/;

open(my $fh, '<', $file) or die "could not read $file: $!\n";
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

# ---- patch A: text line in the StatusView ------------------------------
open(my $sf, '<', $snippet_file) or die "could not read $snippet_file: $!\n";
my $snippet = do { local $/; <$sf> }; close $sf;

my $sv = index($new, "Ext.define('PVE.node.StatusView'");
die "could not find 'PVE.node.StatusView' in $file — incompatible PVE version\n" if $sv < 0;

my $status_height = 0;

# make room for the new line without cutting the panel (reversible via the comment)
if (substr($new, $sv, 2000) =~ /(\n[ \t]*height:[ \t]*)(\d+)(,)/) {
    my ($pre, $h) = ($1, $2);
    my $start = $sv + $-[0];
    my $len   = $+[0] - $-[0];
    $status_height = $panel_abs ? $panel_abs : $h + $panel_bump;
    substr($new, $start, $len) = $pre . $status_height . ", // PVE-SENSORS-MOD height was $h";
    print "OK    StatusView height: $h -> $status_height\n";
} else {
    print "WARN  could not find 'height:' in the StatusView — the panel may cut the new line\n";
}

pos($new) = $sv;
$new =~ /\G.*?\{\s*itemId:\s*'cpus',.*?^[ \t]*\},\n/smg
    or die "could not find the itemId: 'cpus' item inside the StatusView in $file\n"
         . "Your PVE version changed the file — not touching it blindly.\n";
substr($new, $+[0], 0) = $snippet;
print "OK    'Temperatures' line -> Summary\n";

# ---- patch B+C: model fields + chart panel ------------------------------
if (defined $fields_json && length $fields_json) {

    # B: t_* fields in the pve-rrd-node model (otherwise the store drops the values)
    my $m = index($new, "Ext.define('pve-rrd-node'");
    if ($m < 0) {
        print "WARN  could not find the 'pve-rrd-node' model — chart NOT installed\n";
    } else {
        pos($new) = $m;
        if ($new =~ /\G.*?fields:\s*\[\n/sg) {
            substr($new, $+[0], 0) =
                  "\t// PVE-SENSORS-FIELDS-BEGIN\n"
                . "\t$fields_json,\n"
                . "\t// PVE-SENSORS-FIELDS-END\n";
            print "OK    temperature fields -> pve-rrd-node model\n";

            # C: proxmoxRRDChart panel in the node Summary
            my $su = index($new, "Ext.define('PVE.node.Summary'");
            if ($su < 0) {
                print "WARN  could not find 'PVE.node.Summary' — panel NOT installed\n";
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
                        # No seriesConfig and no custom axes: that way the panel uses
                        # exactly the default proxmoxRRDChart style (filled areas,
                        # opacity 0.6, axis starting at zero), same as the
                        # CPU Usage / Server Load / Memory usage charts.
                        . "$ind    store: rrdstore,\n"
                        . "$ind},\n"
                        . "$ind// PVE-SENSORS-CHART-END\n";
                    print "OK    'Temperatures' panel -> Summary\n";
                } else {
                    print "WARN  could not find proxmoxRRDChart in the Summary — panel NOT installed\n";
                }

                # The Summary 'itemcontainer' uses a 'column' layout (CSS floats)
                # and ALL cells -- including the StatusView itself -- inherit the
                # same minHeight. Out of the box the panel (350) fit in the cell
                # (360). Once it grows to fit the temperatures it overflows the
                # cell, the rows get misaligned and a gap is left in the left
                # column. Matching minHeight to the panel height realigns it all.
                if ($status_height) {
                    my $su3 = index($new, "Ext.define('PVE.node.Summary'");
                    if ($su3 >= 0 && substr($new, $su3, 8000) =~ /(\n[ \t]*minHeight:[ \t]*)(\d+)(,)/) {
                        my ($pre, $mh) = ($1, $2);
                        if ($status_height > $mh) {
                            my $start = $su3 + $-[0];
                            my $len   = $+[0] - $-[0];
                            substr($new, $start, $len) =
                                $pre . $status_height . ", // PVE-SENSORS-MOD minHeight was $mh";
                            print "OK    cell minHeight: $mh -> $status_height (realigns the columns)\n";
                        }
                    } else {
                        print "WARN  could not find 'minHeight:' in the Summary — the columns may be misaligned\n";
                    }
                }
            }
        } else {
            print "WARN  could not find 'fields: [' in the model — chart NOT installed\n";
        }
    }
}

# ---- proof of reversibility --------------------------------------------
strip($new) eq $base
    or die "CHECK FAILED: the patch of $file is not reversible. Nothing was written.\n";

save($file, $new);
print "DONE  $file patched (reversibility verified)\n";
