package Slim::Schema;


# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Schema

=head1 SYNOPSIS

my $track = Slim::Schema->objectForUrl($url);

=head1 DESCRIPTION

L<Slim::Schema> is the main entry point for all interactions with Lyrion Music Server's
database backend. It provides an ORM abstraction layer on top of L<DBI>,
acting as a subclass of L<DBIx::Class::Schema>.

=cut

use strict;

use base qw(DBIx::Class::Schema);

use DBIx::Migration;
use Digest::MD5 qw(md5_hex);
use File::Basename qw(basename dirname);
use File::Spec::Functions qw(:ALL);
use List::Util qw(max);
use Path::Class;
use Scalar::Util qw(blessed);
use Storable;
use Tie::Cache::LRU::Expires;
use URI;

use Slim::Formats;
use Slim::Music::VirtualLibraries;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::SQLHelper;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Slim::Utils::Unicode;
use Slim::Utils::Progress;
use Slim::Utils::Prefs;
use Slim::Schema::Debug;

use Slim::Schema::RemoteTrack;
use Slim::Schema::RemotePlaylist;

my $log = logger('database.info');

my $prefs = preferences('server');

# Singleton objects for Unknowns
our ($_unknownArtist, $_unknownGenre, $_unknownAlbumId) = ('', '', undef);

# Hash of stuff about the last Album created
our $lastAlbum = {};

# Optimization to cache content type for track entries rather than look them up everytime.
tie our %contentTypeCache, 'Tie::Cache::LRU::Expires', EXPIRES => 300, ENTRIES => 128;

# For the VA album merging & scheduler globals.
my ($variousAlbumIds, $vaObj, $vaObjId);

# Map the tags we get from metadata onto the database
my %tagMapping = (
	'size'       => 'audio_size',
	'offset'     => 'audio_offset',
	'rate'       => 'samplerate',
	'age'        => 'timestamp',
	'ct'         => 'content_type',
	'fs'         => 'filesize',
	'blockalign' => 'block_alignment',
);

our $initialized         = 0;
my $trackAttrs           = {};
my $trackPersistentAttrs = {};

my %ratingImplementations = (
	'LOCAL_RATING_STORAGE' => \&_defaultRatingImplementation,
);

# Track the last error during scanning
my $LAST_ERROR = 'Unknown Error';

# Cache the basic top-level ResultSet objects
my %RS_CACHE = ();

# Cache library totals
my $TOTAL_CACHE = {};

# DB-handle cache
my $_dbh;

sub dbh {
	return $_dbh || shift->storage->dbh;
}

=head1 METHODS

All methods below are class methods on L<Slim::Schema>. Please see
L<DBIx::Class::Schema> for methods on the superclass.

=head2 init( )

Connect to the database as defined by sqlitesource, dbusername & dbpassword in the
prefs file. Set via L<Slim::Utils::Prefs>.

This method will also initialize the schema to the current version, and
automatically upgrade older versions to the most recent.

Must be called before any other actions. Generally from L<Slim::Music::Info>

=cut

sub init {
	my ( $class, $dsn, $sql ) = @_;

	return if $initialized;

	my $dbh = $class->_connect($dsn, $sql) || do {

		# Not much we can do if there's no DB.
		logBacktrace("Couldn't connect to database! Fatal error: [$!] Exiting!");
		exit;
	};

	if (Slim::Utils::OSDetect->getOS()->sqlHelperClass()->canCacheDBHandle()) {
		$_dbh = $dbh;
	}

	# Bug: 4076
	# If a user was using MySQL with 6.3.x (unsupported), their
	# metainformation table won't be dropped with the schema_1_up.sql
	# file, since the metainformation table doesn't get dropped to
	# maintain state. We need to wipe the DB and start over.
	eval {
		local $dbh->{HandleError} = sub {};
		$dbh->do('SELECT name FROM metainformation') || die $dbh->errstr;

		# when upgrading from SBS to LMS let's check the additional tables,
		# as the schema numbers might be overlapping, not causing a re-build
		$dbh->do('SELECT id FROM images LIMIT 1') || die $dbh->errstr;
	};

	# If we couldn't select our new 'name' column, then drop the
	# metainformation (and possibly dbix_migration, if the db is in a
	# wierd state), so that the migrateDB call below will update the schema.
	if ( $@ ) {
		main::INFOLOG && $log->is_info && $log->info("Creating new database - empty, outdated or invalid database found");

		eval {
			$dbh->do('DROP TABLE IF EXISTS metainformation');
			$dbh->do('DROP TABLE IF EXISTS dbix_migration');
		}
	}

	my $update = $class->migrateDB;

	# Load the DBIx::Class::Schema classes we've defined.
	# If you add a class to the schema, you must add it here as well.
	$class->load_classes(qw/
		Album
		Comment
		Contributor
		ContributorAlbum
		ContributorTrack
		Genre
		GenreTrack
		LibraryTrack
		MetaInformation
		Playlist
		PlaylistTrack
		Rescan
		Track
		Year
		Progress
		Work
		Composer
	/);
	$class->load_classes('TrackPersistent') unless (!main::STATISTICS);

	# Build all our class accessors and populate them.
	for my $accessor (qw(lastTrackURL lastTrack trackAttrs trackPersistentAttrs driver schemaUpdated)) {

		$class->mk_classaccessor($accessor);
	}

	for my $name (qw(lastTrack)) {

		$class->$name({});
	}

	$trackAttrs = Slim::Schema::Track->attributes;

	if ( main::STATISTICS ) {
		$trackPersistentAttrs = Slim::Schema::TrackPersistent->attributes;
	}

	# Use our debug and stats class to get logging and perfmon for db queries
	$class->storage->debugobj('Slim::Schema::Debug');

	# Bug 17609, avoid a possible locking issue by ensuring VA object is up to date at init time
	# instead of waiting until the first time it's called, for example through artistsQuery.
	$class->variousArtistsObject;

	# Don't reset the schemaUpdated flag without a scan, or we might miss a schema change
	$class->schemaUpdated($update) unless $class->schemaUpdated;

	# Migrate the old Mov content type to mp4 and aac - done here as at pref migration time, the database is not loaded
	if ( !main::SCANNER &&
		 !$prefs->get('migratedMovCT') && Slim::Schema->count('Track', { 'me.content_type' => 'mov' }) ) {

		$log->warn("Migrating 'mov' tracks to new database format");

		Slim::Schema->rs('Track')->search({ 'me.content_type' => 'mov', 'me.remote' => 1 })->delete_all;

		my $rs = Slim::Schema->rs('Track')->search({ 'me.content_type' => 'mov' });

		while (my $track = $rs->next) {

			if ($track->url =~ /\.(mp4|m4a|m4b)$/) {
				$track->content_type('mp4');
				$track->update;
			}

			if ($track->url =~ /\.aac$/) {
				$track->content_type('aac');
				$track->update;
			}
		}

		$prefs->set('migratedMovCT' => 1);
	}

	if ( !main::SCANNER ) {
		# Wipe cached data after rescan
		Slim::Control::Request::subscribe( sub {
			$class->wipeCaches;
			Slim::Schema::Album->addReleaseTypeStrings;
		}, [['rescan'], ['done']] );
	}

	$initialized = 1;

	$class->updateDebug;
}

sub hasLibrary {
	return $initialized;
}

sub _connect {
	my ( $class, $dsn, $sql ) = @_;

	$sql ||= [];

	my ($driver, $source, $username, $password) = $class->sourceInformation;

	# For custom exceptions
	$class->storage_type('Slim::Schema::Storage');

	my $sqlHelperClass = Slim::Utils::OSDetect->getOS()->sqlHelperClass();
	my $on_connect_do = $sqlHelperClass->on_connect_do();

	$class->connection( $dsn || $source, $username, $password, {
		RaiseError    => 1,
		AutoCommit    => 1,
		PrintError    => 0,
		Taint         => 1,
		on_connect_do => [
			@{$on_connect_do},
			@{$sql},
		]
	} ) || return;

	$sqlHelperClass->postConnect( $class->storage->dbh );

	return $class->storage->dbh;
}

=head2 throw_exception( $self, $msg )

Override L<DBIx::Class::Schema>'s throw_exception method to use our own error
reporting via L<Slim::Utils::Misc::msg>.

=cut

sub throw_exception {
	my ($self, $msg) = @_;

	logBacktrace($msg);
}

=head2 updateDebug

Check and update debug status for the storage class.
Debugging is normally disabled, but must be enabled if either logging for database.sql or perfmon is required

=cut

sub updateDebug {
	my $class  = shift;

	# May not have a DB
	return if !hasLibrary();

	my $debug  = (main::INFOLOG && logger('database.sql')->is_info) || main::PERFMON;

	$class->storage->debug($debug);
}

=head2 disconnect()

Disconnect from the database, and uninitialize the class.

=cut

sub disconnect {
	my $class = shift;

	eval { $class->storage->dbh->disconnect };

	$initialized = 0;
}

=head2 sourceInformation()

Returns in order: database driver name, DBI DSN string, username, password
from the current settings.

=cut

sub sourceInformation {
	my $class = shift;

	my $sqlHelperClass = Slim::Utils::OSDetect->getOS()->sqlHelperClass();

	my $source   = $sqlHelperClass->source();
	my $username = $prefs->get('dbusername');
	my $password = $prefs->get('dbpassword');

	my ($driver) = ($source =~ /^dbi:(\w+):/);

	return ($driver, $source, $username, $password);
}

=head2 wipeDB()

Wipes and reinitializes the database schema. Calls the schema_clear.sql script
for the current database driver.

WARNING - All data in the database will be dropped!

=cut

sub wipeDB {
	my $class = shift;

	my $log = logger('scan.import');

	main::INFOLOG && $log->is_info && $log->info("Start schema_clear");

	my ($driver) = $class->sourceInformation;

	eval {
		Slim::Utils::SQLHelper->executeSQLFile(
			$driver, $class->storage->dbh, "schema_clear.sql"
		);

		$class->migrateDB;
	};

	if ($@) {
		logError("Failed to clear & migrate schema: [$@]");
	}

	main::INFOLOG && $log->is_info && $log->info("End schema_clear");
}

=head2 optimizeDB()

Calls the schema_optimize.sql script for the current database driver.

=cut

sub optimizeDB {
	my $class = shift;

	my $log = logger('scan.import');

	main::INFOLOG && $log->is_info && $log->info("Start schema_optimize");

	my ($driver) = $class->sourceInformation;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'dboptimize',
		'total' => 2,
		'bar'   => 1
	});

	eval {
		Slim::Utils::SQLHelper->executeSQLFile(
			$driver, $class->storage->dbh, "schema_optimize.sql"
		);

		$progress->update();
		$class->forceCommit;

		Slim::Utils::OSDetect->getOS()->sqlHelperClass()->optimizeDB();
	};

	$progress->final(2);

	if ($@) {
		logError("Failed to optimize schema: [$@]");
	}

	main::INFOLOG && $log->is_info && $log->info("End schema_optimize");
}

=head2 migrateDB()

Migrates the current schema to the latest schema version as defined by the
data files handed to L<DBIx::Migration>.

=cut

sub migrateDB {
	my $class = shift;

	my $dbh = $class->storage->dbh;
	my ($driver, $source, $username, $password) = $class->sourceInformation;

	# Migrate to the latest schema version - see SQL/$driver/schema_\d+_up.sql
	my $dbix = DBIx::Migration->new({
		dbh   => $dbh,
		dir   => catdir(scalar Slim::Utils::OSDetect::dirsFor('SQL'), $driver),
		debug => $log->is_debug,
	});

	# Hide errors that aren't really errors
	my $cur_handler = $dbh->{HandleError};
	my $new_handler = sub {
		return 1 if $_[0] =~ /no such table/;
		goto $cur_handler;
	};

	local $dbh->{HandleError} = $new_handler;

	my $old = $dbix->version || 0;

	if ($dbix->migrate) {

		my $new = $dbix->version || 0;

		if ( main::INFOLOG && $log->is_info ) {
			$log->info(sprintf("Connected to database $source - schema version: [%d]", $new));
		}

		if ($old != $new) {

			if ( $log->is_warn ) {
				$log->warn(sprintf("Migrated database from schema version: %d to version: %d", $old, $new));
			}

			return 1;

		}

	} else {

		# this occurs if a user downgrades Lyrion Music Server to a version with an older schema and which does not include
		# the required downgrade sql scripts - attempt to drop and create the database at current schema version

		if ( $log->is_warn ) {
			$log->warn(sprintf("Unable to downgrade database from schema version: %d - Attempting to recreate database", $old));
		}

		eval { $class->storage->dbh->do('DROP TABLE IF EXISTS dbix_migration') };

		if ($dbix->migrate) {

			if ( $log->is_warn ) {
				$log->warn(sprintf("Successfully created database at schema version: %d", $dbix->version));
			}

			return 1;

		}

		logError(sprintf("Unable to create database - **** You may need to manually delete the database ****", $old));

	}

	return 0;
}

