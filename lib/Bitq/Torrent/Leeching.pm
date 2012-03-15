package Bitq::Torrent::Leeching;
use Mouse;
use Bitq::Torrent::Metadata;
use Fcntl qw(SEEK_SET);
use File::Temp ();
use Log::Minimal;

with 'Bitq::Torrent::WithMetadata';

has completed => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
);

has work_dir => (
    is => 'ro',
    default => sub {
        File::Temp::tempdir( CLEANUP => 1 );
    }
);

has dest_file => (
    is => 'ro',
    default => sub {
        File::Spec->catfile( $_[0]->work_dir, $_[0]->metadata->info_hash );
    }
);

has bitfield => (
    is => 'ro',
    clearer => 'clear_bitfield',
    lazy => 1,
    builder => \&create_bitfield,
    trigger => sub {
        if ($_[1]->is_full) {
            $_[0]->completed(1);
        }
    }
);

sub create_bitfield {
    my ($self) = @_;

    my $metadata  = $self->metadata;
    my $p_length  = $metadata->piece_length;
    my $p_count   = $metadata->piece_count;
    my $vec       = Bit::Vector->new( $p_count );

    if ($self->completed) {
        $vec->Fill();
        return $vec;
    }

    my $dest_file = $self->dest_file;

    debugf "Calculating bitfield for %s", $dest_file;
    my $fh;
    if (! -f $dest_file) {
        $vec->Empty();
        return $vec;
    }

    open $fh, '<', $dest_file
        or die "Could not open $dest_file: $!";

    my $pieces   = $metadata->pieces;
    my $p_offset = 0;
    my $v_offset = 0;
    for my $i ( 0 .. $p_count - 1 ) {
        my $hash = $metadata->hash_at( $i );
        my $this_piece;
        my $n_read = read $fh, $this_piece, $p_length;
        debugf " + bitfield (%d): read %d bytes", $i, $n_read;
        if ($n_read) {
            my $this_hash = Digest::SHA::sha1( $this_piece );
            if ( $this_hash eq $hash ) {
                debugf " + bitfield (%d): hash matches", $i;
                $vec->Bit_On( $i );
            } else {
                debugf " + bitfield (%d): hash did not match...", $i;
            }
        }
    }

    return $vec;
}

sub read_piece {
    my ($self, $i, $begin, $length) = @_;

    open my $fh, '<', $self->dest_file
        or die "Failed to open @{[ $self->dest_file ]}: $!";
    seek $fh, $i * $self->piece_length + $begin, SEEK_SET;
    my $buf;
    read $fh, $buf, $length;
    close $fh;
    return $buf;
}

sub unpack_completed {
    my ($self, $dest_dir) = @_;

    my $metadata = $self->metadata;
    my $base_dir = $metadata->is_single_file ?
        $dest_dir :
        File::Spec->catdir( $dest_dir, $metadata->name )
    ;

    open my $fh, '<', $self->dest_file or
        die "Could not open file @{[$self->dest_file]}: $!";
    foreach my $fileinfo ( @{ $self->files } ) {
        my $buf;
        my $length = $fileinfo->{length};
        my $bufsiz = 8192;

        my $dest = File::Spec->catfile( $base_dir, @{$fileinfo->{path}} );
        debugf "unpacking to %s", $dest;
        open my $dest_fh, '>', $dest or
            die "Could not open file $dest: $!";
        while ( $length > 0 ) {
            if ( $bufsiz > $length ) {
                $bufsiz = $length;
            }
            my $n_read = read $fh, $buf, $bufsiz;
            print $dest_fh $buf;
            $length -= $n_read;
        }
        debugf "Wrote to %s", $dest;
    }
    $self->completed(1);
}

sub add_piece {
    my ($self, $i, $offset, $content) = @_;

    my $file = $self->dest_file;
    if (! -f $file ) {
        open my $fh, '>', $file
            or die "Failed to open $file: $!";
        seek $fh, $self->total_size, SEEK_SET;
        truncate $fh, 0;
        close $fh;
    }

    open my $fh, '+<', $file
        or die "Failed to open file $file: $!";
    seek $fh, $i * $self->piece_length + $offset, SEEK_SET;
    print $fh $content;
    close $fh;

    debugf "Wrote to $file (%d for %d bytes)", 
        $i * $self->piece_length + $offset,
        bytes::length($content)
    ;

    $self->clear_bitfield;
}

no Mouse;

1;
