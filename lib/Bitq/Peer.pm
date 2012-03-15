# A "peer" may sound like it represents a "connection" between another 
# client, but it should be thought as a connection for a SPECIFIC torrent
# That's why it needs a torrent as its instance variable.

package Bitq::Peer;
use Mouse;
use AnyEvent::Handle;
use Fcntl qw(SEEK_SET);
use Bitq::Torrent;
use List::Util ();
use Log::Minimal;

use constant +{
    PKT_TYPE_CHOKE          => 0x00, # no payload
    PKT_TYPE_UNCHOKE        => 0x01, # no payload
    PKT_TYPE_INTERESTED     => 0x02, # no payload
    PKT_TYPE_NOT_INTERESTED => 0x03, # no payload
    PKT_TYPE_HAVE           => 0x04,
    PKT_TYPE_BITFIELD       => 0x05,
    PKT_TYPE_REQUEST        => 0x06,
    PKT_TYPE_PIECE          => 0x07,
    PKT_TYPE_CANCEL         => 0x08,
};

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

# This method is for when we just accepted a connection. We wait for
# a handshake, and serve the remote peer
sub accept_handle {
    my $class = shift;
    my $self = $class->new(@_);

    my $SELF = $self;
    Scalar::Util::weaken($SELF);
    my $hdl = $self->handle;
    $hdl->on_error( sub {
        critf "Peer from %s:%s had an error before handshake. %s",
            $SELF->host,
            $SELF->port,
            $_[2]
        ;
        $SELF->disconnect();
    } );
    $hdl->push_read( "bittorrent.handshake", sub {
        my ($hdl, @args) = @_;

        $hdl->on_error(undef);
        my ($protocol, $reserved, $info_hash, $peer_id);
        if (@args == 1) {
            critf "Bad handshake, closing connection";
            $SELF->disconnect( "Bad handshake" );
            return;
        } else {
            ($protocol, $reserved, $info_hash, $peer_id) = @args;
        }

        debugf "Read handshake from leecher: $protocol, $reserved, $info_hash, $peer_id";
        my $app = $self->app;
        my $torrent = $app->find_torrent( $info_hash );
        if (! $torrent) {
            $SELF->disconnect( "No such torrent" );
            return;
        }

        $app->add_leecher( $info_hash, $self );
        $self->torrent($torrent);
        $self->remote_peer_id( $peer_id );

        $hdl->push_write( "bittorrent.handshake", $reserved, $info_hash, $peer_id );
        $hdl->on_drain( sub {
            $_[0]->on_drain(undef);
            debugf "Sent handshake to leecher %s", $peer_id;

            $_[0]->on_error( sub {
                critf "Error while sending peer ID";
            });
            $_[0]->push_write( $app->peer_id );
            my $bitfield = $torrent->calc_bitfield( $app->work_dir );
            infof "%s sending bitfield %s to %s", 
                $self->app->peer_id,
                $bitfield->to_Bin,
                $self->remote_peer_id,
            ;

            $_[0]->push_write( "bittorrent.packet", PKT_TYPE_BITFIELD, $bitfield->Block_Read() );
            $_[0]->push_write( "bittorrent.packet", PKT_TYPE_UNCHOKE);

            $self->handle_incoming();
        } );
        $hdl->on_error( sub {
            critf "Error while sending handshake to leecher %s: %s", $peer_id, $_[2];
        } );
    });

    return $self;
}

sub start_download {
    my $class = shift;
    my $self = $class->new(@_);

    # This is where we connect to another peer, and ask for a file.
    # The initialization consists of handshake sent, server checking for 
    # appropriate info and returning a handshake.
    #
    # I'd rather push this logic into the peer, but it requires way too much
    # knowledge of the entire application to check if this leecher is "correct"

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
            $self->start();
        }
    );
    $self->handle( $hdl );
}

sub start {
    my ($self) = @_;

    my $hdl = $self->handle;
    my $app = $self->app;
    my $host    = $self->host;
    my $port    = $self->port;
    my $torrent = $self->torrent;
    $hdl->on_error( sub {
        $_[0]->on_error(undef);
        critf "Error while writing handshake from %s to peer on %s:%s",
            $app->peer_id,
            $host,
            $port
        ;
    } );
    $hdl->on_eof( sub {
        $self->disconnect("Received EOF");
    } );
    $hdl->on_drain( sub {
        $_[0]->on_drain(undef);
        debugf "Sent handshake from %s to peer on %s:%s", $app->peer_id, $host, $port;
        $_[0]->on_error( sub {
            critf "Error while waiting for handshake";
        } );
        debugf "Waiting for handshake from %s:%s", $host, $port;
        $_[0]->push_read( "bittorrent.handshake" => sub {
            debugf "Read handshake from peer $host:$port";
            $_[0]->on_error( sub {
                critf "Error while waiting for remote peer ID";
            } );
            $_[0]->push_read( chunk => 20, sub {
                my $remote_peer_id = $_[1];
                debugf "Remote peer_id = $remote_peer_id";
                $self->remote_peer_id( $remote_peer_id );
                $self->handle_incoming();
            } );
        } );
    } );
    $hdl->on_error( sub {
        critf "Error while waiting for handshake from peer on %s:%s", $host, $port;
        $self->app->remove_peer( $torrent->info_hash );
    } );
    $hdl->push_write( "bittorrent.handshake" =>
        undef, $torrent->info_hash, $self->app->peer_id );

}

sub handle_incoming {
    my $self = shift;
    my $hdl = $self->handle;

    $hdl->on_error( sub {
        critf "Error while waiting for packet @_";
    } );
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
                infof "%s received bitfield '%s' from %s",
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
    $torrent->calc_bitfield( $self->app->work_dir );
    my $bitfield = $torrent->bitfield;
    if ($bitfield->is_full) {
        my $file = File::Spec->catfile( $self->app->work_dir, $torrent->info_hash );
        $torrent->unpack_completed( $file, $self->app->work_dir );
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

        my $piece = $torrent->pieces->[$index];

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
    my $file = File::Spec->catfile( $self->app->work_dir, $torrent->info_hash );
    if (! -f $file ) {
        open my $fh, '>', $file
            or die "Failed to open $file: $!";
        seek $fh, $torrent->total_size, SEEK_SET;
        truncate $fh, 0;
        close $fh;
    }

    open my $fh, '+<', $file
        or die "Failed to open file $file: $!";
    seek $fh, $index * $torrent->piece_length + $begin, SEEK_SET;
    print $fh $piece_content;
    close $fh;

    debugf "Wrote to $file (%d for %d bytes)", 
        $index * $torrent->piece_length + $begin,
        bytes::length($piece_content)
    ;

    # send my state
    my $bitfield = $torrent->calc_bitfield( $self->app->work_dir );
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

    $reason ||= "(Unknown)";
    infof( "%s disconnecting peer (%s) because: %s",
        $self->app->peer_id,
        $self->remote_peer_id || 'unknown',
        $reason || "(unknown)"
    );
    $self->handle->destroy;
    $self->handle(undef);

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