=head2 rs( $class )

Returns a L<DBIx::Class::ResultSet> for the specified class.

A shortcut for resultset()

=cut

sub rs {
	my $class   = shift;
	my $rsClass = ucfirst shift;
	if ( !exists $RS_CACHE{$rsClass} ) {
		$RS_CACHE{$rsClass} = $class->resultset($rsClass);
	}

	return $RS_CACHE{$rsClass};
}

=head2 search( $class, $cond, $attr )

Returns a L<DBIx::Class::ResultSet> for the specified class.

A shortcut for resultset($class)->search($cond, $attr)

=cut

sub search {
	my $class   = shift;
	my $rsClass = shift;

	return $class->rs(ucfirst($rsClass))->search(@_);
}

=head2 single( $class, $cond )

Returns a single result from a search on the specified class' L<DBIx::Class::ResultSet>

A shortcut for resultset($class)->single($cond)

=cut

sub single {
	my $class   = shift;
	my $rsClass = shift;

	return $class->rs(ucfirst($rsClass))->single(@_);
}

=head2 first( $class, $cond )

Returns the first result from a search on the specified class' L<DBIx::Class::ResultSet>

A shortcut for resultset($class)->search($cond)->first()

=cut

sub first {
	my $class   = shift;
	my $rsClass = shift;

	return $class->rs(ucfirst($rsClass))->search(@_)->first();
}

=head2 count( $class, $cond, $attr )

Returns the count result from a search on the specified class' L<DBIx::Class::ResultSet>

A shortcut for resultset($class)->count($cond, $attr)

=cut

sub count {
	my $class   = shift;
	my $rsClass = shift;

	return $class->rs(ucfirst($rsClass))->count(@_);
}

=head2 find( $class, $cond, $attr )

Returns an object result from a search on the specified class'
L<DBIx::Class::ResultSet>. This find is done on the class' primary key.

If the requested class is L<Slim::Schema::Track>, a validity check is dne
before returning.

Overrides L<DBIx::Class::ResultSet::find>

=cut

sub find {
	my $class   = shift;
	my $rsClass = ucfirst(shift);

	# If we only have a single attribute and it is not a reference and it is negative
	# then this indicates a remote track.
	if (@_ == 1 && ! ref $_[0] && $_[0] < 0) {
		return Slim::Schema::RemoteTrack->fetchById($_[0]);
	}

	return if !$initialized;

	my $object  = eval { $class->rs($rsClass)->find(@_) };

	if ($@) {

		logBacktrace("Failed: [$@]. Returning undef.");

		return undef;
	}

	# If we're requesting a Track - make sure it's still on disk and valid.
	# Do not do this if we're in the scanner, the artwork scanner calls this
	# but we do not need to stat all the files again
	if ( !main::SCANNER && $rsClass eq 'Track' ) {
		$object = $class->_checkValidity($object)
	}

	return $object;
}

=head2 searchTypes()

Returns commmon searchable types - constant values: contributor, album, track.

=cut

# Return the common searchable types.
sub searchTypes {
	my $class = shift;

	return qw(contributor album genre track);
}

=head2 contentType( $urlOrObj )

Fetch the content type for a URL or Track Object.

Try and be smart about the order of operations in order to avoid hitting the
database if we can get a simple file extension match.

=cut

sub contentType {
	my ($self, $urlOrObj) = @_;

	# Bug 15779 - if we have it in the cache then just use it
	# This does not even check that $urlOrObj is actually a URL
	# but there should be no practical chance of a key-space clash if it is not.
	if (defined $contentTypeCache{$urlOrObj}) {
		return $contentTypeCache{$urlOrObj};
	}

	my $defaultType = 'unk';
	my $contentType = $defaultType;

	# See if we were handed a track object already, or just a plain url.
	my ($track, $url, $blessed) = _validTrackOrURL($urlOrObj);

	# We can't get a content type on a undef url
	if (!defined $url) {
		return $defaultType;
	}

	# Try again for a cache hit - return immediately.
	if (defined $contentTypeCache{$url}) {
		return $contentTypeCache{$url};
	}

	# Track will be a blessed object if it's defined.
	# If we have an object - return from that.
	if ($track) {

		$contentType = $track->content_type;

	} else {

		# Otherwise, try and pull the type from the path name and avoid going to the database.
		$contentType = Slim::Music::Info::typeFromPath($url);
	}

	# Nothing from the path, and we don't have a valid track object - fetch one.
	if ((!defined $contentType || $contentType eq $defaultType) && !$track) {

		$track   = $self->objectForUrl($url);

		if (isaTrack($track)) {

			$contentType = $track->content_type;
		}
	}

	# Nothing from the object we already have in the db.
	if ((!defined $contentType || $contentType eq $defaultType) && $blessed) {

		$contentType = Slim::Music::Info::typeFromPath($url);
	}

	# Only set the cache if we have a valid contentType
	if (defined $contentType && $contentType ne $defaultType) {

		$contentTypeCache{$url} = $contentType;
	}

	return $contentType;
}

# The contentTypeCache can used above can erroneously be set to type inferred from url path - allow it to be cleared
sub clearContentTypeCache {
	my ($self, $urlOrObj) = @_;
	delete $contentTypeCache{$urlOrObj};
}

=head2 objectForUrl( $args )

The workhorse for getting L<Slim::Schema::Track> or L<Slim::Schema::Playlist>
objects from the database.

Based on arguments, will try and search for the url in the database, or
optionally create it if it does not already exist.

Required $args:

=over 4

=item *

The URL to look for.

=back

Optional $args:

=over 4

=item * create

Create the object (defaults to L<Slim::Schema::Track>) if it does not exist.

=item * readTags

Read metadata tags from the specified file or url.

=item * commit

Commit to the database (if not in AutoCommit mode).

=item * playlist

Find or create the object as a L<Slim::Schema::Playlist>.

=back

Returns a new L<Slim::Schema::Track> or L<Slim::Schema::Playlist> object on success.

=cut

sub objectForUrl {
	my $self = shift;
	my $args = shift;

	# Handle both old and new calling methods.
	# We silently handle the single arg case to fetch a URL.
	my $url        = $args;
	my $create     = 0;
	my $readTag    = 0;
	my $commit     = 0;
	my $playlist   = 0;
	my $checkMTime = 1;
	my $playlistId;

	if (@_) {

		logBacktrace("Callers - please update to pass named args!");

		($url, $create, $readTag) = ($args, @_);

	} elsif (ref($args) eq 'HASH') {

		$url        = $args->{'url'};
		$create     = $args->{'create'};
		$readTag    = $args->{'readTag'} || $args->{'readTags'};
		$commit     = $args->{'commit'};
		$playlist   = $args->{'playlist'};
		$checkMTime = $args->{'checkMTime'} if defined $args->{'checkMTime'};
		$playlistId = $args->{'playlistId'};
	}

	# Confirm that the URL itself isn't an object (see bug 1811)
	# XXX - exception should go here. Coming soon.
	if (blessed($url) || ref($url)) {

		# returning already blessed url
		return $url;
	}

	if (!$url) {

		logBacktrace("Null track request! Returning undef.");
		return undef;
	}

	if ( $url =~ /^db:/) {
		return _objForDbUrl($url);
	}

	# Create a canonical version, to make sure we only have one copy.
	if ( $url =~ /^(file|http)/i ) {
		$url = URI->new($url)->canonical->as_string;
	}

	# Pull the track object for the DB
	my $track = $self->_retrieveTrack($url, $playlist);
	my $isRemote = Slim::Music::Info::isRemoteURL($url);

	# Check to see if we have a remote track stored in our database
	if (!$track && $isRemote && !$create && !$readTag) {
		$track = $self->_retrieveTrack($url, $playlist, 'integrateRemote');
	}

	# Bug 14648: Check to see if we have a playlist with remote tracks
	if (!$track && defined $playlistId && $isRemote) {

		if (my $playlistObj = $self->find('Playlist', $playlistId)) {
			# Parse the playlist file to cause the RemoteTrack objects to be created
			Slim::Formats::Playlists->parseList($playlistObj->url);

			# try again
			$track = $self->_retrieveTrack($url, $playlist);
		}
	}

	# _retrieveTrack will always return undef or a track object
	elsif ($track && $checkMTime && !$create && !$playlist) {
		$track = $self->_checkValidity($track);
	}

	# _checkValidity will always return undef or a track object
	if (!$track && $create) {

		$track = $self->updateOrCreate({
			'url'      => $url,
			'readTags' => $readTag,
			'commit'   => $commit,
			'playlist' => $playlist,
		});
	}

	return $track;
}

sub _objForDbUrl {
	my ($url) = @_;

	if ($url =~ /^db:(\w+)\.(.+)/ ) {
		my ($class, $values) = ($1, $2);

		my $query = {};
		for my $term (split('&', $values)) {
			if ($term =~ /(.*)=(.*)/) {
				my $key = $1;
				next if $key eq 'composer.name' || $key eq 'work.title' || $key eq 'track.grouping';
				my $value = Slim::Utils::Misc::unescape($2);

				if (utf8::is_utf8($value)) {
					utf8::decode($value);
					utf8::encode($value);
				}

				$query->{$key} = $value;
			}
		}

		my $params;
		$params->{prefetch} = [];
		foreach (keys %$query) {
			if (/^(?!composer|work|track)(.*)\./) {
				push @{ $params->{prefetch} }, $1;
			}
		}

		return Slim::Schema->search(ucfirst($class), $query, $params)->first;
	}
}

