package App::swcat;

# DATE
# VERSION

use 5.010001;
use strict 'subs', 'vars';
use warnings;
use Log::ger;

use Perinci::Object;
use PerlX::Maybe;

use vars '%Config';
our %SPEC;

our $db_schema_spec = {
    latest_v => 2,

    install => [
        'CREATE TABLE sw_cache (
             software VARCHAR(128) NOT NULL,
             name VARCHAR(64) NOT NULL,
             value TEXT NOT NULL,
             mtime INT NOT NULL
         )',
        'CREATE UNIQUE INDEX ix_sw_cache__software_name ON sw_cache(software,name)',
    ], # install

    upgrade_to_v2 => [
        'DROP TABLE sw_cache', # remove all cache
        'CREATE TABLE sw_cache (
             software VARCHAR(128) NOT NULL,
             name VARCHAR(64) NOT NULL,
             value TEXT NOT NULL,
             mtime INT NOT NULL
         )',
        'CREATE UNIQUE INDEX ix_sw_cache__software_name ON sw_cache(software,name)',
    ],

    install_v1 => [
        'CREATE TABLE sw_cache (
             software VARCHAR(128) NOT NULL PRIMARY KEY,
             latest_version VARCHAR(32),
             check_latest_version_mtime INT
         )',
    ], # install
}; # db_schema_spec

