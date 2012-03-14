package Bitq::Tracker;
use Mouse;
use DBI;
use SQL::Maker;
use Log::Minimal;
use Bitq::Protocol::BEP23 qw(compact_ipv4);

has app => (
    is => 'ro',
    required => 1,
);

has store => (
    is => 'ro',
    required => 1,
);

sub announce {
    my ($self, $args) = @_;

    my $compact    = $args->{compact};
    my $address    = $args->{address};
    my $event      = $args->{event};
    my $hash_key   = $args->{hash_key};
    my $info_hash  = $args->{info_hash};
    my $key        = $args->{key};
    my $max_peers  = $args->{max_peers} || 50;
    my $peer_id    = $args->{peer_id};
    my $port       = $args->{port};
    my $tracker_id = $args->{tracker_id};

    if ($peer_id eq $self->app->peer_id ) {
        infof "Received our peer ID in announce. Ignoring...";
        return { };
    } 

    if ($event eq 'started') {
        $self->store->record_started( {
            tracker_id => $tracker_id,
            info_hash  => $info_hash,
            peer_id    => $peer_id,
            address    => $address,
            port       => $port,
            downloaded => 0,
            uploaded   => 0,
        } );
    } elsif ($event eq 'stopped') {
#        my ($sql, @binds) = $self->_sql_maker->delete( peers => { hash => $hash_key } );
#        $dbh->do( $sql, undef, @binds );
    } elsif ($event eq 'completed') {
        $self->store->record_completed( $info_hash );
    }

    my %body = (
        'min interval' => 60 * 5,
        'interval'     => 60 * 10,
        'tracker id'   => $tracker_id
    );

    my $peers = [
        grep { $_->{peer_id} ne $peer_id }
            @{ $self->store->load_peers_for( $info_hash, $max_peers ) }
    ];

    if ($compact) {
        $body{peers} = compact_ipv4( @$peers );
    } else {
        $body{peers} = [
            map {
                +{
                    peer_id => $_->{peer_id},
                    ip      => $_->{address},
                    port    => $_->{port},
                }
            } @$peers
        ];
    }
    return \%body;
}
    
no Mouse;

1;
