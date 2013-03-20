use strict;
use warnings;
use Module::Build;

my $build = Module::Build->new(
    license              => 'perl',
    dynamic_config       => 0,

    build_requires       => {
        'Test::More' => '0.98',
        'Test::Requires' => 0,
        'HTTP::Request::Common' => 0,
        'URI::Escape'    => '1.60',
        'Try::Tiny'      => '0.12',
    },
    configure_requires   => { 'Module::Build' => '0.38' },
    requires             => {
        perl => '5.008005',
        'POSIX'       => '0',
        'Time::Local' => '0',
    },

    no_index    => { 'directory' => [ 'inc' ] },
    name        => 'Apache-LogFormat-Compiler',
    module_name => 'Apache::LogFormat::Compiler',

    # script_files => [''],

    test_files => (-d '.git' || $ENV{RELEASE_TESTING}) ? 't/ xt/' : 't/',
    recursive_test_files => 1,
   
    create_readme  => 1,
    create_license => 1,
);
$build->create_build_script();
