package Bitq::Torrent::Seed;
use Mouse;
use Fcntl qw(SEEK_END);
use Log::Minimal;

with 'Bitq::Torrent::WithMetadata';

has completed => (
    is => 'rw',
    isa => 'Bool',
    default => 1,
);

has source_dir => (
    is => 'ro',
    required => 1,
);

has bitfield => (
    is => 'ro',
    lazy => 1,
    clearer => 'clear_bitfield',
    builder => sub {
        my $v = Bit::Vector->new( $_[0]->metadata->piece_count );
        $v->Fill;
        return $v;
    }
);
    
sub write_torrent {
    my ($self, $file) = @_;

    open my $fh, '>',  $file or die "Could not open file $file for writing: $!";
    print $fh $self->metadata->encoded_value;
    close $fh;
}

sub path_to {
    my ($self, $info) = @_;
    my $metadata = $self->metadata;
    if ( $metadata->is_single_file ) {
        return File::Spec->catfile( $self->source_dir, @{$info->{path}} );
    } else {
        return File::Spec->catfile( $self->source_dir, $metadata->{info}->{name}, @{$info->{path}} );
    }
}

sub read_piece {
    my ($self, $i, $begin, $length) = @_;
    my @fileinfo = @{$self->files};
    my $offset   = $i * $self->piece_length + $begin;
    my $sofar    = 0;

    while ( 1 ) {
        my $fileinfo = shift @fileinfo;
        if (! $fileinfo) {
            die "Bad read length, reached end of torrent";
        }

        $sofar += $fileinfo->{length};
        if ($offset > $sofar) {
            # not enough
            debugf "Looking for offset %d, current = %d", $offset, $sofar;
            next;
        }


        # sofar is at the end of current file. in order to backtrack to
        # the corret read location, we just need to subtract the offset

        my $open_fileinfo = sub {
            my $info = shift;
            my $file = $self->path_to( $info );
            open my $fh, '<', $file or
                die "Failed to open file $file: $!";
            return $fh;
        };

        my $fh = $open_fileinfo->( $fileinfo );
        seek $fh, $offset - $sofar, SEEK_END;

        my $buf = '';
        while (1) {
            my $n_read = read $fh, $buf, $length, bytes::length($buf);
            if (! defined $n_read ) {
                die "Something very wrong while reading from file";
            }

            if ( bytes::length($buf) == $length ) {
                return $buf;
            }

            if (! $n_read) { # eof
                $fileinfo = shift @fileinfo;
                if (! $fileinfo) {
                    die "Bad read length, reached end of torrent";
                }
                $fh = $open_fileinfo->( $fileinfo );
            }
        }
    }
}



no Mouse;

1;
