package Bitq::Peer::Seeder;
use Mouse;
use Bitq::Protocol qw(pack_handshake);
use Log::Minimal;
use Bitq::Constants qw(:packet);

extends 'Bitq::Peer';

sub start {
    my $class = shift;
    my $self = $class->new(@_);

    my $hdl = $self->handle;
    $hdl->on_error( sub {
        critf "Peer from %s:%s had an error before handshake. %s",
            $self->host,
            $self->port,
            $_[2]
        ;
        $self->disconnect($_[2]);
    } );
    $hdl->on_read( sub {
        $_[0]->unshift_read( "bittorrent.handshake" => sub {
            my $hdl = shift;
            $self->prepare_handle($hdl);
            $self->handle_handshake(@_);
        } );
    } );

    return $self;
}

sub handle_handshake {
    my ($self, $protocol, $reserved, $info_hash, $peer_id) = @_;

    debugf "Read handshake from leecher: $protocol, $reserved, $info_hash, $peer_id";
    my $app = $self->app;
    my $torrent = $app->find_torrent( $info_hash );
    if (! $torrent) {
        $self->disconnect( "No such torrent $info_hash" );
        return;
    }

    $app->add_leecher( $info_hash, $self );
    $self->torrent($torrent);
    $self->remote_peer_id( $peer_id );

    my $hdl = $self->handle;
    $hdl->push_write( "bittorrent.handshake", $reserved, $info_hash, $peer_id );
    $hdl->push_write( $app->peer_id );
    $hdl->push_write( "bittorrent.packet", PKT_TYPE_BITFIELD, $torrent->bitfield->Block_Read() );
    $hdl->push_write( "bittorrent.packet", PKT_TYPE_UNCHOKE);
}

no Mouse;

1;