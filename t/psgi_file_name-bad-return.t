use strict;
use warnings;
use Path::Tiny;
use lib path (__FILE__)->parent->parent->child ('t_deps/lib')->stringify;
use Tests;

my $TestDataPath = path (__FILE__)->parent->parent->child ('t_deps/data');

test {
  my $c = shift;
  my $host = '127.0.0.1';
  my $port1 = find_listenable_port;

  my $url1 = Web::URL->parse_string (qq<http://$host:$port1>);
  my $client1 = Web::Transport::ConnectionClient->new_from_url ($url1);

  my $server;
  promised_cleanup {
    return Promise->all ([
      (defined $server ? $server->stop : undef),
      $client1->close,
    ])->then (sub { done $c; undef $c });
  } Sarze->start (
    hostports => [
      [$host, $port1],
    ],
    psgi_file_name => $TestDataPath->child ('psgi_file_name-4.psgi'),
  )->then (sub {
    $server = $_[0];
    test {
      ok 0;
    } $c;
  }, sub {
    my $error = $_[0];
    test {
      like $error, qr{CODE is not returned.+psgi_file_name-4.psgi}, $error;
    } $c;
  })->then (sub {
    return $client1->request (path => []);
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->is_network_error;
    } $c;
  });
} n => 2, name => 'psgi file does not return a CODE';

test {
  my $c = shift;
  my $host = '127.0.0.1';
  my $port1 = find_listenable_port;

  my $url1 = Web::URL->parse_string (qq<http://$host:$port1>);
  my $client1 = Web::Transport::ConnectionClient->new_from_url ($url1);

  my $server;
  promised_cleanup {
    return Promise->all ([
      (defined $server ? $server->stop : undef),
      $client1->close,
    ])->then (sub { done $c; undef $c });
  } Sarze->start (
    hostports => [
      [$host, $port1],
    ],
    psgi_file_name => $TestDataPath->child ('psgi_file_name-5.psgi'),
  )->then (sub {
    $server = $_[0];
    test {
      ok 0;
    } $c;
  }, sub {
    my $error = $_[0];
    test {
      like $error, qr{CODE is not returned.+psgi_file_name-5.psgi}, $error;
    } $c;
  })->then (sub {
    return $client1->request (path => []);
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->is_network_error;
    } $c;
  });
} n => 2, name => 'psgi file does not return a CODE';

run_tests;

=head1 LICENSE

Copyright 2016-2022 Wakaba <wakaba@suikawiki.org>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