sub _createOrUpdateAlbum {
	my ($self, $attributes, $trackColumns, $isCompilation, $contributorId, $hasAlbumArtist, $create, $track, $basename) = @_;

	my $dbh = $self->dbh;

	# Now handle Album creation
	my $title     = $attributes->{ALBUM};
	my $disc      = $attributes->{DISC};
	my $discc     = $attributes->{DISCC};
	# Bug 10583 - Also check for MusicBrainz Album Id
	my $brainzId  = $attributes->{MUSICBRAINZ_ALBUM_ID};
	my $extId     = $attributes->{EXTID} || $attributes->{ALBUM_EXTID};

	# if we have a disc number from an online service, default disc count to 1
	$discc ||= 1 if $extId && $disc;

	my $isDebug = main::DEBUGLOG && $log->is_debug;

	# Bug 17322, strip leading/trailing spaces from name
	if ( $title ) {
		$title =~ s/^ +//;
		$title =~ s/ +$//;
	}

	# Bug 4361, Some programs (iTunes) tag things as Disc 1/1, but
	# we want to ignore that or the group discs logic below gets confused
	# Bug 10583 - Revert disc 1/1 change.
	# "Minimal tags" don't help for the "Greatest Hits" problem,
	# either main contributor (ALBUMARTIST) or MB Album Id should be used.
	# In the contrary, "disc 1/1" helps aggregating compilation tracks in different directories.
	# At least, visible presentation is now the same for compilations: disc 1/1 behaves like x/x.
	#if ( $discc && $discc == 1 ) {
	#	$log->debug( '-- Ignoring useless DISCC tag value of 1' );
	#	$disc = $discc = undef;
	#}

	my $albumId;
	my $albumHash = {};

	if ($track && !$trackColumns) {
		$trackColumns = { $track->get_columns };
	}

	my $noAlbum = string('NO_ALBUM');

	if ( !$create && $track ) {
		$albumHash = Slim::Schema::Album->findhash( $track->album->id );
		my $differentTitle = Slim::Utils::Text::ignoreCase($title, 1) ne $albumHash->{titlesearch};

		# Bug: 4140
		# If the track is from a FLAC cue sheet, the original entry will have a 'No Album' album. See if we have a real album name.
		# If the album name has changed in other ways, we'll have to see whether the new name already exists.
		# But don't rescan with online libraries - we're handling them in the Online Library integration importer.
		if (
			!$albumHash->{extid} && $title && $albumHash->{title}
			&& ( ($albumHash->{title} eq $noAlbum && $title ne $noAlbum) || $differentTitle )
		) {
			# https://github.com/LMS-Community/slimserver/issues/547
			# check whether new album already exists if we're changing album title
			$albumId = $albumHash->{id} if $differentTitle;
			$create = 1;
		}
	}

	# If the album does not have a title, use the singleton "No Album" album
	if ( $create && (!defined $title || $title eq '') ) {
		# let the external scanner make an attempt to find any existing "No Album" in the
		# database before we assume there are none from previous scans
		if ( !defined $_unknownAlbumId ) {
			$_unknownAlbumId = $dbh->selectrow_array( qq{
				SELECT id FROM albums WHERE title = ?
			}, undef, $noAlbum );
		}

		if ( !defined $_unknownAlbumId ) {
			my $sortkey = Slim::Utils::Text::ignoreCaseArticles($noAlbum);

			$albumHash = {
				title       => $noAlbum,
				titlesort   => $sortkey,
				titlesearch => Slim::Utils::Text::ignoreCase($noAlbum, 1),
				compilation => 0, # Will be set to 1 below, if needed
				year        => 0,
				contributor => $vaObjId || $self->variousArtistsObject->id,
				release_type=> 'ALBUM',
			};

			$_unknownAlbumId = $self->_insertHash( albums => $albumHash );

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Created NO ALBUM as id: [%d]", $_unknownAlbumId));
		}
		else {
			# Bug 17370, detect if No Album is a "compilation" (more than 1 artist with No Album)
			# We have to check the other tracks already on this album, and if the artists differ
			# from the current track's artists, we have a compilation
			my $is_comp = $self->mergeSingleVAAlbum( $_unknownAlbumId, 1 );

			if ( $is_comp ) {
				$self->_updateHash( albums => {
					id          => $_unknownAlbumId,
					compilation => 1,
				}, 'id' );
			}
		}

		main::DEBUGLOG && $isDebug && $log->debug("-- Track has no album");

		return $_unknownAlbumId;
	}

	# Used for keeping track of the album name.
	$basename ||= dirname($trackColumns->{'url'});

	if ($create) {

		# Calculate once if we need/want to test for disc
		# Check only if asked to treat discs as separate and
		# if we have a disc, provided we're not in the iTunes situation (disc == discc == 1)
		my $checkDisc = 0;

		# Bug 10583 - Revert disc 1/1 change. Use MB Album Id in addition (unique id per disc, not per set!)
		if (!$prefs->get('groupdiscs') &&
			(($disc && $discc) || ($disc && !$discc) || $brainzId)) {

			$checkDisc = 1;
		}

		main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- %shecking for discs", $checkDisc ? 'C' : 'NOT C'));

		# Go through some contortions to see if the album we're in
		# already exists. Because we keep contributors now, but an
		# album can have many contributors, check the disc and
		# album name, to see if we're actually the same.
		#
		# For some reason here we do not apply the same criterias as below:
		# Path, compilation, etc are ignored...
		#
		# Be sure to use get_column() for the title equality check, as
		# get() doesn't run the UTF-8 trigger, and ->title() calls
		# Slim::Schema::Album->title() which has different behavior.

		if (
			($extId && $lastAlbum->{extid} && $extId eq $lastAlbum->{extid} && $disc && $disc == $lastAlbum->{disc})
			||
			(  $lastAlbum->{_dirname}
				&& $lastAlbum->{_dirname} eq $basename
				&& $lastAlbum->{title} eq $title
				&& (!$checkDisc || (($disc || '') eq ($lastAlbum->{disc} || 0)))
			)
		) {
			delete $lastAlbum->{_dirname};
			$albumHash = $lastAlbum;

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Same album '%s' (id: [%d]) as previous track", $title, $lastAlbum->{id}));
		}
		else {
			# Construct SQL to search for this album.  A bit uglier than using DBIC but much, much faster
			my $search = [];
			my $values = [];
			my $join;

			# Don't use year as a search criteria. Compilations in particular
			# may have different dates for each track...
			# If re-added here then it should be checked also above, otherwise
			# the server behaviour changes depending on the track order!
			# Maybe we need a preference?
			# This used to do: #'year'  => $trackColumns{'year'},

			push @{$search}, 'albums.title = ?';
			push @{$values}, $title;

			if (defined $brainzId) {
				push @{$search}, 'albums.musicbrainz_id = ?';
				push @{$values}, $brainzId;
				main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Checking for MusicBrainz Album Id: %s", $brainzId));
			}

			if (defined $extId) {
				push @{$search}, 'albums.extid = ?';
				push @{$values}, $extId;
				main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Checking for External Album Id: %s", $extId));
			}

			if ($albumId) {
				push @{$search}, 'albums.id != ?';
				push @{$values}, $albumId;
				main::DEBUGLOG && $isDebug && $log->debug("-- Checking whether we need to merge existing albums");
			}

			my $checkContributor;

			# Add disc to the search criteria if needed
			if ($checkDisc && !$extId) {
				if ($disc) {
					push @{$search}, 'albums.disc = ?';
					push @{$values}, $disc;
				}

				$checkContributor = 1;
			}
			elsif ($discc && !$extId) {
				# If we're not checking discs - ie: we're in
				# groupdiscs mode, check discc if it exists,
				# in the case where there are multiple albums
				# of the same name by the same artist. bug3254

				push @{$search}, 'albums.discc = ?';
				push @{$values}, $discc;

				$checkContributor = 1;
			}
			elsif ( defined $disc && !defined $discc && !$extId ) {

				# Bug 3920 - In the case where there's two
				# albums of the same name, but one is
				# multidisc _without_ having a discc set.
				push @{$search}, 'albums.disc IS NOT NULL';

				$checkContributor = 1;
			}

			if ( $checkContributor && defined $contributorId ) {
				# Bug 4361, also match on contributor, so we don't group
				# different multi-disc albums together just because they
				# have the same title
				my $contributor = $contributorId;
				if ( $isCompilation && !$hasAlbumArtist ) {
					$contributor = $self->variousArtistsObject->id;
				}

				push @{$search}, 'albums.contributor = ?';
				push @{$values}, $contributor;
			}

			# Bug 3662 - Only check for undefined/null values if the
			# values are undefined.
			if ( !defined $disc && !$extId ) {
				push @{$search}, 'albums.disc IS NULL';

				if ( !defined $discc ) {
					push @{$search}, 'albums.discc IS NULL';
				}
			}

			# If we have a compilation bit set - use that instead
			# of trying to match on the artist. Having the
			# compilation bit means that this is 99% of the time a
			# Various Artist album, so a contributor match would fail.
			if ( defined $isCompilation && !$extId ) {
				# in the database this is 0 or 1
				push @{$search}, 'albums.compilation = ?';
				push @{$values}, $isCompilation;
			}

			# Bug 10583 - If we had the MUSICBRAINZ_ALBUM_ID in the tracks table,
			# we could join on it here ...
			# TODO: Join on MUSICBRAINZ_ALBUM_ID if it ever makes it into the tracks table.

			# Join on tracks with the same basename to determine a unique album.
			# Bug 10583 - Only try to aggregate from basename
			# if no MUSICBRAINZ_ALBUM_ID and no DISC and no DISCC available.
			# Bug 11780 - Need to handle groupdiscs mode differently; would leave out
			# basename check if MB Album Id given and thus merge different albums
			# of the same name into one.
			if (
				# In checkDisc mode, try "same folder" only if none of MUSICBRAINZ_ALBUM_ID,
				# DISC and DISCC are known.
				($checkDisc && !defined $brainzId && !defined $disc && !defined $discc && !$extId) ||
				# When not checking discs (i.e., "Group Discs" mode), try "same folder"
				# as a last resort if both DISC and DISCC are unknown.
				(!$checkDisc && !defined $disc && !defined $discc && !$extId)
			) {
				push @{$search}, 'tracks.url LIKE ?';
				push @{$values}, "$basename%";
				$join = 1;
			}

			# with an online library item we don't have a path to check, but we hopefully have
			# consistent disc information (complete or none at all)
			if ($extId && $disc && !$prefs->get('groupdiscs')) {
				push @{$search}, 'tracks.disc = ?';
				push @{$values}, $disc;
				$join = 1;
			}

			main::DEBUGLOG && $isDebug && $log->debug( "-- Searching for an album with: " . Data::Dump::dump($search, $values) );

			my $sql = 'SELECT albums.* FROM albums ';
			$sql   .= 'JOIN tracks ON (albums.id = tracks.album) ' if $join;
			$sql   .= 'WHERE ';
			$sql   .= join( ' AND ', @{$search} );
			$sql   .= ' LIMIT 1';

			my $sth = $dbh->prepare_cached($sql);
			$sth->execute( @{$values} );

			$albumHash = $sth->fetchrow_hashref || {};

			$sth->finish;

			main::DEBUGLOG && $isDebug && $albumHash->{id} && $log->debug(sprintf("-- Found the album id: [%d]", $albumHash->{id}));

			# We've found an album above - and we're not looking
			# for a multi-disc or compilation album; check to see
			# if that album already has a track number that
			# corresponds to our current working track and that
			# the other track is not in our current directory.
			# If so, then we need to create a new album.
			# If not, the album object is valid.
			if ( $albumHash->{id} && $checkDisc && !defined $isCompilation ) {
				$sth = $dbh->prepare_cached( qq{
					SELECT url
					FROM   tracks
					WHERE  album = ?
					AND    tracknum = ?
					LIMIT 1
				} );

				$sth->execute( $albumHash->{id}, $trackColumns->{tracknum} );
				my ($matchTrack) = $sth->fetchrow_array;
				$sth->finish;

				if ( $matchTrack && dirname($matchTrack) ne $basename ) {
					main::INFOLOG && $log->is_info && $log->info(sprintf("-- Track number mismatch with album id: [%d]", $albumHash->{id}));
					$albumHash = {};
				}
			}

			# Didn't match anything? It's a new album, start populating albumHash
			if ( !$albumHash->{id} ) {
				$albumHash->{title} = $title;
			}
		}
	}

	# Always normalize the sort, as ALBUMSORT could come from a TSOA tag.
	$albumHash->{titlesort} = Slim::Utils::Text::ignoreCaseArticles( $attributes->{ALBUMSORT} || $title );

	# And our searchable version.
	$albumHash->{titlesearch} = Slim::Utils::Text::ignoreCase($title, 1);

	# Bug 2393 - was fixed here (now obsolete due to further code rework)
	$albumHash->{compilation} = $isCompilation;

	# let's not mess with compilation - we've already got our logic, and it's messy enough!
	my ($releaseType) = grep { lc($_) ne 'compilation' } Slim::Music::Info::splitTag($attributes->{RELEASETYPE});
	$albumHash->{release_type} = Slim::Utils::Text::ignoreCase( $releaseType || 'album' );
	Slim::Schema::Album->addReleaseTypeMap($releaseType, $albumHash->{release_type});

	# Bug 3255 - add album contributor which is either VA or the primary artist, used for sort by artist
	$vaObjId ||= $self->variousArtistsObject->id;

	if ( $isCompilation && !$hasAlbumArtist ) {
		$albumHash->{contributor} = $vaObjId
	}
	elsif ( defined $contributorId ) {
		$albumHash->{contributor} = $contributorId;

		# Set compilation to 1 if the primary contributor is VA
		if ( $contributorId == $vaObjId ) {
			$albumHash->{compilation} = 1;
		}
	}

	$albumHash->{musicbrainz_id} = $attributes->{MUSICBRAINZ_ALBUM_ID};

	# Handle album gain tags.
	for my $gainTag ( qw(REPLAYGAIN_ALBUM_GAIN REPLAYGAIN_ALBUM_PEAK) ) {
		my $shortTag = lc($gainTag);
		   $shortTag =~ s/^replaygain_album_(\w+)$/replay_$1/;

		# Bug 8034, this used to not change gain/peak values if they were already set,
		# bug we do want to update album gain tags if they are changed.
		if ( $attributes->{$gainTag} ) {
			$attributes->{$gainTag} =~ s/\s*dB//gi;
			$attributes->{$gainTag} =~ s/\s//g;  # bug 15965
			$attributes->{$gainTag} =~ s/,/\./g; # bug 6900, change comma to period

			$albumHash->{$shortTag} = $attributes->{$gainTag};

			# Bug 15483, remove non-numeric gain tags
			if ( $albumHash->{$shortTag} !~ /^[\d\-\+\.]+$/ ) {
				my $file = Slim::Utils::Misc::pathFromFileURL($trackColumns->{url});
				$log->error("Invalid ReplayGain tag found in $file: $gainTag -> " . $albumHash->{$shortTag} );

				delete $albumHash->{$shortTag};
			}
		}
		else {
			$albumHash->{$shortTag} = undef;
		}
	}

	# Make sure we have a good value for DISCC if grouping
	# or if one is supplied
	if ( $discc || $prefs->get('groupdiscs') ) {
		$discc = max( ($disc || 0), ($discc || 0), ($albumHash->{discc} || 0) );

		if ($discc == 0) {
			$discc = undef;
		}
	}

	# Check that these are the correct types. Otherwise MySQL will not accept the values.
	if ( defined $disc && $disc =~ /^\d+$/ ) {
		$albumHash->{disc} = $disc;
	}
	else {
		$albumHash->{disc} = undef;
	}

	if ( defined $discc && $discc =~ /^\d+$/ ) {
		$albumHash->{discc} = $discc;
	}
	else {
		$albumHash->{discc} = undef;
	}

	if ( defined $trackColumns->{year} && $trackColumns->{year} =~ /^\d+$/ ) {
		$albumHash->{year} = $trackColumns->{year};
	}
	else {
		$albumHash->{year} = undef;
	}

	if ( $extId ) {
		$albumHash->{extid} = $extId;
	}

	# Bug 7731, filter out duplicate keys that end up as array refs
	while ( my ($tag, $value) = each %{$albumHash} ) {
		if ( ref $value eq 'ARRAY' ) {
			$albumHash->{$tag} = $value->[0];
		}
	}

	if ( !$create && $title ) {
		# Update the album title - the user might have changed it.
		$albumHash->{title} = $title;
	}

	# Link album cover to track cover
	# Future TODO: if an album has multiple images i.e. Ghosts,
	# prefer cover.jpg instead of embedded artwork for album?
	# Would require an additional cover column in the albums table
	if ( $trackColumns->{coverid} || ($trackColumns->{cover} && $trackColumns->{cover} =~ /^https?/) ) {
		$albumHash->{artwork} = $trackColumns->{coverid} || $trackColumns->{cover};
	}

	if ( main::DEBUGLOG && $isDebug ) {
		if ( $albumHash->{id} ) {
			$log->debug(sprintf("-- Updating album '$title' (id: [%d]) with columns:", $albumHash->{id}));
		}
		else {
			$log->debug("-- Creating album '$title' with columns:");
		}

		while (my ($tag, $value) = each %{$albumHash}) {
			$log->debug("--- $tag : $value") if defined $value;
		}
	}

	# Detect if this album is a compilation when an explicit compilation tag is not available
	# This takes the place of the old mergeVariousArtists method
	if ( !defined $isCompilation && $albumHash->{id} ) {
		# We have to check the other tracks already on this album, and if the artists differ
		# from the current track's artists, we have a compilation
		my $is_comp = $self->mergeSingleVAAlbum( $albumHash->{id}, 1 );

		if ( $is_comp ) {
			$albumHash->{compilation} = 1;
			$albumHash->{contributor} = $vaObjId || $self->variousArtistsObject->id;

			main::DEBUGLOG && $isDebug && $log->debug( "Is a Comp : " . $albumHash->{title} );
		}
		else {
			$albumHash->{compilation} = 0;

			main::DEBUGLOG && $isDebug && $log->debug( "Not a Comp : " . $albumHash->{title} );
		}
	}
	else {
		$albumHash->{compilation} ||= 0;
	}

	# Bug: 3911 - don't add years for tracks without albums.
	$self->_createYear( $albumHash->{year} );

	# create/update album
	if ( $albumHash->{id} ) {
		# Update the existing album
		$self->_updateHash( albums => $albumHash, 'id' );
	}
	else {
		# Create a new album
		$albumHash->{id} = $self->_insertHash( albums => $albumHash );

		main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Created album (id: [%d])", $albumHash->{id}));
	}

	# Just cache some stuff about the last Album so we can find it
	# again cheaply when we add the next track.
	# This really does away with lastTrack needing to be a hash
	# but perhaps this should be a dirname-indexed hash instead,
	# perhaps even LRU, although LRU is surprisingly costly.
	# This depends on whether we need to cope with out-of-order scans
	# and I don't really know.
	$lastAlbum = $albumHash;
	$lastAlbum->{_dirname} = $basename unless $albumHash->{extid};

	return $albumHash->{id};
}

