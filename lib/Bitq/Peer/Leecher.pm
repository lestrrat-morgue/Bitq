package Bitq::Peer::Leecher;
use Mouse;
use Log::Minimal;

extends 'Bitq::Peer';

sub start {
    my $class = shift;
    my $self = $class->new(@_);

    my $host    = $self->host;
    my $port    = $self->port;
    my $torrent = $self->torrent;
    infof "Starting to download %s at %s:%s", $torrent->info_hash, $host, $port;

    my $hdl = AnyEvent::Handle->new(
        connect => [ $host, $port ],
        on_connect_error => sub {
            critf "Failed to connect to %s:%s", $host, $port;
            return;
        },
        on_connect => sub {
            debugf "Connected to $host:$port";
            my $app = $self->app;
            $app->add_peer( $torrent->info_hash, $self );

            $_[0]->push_write( "bittorrent.handshake" =>
                undef, $torrent->info_hash, $app->peer_id );
            $_[0]->on_read( sub {
                $_[0]->unshift_read( "bittorrent.handshake" => sub {
                    my $hdl = shift;
                    $self->prepare_handle($hdl);
                    $self->handle_handshake(@_);
                });
            });
        }
    );
    $self->handle( $hdl );

    return $self;
}

sub handle_handshake {
    my ($self, $protocol, $reserved, $info_hash, $peer_id) = @_;

    debugf "Read handshake from peer %s:%s", $self->host, $self->port;
    my $hdl = $self->handle;
    $hdl->on_error( sub {
        critf "Error while waiting for remote peer ID";
    } );
    $hdl->unshift_read( chunk => 20, sub {
        my $remote_peer_id = $_[1];
        debugf "Remote peer_id = $remote_peer_id";
        $self->remote_peer_id( $remote_peer_id );
    } );
}

no Mouse;

1;