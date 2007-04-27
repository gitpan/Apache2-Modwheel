# ===================================================================== #
# $Id$
# $Source$
# $Author$
# $HeadURL$
# $Revision$
# $Date$
# ===================================================================== #
package Apache2::Modwheel;
use strict;
use warnings;
use 5.00800;
use mod_perl2 2.0;
use Class::InsideOut::Policy::Modwheel qw( :std );
use version; our $VERSION = qv('0.2.1');
{

    use Readonly;
    use Scalar::Util            qw(blessed);
    use Apache2::Access           ();
    use Apache2::RequestRec       ();
    use Apache2::RequestUtil      ();
    use Apache2::RequestIO        ();
    use Apache2::Request          ();
    use Apache2::Upload           ();
    use Apache2::Const            -compile=>
        qw(OK SERVER_ERROR FORBIDDEN NOT_FOUND DECLINED);
    use Modwheel::Session;
    use Time::HiRes qw(gettimeofday);
    use namespace::clean;


    public apache     => my %apache_for,     {is => 'rw'};
    public apreq      => my %apreq_for,      {is => 'rw'};
    public modwheel   => my %modwheel_for,   {is => 'rw'};
    public db         => my %db_for,         {is => 'rw'};
    public user       => my %user_for,       {is => 'rw'};
    public object     => my %object_for,     {is => 'rw'};
    public repository => my %repository_for, {is => 'rw'};
    public template   => my %template_for,   {is => 'rw'};

    public disable_uploads => my %disable_uploads_for, {is => 'rw'};

    # 10MB's Upload Limit.
    Readonly my $MAX_UPLOAD_LIMIT => 10_485_760;

    # --------------------------------------------------------------------- #
    # > loghandler_apache2
    #
    # Log handler for Modwheel.
    # --------------------------------------------------------------------- #
    Readonly my $LOGHANDLER_APACHE2 => sub  {

        my ($modwheel, $log_string, $facility) = @_;
        my $apache2 = $modwheel->logobject;
        my $rlog = $apache2->log;

        if ($facility eq 'Error') {
            return $rlog->error($log_string);
        }
        if ($facility eq 'Warning') {
            return $rlog->warn($log_string);
        }
        if ($facility eq 'Info') {
            return $rlog->info($log_string);
        }
        if ($facility eq 'Debug') {
            return $rlog->debug($log_string);
        }

        return;
    };


    # --------------------------------------------------------------------- #
    # > handler
    #
    # Apache calls this function for each request. (like main( ) )
    # --------------------------------------------------------------------- #
    sub handler : method {
        my ($class_or_object, $r) = @_;
        return Apache2::Const::DECLINED if dont_want_this($r);
        return Apache2::Const::OK       if $r->header_only();

        my ($start_s, $start_ms) = gettimeofday;

        my $self = $class_or_object;
        if(!blessed $self) {
            $self = register( $class_or_object );
        }

        $self->_init($r);
        my $req      = $self->apreq;
        my $modwheel = $self->modwheel;
        my $db       = $self->db;
        my $user     = $self->user;
        my $object   = $self->object;
        my $template = $self->template;

        # Connect to database
        my $no_connect = $r->dir_config('NoDatabaseConnect');
        if (!_find_bool_value($no_connect)) {
            my $use_cache = _find_bool_value($r->dir_config('ModwheelCachedDB'));
            my $ret = $use_cache    ? $db->connect_cached( )
                                    : $db->connect( )
            ;
            return 500 if !$ret;
        }

        # Save user info if user is logged in.
        my $uname   = $r->user || 'guest';
        $user->set_uname($uname);
        if ($db->connected) {
            $user->set_uid( $user->uidbyname($uname) );
        }

        my ($parent, $page) = $self->get_parent_and_page( );

        # Find the filename (page) for this object
        if ($r->dir_config('ModwheelFollowTemplates')) {
            my $o = $object->fetch({id => $parent});
            if ( $o->template ) {
                $page = $o->template;
            }
        }
        $page   ||= $modwheel->siteconfig->{directoryindex};

        # remove leading slash.
        $page =~ s{^/}{}xms;

        # add template dir as prefix to page path
        $page = $modwheel->siteconfig->{templatedir} . q{/} . $page;
        return Apache2::Const::NOT_FOUND if !-f $page;

        if (!$self->disable_uploads && $db->connected) {
            $self->handle_uploads($parent);
        }

        # set up the template object:
        $template->init(
            {   input  => $page,
                param  => $req,
                parent => $parent,
            }
        ) or return simple_print_error($template->errstr);

        my ($end_s, $end_ms) = gettimeofday;
        my $compile_s  = $end_s  - $start_s;
        my $compile_ms = $end_ms - $start_ms;
        my $stash = $template->stash( );
        $stash->set('compile_s', $compile_s);
        $stash->set('compile_ms', $compile_ms);

        my $content_type = $r->dir_config('ContentType') || 'text/html';
        $r->content_type($content_type);

        my $process_args = {};
        my $output = $template->process($process_args);

        $r->print($output);

        $db->disconnect( );

        return Apache2::Const::OK;

    }

    # --------------------------------------------------------------------- #
    # ->_init($r)
    #
    # Set up Modwheel, libapreq2, configuration etc.
    # --------------------------------------------------------------------- #
    sub _init {
        my ($self, $r) = @_;

        my $disable_uploads = $r->dir_config('ModwheelFileUploads');
        $disable_uploads_for{ident $self}
            = _find_bool_value($disable_uploads);

        my $apreq = Apache2::Request->new( $r,
            MAX_BODY        => $MAX_UPLOAD_LIMIT,
            DISABLE_UPLOADS => $disable_uploads,
        );


        # Set up our Modwheel instance.
        my $modwheel_config = {
            prefix              => $r->dir_config('ModwheelPrefix'),
            configfile          => $r->dir_config('ModwheelConfigFile'),
            site                => $r->dir_config('ModwheelSite'),
            locale              => $r->dir_config('Locale'),
            add_loghandlers     => {
                apache2 => $LOGHANDLER_APACHE2,
            },
            logmode             => 'apache2',
            logobject           => $r,
        };

        my ($modwheel, $user, $db, $object, $repository, $template)
            = modwheel_session($modwheel_config);
       
        $apache_for{ident $self}     = $r;
        $apreq_for{ident $self}      = $apreq;
        $modwheel_for{ident $self}   = $modwheel;
        $db_for{ident $self}         = $db;
        $user_for{ident $self}       = $user;
        $repository_for{ident $self} = $repository;
        $template_for{ident $self}   = $template;

        return;
    }

    # --------------------------------------------------------------------- #
    # > dont_want_this($r)
    #
    # User can set up a list of locations we pass on to other handlers,
    # like images, static data etc.
    # --------------------------------------------------------------------- #
    sub dont_want_this {
        my ($r) = @_;

        # we don't care about favicon.ico
        # XXX: this is a hack, must change
        return 1 if $r->uri =~ m/ favicon.ico$ /xms;

        my $dont_handle = $r->dir_config('DontHandle');
        if ($dont_handle) {
            my @dont_handle_locations = split m/ \s+ /xms, $dont_handle;
            foreach my $location (@dont_handle_locations) {

                # remove trailing slashes.
                $location =~ s{ ^/ }{}xms;
                return 1 if $r->uri =~ m{ ^/ \Q$location\E }xms;
            }
        }

        return 0;
    }

    # --------------------------------------------------------------------- #
    # ->get_parent_and_page( )
    #
    # Get the parent node we want + parse the location (i.e /Music/index.html)
    # so we know what file to send to the template driver.
    #
    # Returns: ($parent, $page)
    # --------------------------------------------------------------------- #
    sub get_parent_and_page {
        my ($self) = @_;
        my $r      = $self->apache;
        my $req    = $self->apreq;
        my $db     = $self->db;
        my $object = $self->object;
        my $parent = $req->param('parent');
        my $page   = $r->uri;

        # untaint location.
        my $loc  = quotemeta $r->location;
        $page =~ s/^ $loc \/?//xms;

        # Set up parent id or convert web path to parent id.
        my $use_web_path = $r->dir_config('ModwheelWebPathToId');
        if (_find_bool_value($use_web_path) && $db->connected) {
            if (!$parent) {
                $parent = $object->path_to_id($page);
                if (!$parent) {
                    $db->disconnect();
                    return Apache2::Const::NOT_FOUND;
                }
            }
            $page =~ s{ ^.*/ }{}xms;
            if ($page !~ m/ \.[\w\d_]+$ /xms) {
                undef $page;
            }
        }
        $parent ||= Modwheel::Object::MW_TREE_ROOT;

        return ($parent, $page);
    }

    # --------------------------------------------------------------------- #
    # ->handle_uploads($parent)
    #
    # Pass uploads to the Modwheel Repository system.
    # --------------------------------------------------------------------- #
    sub handle_uploads {
        my ($self, $parent) = @_;
        my $r          = $self->apache;
        my $req        = $self->apreq;
        my $repository = $self->repository;

        # If the user uploads files, add them to the repository.
        my @uploads;
        foreach ($req->upload) {
            my $upload = $req->upload($_);
            if ($upload) {
                my $upload_in = $req->param('id');
                $upload_in ||= $parent;
                my %current_upload = (
                    filename   => $upload->filename,
                    mimetype   => $upload->type,
                    size       => $upload->size,
                    parent     => $upload_in,
                );
                $repository->upload_file($upload->fh, %current_upload);
                push @uploads, \%current_upload;
            }
        }

        return;
    }

    # --------------------------------------------------------------------- #
    # > simple_print_error($r, $errstr)
    #
    # Print error as a simple HTML page to the web-server.
    # --------------------------------------------------------------------- #
    sub simple_print_error {
        my ($r, $errstr) = @_;
        $r->content_type('text/html');
        print <<"HTML"
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
                "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
            <head>
                <title>Modwheel - Error</title>
                <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
            </head>
            <body>
                <h1>Sorry! An error occured.</h1>
                <h3>The error was:</h3>
                <p>$errstr</p>
            </body>
            </html>
HTML
            ;

        return Apache2::Const::OK;
    }

    # --------------------------------------------------------------------- #
    # > _find_bool_value($string)
    #
    # Try to find if a string means "Yes" or "No", "True", "False" and so on.
    # --------------------------------------------------------------------- #
    sub _find_bool_value {
        my ($string) = @_;
        return 0 if !$string;

        return 0 if $string eq '0';
        return 1 if $string eq '1';

        if ($string =~ m/false | no  | off/xmsi) {
            return 0;
        }
        if ($string =~ m/true  | yes | on /xmsi) {
            return 1;
        }

        if ($string =~ m/^\d+$/xms) {
            return 1;
        }

        if ($string eq 'Inf') {
            return 1;
        }

        return;
    }

}

