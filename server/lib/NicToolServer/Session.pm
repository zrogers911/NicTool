package NicToolServer::Session;
# ABSTRACT: manage nictool login sessions

use strict;
use warnings;
use Digest::HMAC_SHA1 qw(hmac_sha1_hex);

@NicToolServer::Session::ISA = qw(NicToolServer);

sub debug_session_sql {0}

### public methods
sub verify {

    # return of 0 = sucess, return of anything else = error
    my $self = shift;

    my $data = $self->{'client'}->data();
    $data->{'action'} = uc( $data->{'action'} );

    my $vcheck = $self->ver_check;
    return $vcheck if $vcheck;

    #warn "action is ".$data->{'action'};
    return $self->verify_login if $data->{'action'} eq 'LOGIN';
    return $self->verify_session;    # just verify the session
}

### private methods
sub verify_login {
    my $self = shift;

    # timeout_sessions could be called from a cron job every
    # $NicToolServer::session_timeout. This is easier to setup
    $self->timeout_sessions;

    my $data = $self->{'client'}->data();
    my $dbh  = $self->{'dbh'};

    my $error_msg = 'Invalid username and/or password.';

    return $self->auth_error('invalid group(s)')
        if !$self->populate_groups;    # sets $data->nt_group_id

    my $sql
        = "SELECT nt_user.*, nt_group.name AS groupname FROM nt_user, nt_group "
        . "WHERE nt_user.nt_group_id = nt_group.nt_group_id AND "
        . "nt_user.deleted=0 AND nt_user.nt_group_id IN ("
        . join( ',', @{ $data->{'groups'} } )
        . ") AND nt_user.username = ?";

    my $users = $self->exec_query( $sql, $data->{'username'} )
        or return $self->error_response( 505, $dbh->errstr );

    return $self->auth_error('no such username') if !$users;
    return $self->auth_error('invalid username') if scalar @$users > 1;

    my $attempted_pass = $data->{'password'};
    delete( $data->{'password'} );

# delete the hashkey or perl maintains attempted_pass as a ref to the hash key's lvalue

    $data->{'user'} = $users->[0];

    # RCC - Handle HMAC passwords
    if ( $data->{user}{password} =~ /[0-9a-f]{40}/ ) {
        $attempted_pass = hmac_sha1_hex( $attempted_pass, $data->{username} );
    }

    return $self->auth_error('invalid password')
        if $attempted_pass ne $data->{user}{password};

    $self->clean_user_data;

    $data->{'user'}->{'nt_user_session'} = $self->session_id;

    $sql = "SELECT * FROM nt_perm " . "WHERE deleted=0 AND nt_user_id = ?";
    my $perms = $self->exec_query( $sql, $data->{user}{nt_user_id} )
        or return $self->error_response( 505, $dbh->errstr );

    my $groupperm;
    my $perm = $perms->[0];

    $sql
        = "SELECT nt_perm.* FROM nt_perm"
        . " INNER JOIN nt_user ON nt_perm.nt_group_id = nt_user.nt_group_id "
        . " WHERE ( nt_perm.deleted=0 "
        . " AND nt_user.deleted=0 "
        . " AND nt_user.nt_user_id = ?" . " )";
    $perms = $self->exec_query( $sql, $data->{user}{nt_user_id} )
        or return $self->error_response( 505, $dbh->errstr );
    $groupperm = $perms->[0];

    if ( !$perm ) {
        $perm = $groupperm;
        $perm->{'inherit_group_permissions'} = 1;
    }
    else {
        $perm->{'inherit_group_permissions'} = 0;

        #for now usable_ns settings are always inherited from the group
        for ( 0 .. 9 ) {
            $perm->{"usable_ns$_"} = $groupperm->{"usable_ns$_"};
        }
    }

    if ( !$perm ) {
        return $self->error_response( 507,
                  "Could not find permissions for user ("
                . $data->{user}{nt_user_id}
                . ")" );
    }
    delete $perm->{'nt_user_id'};
    delete $perm->{'nt_group_id'};
    delete $perm->{'nt_perm_id'};
    delete $perm->{'nt_perm_name'};

    foreach ( keys %$perm ) {
        $data->{'user'}->{$_} = $perm->{$_};
    }

    $sql
        = 'INSERT INTO nt_user_session(nt_user_id, nt_user_session, last_access) VALUES (??)';
    my $nt_user_session_id = $self->exec_query( $sql,
        [ $data->{user}{nt_user_id}, $data->{user}{nt_user_session}, time() ]
    );

    $sql
        = "INSERT INTO nt_user_session_log(nt_user_id, action, timestamp, nt_user_session_id, nt_user_session) VALUES (??)";
    $self->exec_query(
        $sql,
        [   $data->{user}{nt_user_id}, 'login',
            time(),                    $nt_user_session_id,
            $data->{user}{nt_user_session}
        ]
    );

    return 0;
}

