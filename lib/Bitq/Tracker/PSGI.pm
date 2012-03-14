package Bitq::Tracker::PSGI;
use Mouse;
use Log::Minimal;
use Bitq::Bencode qw(bencode);
use Plack::Request;
use Twiggy::Server;

extends 'Bitq::Tracker';

has httpd => (
    is => 'rw'
);

has url => (
    is => 'rw',
);

has port => (
    is => 'ro',
    default => '13209',
);

my %actions = (
    '/announce.pl' => 'announce',
    '/scrape.pl'  => 'scrape',
);

sub start {
    my $self = shift;
    my $server = Twiggy::Server->new(
        host => '127.0.0.1',
        port => $self->port,
    );
    $server->register_service( $self->to_app );
    $self->httpd( $server );
    $self->url( sprintf "http://127.0.0.1:%d/announce.pl", $self->port );
}

sub to_app {
    my $self = shift;

    my $app =  sub {
        my $env = shift;
        my $callback = $actions{ $env->{PATH_INFO} };
        if (! $callback) {
            return [ 404, [ "Content-Type" => "text/plain" ], [ "Not Found" ] ];
        }

        $self->$callback( $env );
    };

    # XXX should be only on devel-ish env
    foreach my $middleware ( qw( Lint StackTrace AccessLog ) ) {
        my $klass = "Plack::Middleware::$middleware";
        Mouse::Util::load_class( $klass );
        $app = $klass->wrap( $app );
    }

    return $app;
}

around announce => sub {
    my ($next, $self, $env) = @_;

infof "In PSGI::announce";

    my $req = Plack::Request->new($env);

    my $info_hash = $req->param('info_hash');
    my $key       = $req->param('key');
    my $peer_id   = $req->param('peer_id');
    my $event     = $req->param('event');

    if ( ! $info_hash || ! $key || ! $peer_id ) {
        infof( "Malformed request [ info_hash = %s, key = %s, peer_id = %s ]",
            $info_hash || '(null)',
            $key       || '(null)',
            $peer_id   || '(null)',
        );

        return [ 400, [ "Content-Type" => "text/plain" ], [ "Malformed request" ] ];
    }

    my $hash_key  = pack 'H*', $key ^ $info_hash ^ pack 'B*', $peer_id;
    my $tracker_id =
        $req->param('trackerid') ||
        $req->param('tracker id') ||
        pack( 'H*', int rand time )
    ;
    my $max_peers  = $req->param('max_peers') || 50;
    my $psgix_io = $req->env->{'psgix.io'};
    my $peer_port = $req->param('port');
infof "Callinig Tracker::announce";
    my $rv = $self->$next({
        address    => $req->address || undef,
        compact    => $req->param('compact') || 0,
        event      => $event,
        hash_key   => $hash_key,
        info_hash  => $info_hash,
        key        => $key,
        max_peers  => $max_peers,
        peer_id    => $peer_id,
        port       => $peer_port,
        tracker_id => $tracker_id,
    });

    return [200, [ 'Content-Type' => 'text/plain' ],[ bencode $rv ] ];
};

sub scrape {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);

    my $dbh = $self->dbh();
    my %ret;
    foreach my $info_hash ( $req->param('info_hash') ) {
        my $list = $dbh->selectall_arrayref( <<EOM, { Slice => {} }, $info_hash );
            SELECT complete, downloaded, incomplete, name from files
                WHERE info_hash = ?
EOM
        $ret{$info_hash} = $list;
    }

    return [200, [ 'Content-Type' => 'text/plain' ],  [ bencode \%ret ] ];
}

no Mouse;

1;

