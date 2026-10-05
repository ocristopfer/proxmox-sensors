# Minimal stand-in for PVE/API2/Nodes.pm: only the parts the patcher anchors on.
package PVE::API2::Nodes::Nodeinfo;

use strict;
use warnings;

my $status = {
    name => 'status',
    method => 'GET',
    description => "Read node status",
    code => sub {
	my ($param) = @_;

	my $res = {
	    uptime => 0,
	};

	return $res;
    },
};

my $rrddata = {
    name => 'rrddata',
    method => 'GET',
    description => "Read node RRD statistics",
    code => sub {
	my ($param) = @_;

	return PVE::RRD::create_rrd_data(
	    "pve2-node/$param->{node}", $param->{timeframe}, $param->{cf});
    },
};

1;
