use inc::Module::Install;

name 'Bitq';

version '0.01';
all_from 'lib/Bitq.pm';

requires 'AnyEvent';
requires 'AnyEvent::HTTP';
requires 'AnyEvent::Handle';
requires 'AnyEvent::Socket';
requires 'DBI';
requires 'Digest::MD5';
requires 'Digest::SHA';
requires 'SQL::Maker';
requires 'Mouse';
requires 'Log::Minimal';
requires 'Twiggy'; # Want to remove hard dep later...

test_requires 'Filesys::Notify::Simple';

WriteAll;