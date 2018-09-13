package App::swcat;

# DATE
# VERSION

use 5.010001;
use strict 'subs', 'vars';
use warnings;
use Log::ger;

our %SPEC;

our $db_schema_spec = {
    latest_v => 1,

    install => [
        'CREATE TABLE sw_cache (
             software VARCHAR(128) NOT NULL PRIMARY KEY,
             latest_version VARCHAR(32),
             check_latest_version_mtime INT
         )',
    ], # install
}; # db_schema_spec

our %args_common = (
    db_path => {
        summary => 'Location of SQLite database (for caching), '.
            'defaults to ~/.cache/swcat.db',
        schema => 'filename*',
        tags => ['common'],
    },
    cache_period => {
        schema => 'int*',
        default => 86400,
        tags => ['common'],
        cmdline_aliases => {
            no_cache => {summary => 'Alias for --cache-period=-1', is_flag=>1, code=>sub { $_[0]{cache_period} = -1 }},
        },
    },
);

our %arg0_software = (
    software => {
        schema => ['str*', match=>qr/\A[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*\z/],
        req => 1,
        pos => 0,
        completion => sub {
            require Complete::Module;
            my %args = @_;
            my $ans = Complete::Module::complete_module(
                word => $args{word},
                ns_prefix => 'Software::Catalog::SW',
            );
            for (@$ans) { s/::/-/g }
            $ans;
        },
    },
);

sub _load_swcat_mod {
    my $name = shift;

    (my $mod = "Software::Catalog::SW::$name") =~ s/-/::/g;
    (my $modpm = "$mod.pm") =~ s!::!/!g;
    require $modpm;
    $mod;
}

sub _create_schema {
    require SQL::Schema::Versioned;

    my $dbh = shift;

    my $res = SQL::Schema::Versioned::create_or_update_db_schema(
        dbh => $dbh, spec => $db_schema_spec);
    die "Can't create/update schema: $res->[0] - $res->[1]\n"
        unless $res->[0] == 200;
}

sub _connect_db {
    require DBI;

    my ($mode, $path) = @_;

    log_trace("Connecting to SQLite database at %s ...", $path);
    if ($mode eq 'ro') {
        # avoid creating the index file automatically if we are only in
        # read-only mode
        die "Can't find index '$path'\n" unless -f $path;
    }
    my $dbh = DBI->connect("dbi:SQLite:dbname=$path", undef, undef,
                           {RaiseError=>1});
    #$dbh->do("PRAGMA cache_size = 400000"); # 400M
    _create_schema($dbh);
    $dbh;
}

sub _set_args_default {
    my $args = shift;
    if (!$args->{db_path}) {
        require File::HomeDir;
        $args->{db_path} = File::HomeDir->my_home . '/.cache/swcat.db';
    }
}

sub _init {
    my ($args, $mode) = @_;

    unless ($App::swcat::state) {
        _set_args_default($args);
        my $state = {
            dbh => _connect_db($mode, $args->{db_path}),
            db_path => $args->{db_path},
        };
        $App::swcat::state = $state;
    }
    $App::swcat::state;
}

sub _cache_result {
    my %args = @_;

    my $now = time();

    my $res;
  RETRIEVE: {
        my $cache_exists;
        log_trace "Getting value from cache ($args{table}, $args{column}, $args{pk}) ...";
        my @row = $args{dbh}->selectrow_array("SELECT $args{column}, $args{mtime_column} FROM $args{table} WHERE $args{pk_column}=?", {}, $args{pk});
        if (!@row) {
            log_trace "Cache doesn't exist yet";
        } elsif ($row[1] < $now - $args{cache_period}) {
            $cache_exists++;
            log_trace "Cache is too old, retrieving from source again";
        } else {
            log_trace "Cache hit ($row[0])";
            $res = [200, "OK (cached)", $row[0]];
            last;
        }
        $res = $args{code}->();
        if ($res->[0] == 200) {
            log_trace "Updating cache ...";
            if ($cache_exists) {
                $args{dbh}->do("UPDATE $args{table} SET $args{column}=?, $args{mtime_column}=? WHERE $args{pk_column}=?", {}, $res->[2], $now, $args{pk});
            } else {
                $args{dbh}->do("INSERT INTO $args{table} ($args{pk_column}, $args{column}, $args{mtime_column}) VALUES (?,?,?)", {}, $args{pk}, $res->[2], $now);
            }
        }
    }
    $res;
}

$SPEC{list} = {
    v => 1.1,
    summary => 'List known software in the catalog',
    args => {
        %args_common,
        detail => {
            schema => ['bool*', is=>1],
            cmdline_aliases => {l=>{}},
        },
    },
};
sub list {
    require PERLANCAR::Module::List;

    my %args = @_;

    my $mods = PERLANCAR::Module::List::list_modules(
        'Software::Catalog::SW::', {list_modules => 1, recurse=>1},
    );
    my @rows;
    for my $mod (sort keys %$mods) {
        (my $name = $mod) =~ s/\ASoftware::Catalog::SW:://;
        $name =~ s/::/-/g;
        my $row;
        if ($args{detail}) {
            my $mod = _load_swcat_mod($name);
            $row = {
                software => $name,
                module => $mod,
            };
        } else {
            $row = $name;
        }
        push @rows, $row;
    }

    [200, "OK", \@rows];
}

$SPEC{latest_version} = {
    v => 1.1,
    summary => 'Get latest version of a software',
    args => {
        %args_common,
        %arg0_software,
    },
};
sub latest_version {
    my %args = @_;
    my $state = _init(\%args, 'rw');

    my $mod = _load_swcat_mod($args{software});
    _cache_result(
        code => sub { $mod->get_latest_version },
        dbh => $state->{dbh},
        cache_period => $args{cache_period},
        table => 'sw_cache',
        pk_column => 'software',
        pk => $args{software},
        column => 'latest_version',
        mtime_column => 'check_latest_version_mtime',
    );
}

1;
# ABSTRACT: Software catalog

=head1 SYNOPSIS

See L<swcat> script.

=cut
