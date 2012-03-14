package Bitq::Protocol::BEP23;
use strict;
use Exporter 'import';

our @EXPORT_OK = qw(
    compact_ipv4
    uncompact_ipv4
);

sub compact_ipv4 {
    my (@peers) = @_;
    my $return = '';
    foreach my $peer (@peers) {
        my @args = (
            ($peer->{address} =~ m{^(\d+)\.(\d+)\.(\d+)\.(\d+)$}),
            int $peer->{port}
        );
        $return .= pack 'C4n', @args;
    }
    return $return;
}

sub uncompact_ipv4 {
    my $string = shift;

    my %peers;
    while (my $packed = substr $string, 0, 6, '') {
        my @args = unpack "C4 n", $packed;
        my $addr = sprintf "%d.%d.%d.%d:%d", @args;
        $peers{ $addr }++;
    }
    return keys %peers;
}

1;
