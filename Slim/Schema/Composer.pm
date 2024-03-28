package Slim::Schema::Composer;


use strict;
use base 'Slim::Schema::DBI';

use Scalar::Util qw(blessed);

use Slim::Schema::ResultSet::Composer;

use Slim::Utils::Log;
use Slim::Utils::Misc;

my %contributorToRoleMap = (
	'ARTIST'      => 1,
	'COMPOSER'    => 2,
	'CONDUCTOR'   => 3,
	'BAND'        => 4,
	'ALBUMARTIST' => 5,
	'TRACKARTIST' => 6,
);

my @contributorRoles = sort keys %contributorToRoleMap;
my @contributorRoleIds = values %contributorToRoleMap;
my $totalContributorRoles = scalar @contributorRoles;

my %roleToContributorMap = reverse %contributorToRoleMap;

{
	my $class = __PACKAGE__;

	$class->table('contributors');

	$class->add_columns(qw(
		id
		name
		namesort
		musicmagic_mixable
		namesearch
		musicbrainz_id
		extid
	));

	$class->set_primary_key('id');
	$class->add_unique_constraint('namesearch' => [qw/namesearch/]);

	$class->utf8_columns(qw/name namesort/);

	$class->resultset_class('Slim::Schema::ResultSet::Composer');
}

1;

__END__
