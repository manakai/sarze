package Sarze::Worker;
use strict;
use warnings;
our $VERSION = '2.0';
use AnyEvent;
use AnyEvent::Handle;
use AbortController;
use Promise;
use Promised::Flow;
use Web::Encoding;
use Web::Transport::PSGIServerConnection;

sub check {
  if ($Sarze::Worker::LoadError) {
    my $error = $Sarze::Worker::LoadError;
    $error =~ s/\x7F/\x7F\x01/g;
    $error =~ s/\x0A/\x7F\x02/g;
    if (utf8::is_utf8 $error) {
      print { $_[0] } encode_web_utf8 "globalfatalerror $$|1|$error\x0A";
    } else {
      print { $_[0] } "globalfatalerror $$|0|$error\x0A";
    }
  } else {
    print { $_[0] } "started\x0A";
  }
  close $_[0];
} # check

sub main {
  srand;
  my $wp = bless {%{$Sarze::Worker::Options},
                  id => $$,
                  feature_set => 'unknown',
                  n => 0,
                  server_ws => []}, 'Sarze::Worker::Process';
  $wp->{parent_fh} = shift;
  $wp->{server_fhs} = [@_];
  $wp->{state} = bless {features => {}}, 'Sarze::Worker::State';

  my $worker_ac = AbortController->new;
  $wp->{state}->{abort} = sub {
    $worker_ac->abort;
    $worker_ac->signal->manakai_error ($_[0]) if defined $_[0];
  };
  $worker_ac->signal->manakai_onabort (sub { });
  for my $sig (qw(INT TERM QUIT)) {
    $wp->{signals}->{$sig} = AE::signal $sig => sub {
      $wp->log ("SIG$sig received");
      $wp->{state}->{abort}->();
    };
  }

  my $ws_completed;
  my $ws_ac = AbortController->new;
  my $ws_pre_ac = AbortController->new;
  Promise->resolve->then (sub {
    return $wp->{worker_state_class}->start (
      state => $wp->{state},
      params => delete $wp->{worker_state_params},
      _pre_signal => $ws_pre_ac->signal,
      signal => $ws_ac->signal,
    );
  })->then (sub {
    die $worker_ac->signal->manakai_error if $worker_ac->signal->aborted;
    $wp->{state}->{data} = $_[0]->[0];
    $ws_completed = Promise->resolve ($_[0]->[1]);
    # or throw

    my $shutdown_timer;
    return Promise->resolve->then (sub {
      my $cons_cv = AE::cv;
      $cons_cv->begin;
      $wp->{done} = sub { $cons_cv->end };

      my $worker_timer;
      my $shutdown = sub {
        $wp->log ("Worker shutdown...");
        $wp->dont_accept_anymore;
        for (values %{$wp->{connections} or {}}) {
          $_->close_after_current_response
              (timeout => $wp->{shutdown_timeout});
        }
        delete $wp->{connections};
        delete $wp->{signals};
        $shutdown_timer = AE::timer $wp->{shutdown_timeout}+1, 0, sub {
          $cons_cv->croak
              ("$wp->{id}: Shutdown timeout ($wp->{shutdown_timeout})\n");
          undef $shutdown_timer;
        };
        undef $worker_timer;
        $ws_pre_ac->abort;
      }; # $shutdown
      for my $sig (qw(INT TERM QUIT)) {
        $wp->{signals}->{$sig} = AE::signal $sig => sub {
          $wp->log ("SIG$sig received");
          $shutdown->();
        };
      }
      die $worker_ac->signal->manakai_error if $worker_ac->signal->aborted;
      $worker_ac->signal->manakai_onabort ($shutdown);

      if ($wp->{seconds_per_worker} > 0) {
        my $timeout = $wp->{seconds_per_worker};
        if ($timeout >= 60*10) {
          $timeout += rand (60*5);
        } elsif ($timeout >= 60) {
          $timeout += rand 30;
        }
        $worker_timer = AE::timer $timeout, 0, sub {
          $wp->log ("|seconds_per_worker| elapsed ($timeout)");
          $shutdown->();
        };
      }

      ## Accept HTTP connections
      my $start_accept = sub {
        for my $fh (@{$wp->{server_fhs}}) {
          push @{$wp->{server_ws}}, AE::io $fh, 0, sub {
            while (1) {
              $cons_cv->begin;
              my ($args, $n) = $wp->accept_next ($fh);
              unless (defined $args) {
                $cons_cv->end;
                last;
              }

              my $opts = {psgi_app => \&main::psgi_app,
                          parent_id => $wp->{id},
                          state => $wp->{state}};
              $opts->{max_request_body_length} = $wp->{max_request_body_length}
                  if defined $wp->{max_request_body_length}; # undef ignored
              my $con = Web::Transport::PSGIServerConnection
                  ->new_from_aeargs_and_opts ($args, $opts);
              $wp->{connections}->{$con} = $con;
              $con->completed->finally (sub {
                $wp->log (sprintf "Connection completed (%s)", $con->id);
                $cons_cv->end;
                delete $wp->{connections}->{$con};
              });
            } # while
          };
        } # $fh
      }; # $start_accept
      my $cancel_accept = sub {
        for (@{$wp->{wp_fhs}}) {
          close $_;
        }
        $wp->{fhs} = [];
      }; # $cancel_accept
      my $start_custom = sub {
        $cons_cv->begin;
        Promise->resolve->then (sub {
          return $wp->{worker_state_class}->custom ($wp->{state});
        })->then (sub {
          $cons_cv->end;
        }, sub {
          $cons_cv->croak ($_[0]);
        });
      }; # start_custom

      $wp->{parent_handle} = AnyEvent::Handle->new
          (fh => $wp->{parent_fh},
           on_read => sub {
             while ($_[0]->{rbuf} =~ s/^([^\x0A]*)\x0A//) {
               my $line = $1;
               if ($line =~ /\Ashutdown\z/) {
                 $shutdown->();
               } elsif ($line =~ s/^feature_set //) {
                 $wp->{feature_set} = $line;
               } elsif ($line =~ s/^parent_id //) {
                 $wp->{id} = $line . '.' . $$ . ({
                   http => 'h',
                   custom => 'c',
                 }->{$wp->{feature_set}} // $wp->{feature_set});
                 $wp->log ("Worker started ($wp->{feature_set})");
                 if ($wp->{feature_set} eq 'http') {
                   $wp->{state}->{features}->{http} = 1;
                 }
                 if ($wp->{feature_set} eq 'custom') {
                   $wp->{state}->{features}->{custom} = 1;
                 }
                 if ($wp->{state}->{features}->{http}) {
                   $start_accept->();
                 } else {
                   $cancel_accept->();
                 }
                 if ($wp->{state}->{features}->{custom}) {
                   $start_custom->();
                 }
                 $start_accept = $cancel_accept = $start_custom = sub { };
               } else {
                 $wp->log ("Broken command from main process: |$line|");
               }
             }
           },
           on_eof => sub { $_[0]->destroy },
           on_error => sub { $_[0]->destroy });
      # XXX should run $shutdown when connection is closed

      return Promise->from_cv ($cons_cv); # connections done
    })->catch (sub {
      my $error = "Worker error: $_[0]";
      $wp->log ($error);
      warn $error;
    })->finally (sub {
      undef $shutdown_timer;
    });
  })->then (sub {
    $wp->log ("Destroy worker state object...");
    $ws_pre_ac->abort;
    $ws_ac->abort;
    delete $wp->{state};
    $worker_ac->signal->manakai_onabort (sub { });
    return $ws_completed;
  })->catch (sub {
    my $error = "Worker error: $_[0]";
    $wp->log ($error);
    delete $wp->{state};
  })->to_cv->recv; # main loop

  $wp->log ("Worker completed");
  close $wp->{parent_fh};
  undef $wp;
} # main

package Sarze::Worker::EmptyWorkerState;

sub start ($%) {
  return [undef, Promise->resolve];
} # start

package Sarze::Worker::BackgroundWorkerState;
# for backcompat
use Promised::Flow;

sub start ($%) {
  my ($class, %args) = @_;
  my ($r1, $s1) = promised_cv;
  my ($r2, $s2) = promised_cv;
  $args{signal}->manakai_onabort (sub {
    $s1->();
    undef $s1;
    $s2->();
    undef $s2;
  });
  return Promise->resolve->then (sub {
    return $args{params}->{class}->start;
  })->then (sub {
    my $obj = $_[0];
    my $stop_failed;
    $args{_pre_signal}->manakai_onabort (sub {
      return Promise->resolve->then (sub {
        $obj->stop; # can throw
      })->then (sub {
        $s2->();
        undef $s2;
      }, sub {
        $s2->();
        $stop_failed = 1;
        undef $s2;
      });
    });
    $args{signal}->manakai_onabort (sub {
      return $r2->then (sub {
        if (not $stop_failed and $obj->can ('destroy')) { # can throw
          return $obj->destroy; # can throw
        }
      })->then (sub {
        return $obj->completed unless $stop_failed;
      })->finally (sub {
        $s1->();
        undef $s1;
        (delete $args{state})->abort if defined $args{state};
      });
    });
    $obj->completed->then (sub {
      (delete $args{state})->abort (undef) if defined $args{state};
    }, sub {
      (delete $args{state})->abort ($_[0]) if defined $args{state};
    });
    return [$obj, Promise->all ([$r1->catch (sub { }), $r2->catch (sub { })])];
  })->catch (sub {
    $args{signal}->manakai_onabort (sub { });
    die $_[0];
  });
} # start

package Sarze::Worker::State;

sub abort ($;$) {
  $_[0]->{abort}->($_[1]);
} # abort

sub features ($) { $_[0]->{features} }

sub data ($) { return $_[0]->{data} }
*background = \&data; # backcompat

sub DESTROY ($) {
  local $@;
  eval { die };
  warn "Reference to @{[ref $_[0]]} is not discarded before global destruction"
      if $@ =~ /during global destruction/;
} # DESTROY

package Sarze::Worker::Process;
use Web::Encoding;

sub log ($$) {
  warn encode_web_utf8 sprintf "%s: %s [%s]\n",
      $_[0]->{id}, $_[1], scalar gmtime time if $_[0]->{debug};
} # log

sub accept_next ($$) {
  my ($self, $s_fh) = @_;

  return (undef, undef) unless defined $self->{server_ws};
  my $peer = accept (my $fh, $s_fh);
  return (undef, undef) unless $peer;

  AnyEvent::fh_unblock $fh;
  my ($service, $host) = AnyEvent::Socket::unpack_sockaddr $peer;
  my $args = [$fh, AnyEvent::Socket::format_address $host, $service];

  my $n = $self->{n}++;
  $self->log ("Accepted $args->[1]:$args->[2] (connection #$n)");

  $self->dont_accept_anymore if $self->{connections_per_worker} <= $self->{n};

  return ($args, $n);
} # accept_next

sub dont_accept_anymore ($) {
  my $self = $_[0];
  return if $self->{nomore}++;

  $self->{parent_handle}->push_write ("nomore\x0A");

  delete $self->{server_ws};
  for (@{delete $self->{server_fhs}}) {
    close $_;
  }

  $self->{done}->();

  $self->log ("Worker no longer accepts new requests");
} # dont_accept_anymore

sub DESTROY ($) {
  local $@;
  eval { die };
  warn "$_[0]->{id}: Reference to @{[ref $_[0]]} is not discarded before global destruction"
      if $@ =~ /during global destruction/;
} # DESTROY

1;

=head1 LICENSE

Copyright 2016-2022 Wakaba <wakaba@suikawiki.org>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
