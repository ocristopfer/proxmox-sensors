# Test stub: lets 'perl -c' load SensorsRRD.pm without librrds-perl installed.
package RRDs;
sub create { } sub update { } sub fetch { return } sub error { return }
1;
