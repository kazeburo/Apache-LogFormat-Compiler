package Apache::LogFormat::Compiler;

use strict;
use warnings;
use 5.008005;
use Carp;
use POSIX ();
use Time::Local qw//;

our $VERSION = '0.13';

# copy from Plack::Middleware::AccessLog
our %formats = (
    common => '%h %l %u %t "%r" %>s %b',
    combined => '%h %l %u %t "%r" %>s %b "%{Referer}i" "%{User-agent}i"',
);

my $tzoffset = POSIX::strftime("%z", localtime);
if ( $tzoffset !~ /^[+-]\d{4}$/ ) {
    my @t = localtime(time);
    my $s = Time::Local::timegm(@t) - Time::Local::timelocal(@t);
    my $min_offset = int($s / 60);
    $tzoffset = sprintf '%+03d%02u', $min_offset / 60, $min_offset % 60;
}

sub _strftime {
    my ($fmt, @time) = @_;
    $fmt =~ s/%z/$tzoffset/g if $tzoffset;
    my $old_locale = POSIX::setlocale(&POSIX::LC_ALL);
    POSIX::setlocale(&POSIX::LC_ALL, 'C');
    my $out = POSIX::strftime($fmt, @time);
    POSIX::setlocale(&POSIX::LC_ALL, $old_locale);
    return $out;
};

sub _safe {
    my $string = shift;
    return unless defined $string;
    $string =~ s/([^[:print:]])/"\\x" . unpack("H*", $1)/eg;
    return $string;
}

sub _string {
    my $string = shift;
    return '-' if ! defined $string;
    return '-' if ! length $string;
    _safe($string);
}

sub header_get {
    my ($headers, $key) = @_;
    $key = lc $key;
    my @headers = @$headers; # copy
    my $value;
    while (my($hdr, $val) = splice @headers, 0, 2) {
        if ( lc $hdr eq $key ) {
            $value = $val;
            last;
        }
    }
    return $value;
}

my $psgi_reserved = { CONTENT_LENGTH => 1, CONTENT_TYPE => 1 };

my $block_handler = sub {
    my($self,$block, $type) = @_;
    my $cb;
    if ($type eq 'i') {
        $block =~ s/-/_/g;
        $block = uc($block);
        $block = "HTTP_${block}" unless $psgi_reserved->{$block};
        $cb =  q!_string($env->{'!.$block.q!'})!;
    } elsif ($type eq 'o') {
        $cb =  q!_string(header_get($res->[1],'!.$block.q!'))!;
    } elsif ($type eq 't') {
        $cb =  q!"[" . _strftime('!.$block.q!', localtime($time)) . "]"!;
    } elsif (exists $self->{extra_block_handlers}->{$type}) {
        $cb =  q!_string($extra_block_handlers->{'!.$type.q!'}->('!.$block.q!',$env,$res,$length,$reqtime))!;
    } else {
        Carp::croak("{$block}$type not supported");
        $cb = "-";
    }
    return q|! . | . $cb . q|
      . q!|;
};

our %char_handler = (
    '%' => q!'%'!,
    h => q!($env->{REMOTE_ADDR} || '-')!,
    l => q!'-'!,
    u => q!($env->{REMOTE_USER} || '-')!,
    t => q!"[" . $t . "]"!,
    r => q!_safe($env->{REQUEST_METHOD}) . " " . _safe($env->{REQUEST_URI}) .
                       " " . $env->{SERVER_PROTOCOL}!,
    s => q!$res->[0]!,
    b => q!(defined $length ? $length : '-')!,
    T => q!(defined $reqtime ? int($reqtime*1_000_000) : '-')!,
    D => q!(defined $reqtime ? $reqtime : '-')!,
    v => q!($env->{SERVER_NAME} || '-')!,
    V => q!($env->{HTTP_HOST} || $env->{SERVER_NAME} || '-')!,
    p => q!$env->{SERVER_PORT}!,
    P => q!$$!,
    m => q!_safe($env->{REQUEST_METHOD})!,
    U => q!_safe($env->{PATH_INFO})!,
    q => q!(($env->{QUERY_STRING} ne '') ? '?' . _safe($env->{QUERY_STRING}) : '' )!,
    H => q!$env->{SERVER_PROTOCOL}!,

);

my $char_handler = sub {
    my $self = shift;
    my $char = shift;
    my $cb = $char_handler{$char};
    if (!$cb && exists $self->{extra_char_handlers}->{$char}) {
        $cb = q!_string($extra_char_handlers->{'!.$char.q!'}->($env,$res,$length,$reqtime))!;
    }
    unless ($cb) {
        Carp::croak "\%$char not supported.";
        return "-";
    }
    q|! . | . $cb . q|
      . q!|;
};

sub new {
    my $class = shift;

    my $fmt = shift || "combined";
    $fmt = $formats{$fmt} if exists $formats{$fmt};

    my %opts = @_;

    my $self = bless {
        fmt => $fmt,
        extra_block_handlers => $opts{block_handlers} || {},
        extra_char_handlers => $opts{char_handlers} || {},
    }, $class; 
    $self->compile();
    return $self;
}

