package inc::Module::Build::Modwheel;

use strict;
use warnings;
use base 'Module::Build';

use File::Path;
use Data::Dumper;
use File::Spec::Functions qw(splitpath catfile);
use English qw( -no_match_vars );

sub new {
    my $class  = shift;
    my $self   = $class->SUPER::new(@_);
    my %args   = @_;
    my $config = $self->notes( 'config_data' ) || { };
        
    for my $question ( @{ $args{config_questions} } ) {
        my ($q, $name, $default) = map { defined $_ ? $_ : '' } @$question;
        $config->{$name} = $self->prompt( $q, $default );
    }

   $self->notes( 'config_module', $args{config_module} );
   $self->notes( 'config_data',   $config );
   return $self;
}

sub ACTION_build {
    my $self = shift;

    $self->write_config( );
    $self->SUPER::ACTION_build(@_);
    return;
}

sub write_config {
    my ($self) = @_;
    my $file = $self->notes( 'config_module' );
    my $data = $self->notes( 'config_data'   );
    my $dump = Data::Dumper->new([$data], ['config_data'])->Dump;
    my $file_path = catfile( 'blib', split( m/::/xms, $file . '.pm' ) );

    my $path = ( splitpath( $file_path ) )[1];
    mkpath( $path ) unless -d $path;

    my $package = <<"END_MODULE";
        package $file;

        my $dump;

        sub get_value {
            my (\$class, \$key) = \@_;
            return unless exists \$config_data->{\$key};
            return               \$config_data->{\$key};
        }

        1;
END_MODULE
    ;

    $package =~ s/^\t//gm;

    open( my $fh, '>', $file_path )
        or die "Cannot write config file module '$path': $OS_ERROR\n";
    print {$fh} $package;
    close $fh;
}

1;
