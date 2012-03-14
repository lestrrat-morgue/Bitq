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

my $torrent = Bitq::Torrent->create_from_file(__FILE__,
    piece_length => 100,
    announce     => 'http://127.0.0.1:13209/announce.pl',
);
my $dir = new_tempdir();
my $dest = File::Spec->catfile( $dir, "completed", File::Basename::basename( __FILE__ ) );
my $source = __FILE__;

diag "Copying $source to $dest";
File::Path::make_path( File::Basename::dirname( $dest ) ) ;
File::Copy::copy($source, $dest) or die "Could not copy";

my $master = Test::TCP->new(code => sub {
    my $port = shift;
    diag "master is $$ on $port";
    my $master = Bitq->new(
        port => $port,
        peer_id => "swarm-master",
        work_dir => $dir,
    );
    eval {
        $master->start_tracker();
        $master->add_torrent( $torrent );
        my $cv = $master->start;
        $cv->recv;
    };
    if ($@) {
        diag "Master failed: $@";
    }
    diag "Master exiting";
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
    my $work_dir = new_tempdir();
    push @dirs, $work_dir,
    push @peers, Test::TCP->new(code => sub {
        my $port = shift;
        diag "peer $i is $$";
        my $client = Bitq->new(
            port => $port,
            peer_id => "swarm-$i",
            work_dir => $work_dir,
        );
        eval {
            $client->add_torrent( $torrent );
            my $cv = $client->start;
            $cv->recv;
        };
        if ($@) {
            diag "Error in swarm $i: $@";
        }
        diag "swarm $i exiting";
    });
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