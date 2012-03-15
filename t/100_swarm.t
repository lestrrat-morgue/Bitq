use strict;
use t::Util;
use Test::More;
use Test::TCP;
use File::Basename ();
use File::Copy();
use File::Spec;
use File::Temp;
use LWP::UserAgent;
use URI;

use_ok "Bitq";

sub new_tempdir {
    File::Temp::tempdir( "net-bittorent-XXXXXX", CLEANUP => 1, TMPDIR => 1 );
}

my $dir = new_tempdir();
my $target_file = File::Spec->catfile( $dir, "100_swarm.dat" );
{
    open my $fh, '>', $target_file or die "Could not open $target_file: $!";
    for (1..10_000) {
        print $fh "0123456789";
    }
    close $fh;
}


my $torrent = Bitq::Torrent->create_from_file(
    $target_file,
    piece_length => 512,
    announce     => 'http://127.0.0.1:13209/announce.pl',
);

$torrent->write_torrent( "test.torrent" );

my $master = Test::TCP->new( code => sub {
    my $port = shift;
    my $master = Bitq->new(
        port => $port,
        peer_id => "swarm-master12345678",
        work_dir => $dir,
    );
    $master->start_tracker();
    $master->add_torrent( $torrent );
    my $cv = $master->start;

    eval {
        $cv->recv;
    };
    if ($@) {
        diag "Error in master: $@";
    }

} );

note "Starting leechers";
my @dirs;
my %peers;
foreach my $i ( 1..2 ) {
    note "Starting leecher $i";
    my $dir = new_tempdir();

    ok ! -f File::Spec->catfile($dir, "100_swarm.dat"), "Downloaded file does not exist";
    push @dirs, $dir;
    $peers{ $dir } = Test::TCP->new( code => sub {
        my $port = shift;
        my $torrent = Bitq::Torrent->load_torrent( "test.torrent" );

        my $client = Bitq->new(
            port => $port,
            peer_id => sprintf("swarm-client%08d", $i),
            work_dir => $dir,
        );
        $client->add_torrent( $torrent );
        my $cv = $client->start;
        $cv->recv;
    } );
}

diag "Wait";
# wait until files are downloaded
{
    local $SIG{ALRM} = sub { die "TiMeOuT" };
    my $found = 0;
    eval {
        alarm(10);
        CHECK: {
            $found = 0;
            foreach my $dir ( @dirs ) {
                my $path = File::Spec->catfile($_, "100_swarm.t");
                if (-f $path) {
                    delete $peers{ $dir };
diag explain \%peers;
                    $found++;
                }
            }
            if ( $found != @dirs ) {
                redo CHECK;
            }
        }
    };
    if ($@) {
        fail "Error before getting files: $@";
    } else {
        is $found, scalar @dirs, "Found all files";
    }
    alarm(0);
}

diag "Cleanup";

undef $master;
undef @dirs;

done_testing;