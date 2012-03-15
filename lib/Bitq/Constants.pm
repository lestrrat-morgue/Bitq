package Bitq::Constants;
use strict;
use Exporter 'import';

my %constants;
BEGIN {
    %constants = (
        packet => {
            PKT_TYPE_CHOKE          => 0x00, # no payload
            PKT_TYPE_UNCHOKE        => 0x01, # no payload
            PKT_TYPE_INTERESTED     => 0x02, # no payload
            PKT_TYPE_NOT_INTERESTED => 0x03, # no payload
            PKT_TYPE_HAVE           => 0x04,
            PKT_TYPE_BITFIELD       => 0x05,
            PKT_TYPE_REQUEST        => 0x06,
            PKT_TYPE_PIECE          => 0x07,
            PKT_TYPE_CANCEL         => 0x08,
        }
    );
}

use constant +{
    map { %$_ } values %constants
};

our %EXPORT_TAGS = (
    map { ($_ => [ keys %{$constants{$_}} ] ) } keys %constants
);
our @EXPORT_OK = (
    map { @$_ } values %EXPORT_TAGS
);

1;