# Years have their own lookup table.
sub _createYear {
	my ($self, $year) = @_;

	if (defined $year) {
		# Bug 17322, strip leading/trailing spaces from name
		$year =~ s/^ +//;
		$year =~ s/ +$//;

		if ($year =~ /^\d+$/) {
			# Using native DBI here to improve performance during scanning
			my $dbh = Slim::Schema->dbh;

			my $sth = $dbh->prepare_cached('SELECT 1 FROM years WHERE id = ?');
			$sth->execute($year);
			my ($exists) = $sth->fetchrow_array;
			$sth->finish;

			if ( !$exists ) {
				$sth = $dbh->prepare_cached( 'INSERT INTO years (id) VALUES (?)' );
				$sth->execute($year);
			}
		}
	}
}
sub _createComments {
	my ($self, $comments, $trackId, $create) = @_;

	if ( $comments ) {
		# Using native DBI here to improve performance during scanning
		my $dbh = Slim::Schema->dbh;

		if (!$create) {
			my $sth_delete = $dbh->prepare_cached( qq{
				DELETE FROM comments
				WHERE track = ?
			} );

			$sth_delete->execute( $trackId );
		}

		# Add comments if we have them:
		my $sth_insert = $dbh->prepare_cached( qq{
			INSERT INTO comments
			(track, value)
			VALUES
			(?, ?)
		} );

		for my $comment (@{$comments}) {
			$sth_insert->execute( $trackId, $comment );

			main::DEBUGLOG && $log->is_debug && $log->debug("-- Track has comment '$comment'");
		}
	}
}

sub _createWork {
	my ($self, $work, $workSort, $composerID, $create) = @_;

	if ( $work ) {
		# Using native DBI here to improve performance during scanning
		my $dbh = Slim::Schema->dbh;

		if (!$create) {
#			my $sth_delete = $dbh->prepare_cached( qq{
#				DELETE FROM works
#				WHERE id = ?
#			} );
#
#			$sth_delete->execute( $trackId );
		}

		my $titlesort = Slim::Utils::Text::ignoreCaseArticles( $workSort || $work );
		$titlesort =~ s/(\d+)/sprintf"%04d",$1/eg unless $workSort; #Use the WORKSORT tag as is if provided, otherwise zero-pad numbers. 
		my $titlesearch = Slim::Utils::Text::ignoreCase($work, 1);

		my $sth = $dbh->prepare_cached('SELECT id FROM works WHERE titlesearch = ? AND composer = ?');
		$sth->execute($titlesearch, $composerID);
		my ($workID) = $sth->fetchrow_array;
		$sth->finish;

		if ( !$workID ) {

			my $sth_insert = $dbh->prepare_cached( qq{
				INSERT INTO works
				(composer, title, titlesort, titlesearch)
				VALUES
				(?, ?, ?, ?)
			} );

			$sth_insert->execute( $composerID, $work, $titlesort, $titlesearch );

			main::DEBUGLOG && $log->is_debug && $log->debug("-- Inserted work '$work'");

			return $dbh->last_insert_id(undef, undef, undef, undef);

		} else {

			return $workID;
		}
	}
}

sub _createTrack {
	my ($self, $columnValueHash, $persistentColumnValueHash, $source) = @_;

	# Create the track
	# Using native DBI here to improve performance during scanning
	my $dbh = $self->dbh;

	my $id = $self->_insertHash( tracks => $columnValueHash );

	if ( main::INFOLOG && $log->is_info && $columnValueHash->{'title'} ) {
		 $log->info(sprintf("Created track '%s' (id: [%d])", $columnValueHash->{'title'}, $id));
	}

	### Create TrackPersistent row

	if ( main::STATISTICS && $columnValueHash->{'audio'} ) {
		# Pull the track persistent data
		my $trackPersistentHash = Slim::Schema::TrackPersistent->findhash(
			$columnValueHash->{musicbrainz_id},
			$columnValueHash->{urlmd5},
		);

		# retrievePersistent will always return undef or a track metadata object
		if ( !$trackPersistentHash ) {
			$persistentColumnValueHash->{added}  = time();
			$persistentColumnValueHash->{url}    = $columnValueHash->{url};
			$persistentColumnValueHash->{urlmd5} = $columnValueHash->{urlmd5};

			# Create a new persistent row
			my @pcols      = keys %{$persistentColumnValueHash};
			my $pcolstring = join( ',', @pcols );
			my $pph        = join( ',', map { '?' } @pcols );

			my $sth = $dbh->prepare_cached("INSERT INTO tracks_persistent ($pcolstring) VALUES ($pph)");
			$sth->execute( map { $persistentColumnValueHash->{$_} } @pcols );
		}
		else {
			while ( my ($key, $val) = each %{$persistentColumnValueHash} ) {
				main::INFOLOG && $log->is_info && $log->info("Updating persistent ", $columnValueHash->{url}, " : $key to $val");
				$trackPersistentHash->{$key} = $val;
			}

			# Always update url/urlmd5 as these values may have changed if we looked up using musicbrainz_id
			$trackPersistentHash->{url}    = $columnValueHash->{url};
			$trackPersistentHash->{urlmd5} = $columnValueHash->{urlmd5};

			$self->_updateHash( tracks_persistent => $trackPersistentHash, 'id' );
		}
	}

	return $id;
}

=head2 _newTrack( $args )

Create a new track with the given attributes.

Required $args:

=over 4

=item * url

The URL to create in the database.

=back

Optional $args:

=over 4

=item * attributes

A hash ref with data to populate the object.

=item * id

An explicit record id.

=item * readTags

Read metadata tags from the specified file or url.

=item * commit

Commit to the database (if not in AutoCommit mode).

=item * playlist

Find or create the object as a L<Slim::Schema::Playlist>.

=back

Returns a new L<Slim::Schema::Track> or L<Slim::Schema::Playlist> object on success.

=cut

