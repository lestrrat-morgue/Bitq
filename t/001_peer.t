use strict;
use Test::More
    skip_all => "This should be a unit test for Bitq::Peer, but unimplemented";
use Test::TCP;
use AnyEvent;
use AnyEvent::Socket;
use t::Util qw(
    anon_object
);

BEGIN {
    use_ok "Bitq::Torrent";
    use_ok "Bitq::Peer";
}

my $peer = Test::TCP->new(code => sub {
    my $port = shift;

    my $cv = AE::cv;

    AnyEvent::Socket::tcp_server( "127.0.0.1", $port, sub {
        my $socket = shift;
        if (! $socket) {
            diag "bad socket";
            next;
        }

        my $client = anon_object(
            methods => {
                peer_id => sub { "Mock Client" }
            }
        );

        note "Got new socket";
        AnyEvent::Util::fh_nonblocking( $socket, 1 );
        my $peer = Bitq::Peer->create_from_handle(
            client => $client,
            host   => "127.0.0.1",
            port   => $port,
            handle => AnyEvent::Handle->new(
                fh => $socket,
                on_error => sub {
                    diag "Error? : @_";
                }
            ),
            torrent => # WHERE DO I GET THIS FROM?
                Bitq::Torrent->create_from_file(__FILE__),
        );

        $cv->cb( sub { diag "Server existing";
            undef $client;
            undef $peer;
        } );
    });

    $cv->recv;
} );

my $cv = AE::cv;
AnyEvent::Socket::tcp_connect( "127.0.0.1", $peer->port, sub {
    my $fh = shift;
    if (! ok $fh, "Got a socket successfully" ) {
        $cv->send();
        return;
    }

    diag "creating AnyEvent::Handle";
    AnyEvent::Util::fh_nonblocking($fh, 1 );
    my $hdl = AnyEvent::Handle->new(
        fh => $fh,
    );

    $cv->cb( sub { $hdl->destroy } );

    $hdl->push_read( chunk => 68, sub {
        my ($handshake) = @_[1];

        # XXX need to make this more robust
        is bytes::length($handshake),  68, "68 bytes";
        my ($proto, $reserved, $infohash, $peer_id) = unpack_handshake($handshake);
        is $proto, "BitTorrent protocol";
        is $peer_id, "Mock Client";

        $_[0]->push_write(
            build_handshake(
                "dummy",
                $infohash,
                "Test client",
            )
        );
        $_[0]->on_drain( sub {
            note "Sent handshake";
            my $t; $t = AE::timer 5, 0, sub { undef $t; $cv->send };
        } );
    } );
} );

note "Now wait for peer to respond...";

$cv->recv;

done_testing;