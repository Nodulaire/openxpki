## OpenXPKI::Server::API::Object.pm
##
## Written 2005 by Michael Bell and Martin Bartosch for the OpenXPKI project
## Copyright (C) 2005-2006 by The OpenXPKI Project

=head1 Name

OpenXPKI::Server::API::UI

=head1 Description


=head1 Functions

=cut

package OpenXPKI::Server::API::UI;

use strict;
use warnings;
use utf8;
use English;

use Data::Dumper;

use Class::Std;
use OpenXPKI::Control;
use OpenXPKI::Debug;
use OpenXPKI::Exception;
use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Crypto::CSR;
use OpenXPKI::Crypto::VolatileVault;
use OpenXPKI::FileUtils;
use OpenXPKI::VERSION;
use OpenXPKI::Template;
use DateTime;
use OpenXPKI::Serialization::Simple;
use List::Util qw(first);

use MIME::Base64 qw( encode_base64 decode_base64 );

sub START {

    # somebody tried to instantiate us, but we are just an
    # utility class with static methods
    OpenXPKI::Exception->throw( message =>
          'I18N_OPENXPKI_SERVER_API_SUBCLASSES_CAN_NOT_BE_INSTANTIATED', );
}

=head2 get_ui_system_status

Return information about critical items of the system such as
status of secret groups, expiring crls/tokens, etc.

=cut

sub get_ui_system_status {

    my $self = shift;

    my $result;
    my $crypto = CTX('crypto_layer');
    my $pki_realm = CTX('api')->get_pki_realm();

    # Offline Secrets
    my $offline = 0;

    # Secret groups tend to have exceptions in unusual situations
    # To not crash the whole method, we put an eval around until this is
    # resolved, see #255

    my %secrets = $crypto->get_secret_groups();
    foreach my $secret (keys %secrets) {
        my $status;
        eval {
            $status = $crypto->is_secret_group_complete( $secret ) || 0;
        };
        if (!$status) { $offline++ };
    }

    $result->{secret_offline} = $offline;

    # Expiring CRLs
    
    # find all active tokens    
    my $group = CTX('config')->get("realm.$pki_realm.crypto.type.certsign");
    my $db_results = CTX('dbi_backend')->select(
        TABLE   => 'ALIASES',
        COLUMNS => [ 'IDENTIFIER' ],
        VALID_AT => time(),
        DYNAMIC => {
            'ALIASES.PKI_REALM' => { VALUE => $pki_realm },
            'ALIASES.GROUP_ID' => { VALUE => $group },            
        },
    );
    
    my $crl_expiry = 0;
    foreach my $ca (@{$db_results}) {
        my $crl_result = CTX('dbi_backend')->first(
            TABLE   => 'CRL',
            COLUMNS => [ 'NEXT_UPDATE' ],
            DYNAMIC => { 
                PKI_REALM => { VALUE => $pki_realm },
                ISSUER_IDENTIFIER => { VALUE => $ca->{IDENTIFIER} }, 
            },
            ORDER => [ 'NEXT_UPDATE' ],
            REVERSE => 1,
        );
        if (($crl_expiry == 0) || ($crl_expiry > $crl_result->{NEXT_UPDATE})) {
            $crl_expiry  = $crl_result->{NEXT_UPDATE};
        }         
    }    
    $result->{crl_expiry} = $crl_expiry;

    # Vault Token
    my $dv_group = CTX('config')->get("crypto.type.datasafe");
    my $dv_token = CTX('dbi_backend')->first(
        TABLE   => 'ALIASES',
        COLUMNS => [
            'NOTAFTER',
        ],
        DYNAMIC => {
            'PKI_REALM' => { VALUE => $pki_realm },
            'GROUP_ID' => { VALUE => $dv_group },
        },
        'ORDER' => [ 'NOTAFTER' ],
        'REVERSE' => 1,
    );

    $result->{dv_expiry} = $dv_token->{NOTAFTER};

    my $pids = OpenXPKI::Control::get_pids();
    $result->{watchdog} =  scalar @{$pids->{watchdog}};
    $result->{worker} =  scalar @{$pids->{worker}};
    $result->{workflow} =  scalar @{$pids->{workflow}};
    
    $result->{version} = $OpenXPKI::VERSION::VERSION; 

    return $result;

}

sub list_process {

    my $self = shift;

    my $process = OpenXPKI::Control::list_process();

    return $process;

}

sub get_menu {

    ##! 1: 'start'

    my $self = shift;

    my $role = CTX('session')->get_role();

    ##! 16: 'role is ' . $role
    if (!CTX('config')->exists( ['uicontrol', $role ] )) {
        ##! 16: 'no menu for role, use default '
        $role = '_default';
    }

    # we silently assume that the config layer node can return a deep hash ;)
    my $menu = CTX('config')->get_hash( [ 'uicontrol', $role ], { deep => 1 });

    return $menu;

}

sub get_motd {

    ##! 1: 'start'

    my $self = shift;
    my $args = shift;

    my $role = $args->{ROLE} || CTX('session')->get_role();

    # The role is used as DP Key, can also be "_any" 
    my $datapool = CTX('api')->get_data_pool_entry({
        NAMESPACE   =>  'webui.motd',
        KEY         =>  $role   
    });
    ##! 16: 'Item for role ' . $role .': ' . Dumper $datapool
    
    # Nothing for role, so try _any
    if (!$datapool) {
        $datapool = CTX('api')->get_data_pool_entry({
            NAMESPACE   =>  'webui.motd',
            KEY         =>  '_any' 
        });
        ##! 16: 'Item for _any: ' . Dumper $datapool        
    }

    if ($datapool) {
        return OpenXPKI::Serialization::Simple->new()->deserialize( $datapool->{VALUE} );        
    }

    return undef;
}

=head2 render_template 

Wrapper around OpenXPKI::Template->render, expects TEMPLATE and PARAMS. 
This is a workaround and should be refactored, see #283

=cut
sub render_template {
    
    my $self = shift;
    my $args = shift;
    
    my $template = $args->{TEMPLATE};
    my $param = $args->{PARAMS};
    
    my $oxtt = OpenXPKI::Template->new();    
    my $res = $oxtt->render( $template, $param );
    
    # trim whitespace
    $res =~ s{ \A (\s\n)+ }{}xms;
    $res =~ s{ (\s\n)+ \z }{}xms;    
    return $res;
    
}


1,

__END__;
