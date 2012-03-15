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
use Bitq::Torrent::Leeching;
use Bitq::Torrent::Seed;

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
    my ($files, $piece_length) = @_;

    my $data   = '';
    my @pieces;
    while ( my $file = shift @$files ) {
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
    my ($class, $file, %args) = @_;

    require File::Basename;
    my $file_abs = Cwd::abs_path( $file );
    my $basename = File::Basename::basename( $file_abs );
    my $dir      = File::Basename::dirname( $file_abs );

    my $piece_length  = $args{piece_length} || 2 ** 18;
    my $name          = $args{name}         || $basename;
    my $private       = $args{private};
    my $announce      = $args{announce};
    my $announce_list = $args{announce_list};
    my $comment       = $args{comment};

    my %data = (
        info => {
            'piece length'  => $piece_length,
            'name'          => $name,
            'length'        => -s $file_abs,
        },
        'creation date' => time,
        'created by'    => 'Bitq::Torrent/Perl',
    );

    if ($private) {
        $data{info}->{private} = 1;
    }
    if ($announce) {
        $data{announce} = $announce;
    }
    if ($announce_list && scalar @$announce_list > 0 ) {
        $data{'announce-list'} = $announce_list;
    }
    if ($comment) {
        $data{comment} = $comment;
    }

    my @pieces = generate_pieces([ $file_abs ], $piece_length);
    $data{info}->{pieces} = join '', @pieces;

    my $t = Bitq::Torrent::Seed->new(
        # This is where the actual file exists
        source_dir => $dir,
        metadata => Bitq::Torrent::Metadata->new(unpacked => \%data),
    );

    return $t;
}

sub create_from_dir {
    my ($class, $dir, @args) = @_;

#        $data{info}->{name}  = $self->dir;
#        $data{info}->{files} = [ $self->generate_fileinfo ];

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

    open my $fh, '<', $file or die "Could not open file $file for reading: $!";
    my $data = do { local $/; <$fh> };
    close $fh;

    Bitq::Torrent::Leeching->new(
        metadata => Bitq::Torrent::Metadata->new(
            unpacked => Bitq::Bencode::bdecode($data)
        ),
    );
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