sub verify_session {
    my $self = shift;

    my $data = $self->{'client'}->data();
    my $dbh  = $self->{'dbh'};

    my $sql
        = "SELECT nt_user.*, nt_user_session.*, nt_group.name as groupname FROM nt_user_session, nt_user, nt_group 
        WHERE nt_user_session.nt_user_id = nt_user.nt_user_id
          AND nt_user.nt_group_id = nt_group.nt_group_id
          AND nt_user.deleted=0
          AND nt_user_session.nt_user_session = ?";

    my $sessions = $self->exec_query( $sql, $data->{nt_user_session} )
        or return $self->error_response( 505, $dbh->errstr );

    return $self->auth_error('Your session has expired. Please login again')
        if !$sessions;

    $data->{'user'} = $sessions->[0];

    my $max_age = time() - $NicToolServer::session_timeout;
    if ( $max_age >= $data->{user}{last_access} ) {
        $self->logout('timeout');
        return $self->auth_error('Your session expired. Please login again');
    }

    # delete session and log logout if LOGOUT
    return $self->logout if $data->{'action'} eq 'LOGOUT';

    $sql = "SELECT * FROM nt_perm WHERE deleted=0 AND nt_user_id = ?";
    my $perms = $self->exec_query( $sql, $data->{user}{nt_user_id} )
        or return $self->error_response( 505, $dbh->errstr );

    my $groupperm;
    my $perm = $perms->[0];

    $sql
        = "SELECT nt_perm.* FROM nt_perm"
        . " INNER JOIN nt_user ON nt_perm.nt_group_id = nt_user.nt_group_id "
        . " WHERE ( nt_perm.deleted=0 "
        . " AND nt_user.deleted=0 "
        . " AND nt_user.nt_user_id = ? )";
    $perms = $self->exec_query( $sql, $data->{user}{nt_user_id} )
        or return $self->error_response( 505, $dbh->errstr );
    $groupperm = $perms->[0];

    if ( !$perm ) {
        $perm = $groupperm;
    }
    else {

        #for now usable_ns settings are always inherited from the group
        for ( 0 .. 9 ) {
            $perm->{"usable_ns$_"} = $groupperm->{"usable_ns$_"};
        }
    }

    if ( !$perm ) {
        return $self->error_response( 507,
                  "Could not find permissions for user ("
                . $data->{'user'}->{'nt_user_id'}
                . ")" );
    }
    delete $perm->{'nt_user_id'};
    delete $perm->{'nt_group_id'};

    #@{$data->{'user'}}{sort keys %$perm} = @{$perm}{sort keys %$perm};
    foreach ( keys %$perm ) {
        $data->{'user'}->{$_} = $perm->{$_};
    }

    $sql = "UPDATE nt_user_session SET last_access = ?"
        . " WHERE nt_user_session_id = ?";
    $self->exec_query( $sql, [ time(), $data->{user}{nt_user_session_id} ] );

    $self->clean_user_data;

    return 0;
}

