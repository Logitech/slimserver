package Slim::Schema::Track;


use strict;
use base 'Slim::Schema::DBI';

use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(blessed);
use Tie::Cache::LRU::Expires;

use Slim::Schema::ResultSet::Track;

use Slim::Music::Artwork;
use Slim::Music::Info;
use Slim::Utils::DateTime;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $prefs = preferences('server');
my $log = logger('database.info');

# rendering the playlist will call displayAsHTML repeatedly, often requesting the same artists and albums over and over again
# keep a small cache of contributor objects for a short period of time, while we're looping the playlist items
tie my %albumCache, 'Tie::Cache::LRU::Expires', EXPIRES => 5, ENTRIES => 15;

our @allColumns = (qw(
	id urlmd5 url content_type title titlesort titlesearch album primary_artist tracknum
	timestamp added_time updated_time filesize disc remote audio audio_size audio_offset year secs
	cover cover_cached vbr_scale bitrate samplerate samplesize channels block_alignment endian
	bpm tagversion drm musicmagic_mixable dlna_profile
	musicbrainz_id lossless lyrics replay_gain replay_peak extid virtual work subtitle grouping
));

{
	my $class = __PACKAGE__;

	$class->table('tracks');

	$class->add_columns(
		@allColumns,
		coverid => { accessor => '_coverid' }, # use a wrapper method for coverid
	);

	$class->set_primary_key('id');

	# setup our relationships
	$class->belongs_to('album' => 'Slim::Schema::Album');
	$class->belongs_to('primary_artist'  => 'Slim::Schema::Contributor');
	$class->belongs_to('work' => 'Slim::Schema::Work');

	$class->has_many('genreTracks'       => 'Slim::Schema::GenreTrack' => 'track');
	$class->has_many('comments'          => 'Slim::Schema::Comment'    => 'track');

	$class->has_many('contributorTracks' => 'Slim::Schema::ContributorTrack');
	$class->has_many('libraryTracks'     => 'Slim::Schema::LibraryTrack');

	if ($] > 5.007) {
		$class->utf8_columns(qw/title titlesort lyrics/);
	}

	$class->resultset_class('Slim::Schema::ResultSet::Track');

	if (main::STATISTICS) {
		$class->might_have(
			persistent => 'Slim::Schema::TrackPersistent',
			{ 'foreign.urlmd5' => 'self.urlmd5' },
			{ cascade_delete => 0 },
		);
	}

	# Simple caching as artistsWithAttributes is expensive.
	$class->mk_group_accessors('simple' => 'cachedArtistsWithAttributes');
}

# Wrappers - to make sure that the UTF-8 code is called. I really just want to
# rename these in the database.
sub name {
	return shift->title;
}

sub namesort {
	return shift->titlesort;
}

sub namesearch {
	return shift->titlesearch;
}

sub work {
	return shift->work;
}

sub contributors {
	my $self = shift;

	return $self->contributorTracks->search_related(
		'contributor', undef, { distinct => 1 }
	)->search(@_);
}

sub genres {
	my $self = shift;

	return $self->genreTracks->search_related('genre', @_);
}

sub attributes {
	my $class = shift;

	# Return a hash ref of column names
	return { map { $_ => 1 } @allColumns };
}

sub albumid {
	my $self = shift;

	return $self->get_column('album');
}

sub albumname {
	my $self = shift;

	my $names = Slim::Schema->dbh->selectall_arrayref('SELECT title FROM albums WHERE id = ?', {}, $self->albumid);

	if (ref $names && scalar ref $names) {
		utf8::decode($names->[0][0]);
		return $names->[0][0];
	}
}

# Partly, this is a placehold for a later, more-efficient caching implementation
sub artistName {
	my $self = shift;

	my $names = Slim::Schema->dbh->selectall_arrayref('SELECT name FROM contributors WHERE id = ?', {}, scalar $self->artistid);

	if (ref $names && scalar ref $names) {
		utf8::decode($names->[0][0]);
		return $names->[0][0];
	}
}

sub _artistid {
	my $self = shift;

	my $id = undef;

	if (defined ($id = $self->get_column('primary_artist'))) {
		main::DEBUGLOG && $log->debug("Using cached primary artist");
		return wantarray ? ($id, $self->primary_artist) : $id;
	}

	# XXX primary_artist is now set during scan, the below code should be removed

	# Bug 3824 - check for both types, in the case that an ALBUMARTIST was set.
	my $artist = $self->contributorsOfType('ARTIST')->single ||
				 $self->contributorsOfType('TRACKARTIST')->single;

	if ($artist) {
		$self->set_column('primary_artist', $id = $artist->id);
		$self->update;
		main::DEBUGLOG && $log->debug("Track ", $self->id, " caching primary artist $id -> ", $artist->name);
	}

	return wantarray ? ($id, $artist) : $id;
}

