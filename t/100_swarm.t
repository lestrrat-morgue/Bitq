use strict;
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

my $torrent = Bitq::Torrent->create_from_file(
    __FILE__,
    piece_length => 100,
    announce     => 'http://127.0.0.1:13209/announce.pl',
);

{
    my $dest = File::Spec->catfile( $dir, "completed", File::Basename::basename( __FILE__ ) );
    my $source = __FILE__;

    diag "Copying $source to $dest";
    File::Path::make_path( File::Basename::dirname( $dest ) ) ;
    File::Copy::copy($source, $dest) or die "Could not copy";
    $torrent->write_torrent( "test.torrent" );
}

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
    $cv->recv;
} );

subtest 'check tracker sanity' => sub {
    my $url = URI->new(sprintf "http://127.0.0.1:13209/announce.pl", $master->port);
    $url->query_form( {
        info_hash => 'DUMMY',
        peer_id => 'DUMMY',
        key => 'DUMMY',
    } );
    my $ua = LWP::UserAgent->new;
    my $res = $ua->get( $url );
    if (! ok $res->is_success(), "GET tracker url is successful") {
        diag $res->as_string;
    }
};

diag "Starting leechers";
my @dirs;
my @peers;
foreach my $i ( 1..2 ) {
    my $dir = new_tempdir();
    push @dirs, $dir;
    push @peers, Test::TCP->new( code => sub {
        my $port = shift;
        my $torrent = Bitq::Torrent->load_torrent( "test.torrent" );

        my $client = Bitq->new(
            port => $port,
            peer_id => sprintf("swarm-client%08", $i),
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
    eval {
        a_larm(10);
        CHECK: {
            my $found = 0;
            foreach my $path ( map { "$_/completed/t/100_swarm.t" } @dirs ) {
                if (-f $path) {
                    $found++;
                }
            }
            if ( $found != @peers ) {
                redo CHECK;
            }
        }
    };
    alarm(0);
}

diag "Cleanup";

undef $master;
undef @peers;

done_testing;