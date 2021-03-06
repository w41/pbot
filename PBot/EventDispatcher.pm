package PBot::EventDispatcher;

use warnings;
use strict;

use IO::Select;
use Carp ();

sub new {
  Carp::croak("Options to " . __FILE__ . " should be key/value pairs, not hash reference") if ref($_[1]) eq 'HASH';
  my ($class, %conf) = @_;
  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;
  $self->{pbot} = delete $conf{pbot} // Carp::croak("Missing pbot reference in " . __FILE__);
  $self->{handlers} = { any => [] };
}

sub register_handler {
  my ($self, $event_type, $sub) = @_;

  push @{$self->{handlers}->{$event_type}}, $sub;
}

sub dispatch_event {
  my ($self, $event_type, $event_data) = @_;
  my $ret = undef;

  if (exists $self->{handlers}->{$event_type}) {
    foreach my $handler (@{$self->{handlers}->{$event_type}}) {
      $ret = $handler->($event_type, $event_data);
      return $ret if $ret;
    }
  }

  foreach my $handler (@{$self->{handlers}->{any}}) {
    $ret = $handler->($event_type, $event_data);
    return $ret if $ret;
  }

  return $ret;
}

1;