sub artistid {
	my $artistid = shift->_artistid();

	return $artistid;
}

sub artist {
	my $self = shift;

	my ($id, $artist) = $self->_artistid;

	return $artist;
}

sub artists {
	my $self = shift;

	# Bug 4024 - include both ARTIST & TRACKARTIST here.
	return $self->contributorsOfType(qw(ARTIST TRACKARTIST))->all;
}

sub artistsWithAttributes {
	my $self = shift;

	if ($self->cachedArtistsWithAttributes) {
		return $self->cachedArtistsWithAttributes;
	}

	my @objs = ();

	for my $type (qw(ARTIST TRACKARTIST)) {

		for my $contributor ($self->contributorsOfType($type)->all) {

			push @objs, {
#				'artist'     => $contributor,
				'artistId'   => $contributor->id,
				'name'       => $contributor->name,
				'attributes' => join('&',
					join('=', 'contributor.id', $contributor->id),
					join('=', 'contributor.role', $type),
				),
			};
		}
	}

	$self->cachedArtistsWithAttributes(\@objs);

	return \@objs;
}

sub composer {
	my $self = shift;

	return $self->contributorsOfType('COMPOSER')->all;
}

sub conductor {
	my $self = shift;

	return $self->contributorsOfType('CONDUCTOR')->all;
}

sub band {
	my $self = shift;

	return $self->contributorsOfType('BAND')->all;
}

sub genre {
	my $self = shift;

	return $self->genres->first;
}

sub genrename {
	my $self = shift;

	my $names = Slim::Schema->dbh->selectall_arrayref(q{
		SELECT genres.name
		FROM genre_track
			JOIN genres ON genres.id = genre_track.genre
		WHERE track = ?
		ORDER BY genre_track.genre
		LIMIT 1
	}, {}, $self->id);

	if (ref $names && scalar ref $names) {
		utf8::decode($names->[0][0]);
		return $names->[0][0];
	}
}

sub genreid {
	my $self = shift;

	my $ids = Slim::Schema->dbh->selectall_arrayref(q{
		SELECT genre
		FROM genre_track
		WHERE track = ?
		ORDER BY genre
		LIMIT 1
	}, {}, $self->id);

	if (ref $ids && scalar ref $ids) {
		return $ids->[0][0];
	}
}

sub comment {
	my $self = shift;

	my $comment;

	# extract multiple comments and concatenate them
	for my $c (map { $_->value } $self->comments) {

		next unless $c;

		# join multiple comments into a single multi-line comment
		# consistent with Slim::Schema::RemoteTrack::comment
		$comment .= "\n" if $comment;
		$comment .= $c;
	}

	return $comment;
}

sub duration {
	my $self = shift;

	my $secs = $self->secs;

	return sprintf('%s:%02s', int($secs / 60), $secs % 60) if defined $secs;
}

sub modificationTime {
	my $self = shift;

	return $self->buildModificationTime( $self->timestamp );
}

sub addedTime {
	my $self = shift;

	return $self->buildModificationTime( $self->added_time );
}

sub lastUpdated {
	my $self = shift;

	return $self->buildModificationTime( $self->updated_time );
}

sub buildModificationTime {
	my ( $self, $time ) = @_;

	return join(', ', Slim::Utils::DateTime::longDateF($time), Slim::Utils::DateTime::timeF($time));
}

sub prettyBitRate {
	my $self = shift;
	my $only = shift;

	my $bitrate  = $self->bitrate;
	my $vbrScale = $self->vbr_scale;

	return $self->buildPrettyBitRate($bitrate, $vbrScale);
}

sub buildPrettyBitRate {
	my ( $self, $bitrate, $vbrScale ) = @_;

	my $mode = defined $vbrScale ? 'VBR' : 'CBR';

	if ($bitrate) {
		return sprintf( "%d", ($bitrate / 1000) ) . Slim::Utils::Strings::string('KBPS') . ' ' . $mode;
	}

	return 0;
}

# Wrappers around common functions
sub isRemoteURL {
	my $self = shift;

	return Slim::Music::Info::isRemoteURL($self->url);
}

sub isPlaylist {
	my $self = shift;

	return Slim::Music::Info::isPlaylist($self->url);
}

sub isCUE {
	my $self = shift;

	return Slim::Music::Info::isCUE($self);
}

sub isContainer {
	my $self = shift;

	return Slim::Music::Info::isContainer($self);
}

