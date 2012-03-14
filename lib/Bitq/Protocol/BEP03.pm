package Bitq::Protocol::BEP03;
use strict;
use Exporter 'import';
our @EXPORT_OK = qw(
    build_handshake
    unpack_handshake
);

sub unpack_handshake {
    my @payload = unpack 'c/a* a8 H40 a20', $_[0];
    $payload[3] =~ s/\0+$//;
    return @payload;
}

sub build_handshake {
    my ($reserved, $info_hash, $peer_id) = @_;

    return pack 'c/a* a8 H40 a20',
        'BitTorrent protocol',
        $reserved,
        $info_hash,
        $peer_id
    ;
}

1;
