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
    eval => q{
      sub main::psgi_app {
        return [200, [], ['OK!']];
      }
    },
  )->then (sub {
    $server = $_[0];
    return Promise->all ([
      $client1->request (path => []),
    ])->then (sub {
      my ($res1) = @{$_[0]};
      test {
        is $res1->status, 200;
        is $res1->body_bytes, 'OK!';
      } $c;
    });
  });
} n => 2, name => 'an eval';

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
    eval => q{
      not perl code !
    },
  )->then (sub {
    $server = $_[0];
    test {
      ok 0;
    } $c;
  }, sub {
    my $error = $_[0];
    test {
      like $error, qr{\Qat Sarze eval (@{[__FILE__]} line @{[__LINE__+9]}) line \E};
    } $c;
  })->then (sub {
    return $client1->request (path => []);
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->is_network_error;
    } $c;
  });
} n => 2, name => 'a broken eval';

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
    eval => q{use strict;
      use warnings;
      # test
      $test;
    },
  )->then (sub {
    $server = $_[0];
    test {
      ok 0;
    } $c;
  }, sub {
    my $error = $_[0];
    test {
      like $error, qr{\Qat Sarze eval (@{[__FILE__]} line @{[__LINE__+9]}) line 4\E};
    } $c;
  })->then (sub {
    return $client1->request (path => []);
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->is_network_error;
    } $c;
  });
} n => 2, name => 'a broken eval';

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
    eval => q{
      "ok";
    },
  )->then (sub {
    $server = $_[0];
    test {
      ok 0;
    } $c;
  }, sub {
    my $error = $_[0];
    test {
      like $error, qr{\QSarze eval (@{[__FILE__]} line @{[__LINE__+9]}) does not define &main::psgi_app\E};
    } $c;
  })->then (sub {
    return $client1->request (path => []);
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->is_network_error;
    } $c;
  });
} n => 2, name => 'eval does not define &main::psgi_app';

test {
  my $c = shift;
  my $host = '127.0.0.1';
  my $port1 = find_listenable_port;

  my $url1 = Web::URL->parse_string (qq<http://$host:$port1>);
  my $client1 = Web::Transport::ConnectionClient->new_from_url ($url1);

  my $server;
  my $server2;
  promised_cleanup {
    return Promise->all ([
      (defined $server ? $server->stop : undef),
      (defined $server2 ? $server2->stop : undef),
      $client1->close,
    ])->then (sub { done $c; undef $c });
  } Sarze->start (
    hostports => [
      [$host, $port1],
    ],
    eval => q{
      sub main::psgi_app {
        return [200, [], ['OK!']];
      }
    },
  )->then (sub {
    $server = $_[0];
    return Sarze->start (
      hostports => [
        [$host, $port1],
      ],
      eval => q{
        sub main::psgi_app {
          return [200, [], ['OK!']];
        }
      },
    );
  })->then (sub {
    $server2 = $_[0];
    test {
      ok 0;
    } $c;
  }, sub {
    my $error = $_[0];
    test {
      like $error, qr{\Qat @{[__FILE__]} line @{[__LINE__-18]}\E};
    } $c;
  })->then (sub {
    return $server->stop;
  })->then (sub {
    return $server->completed;
  })->then (sub {
    return $client1->request (path => []);
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->is_network_error;
    } $c;
  });
} n => 2, name => 'duplicate listen error';

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
    eval => q{
      "ok";
    },
    psgi_file_name => q{path},
  )->then (sub {
    $server = $_[0];
    test {
      ok 0;
    } $c;
  }, sub {
    my $error = $_[0];
    test {
      like $error, qr{\QBoth |eval| and |psgi_file_name| options are specified\E};
    } $c;
  })->then (sub {
    return $client1->request (path => []);
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->is_network_error;
    } $c;
  });
} n => 2, name => 'eval and psgi_file_name';

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
  )->then (sub {
    $server = $_[0];
    test {
      ok 0;
    } $c;
  }, sub {
    my $error = $_[0];
    test {
      like $error, qr{\QNeither of |eval| and |psgi_file_name| options is specified\E};
    } $c;
  })->then (sub {
    return $client1->request (path => []);
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->is_network_error;
    } $c;
  });
} n => 2, name => 'neither eval nor psgi_file_name';

run_tests;

=head1 LICENSE

Copyright 2016-2017 Wakaba <wakaba@suikawiki.org>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