# we cache whether we had success reading the cover art.
sub coverArt {
	my $self    = shift;
	my $list    = shift || 0;

	my ($body, $contentType, $mtime, $path);

	my $cover = $self->cover;

	return undef if defined $cover && !$cover;

	# Remote files may have embedded cover art
	if ( $cover && $self->remote ) {
		my $cache = Slim::Utils::Cache->new();
		my $image = $cache->get( 'cover_' . $self->url );
		if ( $image ) {
			$body        = $image->{image};
			$contentType = $image->{type};
			$mtime       = time();
		}

		if ( !$list && wantarray ) {
			return ( $body, $contentType, time() );
		}
		else {
			return $body;
		}
	}

	# return with nothing if this isn't a file.
	# We don't need to search on streams, for example.
	if (!$self->audio) {
		return undef;
	}

	# Don't pass along anchors - they mess up the content-type.
	# See Bug: 2219
	my $url = Slim::Utils::Misc::stripAnchorFromURL($self->url);
	my $log = logger('artwork');

	main::INFOLOG && $log->info("Retrieving artwork for: $url");

	# A numeric cover value indicates the cover art is embedded in the file's
	# metdata tags.
	#
	# Otherwise we'll have a path to a file on disk.

	if ($cover && $cover !~ /^\d+$/) {

		($body, $contentType) = Slim::Music::Artwork->getImageContentAndType($cover);

		if ($body && $contentType) {

			main::INFOLOG && $log->info("Found cached file: $cover");

			$path = $cover;
		}
	}

	# If we didn't already store an artwork value - look harder.
	if (!$cover || $cover =~ /^\d+$/ || !$body) {

		# readCoverArt calls into the Format classes, which can throw an error.
		($body, $contentType, $path) = eval { Slim::Music::Artwork->readCoverArt($self) };

		if ($@) {
			$log->error("Error: Exception when trying to call readCoverArt() for [$url] : [$@]");
		}
	}

	if (defined $path) {
		if ( $self->cover ne $path ) {
			$self->cover($path);
			$self->update;
		}

		# kick this back up to the webserver so we can set last-modified
		$mtime = $path !~ /^\d+$/ ? (stat($path))[9] : (stat($self->path))[9];
	}

	else {
		$self->cover(0);	# means known not to have artwork, don't ask again
		$self->update;
	}

	# This is a hack, as Template::Stash::XS calls us in list context,
	# even though it should be in scalar context.
	if (!$list && wantarray) {
		return ($body, $contentType, $mtime);
	} else {
		return $body;
	}
}

sub coverArtMtime {
	my $self = shift;

	my $artwork = $self->cover;

	if ($artwork && -r $artwork) {
		return (stat(_))[9];
	}

	return -1;
}

sub coverArtExists {
	my $self = shift;

	return defined($self->cover) ? 1 : defined($self->coverArt);
}

sub path {
	my $self = shift;

	my $url  = $self->url;

	# Turn playlist special files back into file urls
	$url =~ s/^playlist:/file:/;

	if (Slim::Music::Info::isFileURL($url)) {

		return Slim::Utils::Misc::pathFromFileURL($url);
	}

	return $url;
}

sub contributorsOfType {
	my ($self, @types) = @_;

	my @roles = map { Slim::Schema::Contributor->typeToRole($_) } @types;

	return $self
		->search_related('contributorTracks', { 'role' => { 'in' => \@roles } }, { 'order_by' => 'role desc' })
		->search_related('contributor')->distinct;
}

sub contributorRoles {
	my $self = shift;

	return Slim::Schema::Contributor->contributorRoles;
}

sub displayAsHTML {
	my ($self, $form, $descend, $sort) = @_;

	my $format = Slim::Music::Info::standardTitleFormat();

	# Go directly to infoFormat, as standardTitle is more client oriented.
	$form->{'text'}     = Slim::Music::TitleFormatter::infoFormat($self, $format, 'TITLE', $form->{'plugin_meta'});
	$form->{'item'}     = $self->id;
	$form->{'itemobj'}  = $self;
	$form->{'coverid'}  = $self->coverid;

	# Only include Artist & Album if the user doesn't have them defined in a custom title format.
	if ($format !~ /ARTIST/) {

		my $contributor_sth = Slim::Schema->dbh->prepare_cached(sprintf(qq(
			SELECT DISTINCT(contributor_track.contributor), contributors.name
			FROM contributor_track, contributors
			WHERE contributor_track.track = ? AND contributor_track.role IN (%s,%s) AND contributors.id = contributor_track.contributor
		), map { Slim::Schema::Contributor->typeToRole($_) } qw(ARTIST TRACKARTIST)) );

		my ($contributorId, $contributorName);
		$contributor_sth->execute($form->{'item'});
		$contributor_sth->bind_col( 1, \$contributorId );
		$contributor_sth->bind_col( 2, \$contributorName );

		my @info;

		while ($contributor_sth->fetch) {

			utf8::decode($contributorName);

			push @info, {
				'artistId'   => $contributorId,
				'name'       => $contributorName,
				'attributes' => 'contributor.id=' . $contributorId,
			};
		}

		if (scalar @info) {
			$form->{'includeArtist'} = 1;
			$form->{'artistsWithAttributes'} = \@info;
		}

		if (!$form->{'includeArtist'} && $form->{'plugin_meta'} && $form->{'plugin_meta'}->{'artist'}) {
			$form->{'includeArtist'} = 1;
		}
	}

	if ($format !~ /ALBUM/) {
		$form->{'includeAlbum'}  = 1;

		my $albumId = $self->albumid;
		my $albumDetails = $albumCache{$albumId};

		if ( !$albumDetails ) {
			my $sth = Slim::Schema->dbh->prepare_cached("SELECT title, artwork FROM albums WHERE id = ?");

			$sth->execute($albumId);
			$albumDetails = $sth->fetchrow_hashref || {};
			$sth->finish;

			utf8::decode($albumDetails->{title});

			$albumCache{$albumId} = $albumDetails;
		}

		$form->{'albumId'} = $albumId;
		$form->{'albumTitle'} = $albumDetails->{title};
		$form->{'artwork_track_id'} = $albumDetails->{artwork};
	}

	$form->{'noArtist'} = Slim::Utils::Strings::string('NO_ARTIST');
	$form->{'noAlbum'}  = Slim::Utils::Strings::string('NO_ALBUM');
}