sub _newTrack {
	my $self = shift;
	my $args = shift;

	my $isDebug = main::DEBUGLOG && $log->is_debug;
	my $isInfo  = main::INFOLOG && $log->is_info;

	my $url           = $args->{'url'};
	my $attributeHash = $args->{'attributes'} || {};
	my $trackId       = $args->{'id'} || 0;
	my $playlist      = $args->{'playlist'} || 0;
	my $source        = $playlist ? 'Playlist' : 'Track';


	if (!$url) {
		logBacktrace("Null track request! Returning undef");
		return undef;
	}

	my $dirname            = dirname($url);
	my $deferredAttributes = {};

	main::INFOLOG && $isInfo && $log->info("\nNew $source: [$url]");

	# Default the tag reading behaviour if not explicitly set
	if (!defined $args->{'readTags'}) {
		$args->{'readTags'} = 'default';
	}

	# Read the tag, and start populating the database.
	if ($args->{'readTags'}) {

		main::INFOLOG && $isInfo && $log->info("readTags is ". $args->{'readTags'});

		$attributeHash = { %{Slim::Formats->readTags($url)}, %$attributeHash  };

		# Abort early if readTags returned nothing, meaning the file is probably bad/missing
		if ( !scalar keys %{$attributeHash} ) {
			$LAST_ERROR = 'Unable to read tags from file';
			return;
		}
	}

	# Abort early and don't add the track if it's DRM'd
	if ($attributeHash->{'DRM'}) {
		$log->warn("$source has DRM -- skipping it!");
		$LAST_ERROR = 'Track is DRM-protected';
		return;
	}

	($attributeHash, $deferredAttributes) = $self->_preCheckAttributes({
		'url'        => $url,
		'attributes' => $attributeHash,
		'create'     => 1,
	});

	# Playlists don't have years.
	if ($playlist) {
		delete $attributeHash->{'YEAR'};
	}

	### Work out Track columns

	# Creating the track only wants lower case values from valid columns.
	my %columnValueHash = ();
	my %persistentColumnValueHash = ();

	# Walk our list of valid attributes, and turn them into something ->create() can use.
	main::DEBUGLOG && $isDebug && $log->debug("Creating $source with columns:");

	while (my ($key, $val) = each %$attributeHash) {

		$key = lc($key);

		# XXX - different check from updateOrCreate, which also checks val != ''
		if (defined $val && exists $trackAttrs->{$key}) {

			# Bug 7731, filter out duplicate keys that end up as array refs
			$val = $val->[0] if ( ref $val eq 'ARRAY' );

			main::DEBUGLOG && $isDebug && $log->debug("  $key : $val");
			$columnValueHash{$key} = $val;
		}

		# Metadata is only included if it contains a non zero value
		if ( main::STATISTICS && $val && exists $trackPersistentAttrs->{$key} ) {

			# Bug 7731, filter out duplicate keys that end up as array refs
			$val = $val->[0] if ( ref $val eq 'ARRAY' );

			main::DEBUGLOG && $isDebug && $log->debug("  (persistent) $key : $val");
			$persistentColumnValueHash{$key} = $val;
		}
	}

	# Tag and rename set URL to the Amazon image path. Smack that.
	# We don't use it anyways.
	$columnValueHash{'url'} = $url;
	$columnValueHash{'urlmd5'} = md5_hex($url);

	# Use an explicit record id if it was passed as an argument.
	if ($trackId) {
		$columnValueHash{'id'} = $trackId;
	}

	# Record time this track was added/updated
	my $now = time();
	$columnValueHash{added_time} = $now;
	$columnValueHash{updated_time} = $now;

	my $ct = $columnValueHash{'content_type'};

	# For simple cases, just create the Track row and return
	if (($playlist && $columnValueHash{extid}) || !defined $ct || $ct eq 'dir' || $ct eq 'lnk' || !$columnValueHash{'audio'}) {
		return $self->_createTrack(\%columnValueHash, \%persistentColumnValueHash, $source);
	}

	# Make a local variable for COMPILATION, that is easier to handle
	my $isCompilation = undef;
	my $compilation = $deferredAttributes->{'COMPILATION'};

	if (defined $compilation) {
		# Use eq instead of == here, otherwise perl will warn.
		if ($compilation =~ /^(?:1|yes|true)$/i) {
			$isCompilation = 1;
			main::DEBUGLOG && $isDebug && $log->debug("-- Track is a compilation");
		} elsif ($compilation =~ /^(?:0|no|false)$/i) {
			$isCompilation = 0;
			main::DEBUGLOG && $isDebug && $log->debug("-- Track is NOT a compilation");
		}
	}

	### Create Contributor rows
	# Walk through the valid contributor roles, adding them to the database.
	my $contributors = $self->_mergeAndCreateContributors($deferredAttributes, $isCompilation, 1);

	# Set primary_artist for the track
	if ( my $artist = $contributors->{ARTIST} || $contributors->{TRACKARTIST} ) {
		$columnValueHash{primary_artist} = $artist->[0];
	}

	### Create Work rows
	my $workID = $self->_createWork($deferredAttributes->{'WORK'}, $deferredAttributes->{'WORKSORT'}, $contributors->{'COMPOSER'}->[0], 1);

	### Find artwork column values for the Track
	if ( !$columnValueHash{cover} && $columnValueHash{audio} ) {
		# Track does not have embedded artwork, look for standalone cover
		# findStandaloneArtwork returns either a full path to cover art or 0
		# to indicate no artwork was found.
		my $cover = Slim::Music::Artwork->findStandaloneArtwork( \%columnValueHash, $deferredAttributes, $dirname );

		$columnValueHash{cover} = $cover;
	}

	if ( $columnValueHash{cover} ) {
		# Generate coverid value based on artwork, mtime, filesize
		$columnValueHash{coverid} = Slim::Schema::Track->generateCoverId( {
			cover => $columnValueHash{cover},
			url   => $url,
			mtime => $columnValueHash{timestamp},
			size  => $columnValueHash{filesize},
		} );
	}

	### Create Album row
	my $albumId = $self->_createOrUpdateAlbum($deferredAttributes,
		\%columnValueHash,														# trackColumns
		$isCompilation,
		$contributors->{'ALBUMARTIST'}->[0] || $contributors->{'ARTIST'}->[0],	# primary contributor-id
		defined $contributors->{'ALBUMARTIST'}->[0] ? 1 : 0,					# hasAlbumArtist
		1,																		# create
		undef,																	# Track
		$dirname,
	);

	### Create Track row
	$columnValueHash{'work'} = $workID if $workID;
	$columnValueHash{'album'} = $albumId if !$playlist;
	$trackId = $self->_createTrack(\%columnValueHash, \%persistentColumnValueHash, $source);

	### Create ContributorTrack & ContributorAlbum rows
	$self->_createContributorRoleRelationships($contributors, $trackId, $albumId);

	### Create Genre rows
	$self->_createGenre($deferredAttributes->{'GENRE'}, $trackId, 1);

	### Create Comment rows
	$self->_createComments($deferredAttributes->{'COMMENT'}, $trackId, 1);

	$self->forceCommit if $args->{'commit'};

	if ($attributeHash->{'CONTENT_TYPE'}) {
		$contentTypeCache{$url} = $attributeHash->{'CONTENT_TYPE'};
	}

	return $trackId;
}

=head2 updateOrCreate( $args )

Update the attributes of a track or create one if one doesn't already exist.

Required $args:

=over 4

=item * url

The URL to find or create in the database.

=back

Optional $args:

=over 4

=item * attributes

A hash ref with data to populate the object.

=item * readTags

Read metadata tags from the specified file or url.

=item * commit

Commit to the database (if not in AutoCommit mode).

=item * playlist

Find or create the object as a L<Slim::Schema::Playlist>.

=item * checkMTime

Check to see if the track has changed, if not - don't update.

=back

Returns a new L<Slim::Schema::Track> or L<Slim::Schema::Playlist> object on success.

=cut

sub updateOrCreate {
	my $self = shift;
	my $args = shift;

	my $trackIdOrTrack = $self->updateOrCreateBase($args);

	return undef if !defined $trackIdOrTrack;

	return $trackIdOrTrack if blessed $trackIdOrTrack;

	return Slim::Schema->rs($args->{'playlist'} ? 'Playlist' : 'Track')->find($trackIdOrTrack);
}

# Tries to avoid instantiating a Track object if not needed
sub updateOrCreateBase {
	my $self = shift;
	my $args = shift;

	#
	my $urlOrObj      = $args->{'url'};
	my $attributeHash = $args->{'attributes'} || {};
	my $commit        = $args->{'commit'};
	my $readTags      = $args->{'readTags'} || 0;
	my $checkMTime    = $args->{'checkMTime'};
	my $playlist      = $args->{'playlist'};
	my $integrateRemote = $args->{'integrateRemote'};
	my $isNew         = $args->{'new'} || 0; # save a query if caller knows the track is new

	my $trackId;

	# XXX - exception should go here. Coming soon.
	my ($track, $url, $blessed) = _validTrackOrURL($urlOrObj);

	if (!defined($url) || ref($url)) {

		logBacktrace("No URL specified! Returning undef.");
		logError(Data::Dump::dump($attributeHash)) if main::DEBUGLOG && !$::quiet;

		return undef;
	}

	# make sure we always have an up to date md5 hash value
	$attributeHash->{urlmd5} = md5_hex($url);

	# Short-circuit for remote tracks
	if (!$integrateRemote && Slim::Music::Info::isRemoteURL($url)) {
		my $class = $playlist ? 'Slim::Schema::RemotePlaylist' : 'Slim::Schema::RemoteTrack';

		($attributeHash, undef) = $self->_preCheckAttributes({
			'url'        => $url,
			'attributes' => $attributeHash,
		});

		return $class->updateOrCreate($track ? $track : $url, $attributeHash);
	}

	# Track will be defined or not based on the assignment above.
	if ( !defined $track && !$isNew ) {
		$track = $self->_retrieveTrack($url, $playlist, $integrateRemote);
	}

	# XXX - exception should go here. Coming soon.
	# _retrieveTrack will always return undef or a track object
	if ($track) {

		# Check the timestamp & size to make sure they've not changed.
		if ($checkMTime && Slim::Music::Info::isFileURL($url) && !$self->_hasChanged($track, $url)) {

			main::INFOLOG && $log->is_info && $log->info("Track is still valid! Skipping update! $url");

			return $track;
		}

		# Pull the track metadata object for the DB if available
		my $trackPersistent;
		if ( main::STATISTICS ) {
			# XXX native DBI
			$trackPersistent = $track->retrievePersistent();
		}

		# Bug: 2335 - readTags is set in Slim::Formats::Playlists::CUE - when
		# we create/update a cue sheet to have a CT of 'cur'
		if (defined $attributeHash->{'CONTENT_TYPE'} && $attributeHash->{'CONTENT_TYPE'} eq 'cur') {
			$readTags = 0;
		}

		main::INFOLOG && $log->is_info && $log->info("Merging entry for $url readTags is: [$readTags]");

		# Force a re-read if requested.
		# But not for non-audio files.
		if ($readTags && $track->get('audio')) {

			$attributeHash = { %{Slim::Formats->readTags($url)}, %$attributeHash  };
		}

		my $deferredAttributes;
		($attributeHash, $deferredAttributes) = $self->_preCheckAttributes({
			'url'        => $url,
			'attributes' => $attributeHash,
		});

		# Update timestamp
		$attributeHash->{updated_time} = time();

		while (my ($key, $val) = each %$attributeHash) {

			$key = lc($key);

			## Need to set grouping to null if no value passed in (may have had a value before this scan)
			if ( (defined $val && $val ne '' || $key eq "grouping") && exists $trackAttrs->{$key} ) {

				main::INFOLOG && $log->is_info && $log->info("Updating $url : $key to $val");

				$track->set_column($key, $val);
			}

			# Metadata is only included if it contains a non zero value
			if ( main::STATISTICS && $val && blessed($trackPersistent) && exists $trackPersistentAttrs->{$key} ) {

				main::INFOLOG && $log->is_info && $log->info("Updating persistent $url : $key to $val");

				$trackPersistent->set_column( $key => $val );
			}
		}

		# _postCheckAttributes does an update
		if (!$playlist) {

			$self->_postCheckAttributes({
				'track'      => $track,
				'attributes' => $deferredAttributes,
				'integrateRemote' => $integrateRemote
			});
		}

		$self->forceCommit if $commit;

		if ($track && $attributeHash->{'CONTENT_TYPE'}) {
			$contentTypeCache{$url} = $attributeHash->{'CONTENT_TYPE'};
		}

	} else {

		$trackId = $self->_newTrack({
			'url'        => $url,
			'attributes' => $attributeHash,
			'readTags'   => $readTags,
			'commit'     => $commit,
			'playlist'   => $playlist,
			'integrateRemote' => $integrateRemote
		});

	}

	return $track || $trackId;
}

=head2 variousArtistsObject()

Returns a singleton object representing the artist 'Various Artists'

=cut

sub variousArtistsObject {
	my $class = shift;

	return $vaObj if main::SCANNER && $vaObj;

	my $vaString = Slim::Music::Info::variousArtistString();

	# Fetch a VA object and/or update it's name if the user has changed it.
	# XXX - exception should go here. Coming soon.
	if (!blessed($vaObj) || !$vaObj->can('name')) {
		$vaObj = $class->first('Contributor', {
			'namesearch' => Slim::Utils::Text::ignoreCase($vaString, 1),
		}) || $class->rs('Contributor')->update_or_create({
			'name'       => $vaString,
			'namesearch' => Slim::Utils::Text::ignoreCase($vaString, 1),
			'namesort'   => Slim::Utils::Text::ignoreCaseArticles($vaString),
		}, { 'key' => 'namesearch' });

		main::DEBUGLOG && $log->is_debug && $log->debug(sprintf("-- Created VARIOUS ARTIST (id: [%d])", $vaObj->id));
	}

	if ($vaObj && $vaObj->name ne $vaString) {

		$vaObj->name($vaString);
		$vaObj->namesort( Slim::Utils::Text::ignoreCaseArticles($vaString) );
		$vaObj->namesearch( Slim::Utils::Text::ignoreCase($vaString, 1) );
		$vaObj->update;
	}

	# this will not change while in the external scanner
	$vaObjId = $vaObj->id if main::SCANNER;

	return $vaObj;
}

=head2 variousArtistsAlbumCount( $find )

Wrapper for the common case of checking the level below the current one
(always Albums), to see if any Various Artists albums exist.

=cut

sub variousArtistsAlbumCount {
	my $class = shift;

	# Bug 3983, 4059: clone the provided hash reference so we don't mung further
	# processing outside this function.
	my $find  = Storable::dclone(shift);

	my %attr = ( 'group_by' => 'me.id' );
	my @join = ();

	# We always want to search for compilation
	$find->{'me.compilation'} = 1;

	if (exists $find->{'genre.id'}) {

		$find->{'genreTracks.genre'} = delete $find->{'genre.id'};
		push @join, { 'tracks' => 'genreTracks' };

	} elsif (exists $find->{'genre.name'}) {

		push @join, { 'tracks' => { 'genreTracks' => 'genre' } };
	}

	$attr{'join'} = \@join;

	return $class->count('Album', $find, \%attr);
}

=head2 trackCount()

Returns the number of local audio tracks in the database.

=cut

sub trackCount {
	my $self = shift;

	return $self->count('Track', { 'me.audio' => 1 });
}

=head2 totalTime()

Returns the total (cumulative) time in seconds of all audio tracks in the database.

=cut

sub totalTime {
	my ($self, $client) = @_;

	my $library_id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);

	$TOTAL_CACHE->{$library_id} ||= {};
	my $totalCache = $TOTAL_CACHE->{$library_id};

	if (!$totalCache->{totalTime}) {
		my $dbh = $self->dbh;
		my $sth;

		if ($library_id) {
			$sth = $dbh->prepare_cached('SELECT SUM(secs) FROM tracks, library_track WHERE library_track.library=? AND library_track.track=tracks.id AND tracks.audio=1');
			$sth->execute($library_id);
		}
		else {
			$sth = $dbh->prepare_cached('SELECT SUM(secs) FROM tracks WHERE tracks.audio=1');
			$sth->execute();
		}

		($totalCache->{totalTime}) = $sth->fetchrow_array;
		$sth->finish;
	}

	return $totalCache->{totalTime};
}

