package t::Util;
use strict;
use Exporter 'import';
use Mouse::Meta::Class;
use Log::Minimal ();

our @EXPORT_OK = qw(
    anon_object
);

BEGIN {
    if ($ENV{HARNESS_ACTIVE}) {
        if (! $ENV{ HARNESS_IS_VERBOSE } ) {
            $Log::Minimal::LOG_LEVEL = "NONE";
            if ($ENV{ LM_COLOR }) {
                $Log::Minimal::COLOR = 1;
            }
        }
    }

    if (! exists $ENV{PLACK_ENV}) {
        $ENV{PLACK_ENV} = "test";
    }
}

sub anon_object {
    my @args = @_;
    my $meta = Mouse::Meta::Class->create_anon_class(
        cache        => 1,
        @args,
    );
    my $object = $meta->new_object;
    return $object;
}

1;
