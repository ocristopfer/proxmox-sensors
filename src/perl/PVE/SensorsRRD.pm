package PVE::SensorsRRD;
# installed by proxmox-enable-sensors.sh (src/perl/PVE).
#
# Reads the RRD maintained by pve-sensors-collect and injects the temperature
# series (prefixed with t_) into the rows returned by GET /nodes/{node}/rrddata,
# aligned by timestamp.
#
# CONTRACT: never throws and never removes/changes existing data. In the worst
# case it returns $res untouched — the PVE API keeps working normally even if
# the RRD is missing, corrupted or being written at this very moment.
use strict;
use warnings;
use RRDs;

my $RRD = '/var/lib/pve-sensors/sensors.rrd';

# same resolutions/counts that PVE uses in PVE::RRD
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
        # only adds; never overwrites a key PVE has already set
        foreach my $k (keys %$v) {
            $row->{$k} = $v->{$k} if !exists $row->{$k};
        }
    }

    return $res;
}

1;