1;
__END__

=head1 NAME

Apache2::Modwheel - Use Modwheel with mod_perl2

=head1 VERSION

This document describes Apache2::Modwheel version 0.0.2

=head1 SYNOPSIS

    <VirtualHost *:80>
            ServerName admin.localhost
        ErrorLog logs/error_log
        <Location />
            SetHandler perl-script                                                                                                             
            PerlAuthenHandler   Apache2::Modwheel::Authen
            PerlResponseHandler Apache2::Modwheel
            PerlSetVar ModwheelPrefix       /opt/devel/Modwheel
            PerlSetVar ModwheelConfigFile   config/modwheelconfig.yml
            PerlSetVar ModwheelSite         Admin
            PerlSetVar ModwheelFileUploads  Yes
            PerlSetVar ModwheelCachedDB     Yes
            PerlSetVar Locale               en_EN
            PerlSetVar DontHandle           "rep javascript css images scriptaculous"
                                                                                                                                          
            AuthType Basic                                                                                                                    
            AuthName "void"                                                                                                                   
            Require valid-user                                                                                                                
        </Location>                                                                                                                           
        Alias /rep /opt/devel/Modwheel/Repository                                                                                             
        Alias /css /opt/devel/Modwheel/Templates/SimpleAdmin/css                                                                              
        Alias /javascript /opt/devel/Modwheel/Templates/SimpleAdmin/javascript                                                                
        Alias /scriptaculous /opt/devel/Modwheel/Templates/Scriptaculous                                                                      
        <Directory /opt/devel/Modwheel/Repository/*/*>                                                                                        
            Order Deny,Allow                                                                                                                  
            Allow from all                                                                                                                    
        </Directory>                                                                                                                          
        <Directory /opt/devel/Modwheel/Templates/*/*>                                                                                         
            Order Deny,Allow                                                                                                                  
            Allow from all                                                                                                                    
        </Directory>                                                                                                                          
    </VirtualHost>    

