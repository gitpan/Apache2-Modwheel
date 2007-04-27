
package Apache2::Modwheel::Authen;
# ===================================================================== #
# $Id$
# $Source$
# $Author$
# $HeadURL$
# $Revision$
# $Date$
# ===================================================================== #
use strict;
use warnings;
use 5.008;
use mod_perl2 2.0;
use version; our $VERSION = qv('0.2.1');

use Readonly;
use Modwheel                ();
use Modwheel::DB            ();
use Modwheel::User          ();
use Apache2::Access         ();
use Apache2::Connection     ();
use Apache2::RequestUtil    ();
use Apache2::RequestRec     ();
use Apache2::ServerRec      ();
use Apache2::Log            ();
use Apache2::Const          -compile
    => qw(OK AUTH_REQUIRED HTTP_UNAUTHORIZED DECLINED SERVER_ERROR);
use namespace::clean;

# --------------------------------------------------------------------- #
# > loghandler_authen_apache2
#
# Loghandler for Modwheel.
# --------------------------------------------------------------------- #
Readonly my $LOGHANDLER_AUTHEN_APACHE2 => sub {

    my ($modwheel, $log_message) = @_;
    my $r = $modwheel->logobject;

    return $r->log_error($log_message);
};



# --------------------------------------------------------------------- #
# > handler($class, $r);
#
# Log in to a Modwheel system.
# --------------------------------------------------------------------- #
sub handler : method {
    my ($class, $r) = @_;
    return Apache2::Const::DECLINED if !$r;

    my ($res, $sent_pw) = $r->get_basic_auth_pw();
    return $res if $res != Apache2::Const::OK;

    my $uname = $r->user;
    if (!$uname || !$sent_pw) {
        $r->note_basic_auth_failure;
        $r->log_reason('Need both username and password.');
        return Apache2::Const::HTTP_UNAUTHORIZED;
    }

    my $modwheel_config = {
        prefix          => $r->dir_config('ModwheelPrefix'),
        configfile      => $r->dir_config('ModwheelConfigFile'),
        site            => $r->dir_config('ModwheelSite'),
        locale          => $r->dir_config('Locale'),
        add_loghandlers => {a2authen => $LOGHANDLER_AUTHEN_APACHE2},
        logmode         => 'a2authen',
        logobject       => $r,
    };

    my $modwheel = Modwheel->new(
        $modwheel_config,
    );
    my $db       = Modwheel::DB->new({
        modwheel => $modwheel,
    });
    my $user     = Modwheel::User->new({
        modwheel => $modwheel,
        db       => $db,
    });
   
    my $connection_config_ref;
    if ($r->dir_config('ModwheelCachedDB') eq 'Yes') {
        $connection_config_ref->{cached} = 1;
    }
    $db->connect( $connection_config_ref )
        or return Apache2::Const::SERVER_ERROR;
    my $server          = $r->server;
    my $client          = $r->connection;
    my $server_hostname = $server->server_hostname;
    my $auth_type       = $r->ap_auth_type;
    my $site            = $modwheel->site;
    my $remote_addr     = $client->remote_ip;
    if (! $user->login($uname, $sent_pw, $remote_addr)) {
        $r->note_basic_auth_failure;
        $r->log_reason( $modwheel->error );
        $db->disconnect( );
        return Apache2::Const::HTTP_UNAUTHORIZED;
    }


    #$r->warn("Modwheel [site: $site@$server_hostname] info || ",
    #    "| Login: $uname [ip: $remote_addr, auth type: $auth_type]"
    #);    

    return Apache2::Const::OK;
}


1;
