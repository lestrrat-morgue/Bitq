package Bitq::Client;
use Mouse;
use Bitq;

has peer_id => (
    is => 'ro',
    lazy => 1,
    builder => '_build_peer_id',
);

sub _build_peer_id {
    return pack(
        'a20',
        (sprintf(
             'NB%s-%8s%-5s',
             $Bitq::MONIKER,
             (join '',
              map {
                  ['A' .. 'Z', 'a' .. 'z', 0 .. 9, qw[- . _ ~]]
                  ->[rand(66)]
                  } 1 .. 8
             ),
             [qw[KaiLi April]]->[rand 2]
         )
        )
    );
}

1;