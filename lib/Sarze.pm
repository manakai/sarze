package Sarze;
use strict;
use warnings;
our $VERSION = '2.0';
use Carp;
use Data::Dumper;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Fork;
use Promise;
use Promised::Flow;
use Web::Encoding;

sub log ($$) {
  warn encode_web_utf8 sprintf "%s: %s [%s]\n",
      $_[0]->{id}, $_[1], scalar gmtime time if $_[0]->{debug};
} # log

my $NewAEF = !!eval q{ use AnyEvent::Fork 1.32; 1 };

sub _init_forker ($$) {
  my ($self, $args) = @_;
  $self->{forker} = AnyEvent::Fork->new;
  $self->{forker}->eval ($NewAEF ? q{ use AnyEvent } : q{
    use AnyEvent;
    $SIG{CHLD} = 'IGNORE';
  })->require ('Sarze::Worker');
  if (defined $args->{eval}) {
    if (defined $args->{psgi_file_name}) {
      $self->{shutdown}->();
      $self->log ("Terminated by option error");
      return Promise->reject
          ("Both |eval| and |psgi_file_name| options are specified");
    }
    my $c = sub { scalar Carp::caller_info
        (Carp::short_error_loc() || Carp::long_error_loc()) }->();
    $c->{file} =~ tr/\x0D\x0A"/   /;
    my $line = sprintf qq{\n#line 1 "Sarze eval (%s line %d)"\n}, $c->{file}, $c->{line};
    $self->{forker}->eval (sprintf q{
      eval "%s";
      if ($@) {
        $Sarze::Worker::LoadError = "$@";
      } elsif (not defined &main::psgi_app) {
        $Sarze::Worker::LoadError = "%s does not define &main::psgi_app";
      }
    }, quotemeta ($line.$args->{eval}), quotemeta sprintf "Sarze eval (%s line %d)", $c->{file}, $c->{line});
  } elsif (defined $args->{psgi_file_name}) {
    require Cwd;
    my $name = quotemeta Cwd::abs_path ($args->{psgi_file_name});
    $self->{forker}->eval (q<
      my $name = ">.$name.q<";
      my $code = do $name;
      if ($@) {
        $Sarze::Worker::LoadError = "$name: $@";
      } elsif (defined $code) {
        if (ref $code eq 'CODE') {
          *main::psgi_app = $code;
        } else {
          $Sarze::Worker::LoadError = "|$name| does not return a CODE";
        }
      } else {
        if ($!) {
          $Sarze::Worker::LoadError = "$name: $!";
        } else {
          $Sarze::Worker::LoadError = "|$name| does not return a CODE";
        }
      }
    >);
  } else {
    $self->{shutdown}->();
    $self->log ("Terminated by option error");
    return Promise->reject
        ("Neither of |eval| and |psgi_file_name| options is specified");
  }

  if (defined $args->{worker_state_class} or
      defined $args->{worker_background_class}) {
    my $cls = $args->{worker_state_class} // $args->{worker_background_class};
    $self->{forker}->eval (sprintf q{
      unless ("%s"->can ('start')) {
        $Sarze::Worker::LoadError ||= "%s->start is not defined";
      }
    }, quotemeta $cls, quotemeta $cls);
    $self->{forker}->eval (sprintf q{
      unless ("%s"->can ('custom')) {
        $Sarze::Worker::LoadError ||= "%s->custom is not defined";
      }
    }, quotemeta $cls, quotemeta $cls)
        if $self->{max}->{custom};
    if (defined $args->{worker_background_class}) {
      warn "Use of Sarze option |worker_background_class| is deprecated\n";
      $args->{worker_state_class} = 'Sarze::Worker::BackgroundWorkerState';
      $args->{worker_state_params} = {class => delete $args->{worker_background_class}};
    }
  } else {
    $args->{worker_state_class} = 'Sarze::Worker::EmptyWorkerState';
  }

  my $options = Dumper {
    connections_per_worker => $args->{connections_per_worker} || 1000,
    seconds_per_worker => $args->{seconds_per_worker} || 60*10,
    shutdown_timeout => $args->{shutdown_timeout} || 60*1,
    max_request_body_length => $args->{max_request_body_length},
    worker_state_class => $args->{worker_state_class},
    worker_state_params => $args->{worker_state_params}, # or undef
    debug => $self->{debug},
  };
  $options =~ s/^\$VAR1 = /\$Sarze::Worker::Options = /;
  $self->{forker}->eval (encode_web_utf8 $options);

  return undef;
} # _init_forker

sub __create_check_worker ($) {
  my ($self) = @_;
  return Promise->resolve (1) if $self->{shutdowning};

  my $fork = $self->{forker}->fork;
  my $worker = $self->{workers}->{$fork} = {shutdown => sub {},
                                            feature_set => 'check'};

  my ($start_ok, $start_ng) = @_;
  my $start_p = Promise->new (sub { ($start_ok, $start_ng) = @_ });

  my $onnomore = sub {
    $start_ok->(0);
  }; # $onnomore

  my $completed;
  my $complete_p = Promise->new (sub { $completed = $_[0] });

  $fork->run ('Sarze::Worker::check', sub {
    my $fh = shift;
    my $rbuf = '';
    my $hdl; $hdl = AnyEvent::Handle->new
        (fh => $fh,
         on_read => sub {
           $rbuf .= $_[0]->{rbuf};
           $_[0]->{rbuf} = '';
           while ($rbuf =~ s/^([^\x0A]*)\x0A//) {
             my $line = $1;
             if ($line eq 'started') {
               $start_ok->(1);
             } elsif ($line =~ /\Aglobalfatalerror (.*)\z/s) {
               my $error = "Fatal error: " . decode_web_utf8 $1;
               $self->log ($error);
               $start_ng->($error);
               $self->{shutdown}->();
             } else {
               my $error = "Broken command from worker process: |$line|";
               $self->log ($error);
               $start_ng->($error);
               $self->{shutdown}->();
             }
           }
         },
         on_error => sub {
           $_[0]->destroy;
           $onnomore->();
           $completed->();
           undef $hdl;
         },
         on_eof => sub {
           $_[0]->destroy;
           $onnomore->();
           $completed->();
           undef $hdl;
         });
  });

  $self->{global_cv}->begin;
  $complete_p->then (sub {
    delete $worker->{shutdown};
    delete $self->{workers}->{$fork};
    undef $fork;
    $self->{global_cv}->end;
  });

  return $start_p;
} # __create_check_worker

sub _create_check_worker ($) {
  my ($self) = @_;
  ## First fork might be failed and $hdl above might receive on_eof
  ## before receiving anything on Mac OS X...
  return promised_wait_until {
    return $self->__create_check_worker;
  } timeout => 60;
} # _create_check_worker

sub _create_worker ($$$) {
  my ($self, $onstop, $feature_set) = @_;
  return if $self->{shutdowning};

  my $fork = $self->{forker}->fork;
  my $worker = $self->{workers}->{$fork} = {accepting => 1, shutdown => sub {},
                                            feature_set => $feature_set};

  my $onnomore = sub {
    if ($worker->{accepting}) {
      delete $worker->{accepting};
      $onstop->();
    }
  }; # $onnomore

  my $completed;
  my $complete_p = Promise->new (sub { $completed = $_[0] });

  $fork->run ('Sarze::Worker::main', sub {
    my $fh = shift;
    my $rbuf = '';
    my $hdl; $hdl = AnyEvent::Handle->new
        (fh => $fh,
         on_read => sub {
           $rbuf .= $_[0]->{rbuf};
           $_[0]->{rbuf} = '';
           while ($rbuf =~ s/^([^\x0A]*)\x0A//) {
             my $line = $1;
             if ($line eq 'nomore') {
               $onnomore->();
             } else {
               $self->log ("Broken command from worker process: |$line|");
             }
           }
         },
         on_error => sub {
           $_[0]->destroy;
           $onnomore->();
           $completed->();
           undef $hdl;
         },
         on_eof => sub {
           $_[0]->destroy;
           $onnomore->();
           $completed->();
           undef $hdl;
         });
    if ($self->{shutdowning}) {
      $hdl->push_write ("shutdown\x0A") if $hdl;
    } else {
      $hdl->push_write ("feature_set $feature_set\x0A") if $hdl;
      $hdl->push_write ("parent_id $self->{id}\x0A") if $hdl;
      my $s = $self;
      $worker->{shutdown} = sub {
        if ($hdl) {
          $hdl->push_write ("shutdown\x0A");
          $s->log ("Send shutdown to a worker ($feature_set)");
        } else {
          $s->log ("Failed to send shutdown to a worker ($feature_set)");
        }
        undef $s;
      };
    }
  });

  $self->{global_cv}->begin;
  $complete_p->then (sub {
    delete $worker->{shutdown};
    delete $self->{workers}->{$fork};
    undef $fork;
    $self->{global_cv}->end;
  });
} # _create_worker

sub _create_workers_if_necessary ($) {
  my ($self) = @_;
  for my $fs (qw(http custom)) {
    my $count = 0;
    $count++ for grep { $_->{accepting} and $_->{feature_set} eq $fs } values %{$self->{workers}};
    while ($count < $self->{max}->{$fs} and not $self->{shutdowning}) {
      $self->_create_worker (sub {
        $self->{timer} = AE::timer 1, 0, sub {
          $self->_create_workers_if_necessary;
          delete $self->{timer};
        };
      }, $fs);
      $count++;
    }
  } # $fs
} # _create_workers_if_necessary

sub start ($%) {
  my ($class, %args) = @_;
  return Promise->reject ("|hostports| is not specified")
      unless defined $args{hostports};

  my $self = bless {
    workers => {},
    global_cv => AE::cv,
    id => $$ . 'sarze' . ++$Sarze::N, # {id} can't contain \x0A
    debug => 0+($args{debug} || $ENV{WEBSERVER_DEBUG} || 0),
  }, $class;
  for my $fs (qw(custom)) {
    $self->{max}->{$fs} = $args{max_counts}->{$fs} || 0;
  }
  $self->{max}->{http} = $args{max_worker_count} // 3;

  my @rstate;
  $self->{global_cv}->begin;
  $self->{shutdown} = sub {
    @rstate = ();
    $self->{global_cv}->end;
    $self->{shutdown} = sub { };
    for (values %{$self->{workers}}) {
      $_->{shutdown}->();
    }
    delete $self->{timer};
    delete $self->{forker};
    delete $self->{signals};
    $self->{shutdowning}++;
  };

  for (@{$args{hostports}}) {
    my ($h, $p) = @$_;
    local $Carp::CarpLevel = $Carp::CarpLevel + 1;
    eval {
      AnyEvent::Socket::_tcp_bind ($h, $p, sub { # tcp_bind can't be used for unix domain socket :-<
        push @rstate, shift;
        $self->log ("Main bound: $h:$p");
      });
    };
    if ($@) {
      $self->{shutdown}->();
      my $error = "$@";
      $self->log ($error);
      return Promise->reject ($error);
    }
  }

  for my $sig (qw(INT TERM QUIT)) {
    $self->{signals}->{$sig} = AE::signal $sig => sub {
      $self->log ("SIG$sig received");
      $self->{shutdown}->();
    };
  }
  for my $sig (qw(HUP)) {
    $self->{signals}->{$sig} = AE::signal $sig => sub {
      $self->log ("SIG$sig received");
      return if $self->{shutdowning};
      for (values %{$self->{workers}}) {
        $_->{shutdown}->();
      }
    };
    # XXX onhup hook
    # XXX recreate $fork
  }

  my $q = $self->_init_forker (\%args);
  return $q if defined $q;

  my $p = $self->_create_check_worker;
  $self->{completed} = Promise->from_cv ($self->{global_cv})->then (sub {
    delete $self->{timer};
    @rstate = ();
    $self->log ("Main completed");
  });
  return $p->then (sub {
    for (@rstate) {
      $self->{forker}->send_fh ($_->{fh});
    }
    $self->_create_workers_if_necessary;
    return $self;
  });
} # start

sub stop ($) {
  $_[0]->{shutdown}->();
  return $_[0]->completed;
} # stop

sub completed ($) {
  return $_[0]->{completed};
} # completed

sub run ($@) {
  return shift->start (@_)->then (sub {
    return $_[0]->completed;
  });
} # run

sub DESTROY ($) {
  local $@;
  eval { die };
  warn "$$: Reference to @{[ref $_[0]]} ($_[0]->{id}) is not discarded before global destruction"
      if $@ =~ /during global destruction/;
} # DESTROY

1;

=head1 LICENSE

Copyright 2016-2022 Wakaba <wakaba@suikawiki.org>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
