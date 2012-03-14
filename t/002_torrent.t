use strict;
use Test::More;
use File::Temp;

use_ok "Bitq::Torrent";
use_ok "Bitq::Bencode";

my $torrent = Bitq::Torrent->create_from_file( __FILE__, piece_length => 100 );
ok $torrent, "torrent object created";

my $torrent_file = File::Temp->new(
    TEMPLATE => "net-bittorrent-XXXXXX",
    UNLINK   => 1,
);
$torrent->write_torrent( $torrent_file->filename );

{
    $torrent_file->seek(0, 0);
    my $encoded;
    read $torrent_file, $encoded, -s $torrent_file;
    my $data = Bitq::Bencode::bdecode($encoded);

    is $data->{info}->{length}, $torrent->total_size, "sizes match";
    is $data->{info}->{'piece length'}, $torrent->piece_length, "piece length match";

    open my $fh, '<', __FILE__
        or die "Failed to open this test file for reading: $!";

    my $buf;
    my $pieces = $data->{info}->{pieces};
    note explain $pieces;
    for my $i ( 1.. ( (-s $fh) / $torrent->piece_length) + 1) {
        my $read = read $fh, $buf, $torrent->piece_length;
        if( ok defined $read, "read ok $i") {
            if ( $read ) {
                my $got = substr $pieces, 20 * ($i - 1), 20;
                is Digest::SHA::sha1($buf), $got, "sha1 piece ($i) hash matches";
            }
        }
    }
}

done_testing;