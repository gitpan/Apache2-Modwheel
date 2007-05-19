use strict;
use warnings;
no strict 'subs';
use English qw( -no_match_vars );
use ExtUtils::MM_Unix ();

=for comment

BEGIN {
    eval 'use version';
    if ($EVAL_ERROR) {
        die 'Modwheel requires the version module. '            .
            'You can download version from CPAN: '              .
            "http://search.cpan.org/~jpeacock/version-0.71/.\n"
        ;
    }
    eval "use Readonly";
    if ($EVAL_ERROR) {
        die 'Apache2::Modwheel requires the Readonly module. '  .
            'You can download Readonly from CPAN: '             .
            "http://search.cpan.org/~roode/Readonly-1.03/\n"
        ;
    }
}

use version;
use Readonly;

my $v = version->new;

Readonly my $MAIN_DIST_FILE => 'lib/Apache2/Modwheel.pm';

my $modwheel_version
    = ExtUtils::MM_Unix->parse_version($MAIN_DIST_FILE);
my $modwheel_numified_version
    = version->new($modwheel_version)->numify;

=cut

use inc::Module::Install;
    
# Define metadata
name            'Apache2-Modwheel';
version         '0.2.3';
all_from        'lib/Apache2/Modwheel.pm';
author          'Ask Solem <ask@0x61736b.net>';
license         'perl';

    
# Specific dependencies
requires        'namespace::clean'          => 0;
requires        'version'                   => 0;
requires        'Carp'                      => 0;
requires        'Scalar::Util'              => 1.14;
requires        'Readonly'                  => 1.00;
requires        'Modwheel'                  => 0.000002;
requires        'mod_perl2'                 => 2.00;
requires        'Tie::IxHash'               => 1.21;
requires        'Parse::RecDescent'         => 1.94;
requires        'ExtUtils::XSBuilder::ParseSource' => 0.03;
requires        'Apache2::Request'          => 2.00;
requires        'Apache2::Upload'           => 2.00;

build_requires  'Test::More'                => 0.42;
recommends      'Test::YAML::Meta'          => 0.04;
recommends      'Test::Kwalitee'            => 0.30;
    
#no_index        'directory'         => 'demos';
#install_script  'bin/myscript';
    
auto_install;
WriteAll;