=head1 DESCRIPTION

=head1 HANDLERS

=over 4

=item PerlResponseHandler L<Apache2::Modwheel>

This is the main Modwheel handler. It requires that you have
the ModwheelPrefix and ModwheelConfigFile options set.

=item PerlAuthenHandler L<Apache2::Modwheel::Authen>

This module is for authentication via the modwheel user system.

=back

=head1 SUBROUTINES/METHODS



=head1 CONFIGURATION AND ENVIRONMENT

=head2 APACHE CONFIGURATION DIRECTIVES

=over 4

=item PerlSetVar C<ModwheelPrefix>

This is the directory you installed Modwheel to.

Example:

    PerlSetVar ModwheelPrefix "/opt/Modwheel"

=item PerlSetVar C<ModwheelConfigFile>

This is the Modwheel configuration file to use.
If the filename is relative Modwheel will search for it in
the ModwheelPrefix directory.

Example:

    PerlSetVar ModwheelConfigFile "config/Modwheelconfig.yml"

=item PerlSetVar C<ModwheelSite>

The site to use. Sites are configured in the configuration file.

Example:

    PerlSetVar ModwheelSite "SimpleAdmin"

=item PerlSetVar C<ModwheelFileUploads>

Users will be able to upload files to the site if this is set to Yes.
This is used for the Repositories.

