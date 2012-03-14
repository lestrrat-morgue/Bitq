# A torrent file may contain information about a set of files, or a single
# file. the data structure generated to be bencoded is wickedly asymetrical
# which makes things really annoying.
#
# Torrent.pm will need to work under two modes:
#    1) it must be able to be created and populated with actual files.
#       in this state, it can also represent a completed download, too
#    2) it must be able to represent a completely/partially empty
#       torrent file, which was loaded via a torrent file
#
#   # Creates a new torrent from existing file
#   my $torrent = Bitq->create_from_file( $file, @other_args );
#
#   # Creates a new torrent from existing directory
#   # Will include all files in this directory
#   my $torrent = Bitq->create_from_dir( $dir, @other_args );
#
#   # Creates a new torrent from a .torrent file
#   my $torrent = Bitq->load_torrent( $file );
#
# You should not use "new()". new() creates a new object, but it does not
# guarantee that all of the necessary information was generated.
#
# In all cases, it needs to be able to query particular piece of data.
# The piece is accessed via an index.
#
#   $torrent->total_pieces();
#   $torrent->piece($i);


package Bitq::Torrent;
use Mouse;
use Cwd ();
use Digest::MD5 ();
use Digest::SHA ();
use Fcntl qw(SEEK_END SEEK_SET);
use File::Spec;
use Log::Minimal;
use Bitq::Bencode ();

has parent_dir => (
    is => 'rw',
    default => sub { Cwd::getcwd() },
);

has source => (
    is => 'rw',
);

has completed => (
    is => 'rw',
    isa => 'Bool',
);

has pieces => (
    is => 'rw',
);

has dir => (
    is => 'ro',
);

has files => (
    isa => 'ArrayRef',
    accessor => "_files",
);

has fileinfo => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { +[] }
);

has info_hash => (
    is => 'rw'
);

has info_hash_raw => (
    is => 'rw',
    trigger => sub {
        my $hash = Digest::SHA::sha1_hex( $_[1] );
        debugf( "Detected new file info, setting hex info_hash as %s", $hash );
        $_[0]->info_hash( $hash )
    },
);

has name => (
    is => 'ro',
    required => 1,
);

has total_size => (
    is => 'rw',
    isa => 'Int',
);

has piece_length => (
    is => 'ro',
    isa => 'Int',
    required => 1,
    default => 2**18,
);

has piece_count => (
    is => 'rw',
    isa => 'Int',
);

has announce => (
    is => 'ro',
);

has announce_list => (
    is => 'ro',
    default => sub { +[] }
);

has private => (
    is => 'ro',
    isa => 'Bool',
    default => 0,
);

has comment => (
    is => 'ro',
);

has merge => (
    is => 'ro',
    default => sub { +{} },
);

has bitfield => (
    is => 'rw',
);

sub path_to {
    my ($self, @components) = @_;
    File::Spec->catfile($self->parent_dir, @components);
}

sub files {
    my $self = shift;
    if (@_) {
        my $files = $_[0];
        $files = [ sort { $a cmp $b } @$files ];
        $self->_files($files);
    }
    return $self->_files;
}

