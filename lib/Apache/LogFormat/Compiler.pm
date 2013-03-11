package Apache::LogFormat::Compiler;

use strict;
use warnings;
use 5.008005;
use Carp;
use POSIX ();
use Time::Local qw//;
use Plack::Util;

our $VERSION = '0.03';

# copy from Plack::Middleware::AccessLog
our %formats = (
    common => '%h %l %u %t "%r" %>s %b',
    combined => '%h %l %u %t "%r" %>s %b "%{Referer}i" "%{User-agent}i"',
);

my $tzoffset = POSIX::strftime("%z", localtime);
if ( $tzoffset !~ /^[+-]\d{4}$/ ) {
    my @t = localtime(time);
    my $s = Time::Local::timegm(@t) - Time::Local::timelocal(@t);
    $tzoffset = sprintf '%+03d%02u', int($s/3600), $s % 3600;
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

my $block_handler = sub {
    my($block, $type) = @_;
    my $cb;
    if ($type eq 'i') {
        $block =~ s/-/_/g;
        $cb =  q!_string($env->{"HTTP_" . uc('!.$block.q!')})!;
    } elsif ($type eq 'o') {
        $cb =  q!_string(scalar Plack::Util::headers($res->[1])->get('!.$block.q!'))!;
    } elsif ($type eq 't') {
        $cb =  q!"[" . _strftime('!.$block.q!', localtime($time)) . "]"!;
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
    T => q!int($reqtime*1_000_000)!,
    D => q!$reqtime!,
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
    my $char = shift;
    my $cb = $char_handler{$char};
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

    my $self = bless {
        fmt => $fmt
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
             \%\{(.+?)\}([a-z]) |
             \%(?:[<>])?([a-zA-Z\%])
        )
    ! $1 ? $block_handler->($1, $2) : $char_handler->($3) !egx;

    my @abbr = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
    my $tz = $tzoffset;
    $fmt = q~sub {
        my ($env,$res,$length,$reqtime,$time) = @_;
        $reqtime ||= 0;
        $time ||= time();
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

Apache::LogFormat::Compiler - Compile LogFormat to perl-code 

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

Compile LogFormat to perl-code. For faster generating access_log line.

B<THIS IS A DEVELOPMENT RELEASE. API MAY CHANGE WITHOUT NOTICE>.

=head1 METHOD

=over 4

=item new($fmt:String)

Takes a format string (or a preset template C<combined> or C<custom>)
to specify the log format. This middleware implements a subset of
L<Apache's LogFormat templates|http://httpd.apache.org/docs/2.0/mod/mod_log_config.html>:

   %%    a percent sign
   %h    REMOTE_ADDR from the PSGI environment, or -
   %l    remote logname not implemented (currently always -)
   %u    REMOTE_USER from the PSGI environment, or -
   %t    [local timestamp, in default format]
   %r    REQUEST_METHOD, REQUEST_URI and SERVER_PROTOCOL from the PSGI environment
   %s    the HTTP status code of the response
   %b    content length
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

Some of these format fields are only supported by middleware that subclasses C<AccessLog>.

In addition, custom values can be referenced, using C<%{name}>,
with one of the mandatory modifier flags C<i>, C<o> or C<t>:

   %{variable-name}i    HTTP_VARIABLE_NAME value from the PSGI environment
   %{header-name}o      header-name header
   %{time-format]t      localtime in the specified strftime format

=item log_line($env:HashRef,$res:ArrayRef,$length:Integer,$reqtime:Integer,$time:Integer): $log:String

Generates log line.

  $env      PSGI-style $env
  $res      PSGI-style $res
  $length   Content-Length
  $reqtime  the time taken to serve request in microseconds 
  $time     time the request was received

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

=head1 AUTHOR

Masahiro Nagano E<lt>kazeburo@gmail.comE<gt>

=head1 SEE ALSO

L<Plack::Middleware::AccessLog>, L<http://httpd.apache.org/docs/2.2/mod/mod_log_config.html>

=head1 LICENSE

Copyright (C) Masahiro Nagano

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