Example:

    PerlSetVar ModwheelFileUploads Yes

=item PerlSetVar C<ModwheelWebPathToId>

If this is set to yes, a user can enter i.e
        http://foo.bar/Music/Aphex Twin
in his browser and Modwheel will find the node in the object tree
with this name.

Example:

    PerlSetVar ModwheelWebPathToId Yes

=item PerlSetVar C<Locale>

What language the site is in. For a list of the values that are possible
with this directive you can enter this command: (if you are running a form
of Unix):

    locale -a

Example:

    PerlSetVar Locale en_EN

=item PerlSetVar C<DontHandle>

URL's that Modwheel should'nt handle for this site. This is meant for
static content that does not need any content. i.e /images, /javascript
and so on.

Example:

    PerlSetVar DontHandle "rep javascript css images scriptaculous"

=item PerlSetVar C<ModwheelDBCached>

Turn on database handle cache.

Example:

    PerlSetVar ModwheelCachedDB Yes
    PerlSetVar ModwheelCachedDB No

=item PerlSetVar C<NoDatabaseConnect>

Modwheel will not connect to the database if this is set to 'Yes'.

Example:

    PerlSetVar NoDatabaseConnect Yes

=item PerlSetVar C<ContentType>

Set the content type for this site.

Example:

    PerlSetVar ContentType "text/html"

=item PerlSetVar C<ModwheelFollowTemplates>

If a object has a user-specified template defined and ModwheelFollowTemplates
is set to 'Yes', it will choose this template instead of the default.

Example:

    PerlSetVar ModwheelFollowTemplates Yes

=back

=head1 DIAGNOSTICS

Try running the Apache server in single process mode, with C<httpd -X>.

=head1 INCOMPATIBILITIES

None known.

=head1 EXPORT

None.

=head1 DEPENDENCIES

=over 4

=item * Modwheel v0.0.2

=item * libapreq2 2.0

=item * mod_perl2 2.0

=item * Readonly

=item * Scalar::Util

=item * version

=back

=head1 BUGS AND LIMITATIONS

No bugs reported.

=head1 SEE ALSO

=over 4

=item * L<Modwheel::Manual::Install>

=item * L<Modwheel::Manual::Config>

=item * L<Modwheel::Manual::Intro>

=item * L<Apache2::Modwheel::Authen>

=item * The README included in the Modwheel distribution.

=item * The Modwheel website: L<http://www.0x61736b.net/Modwheel/>

=back

=head1 AUTHOR

Ask Solem, F<< ask@0x61736b.net >>.

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2007 by Ask Solem Hoel C<< ask@0x61736b.net >>.

All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.6 or,
at your option, any later version of Perl 5 you may have available.