our $re_software = qr/\A[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*\z/;

our %args_common = (
    db_path => {
        summary => 'Location of SQLite database (for caching), '.
            'defaults to ~/.cache/swcat.db',
        schema => 'filename*',
        tags => ['common'],
    },
    cache_period => {
        schema => 'int*',
        tags => ['common'],
        cmdline_aliases => {
            no_cache => {summary => 'Alias for --cache-period=-1', is_flag=>1, code=>sub { $_[0]{cache_period} = -1 }},
        },
    },
    arch => {
        schema => 'software::arch*',
        tags => ['common'],
    },
);

our %arg0_software = (
    software => {
        schema => ['str*', match=>$re_software],
        req => 1,
        pos => 0,
        completion => sub {
            require Complete::Module;
            my %args = @_;
            Complete::Module::complete_module(
                word => $args{word},
                ns_prefix => 'Software::Catalog::SW',
                path_sep => '-',
            );
        },
    },
);

our %argopt0_softwares_or_patterns = (
    softwares_or_patterns => {
        'x.name.is_plural' => 1,
        'x.name.singular' => 'software_or_pattern',
        schema => ['array*', of=>['str*', min_len=>1], min_len=>1],
        pos => 0,
        greedy => 1,
        element_completion => sub {
            require Complete::Module;
            my %args = @_;
            Complete::Module::complete_module(
                word => $args{word},
                ns_prefix => 'Software::Catalog::SW',
                path_sep => '-',
            );
        },
    },
);

our %arg0_softwares_or_patterns;
$arg0_softwares_or_patterns{softwares_or_patterns} = {
    %{$argopt0_softwares_or_patterns{softwares_or_patterns}},
    req => 1,
};

our %argopt_arch = (
    arch => {
        schema => ['software::arch*'],
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

sub _detect_arch {
    require Config; Config->import;
    my $archname = $Config{archname};
    if ($archname =~ /\Ax86-linux/) {
        return "linux-x86"; # linux i386
    } elsif ($archname =~ /\Ax86-linux/) {
    } elsif ($archname =~ /\Ax86_64-linux/) {
        return "linux-x86_64";
    } elsif ($archname =~ /\AMSWin32-x86(-|\z)/) {
        return "win32";
    } elsif ($archname =~ /\AMSWin32-x64(-|\z)/) {
        return "win64";
    } else {
        die "Unsupported arch '$archname'";
    }
}

sub _set_args_default {
    my $args = shift;
    if (!$args->{db_path}) {
        require PERLANCAR::File::HomeDir;
        $args->{db_path} = PERLANCAR::File::HomeDir::get_my_home_dir() .
            '/.cache/swcat.db';
    }
    if (!$args->{arch}) {
        $args->{arch} = _detect_arch;
    }
    if (!defined $args->{cache_period}) {
        $args->{cache_period} = 86400;
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
        log_trace "Getting value from cache (table=%s, column=%s, pk=%s) ...", $args{table}, $args{column}, $args{pk};

        my $sqlwhere;
        my $sqlcolumns;
        my $sqlbinds;
        my @bind;
        if (ref $args{pk_column} eq 'ARRAY') {
            $sqlwhere = join(" AND ", map {"$_=?"} @{ $args{pk_column} });
            $sqlcolumns = join(",", @{ $args{pk_column} });
            $sqlbinds = join(",", map {"?"} @{ $args{pk_column} });
            push @bind, @{ $args{pk} };
        } else {
            $sqlwhere = "$args{pk_column}=?";
            $sqlcolumns = $args{pk_column};
            $sqlbinds = "?";
            push @bind, $args{pk};
        }

        my @row = $args{dbh}->selectrow_array("SELECT $args{column}, $args{mtime_column} FROM $args{table} WHERE $sqlwhere", {}, @bind);
        #log_trace "row=%s, now=%s, cache_period=%s", \@row, $now, $args{cache_period};
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
                $args{dbh}->do("UPDATE $args{table} SET $args{column}=?, $args{mtime_column}=? WHERE $sqlwhere", {}, $res->[2], $now, @bind);
            } else {
                $args{dbh}->do("INSERT INTO $args{table} ($sqlcolumns, $args{column}, $args{mtime_column}) VALUES ($sqlbinds, ?,?)", {}, @bind, $res->[2], $now);
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

sub _get_arg_software_or_patterns {
    my $args = shift;

    my $sws = $args->{softwares_or_patterns} // [];
    my $is_single_software;
  RESOLVE_PATTERN:
    {
        if (@$sws && !(grep {$_ !~ $re_software} @$sws)) {
            # user specifies all software, no patterns. so we need not match
            # against list of known software
            $is_single_software = 1 if @$sws == 1;
            last;
        }
        my $res = list();
        die "Can't list known software: $res->[0] - $res->[1]"
            unless $res->[0] == 200;
        my $known = $res->[2];
        if (!@$sws) {
            $sws = $known;
            last;
        }
        my $sws_pat_resolved = [];
        for my $e (@$sws) {
            if ($e =~ $re_software) {
                push @$sws_pat_resolved, $e;
            } elsif ($e =~ m!\A/(.*)/\z!) {
                my $re = qr/$1/;
                for my $sw (@$known) {
                    push @$sws_pat_resolved, $sw
                        if $sw =~ $re && !(grep {$sw eq $_} @$sws_pat_resolved);
                }
            } else {
                die "Invalid software name/pattern '$e'";
            }
        }
        $sws = $sws_pat_resolved;
    } # RESOLVE_PATTERN
    ($sws, $is_single_software);
}

$SPEC{latest_version} = {
    v => 1.1,
    summary => 'Get latest version of one or more software',
    description => <<'_',

Will return the version number in the payload if given a single software name.
Will return an array of {software=>..., version=>...} in the payload if given
multiple software names or one or more patterns.

_
    args => {
        %args_common,
        %argopt0_softwares_or_patterns,
    },
};
sub latest_version {
    my %args = @_;
    my $state = _init(\%args, 'rw');

    my ($sws, $is_single_software) = _get_arg_software_or_patterns(\%args);
    log_trace "sws=%s", $sws;

    my $envres = envresmulti();
    my @rows;
    for my $sw (@$sws) {
        my $mod = _load_swcat_mod($sw);
        my $res = _cache_result(
            code => sub { $mod->get_latest_version(arch => $args{arch}) },
            dbh => $state->{dbh},
            cache_period => $args{cache_period},
            table => 'sw_cache',
            pk_column => ['software', 'name'],
            pk => [$sw, "latest_version.$args{arch}"],
            column => 'value',
            mtime_column => 'mtime',
        );
        $envres->add_result($res->[0], $res->[1], {item_id=>$sw});
        push @rows, {
            software=>$sw,
            version=>$res->[0] == 200 ? $res->[2] : undef,
        };
    }
    my $res = $envres->as_struct;
    if ($is_single_software) {
        $res->[2] = $rows[0]{version};
    } else {
        $res->[2] = \@rows;
    }
    $res;
}

$SPEC{download_url} = {
    v => 1.1,
    summary => 'Get download URL(s) of a software',
    description => <<'_',

Will return the version number in the payload if given a single software name.
Will return an array of {software=>..., version=>...} in the payload if given
multiple software names or one or more patterns.

_
    args => {
        %args_common,
        %argopt0_softwares_or_patterns,
        #%arg_version,
        %argopt_arch,
    },
};
sub download_url {
    my %args = @_;
    my $state = _init(\%args, 'ro');

    my ($sws, $is_single_software) = _get_arg_software_or_patterns(\%args);

    my $envres = envresmulti();
    my @rows;
    for my $sw (@$sws) {
        my $mod = _load_swcat_mod($sw);
        my $res = $mod->get_download_url(
            maybe arch => $args{arch},
        );
        $envres->add_result($res->[0], $res->[1], {item_id=>$sw});
        push @rows, {
            software => $sw,
            url => $res->[2],
        };
    }
    my $res = $envres->as_struct;
    if ($is_single_software) {
        $res->[2] = $rows[0]{url};
    } else {
        $res->[2] = \@rows;
    }
    $res;
}

1;
# ABSTRACT: Software catalog

=head1 SYNOPSIS

See L<swcat> script.


=head1 DESCRIPTION

L<swcat> is a CLI for L<Software::Catalog>.


=head1 SEE ALSO

L<Software::Catalog>

=cut
