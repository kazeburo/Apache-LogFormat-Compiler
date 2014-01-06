use strict;
use warnings;
use Test::More;
use POSIX;
use Time::Local;
use Test::MockTime qw/set_fixed_time restore_time/;
use t::Req2PSGI;
use Apache::LogFormat::Compiler;
use HTTP::Request::Common;

my @abbr = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
#                   +0930            +900       0   -400
my @timezones = ( 
    ['Australia/Darwin','+0930','+0930','+0930','+0930' ],
    ['Asia/Tokyo', '+0900','+0900','+0900','+0900'],
    ['UTC', '+0000','+0000','+0000','+0000'],
    ['Europe/London', '+0000','+0100','+0100','+0000'],
    ['America/New_York','-0500', '-0400', '-0400', '-0500']
);

for my $timezones (@timezones) {
    my ($timezone, @tz) = @$timezones;
    local $ENV{TZ} = $timezone;
    POSIX::tzset;
    my $log_handler = Apache::LogFormat::Compiler->new('%t');

    subtest "$timezone" => sub {
        for my $date ( ([10,1,2013], [10,5,2013], [15,8,2013], [15,11,2013]) ) {
            my ($day,$month,$year) = @$date;
            
            set_fixed_time(timelocal(0, 45, 12, $day, $month - 1, $year));
            my $tz = shift @tz;

            my $log = $log_handler->log_line(
                t::Req2PSGI::req_to_psgi(GET "/"),
                [200,[],[q!OK!]],
            );
            
            my $month_name = $abbr[$month-1];
            is $log, "[$day/$month_name/2013:12:45:00 $tz]\n","$timezone $year/$month/$day";
        }
    };
}

done_testing();