sub compile {
    my $self = shift;
    my $fmt = $self->{fmt};
    $fmt =~ s/!/\\!/g;
    $fmt =~ s!
        (?:
             \%\{(.+?)\}([a-zA-Z]) |
             \%(?:[<>])?([a-zA-Z\%])
        )
    ! $1 ? $block_handler->($self, $1, $2) : $char_handler->($self, $3) !egx;

    my @abbr = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
    my $tz = $tzoffset;
    my $extra_block_handlers = $self->{extra_block_handlers};
    my $extra_char_handlers = $self->{extra_char_handlers};
    $fmt = q~sub {
        my ($env,$res,$length,$reqtime,$time) = @_;
        $time = time() if ! defined $time;
        my @lt = localtime($time);;
        my $t = sprintf '%02d/%s/%04d:%02d:%02d:%02d %s', $lt[3], $abbr[$lt[4]], $lt[5]+1900, 
          $lt[2], $lt[1], $lt[0], $tz;
        q!~ . $fmt . q~!
    }~;
    $self->{log_handler_code} = $fmt;
    $self->{log_handler} = eval $fmt; ## no critic
}

sub log_line {
    my $self = shift;
    my ($env,$res,$length,$reqtime,$time) = @_;
    my $log = $self->{log_handler}->($env,$res,$length,$reqtime,$time);
    $log . "\n";
}

1;
__END__

=encoding utf8

=head1 NAME

Apache::LogFormat::Compiler - Compile a log format string to perl-code 

=head1 SYNOPSIS

  use Apache::LogFormat::Compiler;

  my $log_handler = Apache::LogFormat::Compiler->new("combined");
  my $log = $log_handler->log_line(
      $env,
      $res,
      $length,
      $reqtime,
      $time
  );

=head1 DESCRIPTION

Compile a log format string to perl-code. For faster generation of access_log lines.

=head1 METHOD

=over 4

=item new($fmt:String)

Takes a format string (or a preset template C<combined> or C<custom>)
to specify the log format. This module implements a subset of
L<Apache's LogFormat templates|http://httpd.apache.org/docs/2.0/mod/mod_log_config.html>:

   %%    a percent sign
   %h    REMOTE_ADDR from the PSGI environment, or -
   %l    remote logname not implemented (currently always -)
   %u    REMOTE_USER from the PSGI environment, or -
   %t    [local timestamp, in default format]
   %r    REQUEST_METHOD, REQUEST_URI and SERVER_PROTOCOL from the PSGI environment
   %s    the HTTP status code of the response
   %b    content length of the response
   %T    custom field for handling times in subclasses
   %D    custom field for handling sub-second times in subclasses
   %v    SERVER_NAME from the PSGI environment, or -
   %V    HTTP_HOST or SERVER_NAME from the PSGI environment, or -
   %p    SERVER_PORT from the PSGI environment
   %P    the worker's process id
   %m    REQUEST_METHOD from the PSGI environment
   %U    PATH_INFO from the PSGI environment
   %q    QUERY_STRING from the PSGI environment
   %H    SERVER_PROTOCOL from the PSGI environment

In addition, custom values can be referenced, using C<%{name}>,
with one of the mandatory modifier flags C<i>, C<o> or C<t>:

   %{variable-name}i    HTTP_VARIABLE_NAME value from the PSGI environment
   %{header-name}o      header-name header in the response
   %{time-format]t      localtime in the specified strftime format

=item log_line($env:HashRef, $res:ArrayRef, $length:Integer, $reqtime:Integer, $time:Integer): $log:String

Generates log line.

  $env      PSGI env request HashRef
  $res      PSGI response ArrayRef
  $length   Content-Length
  $reqtime  The time taken to serve request in microseconds. optional
  $time     Time the request was received. optional. If $time is undefined. current timestamp is used.

Sample psgi 

  use Plack::Builder;
  use Time::HiRes;
  use Apache::LogFormat::Compiler;

  my $log_handler = Apache::LogFormat::Compiler->new(
      '%h %l %u %t "%r" %>s %b "%{Referer}i" "%{User-agent}i" %D'
  );
  my $compile_log_app = builder {
      enable sub {
          my $app = shift;
          sub {
              my $env = shift;
              my $t0 = [gettimeofday];
              my $res = $app->();
              my $reqtime = int(Time::HiRes::tv_interval($t0) * 1_000_000);
              $env->{psgi.error}->print($log_handler->log_line(
                  $env,$res,6,$reqtime, $t0->[0]));
          }
      };
      $app
  };

=back

=head1 ADD CUSTOM FORMAT STRING

Apache::LogFormat::Compiler allows one to add a custom format string

  my $log_handler = Apache::LogFormat::Compiler->new(
      '%z %{HTTP_X_FORWARDED_FOR|REMOTE_ADDR}Z',
      char_handlers => +{
          'z' => sub {
              my ($env,$req) = @_;
              return $env->{HTTP_X_FORWARDED_FOR};
          }
      },
      block_handlers => +{
          'Z' => sub {
              my ($block,$env,$req) = @_;
              # block eq 'HTTP_X_FORWARDED_FOR|REMOTE_ADDR'
              my ($main, $alt) = split('\|', $args);
              return exists $env->{$main} ? $env->{$main} : $env->{$alt};
          }
      },
  );

Any single letter can be used, other than those already defined by Apache::LogFormat::Compiler.
Your sub is called with two or three arguments: the content inside the C<{}>
from the format (block_handlers only), the PSGI environment (C<$env>),
and the ArrayRef of the response. It should return the string to be logged.

=head1 AUTHOR

Masahiro Nagano E<lt>kazeburo@gmail.comE<gt>

=head1 SEE ALSO

L<Plack::Middleware::AccessLog>, L<http://httpd.apache.org/docs/2.2/mod/mod_log_config.html>

=head1 LICENSE

Copyright (C) Masahiro Nagano

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
