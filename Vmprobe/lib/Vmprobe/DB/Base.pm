package Vmprobe::DB::Base;

use common::sense;

use LMDB_File qw(:flags :cursor_op);

use Vmprobe::Util;




sub db_name { die "sub-class must specify db name" }

sub key_type { die "sub-class must specify key type" }

sub value_type { die "sub-class must specify value type" }

sub dup_keys { 0 }



our $dbname_to_dbi = {};

sub new {
    my ($class, $txn) = @_;

    my $self = { txn => $txn, };
    bless $self, $class;

    my $db_name = $self->db_name;

    my $dbi = $dbname_to_dbi->{$db_name};

    if (!defined $dbi) {
        my $flags = MDB_CREATE;

        my $key_type = $self->key_type;
        my $value_type = $self->value_type;

        if ($key_type eq 'autoinc' || $key_type eq 'int') {
            $flags |= MDB_INTEGERKEY;
        } elsif ($key_type eq 'raw') {
            ## nothing
        } else {
            die "unknown key type: $key_type";
        }

        if ($self->dup_keys) {
            $flags |= MDB_DUPSORT;

            if ($value_type eq 'int') {
                $flags |= MDB_INTEGERDUP;
            }
        }

        $dbi = $dbname_to_dbi->{$db_name} = $txn->open($db_name, $flags);
    }

    $self->{db} = LMDB_File->new($txn, $dbi);

    $self->{db}->ReadMode(1);

    return $self;
}




sub insert {
    my $self = shift;

    my $key_type = $self->key_type;
    my $value_type = $self->value_type;

    my ($key, $value);

    if ($key_type eq 'autoinc') {
        my $cursor = $self->{db}->Cursor;

        my $last_key = 0;

        eval {
            $cursor->get($last_key, undef, MDB_LAST);
        };

        $key = $last_key + 1;
    } elsif ($key_type eq 'raw' || $key_type eq 'int') {
        $key = shift // die "need to pass in key";
    } else {
        die "unknown key type: $key_type";
    }


    $value = shift // die "need to pass in value";

    if ($value_type eq 'sereal') {
        $value->{id} = $key if $key_type eq 'autoinc';

        $value = sereal_encode($value);
    } elsif ($value_type eq 'raw' || $value_type eq 'int') {
        ## nothing
    } else {
        die "unknown value type: $value_type";
    }

    $self->{db}->put($key, $value);
}


sub update {
    my $self = shift;

    my $key_type = $self->key_type;
    my $value_type = $self->value_type;

    my ($key, $value);

    if ($key_type eq 'autoinc') {
        $value = shift // die "need to pass in value";
        $key = $value->{id};
    } elsif ($key_type eq 'raw' || $key_type eq 'int') {
        $key = shift // die "need to pass in key";
        $value = shift // die "need to pass in value";
    } else {
        die "unknown key type: $key_type";
    }

    if ($value_type eq 'sereal') {
        $value = sereal_encode($value);
    } elsif ($value_type eq 'raw' || $value_type eq 'int') {
        ## nothing
    } else {
        die "unknown value type: $value_type";
    }

    $self->{db}->put($key, $value);
}



sub get {
    my ($self, $key) = @_;

    my $value;

    eval {
        $self->{db}->get($key, $value);
    };

    return undef if !defined $value;

    return ${ $self->_decode_value(\$value) };
}


sub delete {
    my ($self, $key) = @_;

    $self->{db}->del($key);
}


sub foreach {
    my ($self, $cb) = @_;

    _foreach_db($self->{db}, sub {
        my $key = $_[0];

        $cb->($key, sereal_decode($_[1]));
    });
}



sub iterate {
    my ($self, $params) = @_;

    my $cursor = $self->{db}->Cursor;

    my ($key, $value);


    $key = $params->{start} if defined $params->{start};

    eval {
        $cursor->get($key, $value, $params->{start} ? 0 : ($params->{backward} ? MDB_LAST : MDB_FIRST));
    };

    return if $@;

    $params->{cb}->($key, ${ $self->_decode_value(\$value) }) if !$params->{skip_start} || $key ne $params->{start};


    my $direction = $params->{backward} ? MDB_PREV : MDB_NEXT;

    while(1) {
        eval {
            $cursor->get($key, $value, $direction);
        };

        return if $@;

        $params->{cb}->($key, ${ $self->_decode_value(\$value) });
    }
}


sub iterate_dups {
    my ($self, $params) = @_;

    die "DB not declared dup_keys" if !$self->dup_keys();


    my $cursor = $self->{db}->Cursor;

    my ($key, $value);


    $key = $params->{key} // die "need key to iterate over dups";

    if ($params->{offset}) {
        die "offset doesn't support reverse yet" if defined $params->{reverse};

        $value = $params->{offset};

        eval {
            $cursor->get($key, $value, MDB_SET_RANGE);
        };

        return if $@;

        $params->{cb}->($key, ${ $self->_decode_value(\$value) }) if $value ne $params->{offset};
    } else {
        eval {
            $cursor->get($key, $value, MDB_SET);
        };

        return if $@;

        if ($params->{reverse}) {
            eval {
                $cursor->get($key, $value, MDB_LAST_DUP);
            };

            return if $@;
        }

        $params->{cb}->($key, ${ $self->_decode_value(\$value) });
    }


    my $direction = $params->{reverse} ? MDB_PREV_DUP : MDB_NEXT_DUP;

    while(1) {
        eval {
            $cursor->get($key, $value, $direction);
        };

        return if $@;

        $params->{cb}->($key, ${ $self->_decode_value(\$value) });
    }
}



sub last_dup {
    my ($self, $params) = @_;

    die "DB not declared dup_keys" if !$self->dup_keys();

    my $cursor = $self->{db}->Cursor;

    my ($key, $value);


    $key = $params->{key} // die "need key to iterate over dups";

    eval {
        $cursor->get($key, $value, MDB_SET_KEY);
    };

    return if $@;

    $cursor->get($key, $value, MDB_LAST_DUP);

    return $value;
}


#################




sub _decode_value {
    my ($self, $value_ref) = @_;

    my $value_type = $self->value_type;

    if ($value_type eq 'sereal') {
        return \sereal_decode($$value_ref);
    } elsif ($value_type eq 'raw' || $value_type eq 'int') {
        return $value_ref;
    } else {
        die "unknown value type: $value_type";
    }
}


sub _foreach_db {
    my ($db, $cb) = @_;

    my $cursor = my $cursor = $db->Cursor;

    my ($key, $value);

    eval {
        $cursor->get($key, $value, MDB_FIRST);
    };

    return if $@;

    $cb->($key, $value);

    while(1) {
        eval {
            $cursor->get($key, $value, MDB_NEXT);
        };

        return if $@;

        $cb->($key, $value);
    }
}


1;