=head2 mergeSingleVAAlbum($albumid)

Merge a single VA album

=cut

sub mergeSingleVAAlbum {
	my ( $class, $albumid, $returnIsComp ) = @_;

	my $importlog = main::INFOLOG ? logger('scan.import') : undef;
	my $isInfo    = main::INFOLOG && $importlog->is_info;

	my $dbh  = $class->dbh;
	my ($is_comp, $is_comp_db);

	# if album already is flagged as a compilation, we don't need to continue the evaluation
	if ($returnIsComp) {
		my $iscomp_sth = $dbh->prepare_cached( qq{
			SELECT compilation
			FROM   albums
			WHERE  id = ?
		} );

		$iscomp_sth->execute($albumid);
		($is_comp_db) = $iscomp_sth->fetchrow_array;
		$iscomp_sth->finish;

		return 1 if $is_comp_db;
	}

	my $role = Slim::Schema::Contributor->typeToRole('ARTIST');

	my $track_contribs_sth = $dbh->prepare_cached( qq{
		SELECT contributor, track
		FROM   contributor_track
		WHERE  track IN (
			SELECT id
			FROM tracks
			WHERE album = ?
		)
		AND	  role = ?
		ORDER BY contributor, track
	} );

	# Check track contributors to see if all tracks have the same contributors
	my ($contributor, $trackid);
	my %track_contribs;

	$track_contribs_sth->execute( $albumid, $role );
	$track_contribs_sth->bind_columns( \$contributor, \$trackid );

	while ( $track_contribs_sth->fetch ) {
		$track_contribs{ $contributor } .= $trackid . ':';
	}

	my $track_list;
	for my $tracks ( values %track_contribs ) {
		if ( $track_list && $track_list ne $tracks ) {
			# contributors differ for some tracks, it's a compilation
			$is_comp = 1;
			last;
		}
		$track_list = $tracks;
	}

	if ( $returnIsComp ) {
		# Optimization used to avoid extra query when updating an album entry
		return $is_comp;
	}

	if ( $is_comp ) {
		my $comp_sth = $dbh->prepare_cached( qq{
			UPDATE albums
			SET    compilation = 1, contributor = ?
			WHERE  id = ?
		} );

		# Flag as a compilation, set primary contrib to Various Artists
		$comp_sth->execute( $vaObjId || $class->variousArtistsObject->id, $albumid );
	}
	# only update if the flag is not set yet
	elsif (!defined $is_comp_db) {
		my $not_comp_sth = $dbh->prepare_cached( qq{
			UPDATE albums
			SET    compilation = 0
			WHERE  id = ?
		} );

		# Cache that the album is not a compilation so it's not constantly
		# checked during every mergeVA phase.  Scanner::Local will reset
		# compilation to undef when a new/deleted/changed track requires
		# a re-check of VA status
		$not_comp_sth->execute($albumid);
	}
}

=head2 wipeCaches()

Clears the lastTrack caches, and forces a database commit.

=cut

sub wipeCaches {
	my $self = shift;

	$self->forceCommit;

	%contentTypeCache = ();

	$TOTAL_CACHE = {};

	# clear the references to these singletons
	$vaObj          = undef;
	$vaObjId        = undef;
	$_unknownArtist = '';
	$_unknownGenre  = '';
	$_unknownAlbumId = undef;

	$self->lastTrackURL('');
	$self->lastTrack({});
	$lastAlbum = {};

	main::INFOLOG && logger('scan.import')->info("Wiped all in-memory caches.");
}

=head2 wipeLastAlbumCache($id)

Wipe the lastAlbum cache, if it contains the album $id

=cut

sub wipeLastAlbumCache {
	my ( $self, $id ) = @_;

	if ( defined $id && exists $lastAlbum->{id} && $lastAlbum->{id} == $id ) {
		$lastAlbum = {};
	}
}

=head2 wipeAllData()

Wipe all data in the database. Encapsulates L<wipeDB> and L<wipeCaches>

=cut

sub wipeAllData {
	my $self = shift;

	$self->schemaUpdated(undef);
	$self->wipeCaches;
	$self->wipeDB;

	require Slim::Utils::ArtworkCache;
	Slim::Utils::ArtworkCache->new()->wipe();

	main::INFOLOG && logger('scan.import')->info("Wiped the database.");
}

=head2 forceCommit()

Flush any pending database transactions to disk when not in AutoCommit mode.

=cut

sub forceCommit {
	my $self = shift;

	if (!$initialized) {

		main::INFOLOG && $log->is_info && $log->info("Trying to commit transactions before DB is initialized!");
		return;
	}

	$self->lastTrackURL('');
	$self->lastTrack({});

	if (!$self->storage->dbh->{'AutoCommit'}) {

		main::INFOLOG && $log->is_info && $log->info("Syncing to the database.");

		eval { $self->storage->dbh->commit };

		if ($@) {
			logWarning("Couldn't commit transactions to DB: [$@]");
			return;
		}
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug("forceCommit ignored, database is in AutoCommit mode");
	}
}

=head2 artistOnlyRoles( @add );

Return an array ref of valid roles as defined by
L<Slim::Schema::Contributor::contributorRoles>, based on the user's current
prefernces for including Composers, Conductors & Bands when browsing their
audio collection via 'Contributors'.

If a caller wishes to force an addition to the list of roles, pass in the
additional roles.

=cut

sub artistOnlyRoles {
	my $self  = shift;
	my @add   = @_;

	my %roles = (
		'ARTIST'      => 1,
		'ALBUMARTIST' => 1,
	);

	# If the user has requested explict roles to be added, do so.
	for my $role (@add) {

		if ($role) {
			$roles{$role} = 1;
		}
	}

	# And if the user has asked for ALL, give them it.
	if ($roles{'ALL'}) {
		return undef;
	}

	# Loop through each pref to see if the user wants to show that contributor role.
	for my $role (Slim::Schema::Contributor->contributorRoles) {

		if ($prefs->get(sprintf('%sInArtists', lc($role)))) {

			$roles{$role} = 1;
		}
	}

	# If we're using all roles, don't bother with the constraint.
	if (scalar keys %roles != Slim::Schema::Contributor->totalContributorRoles) {

		return [ sort map { Slim::Schema::Contributor->typeToRole($_) } keys %roles ];
	}

	return undef;
}

sub registerRatingImplementation {
	my ( $class, $source, $impl ) = @_;

	if ( ref $impl eq 'CODE' ) {
		$ratingImplementations{$source} = $impl;
	}
}

sub ratingImplementations {
	return [ sort keys %ratingImplementations ];
}

sub rating {
	my ( $class, $track, $rating ) = @_;

	my $impl = $prefs->get('ratingImplementation');

	if ( !$impl || !exists $ratingImplementations{$impl} ) {
		$impl = 'LOCAL_RATING_STORAGE';
	}

	return $ratingImplementations{$impl}->( $track, $rating );
}

#
# Private methods:
#

sub _defaultRatingImplementation {
	my ( $track, $rating ) = @_;

	if ( defined $rating ) {
		$track->rating($rating);
		$track->update;
		Slim::Schema->forceCommit;
	}

	return $track->rating;
}

sub _retrieveTrack {
	my ($self, $url, $playlist, $integrateRemote) = @_;

	return undef if !$url;
	return undef if ref($url);

	my $track;

	if (!$integrateRemote && Slim::Music::Info::isRemoteURL($url)) {
		return Slim::Schema::RemoteTrack->fetch($url, $playlist);
	}

	# Keep the last track per dirname.
	my $dirname = dirname($url);
	my $source  = $playlist ? 'Playlist' : 'Track';

	if (!$playlist && $dirname ne '.' && defined $self->lastTrackURL && $url eq $self->lastTrackURL) {

		$track = $self->lastTrack->{$dirname};

	} else {

		$track = $self->rs($source)->single({ 'url' => $url });
	}

	# XXX - exception should go here. Coming soon.
	if (blessed($track)) {

		if (!$playlist || $track->audio) {
			$self->lastTrackURL($url);
			$self->lastTrack->{$dirname} = $track;

			# Set the contentTypeCache entry here is case
			# it was guessed earlier without knowing the real type
			$contentTypeCache{$url} = $track->content_type;
		}

		return $track;
	}

	return undef;
}

sub _checkValidity {
	my $self  = shift;
	my $track = shift;

	# XXX - exception should go here. Coming soon.
	return undef unless blessed($track);
	return undef unless $track->can('get');

	# Remote tracks are always assumed to be valid
	# Maybe we will add a timeout mechanism later
	return $track if $track->isRemoteURL();

	my $isDebug = main::DEBUGLOG && $log->is_debug;

	my $url = $track->get('url');

	# Don't check for things that aren't audio
	if ($track->get('audio') && $self->_hasChanged($track, $url)) {

		main::DEBUGLOG && $isDebug && $log->debug("Re-reading tags from $url as it has changed.");

		my $oldid = $track->id;
		my $oldAlbum = $track->albumid;

		# Do a cascading delete for has_many relationships - this will
		# clear out Contributors, Genres, etc.
		$track->delete;
		Slim::Schema::Album->rescan($oldAlbum);

		# Add the track back into database with the same id as the record deleted.
		my $trackId = $self->_newTrack({
			'id'       => $oldid,
			'url'      => $url,
			'readTags' => 1,
			'commit'   => 1,
		});

		$track = Slim::Schema->rs('Track')->find($trackId) if (defined $trackId);
	}

	# Track may have been deleted by _hasChanged
	return undef unless $track->in_storage;

	return undef unless blessed($track);
	return undef unless $track->can('url');

	return $track;
}

sub _hasChanged {
	my ($self, $track, $url) = @_;

	my $isDebug = main::DEBUGLOG && $log->is_debug;

	# We return 0 if the file hasn't changed
	#    return 1 if the file has been changed.

	# Don't check anchors - only the top level file.
	return 0 if Slim::Utils::Misc::anchorFromURL($url);

	my $filepath = Slim::Utils::Misc::pathFromFileURL($url);

#	main::DEBUGLOG && $isDebug && $log->debug("Checking for [$filepath] - size & timestamp.");

	# Return if it's a directory - they expire themselves
	# Todo - move directory expire code here?
	return 0 if -d $filepath;
	return 0 if $filepath =~ /\.lnk$/i;

	# See if the file exists
	#
	# Reuse _, as we only need to stat() once.
	if (-e _) {

		my $filesize  = $track->get('filesize');
		my $timestamp = $track->get('timestamp');

		# Check filesize and timestamp to decide if we use the cached data.
		my $fsdef   = (defined $filesize);
		my $fscheck = 0;

		if ($fsdef) {
			$fscheck = (-s _ == $filesize);
		}

		# Now the AGE
		my $agedef   = (defined $timestamp);
		my $agecheck = 0;

		if ($agedef) {
			$agecheck = ((stat(_))[9] == $timestamp);
		}

		return 0 if  $fsdef && $fscheck && $agedef && $agecheck;
		return 0 if  $fsdef && $fscheck && !$agedef;
		return 0 if !$fsdef && $agedef  && $agecheck;

		return 1;

	} else {

		# Bug 4402, if the entire volume/drive this file is on is unavailable,
		# it's likely removable storage and shouldn't be deleted
		my $offline;

		if ( main::ISWINDOWS ) {
			# win32, check the drive letter
			my $parent = Path::Class::File->new($filepath)->dir;
			if ( my $vol = $parent->volume ) {
				if ( !-d $vol ) {
					$offline = 1;
				}
			}
		}
		elsif ( main::ISMAC ) {
			# Mac, check if path is in /Volumes
			if ( $filepath =~ m{^/Volumes/([^/]+)} ) {
				if ( !-d "/Volumes/$1" ) {
					$offline = 1;
				}
			}
		}
		else {
			# XXX: Linux/Unix, not sure how to tell if a given path
			# is from an unmounted filesystem
		}

		if ( $offline ) {
			main::DEBUGLOG && $isDebug && $log->debug( "Drive/Volume containing [$filepath] seems to be offline, skipping" );
			return 0;
		}

		main::DEBUGLOG && $isDebug && $log->debug("Removing [$filepath] from the db as it no longer exists.");

		# Be sure to clear the track out of the cache as well.
		if ($self->lastTrackURL && $url eq $self->lastTrackURL) {
			$self->lastTrackURL('');
		}

		my $dirname = dirname($url);

		if (defined $self->lastTrack->{$dirname} && $self->lastTrack->{$dirname}->url eq $url) {
			delete $self->lastTrack->{$dirname};
		}

		$track->delete;
		$track = undef;

		$self->forceCommit;

		return 0;
	}
}

