use strict;
use warnings;
use Path::Tiny;
use lib path (__FILE__)->parent->parent->child ('t_deps/lib')->stringify;
use Tests;

test {
  my $c = shift;
  my $host = '127.0.0.1';
  my $port1 = find_listenable_port;

  my $url1 = Web::URL->parse_string (qq<http://$host:$port1>);
  my $client1 = Web::Transport::BasicClient->new_from_url ($url1);

  my $temp_path = get_temp_file_path;

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
    worker_state_params => {
      temp_path => '' . $temp_path,
    },
    max_worker_count => 1,
    max_counts => {custom => 1},
    eval => q{
      use Data::Dumper;

      sub main::psgi_app {
        return [200, [], [Dumper $_[0]->{'manakai.server.state'}->features]];
      }

      package Worker;
      use Promise;
      use Promised::Flow;
      use Data::Dumper;
      sub start {
        my ($class, %args) = @_;
        my ($r, $s) = promised_cv;
        $args{signal}->manakai_onabort (sub {
          return promised_sleep (1)->then (sub {
            $s->();
          });
        });

        return Promise->resolve ([(bless {
          params => $args{params},
        }, $class), $r]);
      }
      sub custom ($$) {
        my ($class, $state) = @_;

        my $temp_path = $state->{data}->{params}->{temp_path};
        open my $temp_file, '>>', $temp_path or die "$0: $temp_path: $!";
        print $temp_file Dumper {
          class => $class,
          state_class => ref $state,
          features => $state->features,
        };
        close $temp_file;

      } # custom
      sub DESTROY ($) {
        local $@;
        eval { die };
        warn "Reference to @{[ref $_[0]]} is not discarded before global destruction\n"
            if $@ =~ /during global destruction/;
      } # DESTROY
    },
  )->then (sub {
    $server = $_[0];
    return Promise->all ([
      $client1->request (path => [], headers => {
      }),
    ])->then (sub {
      my ($res1) = @{$_[0]};
      test {
        like $res1->body_bytes, qr{^\s*\$VAR1\s*=\s*\{[^;\$]+\};\s*$};
        no strict;
        my $rdata = eval $res1->body_bytes;
        die $@ if $@;
        ok $rdata->{http};
        ok ! $rdata->{custom};
      } $c;
      return $server->stop;
    })->then (sub {
      test {
        my $temp = $temp_path->slurp;
        like $temp, qr{^\s*\$VAR1\s*=\s*\{[^;\$]+\};\s*$};
        no strict;
        my $cdata = eval $temp;
        die $@ if $@;
        is $cdata->{class}, 'Worker';
        is $cdata->{state_class}, 'Sarze::Worker::State';
        ok ! $cdata->{feature}->{http};
        ok $cdata->{features}->{custom};
      } $c;
    });
  });
} n => 8, name => 'has a class';

test {
  my $c = shift;
  my $host = '127.0.0.1';
  my $port1 = find_listenable_port;

  my $url1 = Web::URL->parse_string (qq<http://$host:$port1>);
  my $client1 = Web::Transport::BasicClient->new_from_url ($url1);

  my $temp_path = get_temp_file_path;

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
    worker_state_params => {
      temp_path => '' . $temp_path,
    },
    max_worker_count => 1,
    max_counts => {custom => 1},
    eval => q{
      use Data::Dumper;

      sub main::psgi_app {
        return [200, [], [Dumper $_[0]->{'manakai.server.state'}->features]];
      }

      package Worker;
      use Promise;
      use Promised::Flow;
      use Data::Dumper;
      sub start {
        my ($class, %args) = @_;
        my ($r, $s) = promised_cv;
        $args{signal}->manakai_onabort (sub {
          return promised_sleep (1)->then (sub {
            $s->();
          });
        });

        return Promise->resolve ([(bless {
          params => $args{params},
        }, $class), $r]);
      }
      sub custom ($$) {
        my ($class, $state) = @_;

        my $temp_path = $state->{data}->{params}->{temp_path};
        open my $temp_file, '>>', $temp_path or die "$0: $temp_path: $!";
        print $temp_file Dumper {
          class => $class,
          state_class => ref $state,
          features => $state->features,
        };
        close $temp_file;

        die "abc error";
      } # custom
      sub DESTROY ($) {
        local $@;
        eval { die };
        warn "Reference to @{[ref $_[0]]} is not discarded before global destruction\n"
            if $@ =~ /during global destruction/;
      } # DESTROY
    },
  )->then (sub {
    $server = $_[0];
    return promised_sleep (3)->then (sub {
      return Promise->all ([
        $client1->request (path => [], headers => {
        }),
      ]);
    })->then (sub {
      my ($res1) = @{$_[0]};
      test {
        like $res1->body_bytes, qr{^\s*\$VAR1\s*=\s*\{[^;\$]+\};\s*$};
        no strict;
        my $rdata = eval $res1->body_bytes;
        die $@ if $@;
        ok $rdata->{http};
        ok ! $rdata->{custom};
      } $c;
      return $server->stop;
    })->then (sub {
      test {
        my $temp = $temp_path->slurp;
        like $temp, qr{^\s*\$VAR1\s*=\s*\{[^;\$]+\};\s*}; # +
        no strict;
        my $cdata = eval $temp;
        die $@ if $@;
        is $cdata->{class}, 'Worker';
        is $cdata->{state_class}, 'Sarze::Worker::State';
        ok ! $cdata->{feature}->{http};
        ok $cdata->{features}->{custom};
      } $c;
    });
  });
} n => 8, name => 'custom throws';

test {
  my $c = shift;
  my $host = '127.0.0.1';
  my $port1 = find_listenable_port;

  my $url1 = Web::URL->parse_string (qq<http://$host:$port1>);
  Sarze->start (
    hostports => [
      [$host, $port1],
    ],
    worker_state_class => 'Worker',
    max_worker_count => 1,
    max_counts => {custom => 1},
    eval => q{
      use Data::Dumper;

      sub main::psgi_app {
        return [200, [], [Dumper $_[0]->{'manakai.server.state'}->features]];
      }

      package Worker;
      use Promise;
      use Promised::Flow;
      use Data::Dumper;
      sub start {
        my ($class, %args) = @_;
        my ($r, $s) = promised_cv;
        $args{signal}->manakai_onabort (sub {
          return promised_sleep (1)->then (sub {
            $s->();
          });
        });

        return Promise->resolve ([(bless {
          params => $args{params},
        }, $class), $r]);
      }
      sub DESTROY ($) {
        local $@;
        eval { die };
        warn "Reference to @{[ref $_[0]]} is not discarded before global destruction\n"
            if $@ =~ /during global destruction/;
      } # DESTROY
    },
  )->then (sub {
    my $server = $_[0];
    test {
      ok 0, $server;
    } $c;
  }, sub {
    my $e = $_[0];
    test {
      like $e, qr{^Sarze: \d+: Failed to initiate a worker: Worker->custom is not defined at Sarze eval \([^()]+\)$}, $e;
    } $c;
  })->finally (sub {
    done $c; undef $c;
  });
} n => 1, name => 'custom method not found';

run_tests;

=head1 LICENSE

Copyright 2016-2022 Wakaba <wakaba@suikawiki.org>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