sub logout {
    my $self = shift;
    my $msg  = shift;
    $msg ||= 'logout';

    #warn "calling Session::logout ... ".join(" ",caller);
    my $data = $self->{'client'}->data();

    my $sql = "DELETE FROM nt_user_session WHERE nt_user_session_id = ?";
    $self->exec_query( $sql, $data->{user}{nt_user_session_id} );

    $sql
        = "INSERT INTO nt_user_session_log(nt_user_id, action, timestamp, nt_user_session, nt_user_session_id) VALUES (??) ";
    $self->exec_query(
        $sql,
        [   $data->{user}{nt_user_id},
            $msg,
            time(),
            $data->{user}{nt_user_session},
            $data->{user}{nt_user_session_id}
        ]
    );

    foreach my $key ( keys %$data ) {
        delete( $data->{$key} );
    }

    return { 'error_code' => 200, error_msg => 'OK', nt_user_session => '' };
}

sub populate_groups {
    my $self = shift;

 # return true on successful population of @$data->{'groups'}, otherwise false

    my $data = $self->{'client'}->data();

    my $ids;
    $data->{'groups'} = [];

    my $sql;
    if ( $data->{'username'} =~ /(.+)\@(.+)/ ) {
        $data->{'username'} = $1;
        $sql
            = "SELECT nt_group_id FROM nt_group WHERE deleted=0 AND name = ?";
        $ids = $self->exec_query( $sql, $2 );
    }
    else {
        return 0 unless @NicToolServer::default_groups;
        $sql
            = "SELECT nt_group_id FROM nt_group WHERE deleted=0 AND name IN (??)";
        $ids = $self->exec_query( $sql, [@NicToolServer::default_groups] );
    }

    my $i = 0;
    foreach (@$ids) {
        push( @{ $data->{'groups'} }, $_->{nt_group_id} );
        $i++;
    }

    # if no group found, return false, else return true
    $i < 1 ? return 0 : return 1;
}

sub timeout_sessions {
    my $self = shift;

    my $valid_until = time() - $NicToolServer::session_timeout;
    my $sql
        = "SELECT nt_user_id, last_access, nt_user_session_id, nt_user_session "
        . "FROM nt_user_session WHERE last_access < ?";
    my $sessions = $self->exec_query( $sql, $valid_until );

    foreach my $s (@$sessions) {

        # delete the dead session
        $sql = "DELETE FROM nt_user_session WHERE nt_user_session_id = ?";
        $self->exec_query( $sql, $s->{'nt_user_session_id'} );

        # log that the session was auto_logged out
        $sql
            = "INSERT INTO nt_user_session_log(nt_user_id, action, timestamp, nt_user_session, nt_user_session_id) VALUES (??)";
        $self->exec_query(
            $sql,
            [   $s->{'nt_user_id'}, 'timeout',
                time(),             $s->{'nt_user_session'},
                $s->{'nt_user_session_id'}
            ]
        );
    }
}

sub clean_user_data {

    # delete unused and password data from DB-returned user hash
    my $self = shift;

    my $data = $self->{'client'}->data();

    my @fields = qw(password deleted nt_user_session_id last_access);

    foreach my $f (@fields) {
        delete( $data->{'user'}->{$f} )
            if ( exists( $data->{'user'}->{$f} ) );
    }

}

sub auth_error {
    my ( $self, $msg ) = @_;
    return { error_code => '403', error_msg => $msg };
}

sub session_id {
    my $self = shift;

    return $ENV{UNIQUE_ID} if ( $ENV{UNIQUE_ID} );    # mod_uniqeid sets this

    warn "mod_uniqueid not available - building my own unique ID.\n"
        if $self->debug;

    srand( $$ | time );
    my $session = int( rand(60000) );
    $session = unpack( "H*", pack( "Nnn", time, $$, $session ) );
    return $session;

}

1;

__END__

=head1 SYNOPSIS


=cut