sub _preCheckAttributes {
	my $self = shift;
	my $args = shift;

	my $url    = $args->{'url'};

	my $deferredAttributes = {};

	# Copy the incoming hash, so we don't modify it
	my $attributes = {};
	my %mappedValues;

	# Normalize attribute names
	while ( my ($key, $val) = each %{ $args->{'attributes'} } ) {
		# don't overwrite mapped values
		next if $mappedValues{$key};

		if ( my $mappedKey = $tagMapping{lc($key)} ) {
			$mappedValues{ uc($mappedKey) } = $attributes->{ uc($mappedKey) } = $val;
		}
		else {
			$attributes->{ $key } = $val;
		}
	}

	# Bug 9359, don't allow tags named 'ID'
	if ( exists $attributes->{'ID'} ) {
		delete $attributes->{'ID'};
	}

	# We've seen people with multiple TITLE tags in the wild.. why I don't
	# know. Merge them. Do the same for ALBUM, as you never know.
	for my $tag (qw(TITLE ALBUM)) {

		if ($attributes->{$tag} && ref($attributes->{$tag}) eq 'ARRAY') {

			$attributes->{$tag} = join(' / ', @{$attributes->{$tag}});
		}
	}

	if ($attributes->{'TITLE'}) {
		# Create a canonical title to search against.
		$attributes->{'TITLESEARCH'} = Slim::Utils::Text::ignoreCase($attributes->{'TITLE'}, 1);

		if (!$attributes->{'TITLESORT'}) {
			$attributes->{'TITLESORT'} = Slim::Utils::Text::ignoreCaseArticles($attributes->{'TITLE'});
		} else {
			# Always normalize the sort, as TITLESORT could come from a TSOT tag.
			$attributes->{'TITLESORT'} = Slim::Utils::Text::ignoreCaseArticles($attributes->{'TITLESORT'});
		}
	}

	# Remote index.
	$attributes->{'REMOTE'} = Slim::Music::Info::isRemoteURL($url) ? 1 : 0;

	# Some formats stick a DISC tag such as 1/2 or 1-2 into the field.
	if ($attributes->{'DISC'} && $attributes->{'DISC'} =~ m|^(\d+)[-/](\d+)$|) {
		$attributes->{'DISC'}  = $1;
		$attributes->{'DISCC'} ||= $2;
	}

	# Some tag formats - APE? store the type of channels instead of the number of channels.
	if (defined $attributes->{'CHANNELS'}) {
		if ($attributes->{'CHANNELS'} =~ /stereo/i) {
			$attributes->{'CHANNELS'} = 2;
		} elsif ($attributes->{'CHANNELS'} =~ /mono/i) {
			$attributes->{'CHANNELS'} = 1;
		}
	}

	# Don't insert non-numeric or '0' YEAR fields into the database. Bug: 2610
	# Same for DISC - Bug 2821
	for my $tag (qw(YEAR DISC DISCC BPM CHANNELS)) {

		if (
		    defined $attributes->{$tag}
		    &&
		    ( $attributes->{$tag} !~ /^\d+$/ || $attributes->{$tag} == 0 )
		) {
			delete $attributes->{$tag};
		}
	}

	# Bug 4823 - check boundaries set by our tinyint schema.
	for my $tag (qw(DISC DISCC)) {
		next if (!defined $attributes->{$tag});
		$attributes->{$tag} = 254 if ($attributes->{$tag} > 254);
		$attributes->{$tag} = 0 if ($attributes->{$tag} < 0);
	}

	# Bug 3759 - Set undef years to 0, so they're included in the count.
	# Bug 3643 - rating is specified as a tinyint - users running their
	# own SQL server may have strict mode turned on.
	for my $tag (qw(YEAR RATING)) {
		$attributes->{$tag} ||= 0;
	}

	# Bug 4803, ensure rating is an integer that fits into tinyint
	if ( $attributes->{RATING} && ($attributes->{RATING} !~ /^\d+$/ || $attributes->{RATING} > 255) ) {
		logWarning("Invalid RATING tag '" . $attributes->{RATING} . "' in " . Slim::Utils::Misc::pathFromFileURL($url));
		$attributes->{RATING} = 0;
	}

	if (defined $attributes->{'TRACKNUM'}) {
		$attributes->{'TRACKNUM'} = Slim::Music::Info::cleanTrackNumber($attributes->{'TRACKNUM'});
	}

	# Munge the replaygain values a little
	processReplayGainTags($attributes, $url);

	# We can take an array too - from vorbis comments, so be sure to handle that.
	my $comments = [];
	my $rawcomments = [];

	if ($attributes->{'COMMENT'} && !ref($attributes->{'COMMENT'})) {

		$rawcomments = [ $attributes->{'COMMENT'} ];

	} elsif (ref($attributes->{'COMMENT'}) eq 'ARRAY') {

		$rawcomments = $attributes->{'COMMENT'};
	}

	# Bug: 2605 - Get URL out of the attributes - some programs, and
	# services such as www.allofmp3.com add it.
	if ($attributes->{'URL'}) {

		push @$rawcomments, delete $attributes->{'URL'};
	}

	# Look for tags we don't want to expose in comments, and splice them out.
	for my $c ( @{$rawcomments} ) {
		next unless defined $c;

		#ignore SoundJam and iTunes CDDB comments, iTunSMPB, iTunPGAP
		if ($c =~ /SoundJam_CDDB_/ ||
		    $c =~ /iTunes_CDDB_/ ||
		    $c =~ /^iTun[A-Z]{4}/ ||
		    $c =~ /^\s*[0-9A-Fa-f]{8}(\+|\s)/ ||
		    $c =~ /^\s*[0-9A-Fa-f]{2}\+[0-9A-Fa-f]{32}/) {

			next;
		}

		push @$comments, $c;
	}

	$attributes->{'COMMENT'} = $comments;

	# Bug: 4282 - we've seen multiple lyrics tags
	if ($attributes->{'LYRICS'} && ref($attributes->{'LYRICS'}) eq 'ARRAY') {

		$attributes->{'LYRICS'} = join("\n", @{$attributes->{'LYRICS'}});
	}

	# The ARTISTSORT and ALBUMARTISTSORT tags are normalized in Contributor->add()
	# since the tag may need to be split.  See bugs #295 and #4584.
	#
	# Push these back until we have a Track object.
	for my $tag (Slim::Schema::Contributor->contributorRoles, qw(
		COMMENT GENRE ARTISTSORT PIC APIC ALBUM ALBUMSORT DISCC
		COMPILATION REPLAYGAIN_ALBUM_PEAK REPLAYGAIN_ALBUM_GAIN
		MUSICBRAINZ_ARTIST_ID MUSICBRAINZ_ALBUMARTIST_ID MUSICBRAINZ_ALBUM_ID
		MUSICBRAINZ_ALBUM_TYPE MUSICBRAINZ_ALBUM_STATUS RELEASETYPE
		ALBUMARTISTSORT COMPOSERSORT CONDUCTORSORT BANDSORT ALBUM_EXTID ARTIST_EXTID WORK WORKSORT
	)) {

		next unless defined $attributes->{$tag};

		$deferredAttributes->{$tag} = delete $attributes->{$tag};
	}

	# If embedded artwork was found, store the length of the artwork
	if ( $attributes->{'COVER_LENGTH'} ) {
		$attributes->{'COVER'} = delete $attributes->{'COVER_LENGTH'};
	}

	# We also need these in _postCheckAttributes, but they should be set during create()
	$deferredAttributes->{'DISC'} = $attributes->{'DISC'} if $attributes->{'DISC'};

	# thumb has gone away, since we have GD resizing.
	delete $attributes->{'THUMB'};

	# RemoteTrack also wants artist and album names
	if ($attributes->{'REMOTE'}) {
		foreach (qw/TRACKARTIST ARTIST ALBUMARTIST/) {
			if (my $a = $deferredAttributes->{$_}) {
				$a = join (' / ', @$a) if ref $a eq 'ARRAY';
				$attributes->{'ARTISTNAME'} = $a;
				last;
			}
		}
		$attributes->{'ALBUMNAME'} = $deferredAttributes->{'ALBUM'} if $deferredAttributes->{'ALBUM'};

		# XXX maybe also want COMMENT & GENRE
	}

	# set Grouping attribute to null if it doesn't exist or trimmed length is zero, otherwise trim leading/trailing spaces:
	if ( !exists($attributes->{'GROUPING'}) || length($attributes->{'GROUPING'} =~ s/^\s+|\s+$//gr) == 0 ) {
		$attributes->{'GROUPING'} = undef;
	} else {
		$attributes->{'GROUPING'} =~ s/^\s+|\s+$//g;
	}

	if (main::DEBUGLOG && $log->is_debug) {

		$log->debug("Report for $url:");
		$log->debug("* Attributes *");

		while (my ($tag, $value) = each %{$attributes}) {

			# Artwork dump is unreadable in logs, so replace with a text tag.  More thorough artwork
			# debugging is available using artwork setting and this avoids pointless log bloat.
			$log->debug(".. $tag : ", ($tag eq 'ARTWORK' ? "[Binary Image Data]" : $value)) if defined $value;
		}

		$log->debug("* Deferred Attributes *");

		while (my ($tag, $value) = each %{$deferredAttributes}) {

			# Artwork dump is unreadable in logs, so replace with a text tag.  Mor thorough artwork
			# debugging is available using artwork setting and this avoids pointless log bloat.
			$log->debug(".. $tag : ", ($tag eq 'ARTWORK' ? "[Binary Image Data]" : $value)) if defined $value;
		}
	}

	return ($attributes, $deferredAttributes);
}

sub processReplayGainTags {
	my ($attributes, $url) = @_;

	# Munge the replaygain values a little
	for my $gainTag (qw(REPLAYGAIN_TRACK_GAIN REPLAYGAIN_TRACK_PEAK)) {

		my $shortTag = $gainTag;
		   $shortTag =~ s/^REPLAYGAIN_TRACK_(\w+)$/REPLAY_$1/;

		if (defined $attributes->{$gainTag}) {

			$attributes->{$shortTag} = delete $attributes->{$gainTag};
			$attributes->{$shortTag} =~ s/\s*dB//gi;
			$attributes->{$shortTag} =~ s/\s//g;  # bug 15965
			$attributes->{$shortTag} =~ s/,/\./g; # bug 6900, change comma to period

			# Bug 15483, remove non-numeric gain tags
			if ( $attributes->{$shortTag} !~ /^[\d\-\+\.]+$/ ) {
				my $file = Slim::Utils::Misc::pathFromFileURL($url);
				$log->error("Invalid ReplayGain tag found in $file: $gainTag -> " . $attributes->{$shortTag} );

				delete $attributes->{$shortTag};
			}
		}
	}
}

sub _createGenre {
	my ($self, $genre, $trackId, $create) = @_;

	# Genre addition. If there's no genre for this track, and no 'No Genre' object, create one.

	my $isDebug = main::DEBUGLOG && $log->is_debug;

	if ($genre) {
		# Bug 17322, strip leading/trailing spaces from name
		$genre =~ s/^ +//;
		$genre =~ s/ +$//;
	}

	if ($create && !$genre && !blessed($_unknownGenre)) {

		my $genreName = string('NO_GENRE');

		# Bug 3949 - Not sure how this can fail, but it can.
		$_unknownGenre = eval {
			$self->rs('Genre')->update_or_create({
				'name'       => $genreName,
				'namesort'   => Slim::Utils::Text::ignoreCaseArticles($genreName),
				'namesearch' => Slim::Utils::Text::ignoreCase($genreName, 1),
			}, { 'key' => 'namesearch' });
		};

		if ($@) {
			logError("Couldn't create genre: [$genreName]: [$@]");
		}

		if (blessed($_unknownGenre) && $_unknownGenre->can('name')) {

			Slim::Schema::Genre->add($_unknownGenre->name, $trackId);

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Created NO GENRE (id: [%d])", $_unknownGenre->id));
			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Track has no genre"));
		}

	} elsif ($create && !$genre && blessed($_unknownGenre)) {

		Slim::Schema::Genre->add($_unknownGenre->name, $trackId);

		main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Track has no genre"));

	} elsif ($create && $genre) {

		Slim::Schema::Genre->add($genre, $trackId);

		main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Track has genre '$genre'"));

	} elsif (!$create && $genre) {
		# get the list of genre names for this track
		my $sth = $self->dbh->prepare_cached( qq{
			SELECT genres.name FROM genre_track JOIN genres ON genres.id = genre_track.genre WHERE genre_track.track = ?
		} );
		$sth->execute($trackId);

		# compare the list of ordered, lower case genre names, new and old
		my $newGenres = join('::', sort map { lc($_->[0]) } @{ $sth->fetchall_arrayref() || [] });
		my $oldGenres = join('::', sort map { lc($_) } Slim::Music::Info::splitTag($genre));

		if ($newGenres ne $oldGenres) {
			# Bug 1143: The user has updated the genre tag, and is
			# rescanning We need to remove the previous associations.
			my $track = Slim::Schema->rs('Track')->find($trackId);
			$track->genreTracks->delete_all;

			Slim::Schema::Genre->add($genre, $trackId);

			main::DEBUGLOG && $isDebug && $log->debug("-- Deleted all previous genres for this track");
			main::DEBUGLOG && $isDebug && $log->debug("-- Track has genre '$genre'");
		}
	}
}

sub _postCheckAttributes {
	my $self = shift;
	my $args = shift;

	my $isDebug = main::DEBUGLOG && $log->is_debug;

	my $track      = $args->{'track'};
	my $attributes = $args->{'attributes'};
	my $create     = $args->{'create'} || 0;

	# Don't bother with directories / lnks. This makes sure "No Artist",
	# etc don't show up if you don't have any.
	my %cols = $track->get_columns;

	my ($trackId, $trackUrl, $trackType, $trackAudio, $trackRemote) =
		(@cols{qw/id url content_type audio remote/});

	if (!defined $trackType || $trackType eq 'dir' || $trackType eq 'lnk') {
		$track->update;
		return undef;
	}

	if (!$args->{integrateRemote} && ($trackRemote || !$trackAudio)) {
		$track->update;
		return;
	}

	# Make a local variable for COMPILATION, that is easier to handle
	my $isCompilation = undef;

	if (defined $attributes->{'COMPILATION'}) {
		# Use eq instead of == here, otherwise perl will warn.
		if ($attributes->{'COMPILATION'} =~ /^(?:yes|true)$/i || $attributes->{'COMPILATION'} eq 1) {
			$isCompilation = 1;
			main::DEBUGLOG && $isDebug && $log->debug("-- Track is a compilation");
		} elsif ($attributes->{'COMPILATION'} =~ /^(?:no|false)$/i || $attributes->{'COMPILATION'} eq 0) {
			$isCompilation = 0;
			main::DEBUGLOG && $isDebug && $log->debug("-- Track is NOT a compilation");
		}
	}

	$self->_createGenre($attributes->{'GENRE'}, $trackId, $create);

	# Walk through the valid contributor roles, adding them to the database.
	my $contributors = $self->_mergeAndCreateContributors($attributes, $isCompilation, $create);

	my $artist = $contributors->{'ALBUMARTIST'} || $contributors->{ARTIST} || $contributors->{TRACKARTIST};
	if ($artist) {
		$cols{primary_artist} = $artist->[0];
	}

	#Work
	if (defined $attributes->{'WORK'}) {
		my $workID = $self->_createWork($attributes->{'WORK'}, $attributes->{'WORKSORT'}, $contributors->{'COMPOSER'}->[0], 1);
		if ($workID) {
			$track->work($workID);
		}
	}

	### Update Album row
	my $albumId = $self->_createOrUpdateAlbum($attributes,
		\%cols,																	# trackColumns
		$isCompilation,
		$artist->[0],	                                          # primary contributor-id
		defined $contributors->{'ALBUMARTIST'}->[0] ? 1 : 0,					# hasAlbumArtist
		$create,																# create
		$track,																	# Track
	);

	# Don't add an album to container tracks - See bug 2337
	if (!Slim::Music::Info::isContainer($track, $trackType)) {
		$track->album($albumId);
	}

	$self->_createContributorRoleRelationships($contributors, $trackId, $albumId);

	# Save any changes - such as album.
	$track->update;

	$self->_createComments($attributes->{'COMMENT'}, $trackId);

	# refcount--
	%{$contributors} = ();
}

sub _mergeAndCreateContributors {
	my ($self, $attributes, $isCompilation, $create) = @_;

	my $isDebug = main::DEBUGLOG && $log->is_debug;

	# Bug: 2317 & 2638
	#
	# Bring back the TRACKARTIST role.
	#
	# If the user has not explictly set a compilation flag, _and_ the user
	# has explict album artist(s) set, make the artist(s) tags become
	# TRACKARTIST contributors for this track.
	if (!$isCompilation) {

		if ($attributes->{'ARTIST'} && $attributes->{'ALBUMARTIST'}) {

			$attributes->{'TRACKARTIST'} = delete $attributes->{'ARTIST'};
			# Bug: 6507 - use any ARTISTSORT tag for this contributor
			$attributes->{'TRACKARTISTSORT'} = delete $attributes->{'ARTISTSORT'};

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Contributor '%s' of role 'ARTIST' transformed to role 'TRACKARTIST'",
				$attributes->{'TRACKARTIST'},
			));
		}
	}

	my %contributors = ();

	for my $tag (Slim::Schema::Contributor->contributorRoles) {

		my $contributor = $attributes->{$tag} || next;

		# Bug 17322, strip leading/trailing spaces from name
		$contributor =~ s/^ +//;
		$contributor =~ s/ +$//;

		# Is ARTISTSORT/TSOP always right for non-artist
		# contributors? I think so. ID3 doesn't have
		# "BANDSORT" or similar at any rate.
		push @{ $contributors{$tag} }, Slim::Schema::Contributor->add({
			'artist'   => $contributor,
			'brainzID' => $attributes->{"MUSICBRAINZ_${tag}_ID"},
			'sortBy'   => $attributes->{$tag.'SORT'},
			# only store EXTID for track artist, as we don't have it for other roles
			'extid'    => $tag eq 'ARTIST' && $attributes->{'ARTIST_EXTID'},
		});

		main::DEBUGLOG && $isDebug && $log->is_debug && $log->debug(sprintf("-- Track has contributor '$contributor' of role '$tag'"));
	}

	# Bug 15553, Primary contributor can only be Album Artist or Artist,
	# so only check for those roles and assign No Artist otherwise
	my $foundContributor = ($contributors{'ALBUMARTIST'} && $contributors{'ALBUMARTIST'}->[0]
							|| $contributors{'ARTIST'} && $contributors{'ARTIST'}->[0]);

	main::DEBUGLOG && $isDebug && $log->debug("-- Track has ", scalar (keys %contributors), " contributor(s)");

	# Create a singleton for "No Artist"
	if ($create && !$foundContributor) {

		if (!$_unknownArtist) {
			my $name        = string('NO_ARTIST');
			$_unknownArtist = $self->rs('Contributor')->update_or_create({
				'name'       => $name,
				'namesort'   => Slim::Utils::Text::ignoreCaseArticles($name),
				'namesearch' => Slim::Utils::Text::ignoreCase($name, 1),
			}, { 'key' => 'namesearch' });

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Created NO ARTIST (id: [%d])", $_unknownArtist->id));
		}

		Slim::Schema::Contributor->add({
			'artist' => $_unknownArtist->name,
		});

		push @{ $contributors{'ARTIST'} }, $_unknownArtist->id;

		main::DEBUGLOG && $isDebug && $log->debug("-- Track has no artist");
	}

	return \%contributors;
}

