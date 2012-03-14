use inc::Module::Install;

name 'Bitq';

version '0.01';
all_from 'lib/Bitq.pm';

requires 'AnyEvent';
requires 'AnyEvent::HTTP';
requires 'AnyEvent::Handle';
requires 'AnyEvent::Socket';
requires 'DBI';
requires 'SQL::Maker';
requires 'Mouse';
requires 'Log::Minimal';

WriteAll;