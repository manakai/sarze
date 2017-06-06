package Sarze;
use strict;
use warnings;
our $VERSION = '1.0';
use Carp;
use Data::Dumper;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Fork;
use Promise;
use Promised::Flow;
use Web::Encoding;
use constant DEBUG => $ENV{WEBSERVER_DEBUG} || 0;

sub log ($$) {
  warn encode_web_utf8 sprintf "%s: %s [%s]\n",
      $_[0]->{id}, $_[1], scalar gmtime time if DEBUG;
} # log

sub __create_check_worker ($) {
  my ($self) = @_;
  return Promise->resolve (1) if $self->{shutdowning};

  my $fork = $self->{forker}->fork;
  my $worker = $self->{workers}->{$fork} = {shutdown => sub {}};

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
warn "(chk) $fork $_[0] [[$self->{id} $rbuf]]";
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
warn "(chk) $fork $_[0] [[$self->{id} onerror $_[2]] <$rbuf>]";
           $onnomore->();
           $completed->();
           undef $hdl;
         },
         on_eof => sub {
           $_[0]->destroy;
warn "(chk) $fork $_[0] [[$self->{id} oneof $_[2]] <$rbuf>]";
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

sub _create_worker ($$) {
  my ($self, $onstop) = @_;
  return if $self->{shutdowning};

  my $fork = $self->{forker}->fork;
  my $worker = $self->{workers}->{$fork} = {accepting => 1, shutdown => sub {}};

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
warn "$fork $_[0] [[$self->{id} $rbuf]]";
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
warn "$fork $_[0] [[$self->{id} onerror $_[2]]<$rbuf>]";
           $onnomore->();
           $completed->();
           undef $hdl;
         },
         on_eof => sub {
           $_[0]->destroy;
warn "$fork $_[0] [[$self->{id} oneof $_[2]]<$rbuf>]";
           $onnomore->();
           $completed->();
           undef $hdl;
         });
    if ($self->{shutdowning}) {
warn "$fork $_[0] [[$self->{id} send shutdown]]";
      $hdl->push_write ("shutdown\x0A");
    } else {
warn "$fork $_[0] [[$self->{id} send parent_id]]";
      $hdl->push_write ("parent_id $self->{id}\x0A");
      $worker->{shutdown} = sub {
warn "$fork $_[0] [[$self->{id} send shutdown if $hdl]]";
 $hdl->push_write ("shutdown\x0A") if $hdl };
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
  my $count = 0;
  $count++ for grep { $_->{accepting} } values %{$self->{workers}};
  while ($count < $self->{max_worker_count} and not $self->{shutdowning}) {
    $self->_create_worker (sub {
      $self->{timer} = AE::timer 1, 0, sub {
        $self->_create_workers_if_necessary;
        delete $self->{timer};
      };
    });
    $count++;
  }
} # _create_workers_if_necessary

sub start ($%) {
  my ($class, %args) = @_;

  my $self = bless {
    workers => {},
    max_worker_count => $args{max_worker_count} || 3,
    global_cv => AE::cv,
    id => $$ . 'sarze' . ++$Sarze::N, # {id} can't contain \x0A
  }, $class;

  $self->{global_cv}->begin;
  $self->{shutdown} = sub {
    $self->{global_cv}->end;
    $self->{shutdown} = sub { };
    for (values %{$self->{workers}}) {
      $_->{shutdown}->();
    }
    delete $self->{forker};
    delete $self->{signals};
    $self->{shutdowning}++;
  };

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

  $self->{forker} = my $forker = AnyEvent::Fork->new;
  $forker->eval (q{
    use AnyEvent;
    $SIG{CHLD} = 'IGNORE';
  })->require ('Sarze::Worker');
  if (defined $args{eval}) {
    if (defined $args{psgi_file_name}) {
      $self->{shutdown}->();
      return Promise->reject
          ("Both |eval| and |psgi_file_name| options are specified");
    }
    my $c = sub { scalar Carp::caller_info
        (Carp::short_error_loc() || Carp::long_error_loc()) }->();
    $c->{file} =~ tr/\x0D\x0A"/   /;
    my $line = sprintf qq{\n#line 1 "Sarze eval (%s line %d)"\n}, $c->{file}, $c->{line};
    $forker->eval (sprintf q{
      eval "%s";
      if ($@) {
        $Sarze::Worker::LoadError = "$@";
      } elsif (not defined &main::psgi_app) {
        $Sarze::Worker::LoadError = "%s does not define &main::psgi_app";
      }
    }, quotemeta ($line.$args{eval}), quotemeta sprintf "Sarze eval (%s line %d)", $c->{file}, $c->{line});
  } elsif (defined $args{psgi_file_name}) {
    require Cwd;
    my $name = quotemeta Cwd::abs_path ($args{psgi_file_name});
    $forker->eval (q<
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
    return Promise->reject
        ("Neither of |eval| and |psgi_file_name| options is specified");
  }
  my $options = Dumper {
    connections_per_worker => $args{connections_per_worker} || 1000,
    seconds_per_worker => $args{seconds_per_worker} || 60*10,
    shutdown_timeout => $args{shutdown_timeout} || 60*1,
    worker_background_class => defined $args{worker_background_class} ? $args{worker_background_class} : '',
    max_request_body_length => $args{max_request_body_length},
  };
  $options =~ s/^\$VAR1 = /\$Sarze::Worker::Options = /;
  $forker->eval (encode_web_utf8 $options);
  my @fh;
  my @rstate;
  for (@{$args{hostports}}) {
    my ($h, $p) = @$_;
    local $Carp::CarpLevel = $Carp::CarpLevel + 1;
    eval {
      AnyEvent::Socket::_tcp_bind ($h, $p, sub { # tcp_bind can't be used for unix domain socket :-<
        push @rstate, shift;
        $self->log ("Main bound: $h:$p");
        push @fh, $rstate[-1]->{fh};
      });
    };
    if ($@) {
      $self->{shutdown}->();
      delete $self->{timer};
      @rstate = ();
      my $error = "$@";
      $self->log ($error);
      return Promise->reject ($error);
    }
  }
  my $p = $self->_create_check_worker;
  $self->{completed} = Promise->from_cv ($self->{global_cv})->then (sub {
    delete $self->{timer};
    @rstate = ();
    $self->log ("Main completed");
  });
  return $p->then (sub {
    return $self if $self->{shutdowning};
    for my $fh (@fh) {
      $forker->send_fh ($fh);
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
  warn "Reference to @{[ref $_[0]]} ($_[0]->{id}) is not discarded before global destruction\
n"
      if $@ =~ /during global destruction/;
} # DESTROY

1;

=head1 LICENSE

Copyright 2016-2017 Wakaba <wakaba@suikawiki.org>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
