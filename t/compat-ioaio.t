use strict;
use warnings;
use Path::Tiny;
use lib path (__FILE__)->parent->parent->child ('t_deps/lib')->stringify;
BEGIN { $ENV{TEST_MAX_CONCUR} = 1 }
use Tests;

test {
  my $c = shift;
  my $host = '127.0.0.1';
  my $port1 = find_listenable_port;

  my $url1 = Web::URL->parse_string (qq<http://$host:$port1>);
  my $client1 = Web::Transport::BasicClient->new_from_url ($url1);

  local $AnyEvent::Fork::TEMPLATE;
  local $ENV{PERL_ANYEVENT_IO_MODEL};

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
    worker_state_class => 'Worker',
    eval => (sprintf q{
      package Worker;
      use Promise;
      use Promised::Flow;
      use AnyEvent::IO;

      my $file_name = q{%s};
      sub invoke ($) {
        AnyEvent::IO::aio_stat ($file_name, $_[0]);
      }

      sub main::psgi_app {
        return [200, [], [$AnyEvent::IO::MODEL]];
      }

      invoke (sub { });

      sub start {
        my ($class) = @_;
        my ($r, $s) = promised_cv;
        invoke ($s);
        return Promise->resolve ([(bless {}, $class), $r]);
      }
    }, __FILE__),
  )->then (sub {
    $server = $_[0];
    return Promise->all ([
      $client1->request (path => [], headers => {
      }),
    ])->then (sub {
      my ($res1) = @{$_[0]};
      test {
        is $res1->body_bytes, "AnyEvent::IO::IOAIO";
      } $c;
      return $server->stop;
    });
  });
} n => 1, name => 'IO::AIO used';

test {
  my $c = shift;
  my $host = '127.0.0.1';
  my $port1 = find_listenable_port;

  my $url1 = Web::URL->parse_string (qq<http://$host:$port1>);
  my $client1 = Web::Transport::BasicClient->new_from_url ($url1);

  local $AnyEvent::Fork::TEMPLATE;
  local $ENV{PERL_ANYEVENT_IO_MODEL} = 'Perl';

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
    worker_state_class => 'Worker2',
    eval => (sprintf q{
      package Worker2;
      use Promise;
      use Promised::Flow;
      use AnyEvent::IO;

      my $file_name = q{%s};
      sub invoke ($) {
        AnyEvent::IO::aio_stat ($file_name, $_[0]);
      }

      sub main::psgi_app {
        return [200, [], [$AnyEvent::IO::MODEL]];
      }

      invoke (sub { });

      sub start {
        my ($class) = @_;
        my ($r, $s) = promised_cv;
        invoke ($s);
        return Promise->resolve ([(bless {}, $class), $r]);
      }
    }, __FILE__),
  )->then (sub {
    $server = $_[0];
    return Promise->all ([
      $client1->request (path => [], headers => {
      }),
    ])->then (sub {
      my ($res1) = @{$_[0]};
      test {
        is $res1->body_bytes, "AnyEvent::IO::Perl";
      } $c;
      return $server->stop;
    });
  });
} n => 1, name => 'AnyEvent::IO::Perl is used';

run_tests;

=head1 LICENSE

Copyright 2024 Wakaba <wakaba@suikawiki.org>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
