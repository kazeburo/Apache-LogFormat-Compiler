#!/usr/bin/env perl

use strict;
use warnings;
use HTTP::Request::Common;
use HTTP::Message::PSGI;
use Plack::Test;
use Plack::Builder;
use Apache::LogFormat::Compiler;
use Benchmark qw/cmpthese timethese/;

my $log_app = builder {
    enable 'AccessLog', format => "combined";
    sub{ [ 200, [], [ "Hello "] ] };
};

my $log_handler = Apache::LogFormat::Compiler->new();
my $compile_log_app = builder {
    enable sub {
        my $app = shift;
        sub {
            my $env = shift;
            my $res = $app->();
            warn $log_handler->log_line($env,$res,6,0);
        }
    };
    sub{ [ 200, [], [ "Hello "] ] };
};

my $env = req_to_psgi(GET "/");
open(STDERR,'>','/dev/null');

cmpthese(timethese(0,{
    'log'   => sub {
        $log_app->($env);
    },
    'compilelog'   => sub {
        $compile_log_app->($env);
    },
}));

__END__
Benchmark: running compilelog, log for at least 3 CPU seconds...
compilelog:  3 wallclock secs ( 3.03 usr +  0.19 sys =  3.22 CPU) @ 25447.20/s (n=81940)
       log:  3 wallclock secs ( 3.17 usr +  0.01 sys =  3.18 CPU) @ 3226.73/s (n=10261)
              Rate        log compilelog
log         3227/s         --       -87%
compilelog 25447/s       689%         --

