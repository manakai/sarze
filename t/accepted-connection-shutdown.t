use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->child ('t_deps/lib');
use lib glob path (__FILE__)->parent->parent->child ('t_deps/modules/*/lib');
use IO::Socket::INET ();
use AnyEvent;
use AnyEvent::Socket qw(tcp_server);
use Test::More;
use Promise;
use Sarze;
use Web::URL;
use Web::Transport::BasicClient;
use Web::Transport::ProxyServerConnection;

sub port {
  my $socket = IO::Socket::INET->new (LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1) or die $!;
  return $socket->sockport;
}
my $port = port;
my $proxy_port = port;
my $server = Sarze->start (
  max_worker_count => 1, seconds_per_worker => -1,
  connections_per_worker => 'Inf', shutdown_timeout => 1,
  hostports => [['127.0.0.1', $port]],
  eval => q{
    use Web::Transport::PSGIServerConnection;
    # Only control when the real worker's shutdown is requested.  Its actual
    # shutdown path, connection handling and PSGI dispatch remain in use.
    my $original = Web::Transport::PSGIServerConnection->can ('new_from_aeargs_and_opts');
    no warnings 'redefine';
    *Web::Transport::PSGIServerConnection::new_from_aeargs_and_opts = sub ($$$) {
      my ($class, $args, $opts) = @_;
      my $con = $original->(@_);
      $con->{connection}->ready->then (sub { $opts->{state}->abort });
      return $con;
    };
    my $count = 0;
    *main::psgi_app = sub {
      my $env = shift;
      my $body = do { local $/; readline $env->{'psgi.input'} } // '';
      $count++;
      return [200, [
        'Content-Length' => length $body, 'X-Probe-Count' => $count,
        'X-Probe-Worker' => $$,
      ], [$body]];
    };
  },
)->to_cv->recv;
my @proxies;
my $proxy = tcp_server '127.0.0.1', $proxy_port, sub {
  push @proxies, Web::Transport::ProxyServerConnection->new_from_aeargs_and_opts ([ @_ ], {});
};
my $client = Web::Transport::BasicClient->new_from_url (
  Web::URL->parse_string ("http://127.0.0.1:$port/"), {
    proxy_manager => bless ({port => $proxy_port}, 'WorkerProbeProxy'),
  },
);
my $guard = AE::timer 20, 0, sub { die "Worker probe timed out\n" };
my %workers;
for my $request (1..3) {
  my $body = "synthetic-request-$request";
  my $res = $client->request (path => [], method => 'POST', body => $body)->to_cv->recv;
  is $res->status, 200, "request $request survives actual worker shutdown";
  is $res->body_bytes, $body, "request $request response is complete";
  is $res->header ('X-Probe-Count'), 1, "request $request is the worker's only dispatch";
  $workers{$res->header ('X-Probe-Worker')}++ if defined $res->header ('X-Probe-Worker');
}
is scalar keys %workers, 3, 'each request drains a different real worker';
$client->close->to_cv->recv;
Promise->all ([map { $_->completed } @proxies])->to_cv->recv;
$server->stop->to_cv->recv;
pass 'server and proxy connections terminate';
undef $proxy;
@proxies = ();
undef $server;
undef $guard;
done_testing;

package WorkerProbeProxy;
sub get_proxies_for_url {
  return Promise->resolve ([{
    protocol => 'http', host => Web::URL->parse_string ('http://127.0.0.1/')->host,
    port => $_[0]->{port},
  }]);
}
