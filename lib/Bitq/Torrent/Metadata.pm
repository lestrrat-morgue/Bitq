package Bitq::Torrent::Metadata;
use Mouse;
use Bitq::Bencode ();
use Digest::SHA   ();

has encoded_value => (
    is => 'ro',
    lazy => 1,
    default => sub {
        return Bitq::Bencode::bencode( $_[0]->unpacked );
    }
);

has info_hash => (
    is => 'ro',
    lazy => 1,
    default => sub {
        Digest::SHA::sha1_hex( Bitq::Bencode::bencode( $_[0]->unpacked->{info} ) )
    }
);

has unpacked => (
    is => 'ro',
    required => 1,
);

has is_single_file => (
    is => 'ro',
    isa => 'Bool',
    lazy => 1,
    default => sub { 
        my $data = $_[0]->unpacked;
        exists $data->{info}->{length} ? 1 :
        exists $data->{info}->{files}  ? 0 :
            Carp::croak( "Cannot find torent file mode: Corrupt metadata?" )
    },
);

has total_size => (
    is => 'ro',
    lazy => 1,
    builder => sub {
        if ( $_[0]->is_single_file ) {
            return $_[0]->unpacked->{info}->{length};
        } else {
            my $length = 0;
            foreach my $file ( @{ $_[0]->unpacked->{info}->{files} } ) {
                $length += $file->{length};
            }
            return $length;
        }
    }
);

has piece_count => (
    is => 'ro',
    lazy => 1,
    builder => sub {
        require bytes;
        bytes::length( $_[0]->pieces ) / 20;
    }
);

has files => (
    is => 'ro',
    lazy => 1,
    builder => sub {
        my $unpacked = $_[0]->unpacked;
        if ($_[0]->is_single_file) {
            return [ {
                length => $unpacked->{info}->{length},
                path   => [ $unpacked->{info}->{name} ]
            } ]
        } else {
            return $unpacked->{info}->{files}
        }
    }
);

sub pieces       { $_[0]->unpacked->{info}->{pieces} }
sub piece_length { $_[0]->unpacked->{info}->{"piece length"} }
sub name         { $_[0]->unpacked->{info}->{name} }
sub hash_at      { substr $_[0]->unpacked->{info}->{pieces}, $_[1] * 20, 20 }
sub announce     { $_[0]->unpacked->{announce} }

no Mouse;

1;

__END__

=head1 DESCRIPTION

Bitq::Torrent::Metadata represents data that can be represented in a .torrent file. It is immutable.

=cut