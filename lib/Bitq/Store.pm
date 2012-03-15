package Bitq::Store;
use Mouse;
use Log::Minimal;
use feature 'state';

has app => (
    is => 'ro',
    required => 1,
);

has dbfile => (
    is => 'ro',
    required => 1,
    lazy => 1,
    default => sub {
        my $self = shift;
        return File::Spec->catfile($self->app->work_dir, "tracker.db");
    }
);

has _sql_maker => (
    is => 'ro',
    default => sub {
        my $self = shift;
        my $dbh = $self->dbh;
        SQL::Maker->new( driver => $dbh->{Name} );
    }
);

sub BUILD {
    my ($self) = @_;
    $self->setup_database();
    return $self;
}

sub setup_database {
    my $self = shift;
    state $stmts = [
        <<EOSQL,
/* peers contain known peers */
CREATE TABLE IF NOT EXISTS peers (
    peer_id    VARBINARY(20) NOT NULL PRIMARY KEY,
    address    VARCHAR(15) NOT NULL,
    port       INT NOT NULL, /*  DEFAULT 6881, */
    uploaded   INT NOT NULL DEFAULT 0,
    downloaded INT NOT NULL DEFAULT 0,
    created_on INTEGER NOT NULL
);
EOSQL
        <<EOSQL,
CREATE TABLE IF NOT EXISTS files (
    info_hash  VARBINARY(20) NOT NULL PRIMARY KEY,
    name       TEXT,
    tracker_id TEXT NOT NULL,
    complete   INT NOT NULL DEFAULT 0,
    incomplete INT NOT NULL DEFAULT 0,
    downloaded INT NOT NULL DEFAULT 0,
    created_on INTEGER NOT NULL
);
EOSQL
        <<EOSQL,
CREATE TABLE IF NOT EXISTS peers_with_file (
    peer_id    VARBINARY(20) NOT NULL,
    info_hash  VARBINARY(20) NOT NULL,
    created_on INTEGER NOT NULL,
    PRIMARY KEY (peer_id, info_hash),
    FOREIGN KEY (peer_id) REFERENCES peers (peer_id) ON DELETE CASCADE,
    FOREIGN KEY (info_hash) REFERENCES peers (info_hash) ON DELETE CASCADE
);
EOSQL
        "DELETE FROM peers",
        "DELETE FROM files",
    ];

    my $dbh = $self->dbh;
    foreach my $sql ( @$stmts ) {
        if ( $sql =~ /CREATE TABLE (?:IF NOT EXISTS) ([^\s]+)/ ) {
            infof "Creating table %s for $$", $1;
        }
        $dbh->do($sql);
    }
}

sub dbh {
    my $self = shift;
    my $dbh = DBI->connect( 'dbi:SQLite:dbname=' . $self->dbfile, undef, undef, {
        RaiseError => 1,
        AutoCommit => 1,
    });
    return $dbh;
}

sub ensure_peer_recorded {
    my ($self, $args) = @_;

    local $Log::Minimal::AUTODUMP = 1;
    infof "Recording peer %s for $$", $args;

    my $dbh = $self->dbh;
local $Log::Minimal::AUTODUMP = 1;
infof "%s", $dbh->selectall_arrayref( <<EOM, { Slice => {} });
        SELECT * FROM peers
EOM
    my ($sql, @binds) = $self->_sql_maker->insert( peers => {
        address    => $args->{address},
        port       => $args->{port},
        peer_id    => $args->{peer_id},
        uploaded   => $args->{uploaded} || 0,
        downloaded => $args->{downloaded} || 0,
        created_on => time(),
    }, { prefix => "REPLACE INTO" } );

    $dbh->do( $sql, undef, @binds );

    my $ret = $dbh->selectall_arrayref( <<EOM, { Slice => {} }, $args->{peer_id});
        SELECT * FROM peers WHERE peer_id = ?
EOM
    $ret->[0];
}

sub ensure_file_recorded {
    my ($self, $args) = @_;

    my ($sql, @binds) = $self->_sql_maker->insert( files => {
        info_hash  => $args->{info_hash} || undef,
        name       => $args->{name} || undef,
        tracker_id => $args->{tracker_id},
        complete   => 0,
        incomplete => 0,
        downloaded => 0,
        created_on => time(),
    }, { prefix => "INSERT OR IGNORE INTO" } );

    my $dbh = $self->dbh;
    $dbh->do( $sql, undef, @binds );

    my $ret = $dbh->selectall_arrayref( <<EOM, { Slice => {} }, $args->{info_hash} );
        SELECT * FROM files WHERE info_hash = ?
EOM
    $ret->[0];
}

sub ensure_peer_has_file {
    my ($self, $args, $peer, $file) = @_;

    my ($sql, @binds) = $self->_sql_maker->insert( peers_with_file => {
        peer_id    => $peer->{peer_id},
        info_hash  => $file->{info_hash},
        created_on => time(),
    }, { prefix => "REPLACE INTO" } );

    my $dbh = $self->dbh;
    $dbh->do( $sql, undef, @binds );
}

sub record_started {
    my ($self, $args) = @_;
    my $peer = $self->ensure_peer_recorded( $args );
    my $file = $self->ensure_file_recorded( $args );
    my $link = $self->ensure_peer_has_file( $args, $peer, $file );
}

sub record_completed {
    my ($self, $args) = @_;

    my $peer = $self->ensure_peer_recorded( $args );
    my $file = $self->ensure_file_recorded( $args );
    my $link = $self->ensure_peer_has_file( $args, $peer, $file );
    my ($sql, @binds) = $self->_sql_maker->update(
        'files',
        {
            complete => \'complete + 1',
        },
        {
            info_hash => $args->{info_hash},
        }
    );
    my $dbh = $self->dbh;
    $dbh->do( $sql, undef, @binds );
}

sub load_peers_for {
    my ($self, $info_hash, $max_peers) = @_;

    $max_peers ||= 50;

    my $dbh = $self->dbh;
    my $peers = $dbh->selectall_arrayref( <<EOSQL, { Slice => {} }, $info_hash );
        SELECT peers.peer_id, peers.address, peers.port
            FROM peers JOIN peers_with_file
            WHERE peers_with_file.info_hash = ?
            ORDER BY random() LIMIT $max_peers
EOSQL
    return $peers;
}

no Mouse;

1;
