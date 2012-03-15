package Bitq::Protocol;
use strict;
use AnyEvent;
use AnyEvent::Handle;
use Log::Minimal;
use Exporter 'import';

our @EXPORT_OK = qw(
    pack_handshake
    unpack_handshake
    compact_ipv4
    uncompact_ipv4
);

sub pack_handshake {
    my ($reserved, $info_hash, $peer_id) = @_;

    if (! defined $reserved) {
        my @reserved = (0, 0, 0, 0, 0, 0, 0, 0);
        $reserved[5] |= 0x10;    # Ext Protocol
        $reserved[7] |= 0x04;    # Fast Ext
        $reserved = join '', map {chr} @reserved;
    }

    return pack 'c/a* a8 H40 a20',
        'BitTorrent protocol',
        $reserved,
        $info_hash,
        $peer_id
    ;
}

sub unpack_handshake {
    my ($handshake) = @_;

    require bytes;
    my $length = bytes::length($handshake);
    if ($length != 68) {
        Carp::croak("Handshake packet is not 68 bytes (was $length)");
    }
    return unpack 'c/a* a8 H40 a20', $handshake;
}

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

AnyEvent::Handle::register_read_type(
    "bittorrent.handshake" => sub {
        my ($self, $cb) = @_;

        my %state = (
            preamble => 0,
        );
        sub {
            if ( ! $state{preamble} ) {
                # Handshakes consiste of 69 bytes total. The first byte is 0x13
                if ( !defined $_[0]{rbuf} || length $_[0]{rbuf} < 1 ) {
                    return;
                }

                my $byte = substr $_[0]{rbuf}, 0, 1;
                if ( unpack("c", $byte) != 0x13 ) {
                    undef %state;
                    critf "Expected 0x13 as first byte in stream, but got %s", 
                    $cb->($_[0], "Bad handshake");
                    return 1;
                }
                $state{preamble} = 1;
            }

            if ( length $_[0]{rbuf} < 68 ) {
                return;
            }

            # whippee we got 68 bytes
            undef %state;
            $cb->( $_[0], unpack_handshake( substr $_[0]{rbuf}, 0, 68, '' ) );
            return 1;
        }
    }
);

AnyEvent::Handle::register_read_type(
    "bittorrent.packet" => sub {
        my ($self, $cb) = @_;

        my %state = (
            len     => 0,
            type    => 0,
        );
        sub {
            if ( ! $state{len} ) {
                # Check the first 4 bytes to figure out the length of the
                # payload. The next byte contains 1 byte that describes the
                # message type, then the payload. 
                if ( length $_[0]{rbuf} < 5 ) {
                    return;
                }
                my $preamble = bytes::substr( $_[0]{rbuf}, 0, 5, '' );
                ($state{len}, $state{type}) = unpack "l c", $preamble;

                # len contains the len for the type byte, so subtract that
                $state{len} -= 1;
            }

            if ( length( $_[0]{rbuf} ) < $state{len} ) {
                return;
            }

            my ($len, $type) = ($state{len}, $state{type});
            my $buffer = bytes::substr( $_[0]{rbuf}, 0, $len, '' );
            undef %state;

            $cb->( $_[0], $type, $buffer );
            return 1;
        }
    }
);

AnyEvent::Handle::register_write_type(
    "bittorrent.handshake" => sub {
        my ($self, $reserved, $info_hash, $peer_id) = @_;
        return pack_handshake( $reserved, $info_hash, $peer_id );
    }
);

AnyEvent::Handle::register_write_type(
    "bittorrent.packet" => sub {
        my ($self, $type, $string) = @_;
        $string ||= '';

        my $len = bytes::length($type) + bytes::length($string);
        debugf "Writing $type $string ($len bytes)";
        return pack( "l c", $len, $type ) . $string;
    }
);

1;
