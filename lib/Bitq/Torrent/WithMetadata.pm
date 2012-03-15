package Bitq::Torrent::WithMetadata;
use Mouse::Role;
use Bitq::Torrent::Metadata;

has metadata => (
    is => 'rw',
    lazy => 1,
    builder => \&create_metadata,
    trigger => sub {
        $_[0]->clear_bitfield();
    },
    handles => [ qw(
        announce
        files
        info_hash
        name
        piece_count
        piece_length
        total_size
    ) ]
);

no Mouse::Role;

1;