sub retrievePersistent {
	my $self = shift;

	if (main::STATISTICS) {
		my $trackPersistent;

		# Match on musicbrainz_id first
		if ( $self->musicbrainz_id ) {
			$trackPersistent = Slim::Schema->first('TrackPersistent', { musicbrainz_id => $self->musicbrainz_id } );
		}
		elsif ($self->urlmd5) {
			$trackPersistent = Slim::Schema->first('TrackPersistent', { urlmd5 => $self->urlmd5 } );
		}

		if ( blessed($trackPersistent) ) {
			return $trackPersistent;
		}
	}

	return undef;
}

# The methods below are stored in the persistent table

sub playcount {
	my ( $self, $val ) = @_;

	if (main::STATISTICS) {
		if ( my $persistent = $self->retrievePersistent ) {
			if ( defined $val ) {
				$persistent->set( playcount => $val );
				$persistent->update;
			}

			return $persistent->playcount;
		}
	}

	return;
}

sub rating {
	my ( $self, $val ) = @_;

	if (main::STATISTICS) {
		if ( my $persistent = $self->retrievePersistent ) {
			if ( defined $val ) {
				$persistent->set( rating => $val );
				$persistent->update;
			}

			return $persistent->rating;
		}
	}

	return;
}

sub lastplayed {
	my ( $self, $val ) = @_;

	if (main::STATISTICS) {
		if ( my $persistent = $self->retrievePersistent ) {
			if ( defined $val ) {
				$persistent->set( lastplayed => $val );
				$persistent->update;
			}

			return $persistent->lastplayed;
		}
	}

	return;
}

#
# New DB field, coverid, stores truncated md5(url, mtime, size)
#  mtime/size are either from cover.jpg or the audio file with embedded art
#
# Cache headers can be set to never expire with this new scheme
#
# Old-style URLs will still be supported but are discouraged:
# /music/<track id>/cover_<dimensions/mode/extension>
# This will require a database lookup, and should spit out deprecated warnings
#
sub coverid {
	my $self = shift;

	my $val = $self->_coverid(@_);

	# Don't initialize on any update, even $track->coverid(undef)
	return $val if @_;

	if ( !defined $val ) {
		# Initialize coverid value
		if ( $self->cover ) {
			$val = $self->generateCoverId( {
				cover => $self->cover,
				url   => $self->url,
				mtime => $self->timestamp,
				size  => $self->filesize,
			} );

			$self->_coverid($val);
			$self->update;
		}
	}

	return $val;
}

sub coverurl {
	my $self = shift;

	my $cover = $self->cover;
	return $cover if $cover && $cover =~ /^https?:/;
}

# Cover ID can be generated without a Track object, so this is a class method
sub generateCoverId {
	my ( $classOrSelf, $args ) = @_;

	my $coverid;
 	my $mtime;
	my $size;

	if ( $args->{cover} =~ /^https?/ ) {
		$mtime = $size = 1;
	}
	elsif ( $args->{cover} =~ /^\d+$/ ) {
		# Cache is based on mtime/size of the file containing embedded art
		$mtime = $args->{mtime};
		$size  = $args->{size};
	}
	elsif ( -e $args->{cover} ) {
		# Cache is based on mtime/size of artwork file
		($size, $mtime) = (stat _)[7, 9];
	}

	if ( $mtime && $size ) {
		$coverid = substr( md5_hex( $args->{url} . $mtime . $size ), 0, 8 );
	}

	return $coverid;
}

1;