sub read_piece {
    my ($self, $i, $begin, $length) = @_;

    infof "Reading piece %d (begin %d, length %d)", $i, $begin, $length;
    if (! $self->completed ) {
        die "yikes";
    }

    my @fileinfo = @{$self->fileinfo};
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
            infof "Looking for offset %d, current = %d", $offset, $sofar;
            next;
        }


        # sofar is at the end of current file. in order to backtrack to
        # the corret read location, we just need to subtract the offset

        my $open_fileinfo = sub {
            my $info = shift;
            my $file = $self->dir ?
                File::Spec->catfile( $self->source, @{ $info->{path}} ) :
                $self->source
            ;
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

sub create_metadata {
    my $self = shift;
    my %data = (
        %{ $self->merge },
        info => {
            'piece length'  => $self->piece_length,
            'pieces'        => '',
            'name'          => $self->name,
        },
        'creation date' => time,
        'created by'    => 'Bitq::Torrent/Perl',
    );

    if ($self->private) {
        $data{info}->{private} = 1;
    }
    if (my $value = $self->announce) {
        $data{announce} = $value;
    }
    if (my $value = $self->announce_list) {
        if ( @$value > 0 ) {
            $data{'announce-list'} = $value;
        }
    }
    if (my $value = $self->comment) {
        $data{comment} = $value;
    }

    my @pieces = $self->generate_pieces();
    $self->piece_count(scalar @pieces);
    $data{info}->{pieces} = join '', @pieces;
    my $files = $self->files;
    if ( @$files == 1 ) {
        my ($fileinfo) = $self->generate_fileinfo;
        my $file       = $files->[0];
        $data{info}->{name} = $file;
        $data{info}->{length} = $fileinfo->{length};
#        $data{info}->{md5sum} = $fileinfo->{md5sum};
    } else {
        $data{info}->{name}  = $self->dir;
        $data{info}->{files} = [ $self->generate_fileinfo ];
    }

use Data::Dumper::Concise;
warn Dumper(\%data);

    return \%data;
}

sub generate_fileinfo {
    my $self = shift;
    my $files = [ @{ $self->files } ];

    my @fileinfo;
    while ( my $file = shift @$files ) {
        $file = $self->path_to($file);
        my (undef, $dirs, $filename) = File::Spec->splitpath($file);
        push @fileinfo, {
            path => [ ( $dirs ? File::Spec->splitdir($dirs) : () ), $filename ],
            length => -s $file,
        };
    }
    $self->fileinfo(\@fileinfo);
    return @fileinfo;
}

sub generate_pieces {
    my $self = shift;
    my $files = [ @{ $self->files } ];

    my $data   = '';
    my @pieces;
    my $piece_length = $self->piece_length;
    while ( my $file = shift @$files ) {
        $file = $self->path_to($file);
        open my $fh, '<', $file or die "Could not open file $file: $!";

        my $size = -s $fh;
        my $sofar = 0;
        while ( $sofar < $size ) {
            my $n_read = read $fh, $data, $piece_length, bytes::length($data);
            if (! defined $n_read) {
                die "Failed to read from file: $!";
            }

            if ( $n_read > 0 ) {
                $sofar += $n_read;
                if ( bytes::length($data) == $piece_length ) {
                    push @pieces, Digest::SHA::sha1($data);
                    $data = '';
                }
            }
        }
    }
    if ( $data ) {
        push @pieces, Digest::SHA::sha1( $data );
    }
    return @pieces;
}

sub compute_hash {
    my $self = shift;
    my $metadata = $self->create_metadata;
    my $hash = Bitq::Bencode::bencode( $metadata );
    $self->info_hash_raw( $hash );
    return $hash;
}

sub create_from_file {
    my ($class, $file, @args) = @_;

    require File::Basename;
    my $file_abs = Cwd::abs_path( $file );
    my $dir = File::Basename::dirname( $file_abs );
    my $t = $class->new(
        name  => File::Basename::basename( $file_abs ),
        @args,
        files     => [ File::Basename::basename( $file_abs ) ],
        source    => $file_abs,
        parent_dir => $dir,
        completed => 1,
    );
    $t->compute_hash;

    return $t;
}

sub create_from_dir {
    my ($class, $dir, @args) = @_;

    $dir = Cwd::abs_path($dir);

    my @files;
    require File::Find;
    File::Find::find(sub {
        if (-l $_ || -f _) {
            push @files, $_;
        }
    }, $dir);

    my $t = $class->new(
        @args,
        files => \@files,
        dir   => $dir,
    );

    return $t;
}

sub load_torrent {
    my ($class, $file) = @_;

    open my $fh, '<', $file or die "Could not open file $file for writing: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    my $hash = Bitq::Bencode::bdecode( $content );

    my @files;
    if ( exists $hash->{info}->{files} ) {
        @files = @{ $hash->{info}->{files} };
    } else {
        @files = ( $hash->{info} );
    }

    my @fileinfo;
    my $total_size = 0;
    foreach my $file ( @files ) {
        push @fileinfo, {
            length => $file->{length},
            name   => $file->{name},
        };
        $total_size  += $file->{length};
    }

    my @pieces;
    {
        my $pieces = $hash->{info}->{pieces};
        my $length = bytes::length($pieces);
        my $offset = 0;
        while ( $length - $offset > 0 ) {
            push @pieces, {
                hash => substr $pieces, $offset, 20,
            };
            $offset += 20;
        }
    }
    $class->new(
        name     => "DUMMY",
        announce => $hash->{announce},
        info_hash_raw => $content,
        total_size    => $total_size,
        piece_count   => scalar @pieces,
        piece_length  => $hash->{info}->{"piece length"},
        pieces        => \@pieces,
        files         => [ map { $_->{name} } @files ],
        fileinfo      => \@fileinfo,
    );
}

sub write_torrent {
    my ($self, $file) = @_;

    open my $fh, '>',  $file or die "Could not open file $file for writing: $!";
    print $fh $self->info_hash_raw;
    close $fh;
}

sub calc_bitfield {
    my ($self, $work_dir) = @_;

    my $metadata = Bitq::Bencode::bdecode($self->info_hash_raw);
use Data::Dumper::Concise;
warn Dumper($metadata);
    my $length   = $metadata->{info}->{length};
    my $p_length = $metadata->{info}->{"piece length"};
    my $p_count  = int($length / $p_length) + 1;
    my $vec      = Bit::Vector->new( $p_count );

    if ( $self->completed ) {
        $vec->Fill;
        $self->bitfield( $vec );
        return $vec;
    }

    my $destfile = File::Spec->catfile( $work_dir, $self->info_hash );
    my $fh;
    if (! -f $destfile) {
        $vec->Empty();
        $self->bitfield( $vec );
        return $vec;
    }

    open $fh, '<', $destfile
        or die "Could not open $destfile: $!";

    my $pieces   = $metadata->{info}->{pieces};
    my $h_length = bytes::length($pieces);
    my $h_offset = 0;
    my $p_offset = 0;
    my $v_offset = 0;
    while ( $h_offset < $h_length ) {
        my $hash = substr $pieces, $h_offset, 20;
        $h_offset += 20;
        $v_offset++;
        infof " + bitfield (%d)", $v_offset;

        my $this_piece;
        my $n_read = read $fh, $this_piece, $p_length;
        infof " + bitfield (%d): read %d bytes", $v_offset, $n_read;
        if ($n_read) {
            my $this_hash = Digest::SHA::sha1( $this_piece );
            if ( $this_hash eq $hash ) {
                infof " + bitfield (%d): hash matches", $v_offset;
                $vec->Bit_On( $v_offset - 1 );
            } else {
                infof " + bitfield (%d): hash did not match...", $v_offset;
            }
        }
    }

    $self->bitfield( $vec );

    return $vec;
}

sub unpack_completed {
    my ($self, $file, $dest_dir) = @_;

    my @fileinfos = @{ $self->fileinfo };
    open my $fh, '<', $file or
        die "Could not open file $file: $!";

    foreach my $fileinfo ( @fileinfos ) {
        my $buf;
        my $length = $fileinfo->{length};
        my $bufsiz = 8192;

        my $dest = File::Spec->catfile($dest_dir, $fileinfo->{name});
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
        infof "Wrote to %s", $dest;
    }
}

1;

__END__

=head1 NAME

Bitq::Torrent - A Torrent File

=head1 SYNOPSIS

    my $t = Bitq::Torrent->create_from_dir(
        "/path/to/dir",
        name         => ...,
    );
    my $hash = $t->compute_hash;

=cut