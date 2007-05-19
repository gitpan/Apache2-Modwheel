use strict;
use warnings;
use inc::Module::Build::Modwheel;

sub YES { 1 };
sub NO  { 0 };

# if set to a string, we should create the installation directory.
my $prefix = q{};

my $builder = Module::Build->new(
    module_name          => 'Apache2-Modwheel',
    license              => 'perl',
    dist_author          => 'Ask Solem <ASKSH@cpan.org>',
    dist_version_from    => 'lib/Apache2/Modwheel.pm',
    dynamic_config       => NO,
    sign                 => NO,
    recursive_test_files => YES,
    requires             => {
        'Modwheel'              => '0.2.3',
        'mod_perl2'             => 2.00,
        'Tie::IxHash'           => 1.21,
        'Parse::RecDescent'     => 1.94,
        'ExtUtils::XSBuilder::ParseSource' => 0.03,
        'Apache2::Request'      => 2.00,
        'Apache2::Upload'       => 2.00,
        'namespace::clean'      => 0,
        'version'               => 0,
        'Carp'                  => 0,
        'Scalar::Util'          => 0,
        'Readonly'              => 1.00,
    },
    recommends           => {
        'Test::Pod'             => 0,
        'Pod::Coverage'         => 0,
        'Test::Pod::Coverage'   => 0,
        'Readonly::XS'          => 1.00,
        'Test::Kwalitee'        => 0.30,
        'Test::YAML::Meta'      => 0.004,
    },
    build_requires       => {
        'Test::More'            => 0.42,
    },
    add_to_cleanup       => [ qw(
        a.out
        test.pl
        test.c
        test.cpp
        test.m
        *.swp
        .gdb_history
        install.cache
        t/cache
    ) ],
    meta_merge          => {
        resources           => {
            HomePage            => 'http://www.0x61736b.net/Modwheel',
            Download            => 'http://search.cpan.org/~asksh/Apache2-Modwheel-0.2.3/',
        },
        distribution_type   => 'Application',
    },
    
);

$builder->create_build_script( );

