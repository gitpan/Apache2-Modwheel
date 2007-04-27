# $Id$
# $Source$
# $Author$
# $HeadURL$
# $Revision$
# $Date$
package Apache2::Modwheel;
use strict;
use warnings;
use 5.00800;
use mod_perl2 2.0;
use version; our $VERSION = qv('0.0.2');

use Readonly;
use Apache2::Access            ();
use Apache2::RequestRec     ();
use Apache2::RequestUtil     ();
use Apache2::RequestIO        ();
use Apache2::Request        ();
use Apache2::Upload            ();
use Apache2::Const            -compile =>
    qw(OK SERVER_ERROR FORBIDDEN NOT_FOUND DECLINED);
use Modwheel                ();
use Modwheel::DB             ();
use Modwheel::User            ();
use Modwheel::Object        ();
use Modwheel::Template        ();
use Modwheel::Repository    ();
use Params::Util ('_HASH', '_ARRAY', '_CODELIKE', '_INSTANCE');

# 10MB's Upload Limit.
Readonly my $MAX_UPLOAD_LIMIT => 10_485_760;

sub handler : method {
    my ($class, $r) = @_;
    return Apache2::Const::DECLINED if dont_want_this($r);

    # Don't process header requests.
    return Apache2::Const::OK        if $r->header_only();

    my $disable_uploads =
        $r->dir_config('ModwheelFileUploads') =~ m/yes/xmsi
        ? 0
        : 1;
    my $req = Apache2::Request->new($r,
        #POST_MAX => "10M",
        MAX_BODY => $MAX_UPLOAD_LIMIT,
        DISABLE_UPLOADS => $disable_uploads,
    );

    # Create log handler routine for Modwheel::log_*.
    my $loghandler_apache2 = sub  {
        my ($modwheel, $log_string, $facility) = @_;
        my $apache2 = $modwheel->logobject;
        my $rlog = $apache2->log;

        #*__ANON__ = 'Apache Modwheel Loghandler()';
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

    # Set up our Modwheel instance.

    my $modwheel_config = {
        prefix             => $r->dir_config('ModwheelPrefix'),
        configfile         => $r->dir_config('ModwheelConfigFile'),
        site             => $r->dir_config('ModwheelSite'),
        locale             => $r->dir_config('Locale'),
        add_loghandlers  => {apache2         => $loghandler_apache2,},
        logobject        => $r,
        logmode             => 'apache2',
        logmode          => 'stderr',
    };

    my $modwheel = Modwheel->new($modwheel_config);
    my $db       = Modwheel::DB->new({modwheel => $modwheel,});
    my $user     = Modwheel::User->new({
        modwheel => $modwheel,
        db         => $db,
    });
    my $object     = Modwheel::Object->new({
       modwheel => $modwheel,
       db          => $db,
       user      => $user,
    });
    my $repository = Modwheel::Repository->new({
        modwheel => $modwheel,
        db         => $db,
        user     => $user,
    });
    my $template = Modwheel::Template->new({
        modwheel => $modwheel,
        db         => $db,
        user     => $user,
        object   => $object,
        repository => $repository,
    });

    # Connect to database
    my $no_connect = $r->dir_config('NoDatabaseConnect');
    if ($no_connect ne 'Yes') {
        $db->connect() or return 500; #Apache2::Const::SERVER_ERROR
    }

    # Save user info if user is logged in.
    my $uname   = $r->user;
    $uname ||= 'guest';
    $user->set_uname($uname);
    if ($db->connected) {
        $user->set_uid( $user->uidbyname($uname) );
    }

    # Set up parent id or convert web path to parent id.
    my $parent;
    my $page = $r->uri;

    # untaint location.
    my $loc  = quotemeta $r->location;
    my $useWebPath = $r->dir_config('ModwheelWebPathToId');
    if ($useWebPath && $useWebPath =~ /yes/xmsi && $db->connected) {
        $parent = $req->param('parent');
        if ($parent) {

            # remove location part of uri requested.
            $page =~ s/^ $loc \/?//xms;
        }
        else {
            $parent = $object->path_to_id($page);

            unless ($parent) {
                $db->disconnect();
                return Apache2::Const::NOT_FOUND;
            }
        }
        $page =~ s{ ^.*/ }{}xms;
        undef $page unless $page =~ m/ \.[\w\d_]+$ /xms;
    }
    else {
        $parent =  $req->param('parent');

        # remove location part of uri requested.
        $page   =~ s/^ $loc \/?//xms;
    }
    $parent ||= Modwheel::Object::MW_TREE_ROOT;

    # Find the filename (page) for this object
    if ($r->dir_config('ModwheelFollowTemplates')) {
        my $o = $object->fetch({id => $parent});
        $page = $o->template if $o->template;
    }
    $page   ||= $modwheel->siteconfig->{directoryindex};

    # remove leading slash.
    $page =~ s{^/}{}xms;

    # add template dir as prefix to page path
    $page = $modwheel->siteconfig->{templatedir} . q{/} . $page;
    return Apache2::Const::NOT_FOUND unless -f $page;

    if (!$disable_uploads && $db->connected) {
        handle_uploads($r, $req, $db, $repository, $parent);
    }

    # set up the template object:
    $template->init(
        {   input  => $page,
            param  => $req,
            parent => $parent,
        }
    ) or return printError($template->errstr);

    my $content_type = $r->dir_config('ContentType') || 'text/html';
    $r->content_type($content_type);

    my $process_args = {};
    my $output = $template->process($process_args);

    $r->print($output);

    $db->disconnect() if $db->connected;

    return Apache2::Const::OK;

}

sub dont_want_this {
    my ($r) = @_;

    # we don't care about favicon.ico XXX: this is a hack, must change
    return 1 if $r->uri =~ m/ favicon.ico$ /xms;

    my $dontHandle = $r->dir_config('DontHandle');
    if ($dontHandle) {
        my @dont_handle_locations = split m/ \s+ /xms, $dontHandle;
        foreach my $location (@dont_handle_locations) {

            # remove trailing slashes.
            $location =~ s{ ^/ }{}xms;
            return 1 if $r->uri =~ m{ ^/ \Q$location\E }xms;
        }
    }

    return 0;
}
   
sub handle_uploads( ) {
    my ($r, $req, $db, $repository, $parent) = @_;

    # If the user uploads files, add them to the repository.
    my @uploads;
    foreach ($req->upload) {
        my $upload = $req->upload($_);
        if ($upload) {
            my $upload_in = $req->param('id');
            $upload_in ||= $parent;
            my %current_upload = (
                filename => $upload->filename,
                mimetype => $upload->type,
                size     => $upload->size,
                parent     => $upload_in
            );
            $repository->upload_file($upload->fh, %current_upload);
            push @uploads, \%current_upload;
        }
    }

    return;
}

sub printError {
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

1;
__END__

=head1 NAME

Apache2::Modwheel - Use Modwheel with mod_perl2

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


=cut

# Local variables:
# vim: ts=4

               M O D W H E E L for A P A C H E 2

INSTALLING THE Modwheel-Apache2 BINDINGS

Installation of the modules is easy:

    perl Makefile.PL
    make
    make install

After this you have to configure your apache server.
The Modwheel install script should have created an example
httpd.conf example to your Modwheel installation dir.
The file is named config/Modwheel-apache-example.conf and can also
be found in the config directory of this distribution.
Study this file and change it to fit your configuration, then add it to your
httpd.conf. Here is a list of what the new Apache configuration directives
means:


=head1 HANDLERS

=over 4

=item PerlResponseHandler L<Apache2::Modwheel>

This is the main Modwheel handler. It requires that you have
the ModwheelPrefix and ModwheelConfigFile options set.

=item PerlAuthenHandler L<Apache2::Modwheel::Authen>

This module is for authentication via the modwheel user system.

=back

=head1 APACHE CONFIGURATION DIRECTIVES

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

=head1 EXPORT

None.

=head1 HISTORY

=over 8

=item 0.01

Initial version.

=back

=head1 SEE ALSO

=over 4

=item * L<Modwheel::Manual::Install>

=item * L<Modwheel::Manual::Config>

=item * L<Modwheel::Manual::Intro>

=item * L<Apache2::Modwheel::Authen>

=item * The README included in the Modwheel distribution.

=item * The Modwheel website: L<http://www.0x61736b.net/Modwheel/>

=back

=head1 AUTHORS

Ask Solem, F<< ask@0x61736b.net >>.

=head1 COPYRIGHT, LICENSE

Copyright (C) 2007 by Ask Solem Hoel C<< ask@0x61736b.net >>.

All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.6 or,
at your option, any later version of Perl 5 you may have available.

