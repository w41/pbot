# File: MessageHistory.pm
# Author: pragma_
#
# Purpose: Keeps track of who has said what and when, as well as their
# nickserv accounts and alter-hostmasks.  
#
# Used in conjunction with AntiFlood and Quotegrabs for kick/ban on
# flood/ban-evasion and grabbing quotes, respectively.

package PBot::MessageHistory;

use warnings;
use strict;

use Getopt::Long qw(GetOptionsFromString);
use Time::HiRes qw(gettimeofday tv_interval);
use Time::Duration;
use Carp ();

use PBot::MessageHistory_SQLite;

sub new {
  if(ref($_[1]) eq 'HASH') {
    Carp::croak("Options to " . __FILE__ . " should be key/value pairs, not hash reference");
  }

  my ($class, %conf) = @_;
  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;
  $self->{pbot} = delete $conf{pbot} // Carp::croak("Missing pbot reference to " . __FILE__);
  $self->{filename} = delete $conf{filename} // $self->{pbot}->{registry}->get_value('general', 'data_dir') . '/message_history.sqlite3';

  $self->{database} = PBot::MessageHistory_SQLite->new(pbot => $self->{pbot}, filename => $self->{filename});
  $self->{database}->begin();
  $self->{database}->devalidate_all_channels();

  $self->{MSG_CHAT}       = 0;  # PRIVMSG, ACTION
  $self->{MSG_JOIN}       = 1;  # JOIN
  $self->{MSG_DEPARTURE}  = 2;  # PART, QUIT, KICK
  $self->{MSG_NICKCHANGE} = 3;  # CHANGED NICK

  $self->{pbot}->{registry}->add_default('text', 'messagehistory', 'max_messages', $conf{max_messages} // 32);

  $self->{pbot}->{commands}->register(sub { $self->recall_message(@_)     },  "recall",          0);
  $self->{pbot}->{commands}->register(sub { $self->list_also_known_as(@_) },  "aka",             0);
  $self->{pbot}->{commands}->register(sub { $self->rebuild_aliases(@_)    },  "rebuildaliases", 90);
  $self->{pbot}->{commands}->register(sub { $self->aka_link(@_)           },  "akalink",        60);
  $self->{pbot}->{commands}->register(sub { $self->aka_unlink(@_)         },  "akaunlink",      60);

  $self->{pbot}->{atexit}->register(sub { $self->{database}->end(); return; });
}

sub get_message_account {
  my ($self, $nick, $user, $host) = @_;
  return $self->{database}->get_message_account($nick, $user, $host);
}

sub add_message {
  my ($self, $account, $mask, $channel, $text, $mode) = @_;
  $self->{database}->add_message($account, $mask, $channel, { timestamp => scalar gettimeofday, msg => $text, mode => $mode });
}

sub rebuild_aliases {
  my ($self, $from, $nick, $user, $host, $arguments) = @_;

  $self->{database}->rebuild_aliases_table;
}

sub aka_link {
  my ($self, $from, $nick, $user, $host, $arguments) = @_;

  my ($id, $alias) = split /\s+/, $arguments;

  if (not $id or not $alias) {
    return "Usage: link <target id> <alias id>";
  }

  my $source = $self->{database}->find_most_recent_hostmask($id);
  my $target = $self->{database}->find_most_recent_hostmask($alias);

  if (not $source) {
    return "No such id $id found.";
  }

  if (not $target) {
    return "No such id $alias found.";
  }

  if ($self->{database}->link_alias($id, $alias)) {
    return "$source linked to $target.";
  } else {
    return "Link failed.";
  }
}

sub aka_unlink {
  my ($self, $from, $nick, $user, $host, $arguments) = @_;

  my ($id, $alias) = split /\s+/, $arguments;

  if (not $id or not $alias) {
    return "Usage: unlink <target id> <alias id>";
  }

  my $source = $self->{database}->find_most_recent_hostmask($id);
  my $target = $self->{database}->find_most_recent_hostmask($alias);

  if (not $source) {
    return "No such id $id found.";
  }

  if (not $target) {
    return "No such id $alias found.";
  }

  if ($self->{database}->unlink_alias($id, $alias)) {
    return "$source unlinked from $target.";
  } else {
    return "Unlink failed.";
  }
}

sub list_also_known_as {
  my ($self, $from, $nick, $user, $host, $arguments) = @_;

  my $usage = "Usage: aka [-h] [-i] [-n] [-r] <nick>; -h show hostmasks; -i show ids; -n show nickserv accounts; -r show relationships";

  if(not length $arguments) {
    return $usage;
  }

  my $getopt_error;
  local $SIG{__WARN__} = sub {
    $getopt_error = shift;
    chomp $getopt_error;
  };

  my ($show_hostmasks, $show_nickserv, $show_id, $show_relationship, $dont_use_aliases_table);
  my ($ret, $args) = GetOptionsFromString($arguments,
    'h'  => \$show_hostmasks,
    'n'  => \$show_nickserv,
    'r'  => \$show_relationship,
    'nt' => \$dont_use_aliases_table,
    'i'  => \$show_id);

  return "$getopt_error -- $usage" if defined $getopt_error;
  return "Too many arguments -- $usage" if @$args > 1;
  return "Missing argument -- $usage" if @$args != 1;

  my %akas = $self->{database}->get_also_known_as(@$args[0], $dont_use_aliases_table);

  if(%akas) {
    my $result = "@$args[0] also known as:\n";

    my %nicks;
    my $sep = "";
    foreach my $aka (sort keys %akas) {
      next if $aka =~ /^Guest\d+(?:!.*)?$/;

      if (not $show_hostmasks) {
        my ($nick) = $aka =~ m/([^!]+)/;
        next if exists $nicks{$nick} and $nicks{$nick}->{id} == $akas{$aka}->{id};
        $nicks{$nick}->{id} = $akas{$aka}->{id};
        $result .= "$sep$nick";
      } else {
        $result .= "$sep$aka";
      }
      $result .= " ($akas{$aka}->{nickserv})" if $show_nickserv and exists $akas{$aka}->{nickserv};

      if ($show_relationship) {
        if ($akas{$aka}->{id} == $akas{$aka}->{alias}) {
          $result .= " [$akas{$aka}->{id}]";
        } else {
          $result .= " [$akas{$aka}->{id} -> $akas{$aka}->{alias}]";
        }
      } elsif ($show_id) {
        $result .= " [$akas{$aka}->{id}]";
      }

      if ($show_hostmasks or $show_nickserv or $show_id or $show_relationship) {
        $sep = ",\n";
      } else {
        $sep = ", ";
      }
    }
    return $result;
  } else {
    return "I don't know anybody named @$args[0].";
  }
}

sub recall_message {
  my ($self, $from, $nick, $user, $host, $arguments) = @_;

  if(not defined $from) {
    $self->{pbot}->{logger}->log("Command missing ~from parameter!\n");
    return "";
  }

  my $usage = 'Usage: recall [nick [history [channel]]] [-c,channel <channel>] [-t,text,h,history <history>] [-b,before <context before>] [-a,after <context after>] [-x,context <nick>] [+ ...]';

  if(not defined $arguments or not length $arguments) {
    return $usage; 
  }

  $arguments = lc $arguments;

  my @recalls = split /\s\+\s/, $arguments;

  my $getopt_error;
  local $SIG{__WARN__} = sub {
    $getopt_error = shift;
    chomp $getopt_error;
  };

  my $recall_text;

  foreach my $recall (@recalls) {
    my ($recall_nick, $recall_history, $recall_channel, $recall_before, $recall_after, $recall_context);

    my ($ret, $args) = GetOptionsFromString($recall,
      'channel|c=s'        => \$recall_channel,
      'text|t|history|h=s' => \$recall_history,
      'before|b=s'         => \$recall_before,
      'after|a=s'          => \$recall_after,
      'context|x=s'        => \$recall_context);

    return "$getopt_error -- $usage" if defined $getopt_error;

    my $channel_arg = 1 if defined $recall_channel;
    my $history_arg = 1 if defined $recall_history;

    $recall_nick = shift @$args;
    $recall_history = shift @$args if not defined $recall_history;
    $recall_channel = shift @$args if not defined $recall_channel;
    $recall_before = 0 if not defined $recall_before;
    $recall_after = 0 if not defined $recall_after;

    # swap nick and channel if recall nick looks like channel and channel wasn't specified
    if(not $channel_arg and $recall_nick =~ m/^#/) {
      my $temp = $recall_nick;
      $recall_nick = $recall_channel;
      $recall_channel = $temp;
    }

    # swap history and channel if history looks like a channel and neither history or channel were specified
    if(not $channel_arg and not $history_arg and $recall_history =~ m/^#/) {
      my $temp = $recall_history;
      $recall_history = $recall_channel;
      $recall_channel = $temp;
    }

    # skip recall command if recalling self without arguments
    $recall_history = $nick eq $recall_nick ? 2 : 1 if defined $recall_nick and not defined $recall_history;

    # set history to most recent message if not specified
    $recall_history = '1' if not defined $recall_history;

    # set channel to current channel if not specified
    $recall_channel = $from if not defined $recall_channel;

    if (not defined $recall_nick and defined $recall_context) {
      $recall_nick = $recall_context;
    }

    my ($account, $found_nick);

    if(defined $recall_nick) {
      ($account, $found_nick) = $self->{database}->find_message_account_by_nick($recall_nick);

      if(not defined $account) {
        return "I don't know anybody named $recall_nick.";
      }

      $found_nick =~ s/!.*$//;
    }

    my $message;

    if($recall_history =~ /^\d+$/) {
      # integral history
      if(defined $account) {
        my $max_messages = $self->{database}->get_max_messages($account, $recall_channel);
        if($recall_history < 1 || $recall_history > $max_messages) {
          return "Please choose a history between 1 and $max_messages";
        }
      }

      $recall_history--;
      $message = $self->{database}->recall_message_by_count($account, $recall_channel, $recall_history, 'recall');

      if(not defined $message) {
        return "No message found at index $recall_history in channel $recall_channel.";
      }
    } else {
      # regex history
      $message = $self->{database}->recall_message_by_text($account, $recall_channel, $recall_history, 'recall');

      if(not defined $message) {
        if(defined $account) {
          return "No such message for nick $found_nick in channel $recall_channel containing text '$recall_history'";
        } else {
          return "No such message in channel $recall_channel containing text '$recall_history'";
        }
      }
    }

    if ($recall_before + $recall_after > 200) {
      return "You may only select 200 lines of surrounding context.";
    }

    my $context_account;

    if (defined $recall_context) {
      ($context_account) = $self->{database}->find_message_account_by_nick($recall_context);

      if(not defined $context_account) {
        return "I don't know anybody named $recall_context.";
      }
    }

    my $messages = $self->{database}->get_message_context($message, $recall_before, $recall_after, $context_account);

    foreach my $msg (@$messages) {
      $self->{pbot}->{logger}->log("$nick ($from) recalled <$msg->{nick}/$msg->{channel}> $msg->{msg}\n");

      my $text = $msg->{msg};
      my $ago = ago(gettimeofday - $msg->{timestamp});

      if(not defined $recall_text) {
        if($text =~ s/^\/me\s+// or $text =~ m/^KICKED /) {
          $recall_text = "[$ago] * $msg->{nick} $text\n";
        } else {
          $recall_text = "[$ago] <$msg->{nick}> $text\n";
        }
      } else {
        if($text =~ s/^\/me\s+// or $text =~ m/^KICKED /) {
          $recall_text .= "[$ago] * $msg->{nick} $text\n";
        } else {
          $recall_text .= "[$ago] <$msg->{nick}> $text\n";
        }
      }
    }
  }

  return $recall_text;
}

1;
