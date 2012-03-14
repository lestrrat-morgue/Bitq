package t::Util;
use strict;
use Exporter 'import';
use Mouse::Meta::Class;

our @EXPORT_OK = qw(
    anon_object
);

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
