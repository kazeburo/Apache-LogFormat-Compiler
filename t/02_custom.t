use strict;
use warnings;
use HTTP::Request::Common;
use HTTP::Message::PSGI;
use Test::More;
use Apache::LogFormat::Compiler;

my $log_handler = Apache::LogFormat::Compiler->new(q!%{%S}t %{x-res-test}o %{x-req-test}i!);
ok($log_handler);

my $log = $log_handler->log_line(
    req_to_psgi(GET "/", 'X-Req-Test'=>'foo'),
    [200,['X-Res-Test'=>'bar'],[q!OK!]],
    2,
    1_000_000
);
like $log, qr!^\[\d{2}\] bar foo$!;

done_testing();
