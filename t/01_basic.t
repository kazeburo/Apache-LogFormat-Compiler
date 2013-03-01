use strict;
use warnings;
use HTTP::Request::Common;
use HTTP::Message::PSGI;
use Test::More;
use Apache::LogFormat::Compiler;

my $log_handler = Apache::LogFormat::Compiler->new();
ok($log_handler);

my $log = $log_handler->log_line(
    req_to_psgi(GET "/"),
    [200,[],[q!OK!]],
    2,
    1_000_000
);
like $log, qr!^[a-z0-9\.]+ - - \[\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} [+\-]\d{4}\] "GET / HTTP/1\.1" 200 2 "-" "-"$!;

done_testing();

