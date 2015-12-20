package EdgeOS::DNS::Blacklist;
use parent 'Exporter';    # imports and subclasses Exporter

use v5.14;
use EdgeOS::DNS::Blacklist;
use File::Basename;
use Getopt::Long;
use HTTP::Tiny;
use lib q{/opt/vyatta/share/perl5/};
use POSIX qw{geteuid};
use Sys::Syslog qw(:standard :macros);
use threads;
use URI;
use Vyatta::Config;

use constant TRUE  => 1;
use constant FALSE => 0;

# require Exporter;
our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration use EdgeOS::DNS::Blacklist ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
# our %EXPORT_TAGS = ( 'all' => [qw()] );
our @EXPORT_OK = (
  qw{
    $c
    delete_file
    get_cfg_actv
    get_cfg_file
    get_file
    get_url
    is_admin
    is_build
    is_configure
    is_version
    log_msg
    popx
    process_data
    pushx
    usage
    write_file
    }
);
our $VERSION = q{1.0};
our $c       = {
  off => qq{\033[?25l},
  on  => qq{\033[?25h},
  clr => qq{\033[0m},
  grn => qq{\033[92m},
  mag => qq{\033[95m},
  red => qq{\033[91m},
};
our @EXPORT = ();

# Remove previous configuration files
sub delete_file {
  my $input = shift;

  if ( -f $input->{file} ) {
    log_msg(
      {
        msg_typ => q{info},
        msg_str => sprintf q{Deleting file %s},
        $input->{file},
      }
    );
    unlink $input->{file};
  }

  if ( -f $input->{file} ) {
    log_msg(
      {
        msg_typ => q{warning},
        msg_str => sprintf q{Unable to delete %s},
        $input->{file},
      }
    );
    return;
  }
  return TRUE;
}

# Process the active (not committed or saved) configuration
sub get_cfg_actv {
  my $config       = new Vyatta::Config;
  my $input        = shift;
  my $exists       = q{existsOrig};
  my $listNodes    = q{listOrigNodes};
  my $returnValue  = q{returnOrigValue};
  my $returnValues = q{returnOrigValues};

  if ( is_configure() ) {
    $exists       = q{exists};
    $listNodes    = q{listNodes};
    $returnValue  = q{returnValue};
    $returnValues = q{returnValues};
  }

# Check to see if blacklist is configured
  $config->setLevel(q{service dns forwarding});
  my $blklst_exists = $config->$exists(q{blacklist}) ? TRUE : FALSE;

  if ($blklst_exists) {
    $config->setLevel(q{service dns forwarding blacklist});
    $input->{config}->{disabled} = $config->$returnValue(q{disabled}) // FALSE;
    $input->{config}->{dns_redirect_ip}
      = $config->$returnValue(q{dns-redirect-ip}) // q{0.0.0.0};

    for my $key ( $config->$returnValues(q{exclude}) ) {
      $input->{config}->{exclude}->{$key} = 1;
    }

    $input->{config}->{disabled}
      = $input->{config}->{disabled} eq q{false} ? FALSE : TRUE;

    for my $area (qw{hosts domains zones}) {
      $config->setLevel(qq{service dns forwarding blacklist $area});
      $input->{config}->{$area}->{dns_redirect_ip}
        = $config->$returnValue(q{dns-redirect-ip})
        // $input->{config}->{dns_redirect_ip};

      for my $key ( $config->$returnValues(q{include}) ) {
        $input->{config}->{$area}->{blklst}->{$key} = 1;
      }

      for my $key ( $config->$returnValues(q{exclude}) ) {
        $input->{config}->{$area}->{exclude}->{$key} = 1;
      }

      if ( !keys %{ $input->{config}->{$area}->{exclude} } ) {
        $input->{config}->{$area}->{exclude} = {};
      }

      if ( !keys %{ $input->{config}->{exclude} } ) {
        $input->{config}->{exclude} = {};
      }

      for my $source ( $config->$listNodes(q{source}) ) {
        $config->setLevel(
          qq{service dns forwarding blacklist $area source $source});
        @{ $input->{config}->{$area}->{src}->{$source} }{qw(prefix url)}
          = ( $config->$returnValue(q{prefix}), $config->$returnValue(q{url}) );
      }
    }
  }
  else {
    $input->{show} = TRUE;
    log_msg(
      {
        msg_typ => q{error},
        msg_str =>
          q{[service dns forwarding blacklist is not configured], exiting!},
      }
    );

    return;
  }
  if ( ( !scalar keys %{ $input->{config}->{domains}->{src} } )
    && ( !scalar keys %{ $input->{config}->{hosts}->{src} } )
    && ( !scalar keys %{ $input->{config}->{zones}->{src} } ) )
  {
    $input->{show} = TRUE;
    log_msg(
      {
        msg_ref => q{error},
        msg_str => q{At least one domain or host source must be configured},
      }
    );
    return;
  }
  return TRUE;
}

# Process a configuration file in memory after get_file() loads it
sub get_cfg_file {
  my $input = shift;
  my $tmp_ref
    = get_nodes( { config_data => get_file( { file => $input->{file} } ) } );
  my $configured
    = (  $tmp_ref->{domains}->{source}
      || $tmp_ref->{hosts}->{source}
      || $tmp_ref->{zones}->{source} ) ? TRUE : FALSE;

  if ($configured) {
    $input->{config}->{dns_redirect_ip} = $tmp_ref->{q{dns-redirect-ip}}
      // q{0.0.0.0};
    $input->{config}->{disabled}
      = $tmp_ref->{disabled} eq q{false} ? FALSE : TRUE;
    $input->{config}->{exclude}
      = exists $tmp_ref->{exclude} ? $tmp_ref->{exclude} : ();

    for my $area (qw{hosts domains zones}) {
      $input->{config}->{$area}->{dns_redirect_ip}
        = $input->{config}->{dns_redirect_ip}
        if !exists( $tmp_ref->{$area}->{q{dns-redirect-ip}} );

      @{ $input->{config}->{$area} }{qw(blklst exclude src)}
        = @{ $tmp_ref->{$area} }{qw(include exclude source)};

    }
  }
  else {
    log_msg(
      {
        msg_typ => q{error},
        msg_str =>
          q{[service dns forwarding blacklist] isn't configured, exiting!},
      }
    );
    return;
  }
  return TRUE;
}

# Read a file into memory and return the data to the calling function
sub get_file {
  my $input = shift;
  my @data  = ();
  if ( -f $input->{file} ) {
    open my $CF, q{<}, $input->{file}
      or die qq{error: Unable to open $input->{file}: $!};
    chomp( @data = <$CF> );

    close $CF;
  }
  return $input->{data} = \@data;
}

# Build hashes from the configuration file data (called by get_nodes())
sub get_hash {
  my $input    = shift;
  my $hash     = \$input->{hash_ref};
  my @nodes    = @{ $input->{nodes} };
  my $value    = pop @nodes;
  my $hash_ref = ${$hash};

  for my $key (@nodes) {
    $hash = \${$hash}->{$key};
  }

  ${$hash} = $value if $value;
  return $hash_ref;
}

# Process a configure file and extract the blacklist data set
sub get_nodes {
  my $input = shift;
  my ( @hasher, @nodes );
  my $cfg_ref = {};
  my $leaf    = 0;
  my $level   = 0;
  my $re      = {
    BRKT => qr/[}]/o,
    CMNT => qr/^(?<LCMT>[\/*]+).*(?<RCMT>[*\/]+)$/o,
    DESC => qr/^(?<NAME>[\w-]+)\s"?(?<DESC>[^"]+)?"?$/o,
    MPTY => qr/^$/o,
    LEAF => qr/^(?<LEAF>[\w\-]+)\s(?<NAME>[\S]+)\s[{]{1}$/o,
    LSPC => qr/\s+$/o,
    MISC => qr/^(?<MISC>[\w-]+)$/o,
    MULT => qr/^(?<MULT>(?:include|exclude)+)\s(?<VALU>[\S]+)$/o,
    NAME => qr/^(?<NAME>[\w\-]+)\s(?<VALU>[\S]+)$/o,
    NODE => qr/^(?<NODE>[\w-]+)\s[{]{1}$/o,
    RSPC => qr/^\s+/o,
  };

LINE:
  for my $line ( @{ $input->{config_data} } ) {
    $line =~ s/$re->{LSPC}//;
    $line =~ s/$re->{RSPC}//;

    for ($line) {
      when (/$re->{MULT}/) {
        pushx( \@nodes, [ $+{MULT}, $+{VALU}, 1 ], 3 );
        get_hash( { nodes => \@nodes, hash_ref => $cfg_ref } );
        popx( \@nodes, 3 );
      }
      when (/$re->{NODE}/) {
        push @nodes, $+{NODE};
      }
      when (/$re->{LEAF}/) {
        $level++;
        pushx( \@nodes, [ $+{LEAF}, $+{NAME} ], 2 );
      }
      when (/$re->{NAME}/) {
        pushx( \@nodes, [ $+{NAME}, $+{VALU} ], 2 );
        get_hash( { nodes => \@nodes, hash_ref => $cfg_ref } );
        popx( \@nodes, 2 );
      }
      when (/$re->{DESC}/) {
        pushx( \@nodes, [ $+{NAME}, $+{DESC} ], 2 );
        get_hash( { nodes => \@nodes, hash_ref => $cfg_ref } );
        popx( \@nodes, 2 );
      }
      when (/$re->{MISC}/) {
        pushx( \@nodes, [ $+{MISC} ], 2 );
        get_hash( { nodes => \@nodes, hash_ref => $cfg_ref } );
        popx( \@nodes, 2 );
      }
      when (/$re->{CMNT}/) {
        next;
      }
      when (/$re->{BRKT}/) {
        pop @nodes;
        if ( $level > 0 ) {
          pop @nodes;
          $level--;
        }
      }
      when (/$re->{MPTY}/) {
        next LINE;
      }
      default {
        printf q{Parse error: "%s"}, $line;
      }
    }
  }
  return $cfg_ref->{service}->{dns}->{forwarding}->{blacklist};
}

# Get lists from web servers
sub get_url {
  my $input = shift;
  my $ua    = HTTP::Tiny->new;
  $ua->agent(
    q{Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11) AppleWebKit/601.1.56 (KHTML, like Gecko) Version/9.0 Safari/601.1.56}
  );

#   $ua->timeout(60);
  $input->{prefix} =~ s/^["](?<UNCMT>.*)["]$/$+{UNCMT}/g;
  my $re = {
    REJECT => qr{\A#|\A\z|\A\n}oms,
    SELECT => qr{\A $input->{prefix} .*\z}xoms,
    SPLIT  => qr{\R|<br \/>}oms,
  };

  my $get = $ua->get( $input->{url} );

  if ( $get->{success} ) {
    $input->{data} = {
      map { my $key = $_; lc($key) => 1 }
        grep { $_ =~ /$re->{SELECT}/ } split /$re->{SPLIT}/,
      $get->{content}
    };
    return $input;
  }
  else {
    $input->{data} = {};
    return $input;
  }
}

# Make sure script runs as root
sub is_admin {
  return TRUE if geteuid() == 0;
  return;
}

# Get build #
sub is_build {
  my $input = is_version();

  # v1.2.0: build 4574253
  # v1.4.1: build 4648309
  # v1.5.0: build 4677648
  # v1.6.0: build 4716006
  # v1.7.0: build 4783374

  if ( $input->{build} >= 4783374 )    # script tested on os v1.7.0 & above
  {
    return TRUE;
  }
  elsif ( $input->{build} < 4783374 )    # os must be upgraded
  {
    return;
  }
}

# Check to see if we are being run under configure
sub is_configure {
  qx{/bin/cli-shell-api inSession};
  return $? >> 8 != 0 ? FALSE : TRUE;
}

# get EdgeOS version
sub is_version {
  my ( $build, $version ) = ( q{UNKNOWN BUILD}, q{UNKNOWN VERSION} );
  my $cmd = qq{cat /opt/vyatta/etc/version};
  chomp( my $edgeOS = qx{$cmd} );

  if ( $edgeOS =~ m/^Version/ ) {
    if ( $edgeOS =~ s{^Version:\s*(?<VERSION>.*)$}{$+{VERSION}}xms ) {
      my @ver = split /\./, $edgeOS;
      $version = join ".", @ver[ 0, 1, 2 ];
      $build = $ver[3];
    }
  }
  return { version => $version, build => $build };
}

# Log and print (if -v)
sub log_msg {
  my $input   = shift;
  my $log_msg = {
    alert    => LOG_ALERT,
    critical => LOG_CRIT,
    debug    => LOG_DEBUG,
    error    => LOG_ERR,
    info     => LOG_NOTICE,
    warning  => LOG_WARNING,
  };

  return unless ( length $input->{msg_typ} . $input->{msg_str} > 2 );

  syslog( $log_msg->{ $input->{msg_typ} },
    qq{$input->{msg_typ}: } . $input->{msg_str} );

  print $c->{off}, qq{\r}, q{ } x $input->{cols}, qq{\r} if $input->{show};

  if ( $input->{msg_typ} eq q{info} ) {
    print $c->{off}, qq{$input->{msg_typ}: $input->{msg_str}} if $input->{show};
  }
  else {
    print STDERR $c->{off}, $c->{red},
      qq{$input->{msg_typ}: $input->{msg_str}$c->{clr}}
      if $input->{show};
  }

  return TRUE;
}

# pop array x times
sub popx {
  my ( $array, $count ) = ( shift, shift );
  return if !@{$array};
  for ( 1 .. $count ) {
    pop @{$array};
  }
  return TRUE;
}

# Crunch the data and throw out anything we don't need
sub process_data {
  my $input = shift;
  my $re    = {
    FQDOMN =>
      qr{(\b(?:(?![.]|-)[\w-]{1,63}(?<!-)[.]{1})+(?:[a-zA-Z]{2,63})\b)}o,
    LSPACE => qr{\A\s+}oms,
    RSPACE => qr{\s+\z}oms,
    PREFIX => qr{\A $input->{prefix} }xms,
    SUFFIX => qr{(?:#.*\z|\{.*\z|[/[].*\z)}oms,
  };

  # Clear the status lines
  print $c->{off}, qq{\r}, qq{ } x $input->{cols}, qq{\r} if $input->{show};

# Process the lines we've been given
LINE:
  for my $line ( keys %{ $input->{data} } ) {
    next LINE if $line eq q{} || !defined $line;
    $line =~ s/$re->{PREFIX}//;
    $line =~ s/$re->{SUFFIX}//;
    $line =~ s/$re->{LSPACE}//;
    $line =~ s/$re->{RSPACE}//;

    # Get all of the FQDNs or domains in the line
    my @elements = $line =~ m/$re->{FQDOMN}/gc;
    next LINE if !scalar @elements;

    # We use map to individually pull 1 to N FQDNs or domains from @elements
    for my $element (@elements) {

      # Break it down into it components
      my @domain = split /[.]/, $element;

      # Create an array of all the subdomains
      my @keys;
      for ( 2 .. @domain ) {
        push @keys, join q{.}, @domain;
        shift @domain;
      }

      # Have we seen this key before?
      my $key_exists = FALSE;
      for my $key (@keys) {
        if ( exists $input->{config}->{ $input->{area} }->{exclude}->{$key} ) {
          $key_exists = TRUE;
          $input->{config}->{ $input->{area} }->{exclude}->{$key}++;
        }
      }

      # Now add the key, convert to .domain.tld if only two elements
      if ( !$key_exists ) {
        $input->{config}->{ $input->{area} }->{src}->{ $input->{src} }
          ->{blklst}->{$element} = 1;
      }
      else {
        $input->{config}->{ $input->{area} }->{src}->{ $input->{src} }
          ->{duplicates}++;
      }

      # Add to the exclude list, so the next source doesnt duplicate values
      $input->{config}->{ $input->{area} }->{exclude}->{$element} = 1;
    }

    $input->{config}->{ $input->{area} }->{src}->{ $input->{src} }->{icount}
      += scalar @elements;

    printf
      qq{$c->{off}%s: $c->{grn}%s$c->{clr} %s processed, ($c->{red}%s$c->{clr} discarded) from $c->{mag}%s$c->{clr} lines\r},
      $input->{src},
      $input->{config}->{ $input->{area} }->{src}->{ $input->{src} }->{icount},
      $input->{config}->{ $input->{area} }->{type},
      @{ $input->{config}->{ $input->{area} }->{src}->{ $input->{src} } }
      { q{duplicates}, q{records} }
      if $input->{show};
  }

  if (
    scalar $input->{config}->{ $input->{area} }->{src}->{ $input->{src} }
    ->{icount} )
  {
    log_msg(
      {
        msg_typ => q{info},
        msg_str => sprintf
          qq{%s: %s %s processed, (%s duplicates) from %s lines\r},
        $input->{src},
        $input->{config}->{ $input->{area} }->{src}->{ $input->{src} }
          ->{icount}, $input->{config}->{ $input->{area} }->{type},
        @{ $input->{config}->{ $input->{area} }->{src}->{ $input->{src} } }
          { q{duplicates}, q{records} },
      }
    );
    return TRUE;
  }
  return;
}

# push array x times
sub pushx {
  my ( $array, $items, $count ) = ( shift, shift, shift );
  return if !@{$array};
  for my $i ( 0 .. $count - 1 ) {
    push @{$array}, $items->[$i];
  }
  return TRUE;
}

# Write the data to file
sub write_file {
  my $input = shift;

  return if !@{ $input->{data} };

  open my $FH, q{>}, $input->{file} or return;
  log_msg(
    {
      msg_typ => q{info},
      msg_str => sprintf q{Saving %s},
      basename( $input->{file} ),
    }
  );

  print {$FH} @{ $input->{data} };

  close $FH;

  return TRUE;
}

1;
__END__

=head1 Blacklist

EdgeOS::DNS::Blacklist - Perl extension for EdgeOS dnsmasq blacklist configuration file generation

=head1 SYNOPSIS

  use EdgeOS::DNS::Blacklist (qw{
  delete_file
  get_cfg_actv
  get_cfg_file
  get_file
  get_url
  is_admin
  is_configure
  log_msg
  popx
  process_data
  pushx
  usage
  write_file});

=head1 DESCRIPTION

Module provides functions for creating dnsmasq configuration files to redirect
dns look ups to alternative IPs (blackholes, pixel servers etc.)

=head2 EXPORT

None by default.

=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.


If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Neil Beadle, E<lt>blacklist@empirecreekcircle.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015 by Neil Beadle

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.23.4 or,
at your option, any later version of Perl 5 you may have available.


=cut