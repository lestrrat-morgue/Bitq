# A "peer" may sound like it represents a "connection" between another 
# client, but it should be thought as a connection for a SPECIFIC torrent
# That's why it needs a torrent as its instance variable.

package Bitq::Peer;
use Mouse;
use AnyEvent::Handle;
use Fcntl qw(SEEK_SET);
use Bitq::Constants qw(:packet);
use Bitq::Protocol qw(unpack_handshake);
use Bitq::Torrent;
use List::Util ();
use Log::Minimal;

has app => (
    is => 'ro',
    weak_ref => 1,
    required => 1,
);

has encryption_mode => (
    is => 'ro',
    default => 0,
);

has handle => (
    is => 'rw',
    trigger => sub {
        $_[0]->prepare_handle( $_[1] ) if $_[1];
    }
);

has 'host' => (
    is => 'ro',
);

has 'port' => (
    is => 'ro',
);

has torrent => (
    is => 'rw',
);

has remote_bitfield => (
    is => 'rw'
);

has remote_peer_id => (
    is => 'rw'
);

has peer_host => (
    is => 'rw'
);

has peer_port => (
    is => 'rw'
);

has on_disconnect => (
    is => 'rw'
);

sub start {}

sub prepare_handle {
    my ($self, $hdl) = @_;

    $hdl->on_error( sub {
        critf "Socket error: %s", $_[1];
    });
    $hdl->on_read( sub {
        $_[0]->unshift_read( "bittorrent.packet" => sub {
            my ($hdl, $type, $string) = @_;
            debugf "Read packet 0x%02x", $type;

            if ( $type == PKT_TYPE_UNCHOKE ) {
                debugf "Received unchoke";
                $self->handle_unchoked();
            } elsif ( $type == PKT_TYPE_BITFIELD ) {
                my $bitfield = Bit::Vector->new( $self->torrent->piece_count );
                $bitfield->Block_Store($string);
                debugf "%s received bitfield '%s' from %s",
                    $self->app->peer_id,
                    $bitfield->to_Bin,
                    $self->remote_peer_id,
                ;
                if ( $bitfield->is_empty ) {
                    $self->disconnect( "Nothing to download from" );
                }
                $self->remote_bitfield( $bitfield );
            } elsif ( $type == PKT_TYPE_REQUEST ) {
                my ($index, $begin, $length) = unpack "NNN", $string;
                debugf "Received request to download piece %d (begin %d for %d)",
                    $index, $begin, $length;
                $self->handle_request( $index, $begin, $length );
            } elsif ( $type == PKT_TYPE_PIECE ) {
                my ($index, $begin, $payload) = unpack "NNa*", $string;
                debugf "Received piece for %d (begin %d, length %d)", $index, $begin, bytes::length($payload);
                $self->handle_piece( $index, $begin, $payload );
            }
        } );
    } );
}

sub handle_unchoked {
    my ($self) = @_;

    my $hdl = $self->handle;
    my $torrent = $self->torrent;
    $torrent->bitfield;
    my $bitfield = $torrent->bitfield;
    if ($bitfield->is_full) {
        $torrent->unpack_completed( $self->app->work_dir );
        infof "%s downloaded %s (%s)",
            $self->app->peer_id,
            $torrent->name,
            $torrent->info_hash
        ;
        $self->disconnect( "Finished downloading" );
        return;
    }

    debugf "My bitfield for %s = %s", $torrent->info_hash, $bitfield->to_Bin;
    my @pieces = (0..$bitfield->Size() - 1); # List::Util::shuffle( 0 .. $bitfield->Size() - 1 ) ;
    my $remote = $self->remote_bitfield;
    foreach my $index ( @pieces ) {
        next if $bitfield->bit_test($index);
        next if ! $remote->bit_test($index);

        # If this is the last piece, then the piece length may not be the
        # same, so calculate it
        my $piece_length = $torrent->piece_length;
        if ( $index == scalar @pieces - 1 ) {
            $piece_length = $torrent->total_size - (scalar @pieces - 1) * $piece_length;
        }
        $hdl->push_write( "bittorrent.packet" => PKT_TYPE_REQUEST, 
            pack "NNN", $index, 0, $piece_length );
        last;
    }

}

sub handle_piece {
    my ($self, $index, $begin, $piece_content) = @_;

    my $torrent = $self->torrent;
    $torrent->add_piece( $index, $begin, $piece_content );

    # send my state
    my $bitfield = $torrent->bitfield;
    $self->handle->push_write( "bittorrent.packet", PKT_TYPE_BITFIELD, $bitfield->Block_Read() );

    # XXX Need to remember which bytes I have within this piece?
    $self->handle_unchoked;
}

sub handle_request {
    my ($self, $index, $begin, $length) = @_;

    my $torrent = $self->torrent;
    my $buf     = $torrent->read_piece( $index, $begin, $length );
    my $hdl     = $self->handle;
    if (! $buf) {
        # don't have what you want, bye bye
        $self->disconnect( "Don't have piece $index" );
    } else {
        $hdl->push_write( "bittorrent.packet", PKT_TYPE_PIECE, 
            pack "NNa*", $index, $begin, $buf );
    }
}

sub disconnect {
    my ($self, $reason) = @_;

    infof( "%s disconnecting peer (%s) because: %s",
        $self->app->peer_id,
        $self->remote_peer_id || 'unknown',
        $reason || sprintf( "(unknown from %s %s)", (caller)[1,2] ),
    );
    $self->handle->destroy;
    $self->handle(undef);

    if ( my $cb = $self->on_disconnect ) {
        $cb->( $self );
    }
#        $->remove_peer( $self );
}

sub DEMOLISH {
    my $self = shift;
    infof "DEMOLISH called for peer to %s:%s, peed_id %s",
        $self->host,
        $self->port,
        $self->app->peer_id
    ;
}

no Mouse;

1;
