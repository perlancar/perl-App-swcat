#!perl

use 5.010;
use strict;
use warnings;
use Test::More 0.98;
use Test::SQL::Schema::Versioned;
use Test::WithDB::SQLite;

use App::swcat;

sql_schema_spec_ok(
    $App::swcat::db_schema_spec,
    Test::WithDB::SQLite->new,
);
done_testing;