sub _createContributorRoleRelationships {

	my ($self, $contributors, $trackId, $albumId) = @_;

	if (!keys %$contributors) {
		main::DEBUGLOG && $log->debug('Attempt to set empty contributor set for trackid=', $trackId);
		return;
	}

	# Wipe track contributors for this track, this is necessary to handle
	# a changed track where contributors have been removed.  Current contributors
	# will be re-added by below
	my $sth_delete_tracks = $self->dbh->prepare_cached( qq{
		DELETE
		FROM contributor_track
		WHERE track = ?
	} );
	$sth_delete_tracks->execute($trackId);

	# Using native DBI here to improve performance during scanning
	if ( my $artist = $contributors->{ARTIST} || $contributors->{TRACKARTIST} ) {
		my $sth_track_artist = $self->dbh->prepare_cached( qq(
			UPDATE tracks
			SET primary_artist = ?
			WHERE id = ?
		) );
		$sth_track_artist->execute( $artist->[0], $trackId );
	}

	my $sth_track = $self->dbh->prepare_cached( qq{
		REPLACE INTO contributor_track
		(role, contributor, track)
		VALUES
		(?, ?, ?)
	} );

	my $sth_album = $self->dbh->prepare_cached( qq{
		REPLACE INTO contributor_album
		(role, contributor, album)
		VALUES
		(?, ?, ?)
	} );

	while (my ($role, $contributorList) = each %{$contributors}) {
		my $roleId = Slim::Schema::Contributor->typeToRole($role);
		for my $contributor (@{$contributorList}) {
			$sth_track->execute( $roleId, $contributor, $trackId );

			# Bug 4882 - Don't remove contributor <-> album mappings here as its impossible to remove only stale ones
			# Instead recreate this table post scan in the sql optimise script so we can base it on all tracks in an album

			# The following is retained at present to add mappings for BMF, entries created will be deleted in the optimise phase
			$sth_album->execute( $roleId, $contributor, $albumId );
		}
	}
}

my %lastTrackOrUrl = (
	obj => ''
);

sub _validTrackOrURL {
	my $urlOrObj = shift;

	if ($lastTrackOrUrl{obj} eq $urlOrObj) {
		return ($lastTrackOrUrl{track}, $lastTrackOrUrl{url}, $lastTrackOrUrl{blessed});
	}

	my $track   = undef;
	my $url     = undef;
	my $blessed = blessed($urlOrObj);

	if (isaTrack($urlOrObj)) {

		$track = $urlOrObj;
		$url   = $track->url;

	}
	elsif ( $urlOrObj && !$blessed ) {

		if ( $urlOrObj =~ /^(file|http)/i ) {
			$url = URI->new($urlOrObj)->canonical->as_string;
		}
		else {
			$url = $urlOrObj;
		}
	}

	%lastTrackOrUrl = (
		obj => $urlOrObj,
		track => $track,
		url => $url,
		blessed => $blessed
	) unless ref $urlOrObj;

	return ($track, $url, $blessed);
}

sub isaTrack {
	my $obj = shift;

	return $obj && blessed $obj && ($obj->isa('Slim::Schema::Track') || $obj->isa('Slim::Schema::RemoteTrack'));
}

sub clearLastError {
	$LAST_ERROR = 'Unknown Error';
}

sub lastError { $LAST_ERROR }

sub totals {
	my ($class, $client) = @_;

	my $library_id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);

	$TOTAL_CACHE->{$library_id} ||= {};
	my $totalCache = $TOTAL_CACHE->{$library_id};

	my %categories = (
		album => ['albums', 0, 1, 'tags:CC'],
		contributor => ['artists', 0, 1, 'tags:CC'],
		genre => ['genres', 0, 1, 'tags:CC'],
		track => ['titles', 0, 1, 'tags:CC'],
		playlist => ['playlists', 0, 1, 'tags:CC'],
	);

	while (my ($key, $query) = each %categories) {
		if ( !$totalCache->{$key} ) {
			push @$query, 'library_id:' . $library_id if $library_id;
			my $request = Slim::Control::Request::executeRequest($client, $query);
			$totalCache->{$key} = $request->getResult('count');

			main::idleStreams();
		}
	}

	return $totalCache;
}

sub _insertHash {
	my ( $class, $table, $hash ) = @_;

	my $dbh = $class->dbh;

	my @cols      = keys %{$hash};
	my $colstring = join( ',', @cols );
	my $ph        = join( ',', map { '?' } @cols );

	my $sth = $dbh->prepare_cached("INSERT INTO $table ($colstring) VALUES ($ph)");
	$sth->execute( map { $hash->{$_} } @cols );

	return $dbh->last_insert_id(undef, undef, undef, undef);
}

sub _updateHash {
	my ( $class, $table, $hash, $pk ) = @_;

	my $id = delete $hash->{$pk};

	# Construct SQL with placeholders for non-null values and NULL for null values
	my @cols      = keys %{$hash};
	my $colstring = join( ', ', map { $_ . (defined $hash->{$_} ? ' = ?' : ' = NULL') } @cols );

	my $sth = $class->dbh->prepare_cached("UPDATE $table SET $colstring WHERE $pk = ?");
	$sth->execute( (grep { defined $_ } map { $hash->{$_} } @cols), $id );

	$hash->{$pk} = $id;

	return 1;
}

my $canFulltextSearch;
sub canFulltextSearch {
	return $canFulltextSearch if defined $canFulltextSearch;

	$canFulltextSearch = Slim::Utils::PluginManager->isEnabled('Slim::Plugin::FullTextSearch::Plugin') && Slim::Plugin::FullTextSearch::Plugin->canFulltextSearch;
	return $canFulltextSearch;
}

=head1 SEE ALSO

L<DBIx::Class>

L<DBIx::Class::Schema>

L<DBIx::Class::ResultSet>,

L<Slim::Schema::Track>

L<Slim::Schema::Playlist>

L<Slim::Music::Info>

L<DBIx::Migration>

=cut

1;

__END__
