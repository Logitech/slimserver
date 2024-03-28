package Slim::Control::Queries;

# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

################################################################################

=head1 NAME

Slim::Control::Queries

=head1 DESCRIPTION

L<Slim::Control::Queries> implements most Lyrion Music Server queries and is designed to
 be exclusively called through Request.pm and the mechanisms it defines.

 Except for subscribe-able queries (such as status and serverstatus), there are no
 important differences between the code for a query and one for
 a command. Please check the commented command in Commands.pm.

=cut

use strict;

use File::Basename qw(basename);
use Storable;
use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);
use List::Util qw(first);
use MIME::Base64 qw(encode_base64 decode_base64);
use Scalar::Util qw(blessed);
use URI::Escape;
use Tie::Cache::LRU::Expires;

use Slim::Music::VirtualLibraries;
use Slim::Utils::Misc qw( specified );
use Slim::Utils::Alarm;
use Slim::Utils::Log;
use Slim::Utils::Unicode;
use Slim::Utils::Prefs;
use Slim::Utils::Text;
use Slim::Web::ImageProxy qw(proxiedImage);

{
	if (main::ISWINDOWS) {
		require Slim::Utils::OS::Win32;
	}
}

my $log = logger('control.queries');

my $prefs = preferences('server');

# Frequently used data can be cached in memory, such as the list of albums for Jive
my $cache = {};

# small, short lived cache of folder entries to prevent repeated disk reads on BMF
tie my %bmfCache, 'Tie::Cache::LRU::Expires', EXPIRES => 60, ENTRIES => $prefs->get('dbhighmem') ? 1024 : 5;

sub init {
	my $class = shift;

	# Wipe cached data after rescan
	if ( !main::SCANNER ) {
		Slim::Control::Request::subscribe( sub {
			$class->wipeCaches;
		}, [['rescan'], ['done']] );
	}
}

sub alarmPlaylistsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['alarm'], ['playlists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $menuMode = $request->getParam('menu') || 0;
	my $id       = $request->getParam('id');

	my $playlists      = Slim::Utils::Alarm->getPlaylists($client);
	my $alarm          = Slim::Utils::Alarm->getAlarm($client, $id) if $id;
	my $currentSetting = $alarm ? $alarm->playlist() : '';

	my @playlistChoices;
	my $loopname = 'item_loop';
	my $cnt = 0;

	my ($valid, $start, $end) = ( $menuMode ? (1, 0, scalar @$playlists) : $request->normalize(scalar($index), scalar($quantity), scalar @$playlists) );

	for my $typeRef (@$playlists[$start..$end]) {

		my $type    = $typeRef->{type};
		my @choices = ();
		my $aref    = $typeRef->{items};

		for my $choice (@$aref) {

			if ($menuMode) {
				my $radio = (
					( $currentSetting && $currentSetting eq $choice->{url} )
					|| ( !defined $choice->{url} && !defined $currentSetting )
				);

				my $subitem = {
					text    => $choice->{title},
					radio   => $radio + 0,
					nextWindow => 'refreshOrigin',
					actions => {
						do => {
							cmd    => [ 'alarm', 'update' ],
							params => {
								id          => $id,
								playlisturl => $choice->{url} || 0, # send 0 for "current playlist"
							},
						},
						preview => {
							title   => $choice->{title},
							cmd	=> [ 'playlist', 'preview' ],
							params  => {
								url	=>	$choice->{url},
								title	=>	$choice->{title},
							},
						},
					},
				};
				if ( ! $choice->{url} ) {
					$subitem->{actions}->{preview} = {
						cmd => [ 'play' ],
					};
				}


				if ($typeRef->{singleItem}) {
					$subitem->{'nextWindow'} = 'refresh';
				}

				push @choices, $subitem;
			}

			else {
				$request->addResultLoop($loopname, $cnt, 'category', $type);
				$request->addResultLoop($loopname, $cnt, 'title', $choice->{title});
				$request->addResultLoop($loopname, $cnt, 'url', $choice->{url});
				$request->addResultLoop($loopname, $cnt, 'singleton', $typeRef->{singleItem} ? '1' : '0');
				$cnt++;
			}
		}

		if ( scalar(@choices) ) {

			my $item = {
				text      => $type,
				offset    => 0,
				count     => scalar(@choices),
				item_loop => \@choices,
			};
			$request->setResultLoopHash($loopname, $cnt, $item);

			$cnt++;
		}
	}

	$request->addResult("offset", $start);
	$request->addResult("count", $cnt);
	$request->addResult('window', { textareaToken => 'SLIMBROWSER_ALARM_SOUND_HELP' } );
	$request->setStatusDone;
}

sub alarmsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['alarms']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $filter	 = $request->getParam('filter');
	my $alarmDOW = $request->getParam('dow');

	# being nice: we'll still be accepting 'defined' though this doesn't make sense any longer
	if ($request->paramNotOneOfIfDefined($filter, ['all', 'defined', 'enabled'])) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('fade', $prefs->client($client)->get('alarmfadeseconds'));

	$filter = 'enabled' if !defined $filter;

	my @alarms = grep {
		defined $alarmDOW
			? $_->day() == $alarmDOW
			: ($filter eq 'all' || ($filter eq 'enabled' && $_->enabled()))
	} Slim::Utils::Alarm->getAlarms($client, 1);

	my $count = scalar @alarms;
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'alarms_loop';
		my $cnt = 0;

		for my $alarm (@alarms[$start..$end]) {

			my @dow;
			foreach (0..6) {
				push @dow, $_ if $alarm->day($_);
			}

			$request->addResultLoop($loopname, $cnt, 'id', $alarm->id());
			$request->addResultLoop($loopname, $cnt, 'dow', join(',', @dow));
			$request->addResultLoop($loopname, $cnt, 'enabled', $alarm->enabled());
			$request->addResultLoop($loopname, $cnt, 'repeat', $alarm->repeat());
			$request->addResultLoop($loopname, $cnt, 'time', $alarm->time());
			$request->addResultLoop($loopname, $cnt, 'volume', $alarm->volume());
			$request->addResultLoop($loopname, $cnt, 'url', $alarm->playlist() || 'CURRENT_PLAYLIST');
			$cnt++;
		}
	}

	$request->setStatusDone();
}

sub albumsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['albums']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}

	my $sqllog = main::DEBUGLOG && logger('database.sql');

	# get our parameters
	my $client        = $request->client();
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tags          = $request->getParam('tags') || 'l';
	my $search        = $request->getParam('search');
	my $compilation   = $request->getParam('compilation');
	my $contributorID = $request->getParam('artist_id');
	my $genreID       = $request->getParam('genre_id');
	my $trackID       = $request->getParam('track_id');
	my $albumID       = $request->getParam('album_id');
	my $roleID        = $request->getParam('role_id');
	my $releaseType   = $request->getParam('release_type');
	my $libraryID     = Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id'));
	my $year          = $request->getParam('year');
	my $sort          = $request->getParam('sort') || ($roleID ? 'artistalbum' : 'album');
	my $work	  = $request->getParam('work_id');
	my $composerID    = $request->getParam('composer_id');
	my $fromSearch    = $request->getParam('from_search');

	my $ignoreNewAlbumsCache = $search || $compilation || $contributorID || $genreID || $trackID || $albumID || $year || Slim::Music::Import->stillScanning();

	# FIXME: missing genrealbum, genreartistalbum
	if ($request->paramNotOneOfIfDefined($sort, ['new', 'album', 'artflow', 'artistalbum', 'yearalbum', 'yearartistalbum', 'random' ])) {
		$request->setStatusBadParams();
		return;
	}

	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();

	my $sql      = 'SELECT %s FROM albums ';
	my $c        = { 'albums.id' => 1, 'albums.titlesearch' => 1, 'albums.titlesort' => 1 };
	my $w        = [];
	my $p        = [];
	my $order_by = "albums.titlesort $collate, albums.disc"; # XXX old code prepended 0 to titlesort, but not other titlesorts
	my $limit;
	my $page_key = "SUBSTR(albums.titlesort,1,1)";
	my $newAlbumsCacheKey = 'newAlbumIds' . Slim::Music::Import->lastScanTime . ($libraryID || Slim::Music::VirtualLibraries->getLibraryIdForClient($client));

	# Normalize and add any search parameters
	if ( defined $trackID ) {
		$sql .= 'JOIN tracks ON tracks.album = albums.id ';
		push @{$w}, 'tracks.id = ?';
		push @{$p}, $trackID;
	}
	# ignore everything if a single $album_id was specified
	elsif ( defined $albumID && $albumID !~ /,/ ) {
		push @{$w}, 'albums.id = ?';
		push @{$p}, $albumID;
	}
	else {
		if ( defined $albumID ) {
			my @albumIds = split(',', $albumID);
			push @{$w}, 'albums.id IN (' . join(',', map {'?'} @albumIds) . ')';
			push @{$p}, @albumIds;
		}
		elsif (specified($search)) {
			if ( Slim::Schema->canFulltextSearch ) {
				Slim::Plugin::FullTextSearch::Plugin->createHelperTable({
					name   => 'albumsSearch',
					search => $search,
					type   => 'album',
				});

				$sql = 'SELECT %s FROM albumsSearch, albums ';
				unshift @{$w}, "albums.id = albumsSearch.id";

				if ($tags ne 'CC') {
					$order_by = $sort = "albumsSearch.fulltextweight DESC, LENGTH(albums.titlesearch)";
				}
			}
			else {
				my $strings = Slim::Utils::Text::searchStringSplit($search);
				if ( ref $strings->[0] eq 'ARRAY' ) {
					push @{$w}, '(' . join( ' OR ', map { 'albums.titlesearch LIKE ?' } @{ $strings->[0] } ) . ')';
					push @{$p}, @{ $strings->[0] };
				}
				else {
					push @{$w}, 'albums.titlesearch LIKE ?';
					push @{$p}, @{$strings};
				}
			}
		}

		my @roles;
		if (defined $contributorID) {
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$compilation = 1;
			}
			else {

				$sql .= 'JOIN contributor_album ON contributor_album.album = albums.id ';
				push @{$w}, 'contributor_album.contributor = ?';
				push @{$p}, $contributorID;

				# only albums on which the contributor has a specific role?
				if ($roleID) {
					@roles = split /,/, $roleID;
					push @roles, 'ARTIST' if $roleID eq 'ALBUMARTIST' && !$prefs->get('useUnifiedArtistsList');
				}
				elsif ($prefs->get('useUnifiedArtistsList')) {
					@roles = ( 'ARTIST', 'TRACKARTIST', 'ALBUMARTIST' );

					# Loop through each pref to see if the user wants to show that contributor role.
					foreach (Slim::Schema::Contributor->contributorRoles) {
						if ($prefs->get(lc($_) . 'InArtists')) {
							push @roles, $_;
						}
					}
				}
				else {
					@roles = Slim::Schema::Contributor->contributorRoles();
				}
			}
		}
		elsif ($roleID) {
			$sql .= 'JOIN contributor_album ON contributor_album.album = albums.id ';

			@roles = split /,/, $roleID;
			push @roles, 'ARTIST' if $roleID eq 'ALBUMARTIST' && !$prefs->get('useUnifiedArtistsList');
		}

		if (scalar @roles) {
			push @{$p}, map { Slim::Schema::Contributor->typeToRole($_) } @roles;
			push @{$w}, 'contributor_album.role IN (' . join(', ', map {'?'} @roles) . ')';

			$sql .= 'JOIN contributors ON contributors.id = contributor_album.contributor ';
		}
		elsif ( $sort =~ /artflow|artistalbum/) {
			$sql .= 'JOIN contributors ON contributors.id = albums.contributor ';
		}

		if ( $sort eq 'new' ) {
			$sql .= 'JOIN tracks ON tracks.album = albums.id ';
			$limit = $prefs->get('browseagelimit') || 100;
			$order_by = "tracks.timestamp desc";

			# Force quantity to not exceed max
			if ( $quantity && $quantity > $limit ) {
				$quantity = $limit;
			}

			# cache the most recent album IDs - need to query the tracks table, which is expensive
			if ( !$ignoreNewAlbumsCache ) {
				my $ids = $cache->{$newAlbumsCacheKey} || [];

				if (!scalar @$ids) {
					my $_cache = Slim::Utils::Cache->new;
					$ids = $_cache->get($newAlbumsCacheKey) || [];

					# get rid of stale cache entries
					my @oldCacheKeys = grep /newAlbumIds/, keys %$cache;
					foreach (@oldCacheKeys) {
						next if $_ eq $newAlbumsCacheKey;
						$_cache->remove($_);
						delete $cache->{$_};
					}

					my $countSQL = qq{
						SELECT tracks.album
						FROM tracks } . ($libraryID ? qq{
							JOIN library_track ON library_track.library = '$libraryID' AND tracks.id = library_track.track
						} : '') . qq{
						WHERE tracks.album > 0
						GROUP BY tracks.album
						ORDER BY tracks.timestamp DESC
					};

					# get the list of album IDs ordered by timestamp
					$ids = Slim::Schema->dbh->selectcol_arrayref( $countSQL, { Slice => {} } ) unless scalar @$ids;

					$cache->{$newAlbumsCacheKey} = $ids;
					$_cache->set($newAlbumsCacheKey, $ids, 86400 * 7) if scalar @$ids;
				}

				my $start = scalar($index);
				my $end   = $start + scalar($quantity || scalar($limit)-1);
				if ($end >= scalar @$ids) {
					$end = scalar(@$ids) - 1;
				}
				push @{$w}, 'albums.id IN (' . join(',', @$ids[$start..$end]) . ')';

				# reset $index, as we're already limiting results using the id list
				$index = 0;
			}

			$page_key = undef;
		}
		elsif ( $sort eq 'artflow' ) {
			$order_by = "contributors.namesort $collate, albums.year, albums.titlesort $collate";
			$c->{'contributors.namesort'} = 1;
			$page_key = "SUBSTR(contributors.namesort,1,1)";
		}
		elsif ( $sort eq 'artistalbum' ) {
			$order_by = "contributors.namesort $collate, albums.titlesort $collate";
			$c->{'contributors.namesort'} = 1;
			$page_key = "SUBSTR(contributors.namesort,1,1)";
		}
		elsif ( $sort eq 'yearartistalbum' ) {
			$order_by = "albums.year, contributors.namesort $collate, albums.titlesort $collate";
			$page_key = "albums.year";
		}
		elsif ( $sort eq 'yearalbum' ) {
			$order_by = "albums.year, albums.titlesort $collate";
			$page_key = "albums.year";
		}
		elsif ( $sort eq 'random' ) {
			$limit = $prefs->get('itemsPerPage');

			# Force quantity to not exceed max
			if ( $quantity && $quantity > $limit ) {
				$quantity = $limit;
			}

			$order_by = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->randomFunction();
			$page_key = undef;
		}

		if (defined $libraryID) {
			push @{$w}, 'albums.id IN (SELECT library_album.album FROM library_album WHERE library_album.library = ?)';
			push @{$p}, $libraryID;
		}

		if (defined $releaseType) {
			my @releaseTypes = map { uc($_) } split(',', $releaseType);
			push @{$w}, 'albums.release_type IN (' . join(', ', map {'?'} @releaseTypes) . ')';
			push @{$p}, @releaseTypes;
		}

		if (defined $year) {
			push @{$w}, 'albums.year = ?';
			push @{$p}, $year;
		}

		if (defined $fromSearch) {
			# If we've got here from a search, we don't want to show the album unless it matches all the user's search criteria.
			# This matters for a Works search: we've shown the user a Work because it matches their criteria, but it is possible
			# that not all albums containing the Work match the all the criteria. (In this context, a work is a group of albums.)
			if ( Slim::Schema->canFulltextSearch ) {
				$fromSearch =~ s/ /* /g;
				$fromSearch .= '*';
				$fromSearch = "type:album " . $fromSearch;
				push @{$w}, "EXISTS (select * FROM fulltext WHERE SUBSTR(fulltext.id, 33)=albums.id AND fulltext MATCH ?)";
				push @{$p}, $fromSearch;
			} else {
				my $strings = Slim::Utils::Text::searchStringSplit($fromSearch);
				if ( ref $strings->[0] eq 'ARRAY' ) {
					push @{$w}, '(' . join( ' OR ', map { 'albums.titlesearch LIKE ?' } @{ $strings->[0] } ) . ')';
					push @{$p}, @{ $strings->[0] };
				}
				else {
					push @{$w}, 'albums.titlesearch LIKE ?';
					push @{$p}, @{$strings};
				}
			}
		}

		if (defined $work) {
			$sql .= 'JOIN tracks ON tracks.album = albums.id ' unless $sql =~ /JOIN tracks/;
			$sql .= 'JOIN works ON tracks.work = works.id ' unless $sql =~ /JOIN works/;
			push @{$w}, 'tracks.work = ?';
			push @{$p}, $work;
			$sql .= 'JOIN contributors AS composer ON works.composer = composer.id ' ;
			$sql .= 'JOIN contributor_track ON contributor_track.track = tracks.id ' unless $sql =~ /JOIN contributor_track/;
			push @{$w}, 'contributor_track.contributor = ? AND contributor_track.role = 2';
			push @{$p}, $composerID;
			$c->{'tracks.work'} = 1;
			$c->{'works.title'} = 1;
			$c->{'composer.name'} = 1;
			$c->{'tracks.grouping'} = 1;
		}

		if (defined $genreID) {
			my @genreIDs = split(/,/, $genreID);
			$sql .= 'JOIN tracks ON tracks.album = albums.id ' unless $sql =~ /JOIN tracks/;
			$sql .= 'JOIN genre_track ON genre_track.track = tracks.id ';
			push @{$w}, 'genre_track.genre IN (' . join(', ', map {'?'} @genreIDs) . ')';
			push @{$p}, @genreIDs;
		}

		if (defined $compilation) {
			if ($compilation == 1) {
				push @{$w}, 'albums.compilation = 1';
			}
			else {
				push @{$w}, '(albums.compilation IS NULL OR albums.compilation = 0)';
			}
		}
	}

	if ( $tags =~ /l/ ) {
		# title/disc/discc is needed to construct (N of M) title
		map { $c->{$_} = 1 } qw(albums.title albums.disc albums.discc);
	}

	if ( $tags =~ /y/ ) {
		$c->{'albums.year'} = 1;
	}

	if ( $tags =~ /j/ ) {
		$c->{'albums.artwork'} = 1;
	}

	if ( $tags =~ /t/ ) {
		$c->{'albums.title'} = 1;
	}

	if ( $tags =~ /i/ ) {
		$c->{'albums.disc'} = 1;
	}

	if ( $tags =~ /q/ ) {
		$c->{'albums.discc'} = 1;
	}

	if ( $tags =~ /w/ ) {
		$c->{'albums.compilation'} = 1;
	}

	my $wantsReleaseTypes = !$prefs->get('ignoreReleaseTypes');
	if ( $tags =~ /W/ && $wantsReleaseTypes ) {
		$c->{'albums.release_type'} = 1;
	}

	if ( $tags =~ /E/ ) {
		$c->{'albums.extid'} = 1;
	}

	if ( $tags =~ /X/ ) {
		$c->{'albums.replay_gain'} = 1;
	}

	if ( $tags =~ /R|S/ ) {
		$c->{'albums.contributor'} = 1;
	}

	if ( $tags =~ /a/ ) {
		# If requesting artist data, join contributor
		if ( $sql !~ /JOIN contributors ON/ ) {
			if ( $sql =~ /JOIN contributor_album/ ) {
				# Bug 17364, if looking for an artist_id value, we need to join contributors via contributor_album
				# or No Album will not be found properly
				$sql .= 'JOIN contributors ON contributors.id = contributor_album.contributor ';
			}
			else {
				$sql .= 'JOIN contributors ON contributors.id = albums.contributor ';
			}
		}
		$c->{'contributors.name'} = 1;

		# if albums for a specific contributor are requested, then we need the album's contributor, too
		$c->{'albums.contributor'} = $contributorID;
	}

	if ( $tags =~ /s/ ) {
		$c->{'albums.titlesort'} = 1;
	}

	if ( @{$w} ) {
		$sql .= 'WHERE ';
		my $s .= join( ' AND ', @{$w} );
		$s =~ s/\%/\%\%/g;
		$sql .= $s . ' ';
	}

	my $dbh = Slim::Schema->dbh;

	$sql .= $work ? "GROUP BY tracks.grouping, albums.id " : "GROUP BY albums.id ";

	if ($page_key && $tags =~ /Z/) {
		$request->addResult('indexList', _createIndexList(sprintf($sql, "$page_key AS n") . " ORDER BY $order_by", $p));

		if ($tags =~ /ZZ/) {
			$request->setStatusDone();
			return
		}
	}

	$sql .= "ORDER BY $order_by " unless $tags eq 'CC';

	# Add selected columns
	# Bug 15997, AS mapping needed for MySQL
	my @cols = sort keys %{$c};
	$sql = sprintf $sql, join( ', ', map { $_ . " AS '" . $_ . "'" } @cols );

	my $stillScanning = Slim::Music::Import->stillScanning();

	# Get count of all results, the count is cached until the next rescan done event
	my $cacheKey = md5_hex($sql . join( '', @{$p} ) . Slim::Music::VirtualLibraries->getLibraryIdForClient($client) . (Slim::Utils::Text::ignoreCase($search, 1) || ''));

	if ( $sort eq 'new' && $cache->{$newAlbumsCacheKey} && !$ignoreNewAlbumsCache ) {
		my $albumCount = scalar @{$cache->{$newAlbumsCacheKey}};
		$albumCount    = $limit if ($limit && $limit < $albumCount);
		$cache->{$cacheKey} ||= $albumCount;
		$limit = undef;
	}

	my $countsql = $sql;
	$countsql .= ' LIMIT ' . $limit if $limit;

	my $count = $cache->{$cacheKey};

	if ( !$count ) {
		my $total_sth = $dbh->prepare_cached( qq{
			SELECT COUNT(1) FROM ( $countsql ) AS t1
		} );

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Albums totals query: $countsql / " . Data::Dump::dump($p) );
		}

		$total_sth->execute( @{$p} );
		($count) = $total_sth->fetchrow_array();
		$total_sth->finish;
	}

	if ( !$stillScanning ) {
		$cache->{$cacheKey} = $count;
	}

	if ($stillScanning) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	# now build the result
	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	my $loopname = 'albums_loop';
	my $chunkCount = 0;

	if ($valid && $tags ne 'CC') {

		# We need to know the 'No album' name so that those items
		# which have been grouped together under it do not get the
		# album art of the first album.
		# It looks silly to go to Madonna->No album and see the
		# picture of '2 Unlimited'.
		my $noAlbumName = $request->string('NO_ALBUM');

		# Limit the real query
		if ($limit && !$quantity) {
			$quantity = "$limit";
			$index ||= "0";
		}
		if ( $index =~ /^\d+$/ && defined $quantity && $quantity =~ /^\d+$/ ) {
			$sql .= "LIMIT ?,? ";
			push @$p, $index, $quantity;
		}

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Albums query: $sql / " . Data::Dump::dump($p) );
		}

		my $sth = $dbh->prepare_cached($sql);
		$sth->execute( @{$p} );

		# Bind selected columns in order
		my $i = 1;
		for my $col ( @cols ) {
			$sth->bind_col( $i++, \$c->{$col} );
		}

		# Little function to construct nice title from title/disc counts
		my $groupdiscs_pref = $prefs->get('groupdiscs');
		my $construct_title = $groupdiscs_pref ? sub {
			return $c->{'albums.title'};
		} : sub {
			return Slim::Music::Info::addDiscNumberToAlbumTitle(
				$c->{'albums.title'}, $c->{'albums.disc'}, $c->{'albums.discc'}
			);
		};

		my ($contributorSql, $contributorSth, $contributorNameSth, $contributorRoleSth);
		if ( $tags =~ /(?:aa|SS)/ ) {
			my @roles = ( 'ARTIST', 'ALBUMARTIST' );

			if ($prefs->get('useUnifiedArtistsList')) {
				# Loop through each pref to see if the user wants to show that contributor role.
				foreach (Slim::Schema::Contributor->contributorRoles) {
					if ($prefs->get(lc($_) . 'InArtists')) {
						push @roles, $_;
					}
				}
			}

			$contributorSql = sprintf( qq{
				SELECT GROUP_CONCAT(contributors.name, ',') AS name, GROUP_CONCAT(contributors.id, ',') AS id
				FROM contributor_album
				JOIN contributors ON contributors.id = contributor_album.contributor
				WHERE contributor_album.album = ? AND contributor_album.role IN (%s)
				GROUP BY contributor_album.role
				ORDER BY contributor_album.role DESC
			}, join(',', map { Slim::Schema::Contributor->typeToRole($_) } @roles) );

			# when filtering by role, put that role at the head of the list if it wasn't in there yet
			if ($roleID) {
				unshift @roles, map { Slim::Schema::Contributor->roleToType($_) || $_ } split(/,/, $roleID);
				my %seen;
				@roles = reverse grep !($seen{$_}++), reverse @roles;

				$contributorSql = sprintf( qq{
					SELECT GROUP_CONCAT(c.name, ',') AS name, GROUP_CONCAT(c.id, ',') AS id
					FROM (
						SELECT contributors.name AS name, contributors.id AS id
						FROM contributor_album
							JOIN	contributors ON contributors.id = contributor_album.contributor
						WHERE contributor_album.album = ? AND contributor_album.role IN (%s)
						GROUP BY contributors.id
						ORDER BY contributor_album.role DESC
					)
					AS c;
				}, join(',', map { Slim::Schema::Contributor->typeToRole($_) } @roles) );
			}
		}

		my $vaObjId = Slim::Schema->variousArtistsObject->id;

		while ( $sth->fetch ) {

			utf8::decode( $c->{'albums.title'} ) if exists $c->{'albums.title'};
			utf8::decode( $c->{'works.title'} ) if exists $c->{'works.title'};
			utf8::decode( $c->{'composer.name'} ) if exists $c->{'composer.name'};
			utf8::decode( $c->{'tracks.grouping'} ) if exists $c->{'tracks.grouping'};
			$request->addResultLoop($loopname, $chunkCount, 'id', $c->{'albums.id'});
			$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'work_id', $c->{'tracks.work'});
			$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'work_name', $c->{'works.title'});
			$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'composer', $c->{'composer.name'});
			$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'grouping', $c->{'tracks.grouping'});

			$tags =~ /l/ && $request->addResultLoop($loopname, $chunkCount, 'album', $construct_title->());
			$tags =~ /y/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'year', $c->{'albums.year'});
			$tags =~ /j/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artwork_track_id', $c->{'albums.artwork'}) if ($c->{'albums.artwork'} || '') !~ /^https?:/;;
			$tags =~ /K/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artwork_url', $c->{'albums.artwork'}) if ($c->{'albums.artwork'} || '') =~ /^https?:/;
			$tags =~ /t/ && $request->addResultLoop($loopname, $chunkCount, 'title', $c->{'albums.title'});
			$tags =~ /i/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'disc', $c->{'albums.disc'});
			$tags =~ /q/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'disccount', $c->{'albums.discc'});
			$tags =~ /w/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'compilation', $c->{'albums.compilation'});
			$tags =~ /W/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'release_type', $wantsReleaseTypes ? $c->{'albums.release_type'} : 'ALBUM');
			$tags =~ /E/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'extid', $c->{'albums.extid'});
			$tags =~ /X/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'album_replay_gain', $c->{'albums.replay_gain'});
			$tags =~ /S/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artist_id', $contributorID || $c->{'albums.contributor'});

			if ($tags =~ /a/) {
				# Bug 15313, this used to use $eachitem->artists which
				# contains a lot of extra logic.

				# Bug 17542: If the album artist is different from the current track's artist,
				# use the album artist instead of the track artist (if available)
				if ($contributorID && $c->{'albums.contributor'} && $contributorID != $c->{'albums.contributor'}) {
					$contributorNameSth ||= $dbh->prepare_cached('SELECT name FROM contributors WHERE id = ?');
					my ($name) = @{ $dbh->selectcol_arrayref($contributorNameSth, undef, $c->{'albums.contributor'}) };
					$c->{'contributors.name'} = $name if $name;
				}

				utf8::decode( $c->{'contributors.name'} ) if exists $c->{'contributors.name'};

				$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artist', $c->{'contributors.name'});
			}

			if ($tags =~ /s/) {
				#FIXME: see if multiple char textkey is doable for year/genre sort
				my $textKey;
				if ($sort eq 'artflow' || $sort eq 'artistalbum') {
					utf8::decode( $c->{'contributors.namesort'} ) if exists $c->{'contributors.namesort'};
					$textKey = substr $c->{'contributors.namesort'}, 0, 1;
				} elsif ( $sort eq 'album' ) {
					utf8::decode( $c->{'albums.titlesort'} ) if exists $c->{'albums.titlesort'};
					$textKey = substr $c->{'albums.titlesort'}, 0, 1;
				}
				$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'textkey', $textKey);
			}

			# want multiple artists?
			if ( $contributorSql && $c->{'albums.contributor'} != $vaObjId && !$c->{'albums.compilation'} ) {
				$contributorSth ||= $dbh->prepare_cached($contributorSql);
				$contributorSth->execute($c->{'albums.id'});

				my $contributor = $contributorSth->fetchrow_hashref;
				$contributorSth->finish;

				# XXX - what if the artist name itself contains ','?
				if ( $tags =~ /aa/ && $contributor->{name} ) {
					utf8::decode($contributor->{name});
					$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artists', $contributor->{name});
				}

				if ( $tags =~ /SS/ && $contributor->{id} ) {
					$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artist_ids', $contributor->{id});
				}
			}

			if ( $tags =~ /R/ ) {
				$contributorRoleSth ||= $dbh->prepare_cached("SELECT role FROM contributor_album WHERE album = ? AND contributor = ?");
				my $rolesRef = $dbh->selectall_arrayref($contributorRoleSth, , undef, $c->{'albums.id'}, $contributorID || $c->{'albums.contributor'});

				if ($rolesRef) {
					my $roles = join(',', map { $_->[0] } @$rolesRef);
					$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'role_ids', $roles);
				}
			}

			$chunkCount++;

			main::idleStreams() if !($chunkCount % 5);
		}

	}

	$request->addResult('count', $count);

	$request->setStatusDone();
}

sub artistsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['artists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}

	my $sqllog = main::DEBUGLOG && logger('database.sql');

	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search   = $request->getParam('search');
	my $year     = $request->getParam('year');
	my $genreID  = $request->getParam('genre_id');
	my $genreString  = $request->getParam('genre_string');
	my $trackID  = $request->getParam('track_id');
	my $albumID  = $request->getParam('album_id');
	my $artistID = $request->getParam('artist_id');
	my $roleID   = $request->getParam('role_id');
	my $includeOnlineOnlyArtists = $request->getParam('include_online_only_artists');
	my $libraryID= Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id'));
	my $tags     = $request->getParam('tags') || '';

	# treat contributors for albums with only one ARTIST but no ALBUMARTIST the same
	my $aa_merge = $roleID && $roleID eq 'ALBUMARTIST' && !$prefs->get('useUnifiedArtistsList');

	my $va_pref  = $prefs->get('variousArtistAutoIdentification') && $prefs->get('useUnifiedArtistsList');

	# we only want external artists without tracks if there's no filtering argument given
	my $wantExternal = $includeOnlineOnlyArtists && !$year && !$genreID && !$genreString && !$trackID && !$albumID && !$artistID;

	if ($wantExternal && $libraryID) {
		my $library = Slim::Music::VirtualLibraries->getLibrary($libraryID) || {};
		$wantExternal = $wantExternal && !$library->{ignoreOnlineArtists};
	}

	my $sql    = 'SELECT %s FROM contributors ';
	my $sql_va = 'SELECT COUNT(*) FROM albums ';
	my $w      = [];
	my $w_va   = [ 'albums.compilation = 1' ];
	my $p      = [];
	my $p_va   = [];

	my $rs;
	my $cacheKey;

	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	my $sort    = "contributors.namesort, contributors.musicbrainz_id $collate";

	# Manage joins
	if (defined $trackID) {
		$sql .= 'JOIN contributor_track ON contributor_track.contributor = contributors.id ';
		push @{$w}, 'contributor_track.track = ?';
		push @{$p}, $trackID;
	}
	elsif (defined $artistID) {
		push @{$w}, 'contributors.id = ?';
		push @{$p}, $artistID;
	}
	else {
		if ( $search && Slim::Schema->canFulltextSearch ) {
			Slim::Plugin::FullTextSearch::Plugin->createHelperTable({
				name   => 'artistsSearch',
				search => $search,
				type   => 'contributor',
			});

			$sql = 'SELECT %s FROM artistsSearch, contributors ';
			unshift @{$w}, "contributors.id = artistsSearch.id";

			if ($tags ne 'CC') {
				$sort = "artistsSearch.fulltextweight DESC, LENGTH(contributors.name), $sort";
			}
		}

		my $roles;
		if ($roleID) {
			$roleID .= ',ARTIST' if $aa_merge;
			$roles = [ map { Slim::Schema::Contributor->typeToRole($_) } split(/,/, $roleID ) ];
		}
		elsif ($prefs->get('useUnifiedArtistsList')) {
			$roles = Slim::Schema->artistOnlyRoles();
		}
		else {
			$roles = [ map { Slim::Schema::Contributor->typeToRole($_) } Slim::Schema::Contributor->contributorRoles() ];
		}

		if ( defined $genreID ) {
			my @genreIDs = split(/,/, $genreID);

			$sql .= 'JOIN contributor_track ON contributor_track.contributor = contributors.id ';
			$sql .= 'JOIN tracks ON tracks.id = contributor_track.track ';
			$sql .= 'JOIN genre_track ON genre_track.track = tracks.id ';
			push @{$w}, 'genre_track.genre IN (' . join(', ', map {'?'} @genreIDs) . ')';
			push @{$p}, @genreIDs;

			# Adjust VA check to check for VA artists in this genre
			$sql_va .= 'JOIN tracks ON tracks.album = albums.id ';
			$sql_va .= 'JOIN genre_track ON genre_track.track = tracks.id ';
			push @{$w_va}, 'genre_track.genre = ?';
			push @{$p_va}, $genreID;
		}

		if ( !defined $search ) {
			if ( $sql !~ /JOIN contributor_track/ ) {
				$sql .= ($wantExternal ? 'LEFT ' : '') . 'JOIN contributor_album ON contributor_album.contributor = contributors.id ';
			}
		}

		if ( $sql =~ /JOIN contributor_track/ ) {
			push @{$w}, '(contributor_track.role IN (' . join( ',', @{$roles} ) . ') ' . ($search ? 'OR contributors.id = ? ' : '') . ') ';
		}
		else {
			if ( $sql !~ /JOIN contributor_album/ ) {
				$sql .= (($search || $wantExternal) ? 'LEFT ' : '') . 'JOIN contributor_album ON contributor_album.contributor = contributors.id ';
			}
			push @{$w}, '(contributor_album.role IN (' . join( ',', @{$roles} ) . ') ' . ($search ? 'OR contributors.id = ? ' : '') . ') ';
		}

		push @{$p}, Slim::Schema->variousArtistsObject->id if $search;

		if ( $va_pref || $aa_merge ) {
			# Don't include artists that only appear on compilations
			if ( $sql =~ /JOIN tracks/ ) {
				# If doing an artists-in-genre query, we are much better off joining through albums
				$sql .= 'JOIN albums ON albums.id = tracks.album ';
			}
			else {
				if ( $sql !~ /JOIN contributor_album/ ) {
					$sql .= ($wantExternal ? 'LEFT ' : '') . 'JOIN contributor_album ON contributor_album.contributor = contributors.id ';
				}
				$sql .= ($wantExternal ? 'LEFT ' : '') . 'JOIN albums ON contributor_album.album = albums.id ';
			}

			push @{$w}, '(albums.compilation IS NULL OR albums.compilation = 0' . ($va_pref ? '' : ' OR contributors.id = ' . Slim::Schema->variousArtistsObject->id) . ')';
		}

		if (defined $albumID || defined $year) {
			if ( $sql !~ /JOIN contributor_album/ ) {
				$sql .= 'JOIN contributor_album ON contributor_album.contributor = contributors.id ';
			}

			if ( $sql !~ /JOIN albums/ ) {
				$sql .= 'JOIN albums ON contributor_album.album = albums.id ';
			}

			if (defined $albumID) {
				push @{$w}, 'albums.id = ?';
				push @{$p}, $albumID;

				push @{$w_va}, 'albums.id = ?';
				push @{$p_va}, $albumID;
			}

			if (defined $year) {
				push @{$w}, 'albums.year = ?';
				push @{$p}, $year;

				push @{$w_va}, 'albums.year = ?';
				push @{$p_va}, $year;
			}
		}

		if ( $search && !Slim::Schema->canFulltextSearch ) {
			my $strings = Slim::Utils::Text::searchStringSplit($search);
			if ( ref $strings->[0] eq 'ARRAY' ) {
				push @{$w}, '(' . join( ' OR ', map { 'contributors.namesearch LIKE ?' } @{ $strings->[0] } ) . ')';
				push @{$p}, @{ $strings->[0] };
			}
			else {
				push @{$w}, 'contributors.namesearch LIKE ?';
				push @{$p}, @{$strings};
			}
		}

		if (defined $libraryID) {
			$sql .= ($wantExternal ? 'LEFT ' : '') . 'JOIN library_contributor ON library_contributor.contributor = contributors.id ';
			push @{$w}, 'library_contributor.library = ?';
			push @{$p}, $libraryID;
		}
	}

	if ( @{$w} ) {
		$sql .= 'WHERE ';
		my $s = join( ' AND ', @{$w} );
		$s =~ s/\%/\%\%/g;
		$sql .= (($wantExternal && !$libraryID) ? "($s) OR (contributors.extid IS NOT NULL AND contributors.extid != '')" : $s) . ' ';
	}

	my $dbh = Slim::Schema->dbh;

	# Various artist handling. Don't do if pref is off, or if we're
	# searching, or if we have a track
	my $count_va = 0;

	if ( $va_pref && !defined $search && !defined $trackID && !defined $artistID && !$roleID ) {
		# Only show VA item if there are any
		if ( @{$w_va} ) {
			$sql_va .= 'WHERE ';
			$sql_va .= join( ' AND ', @{$w_va} );
			$sql_va .= ' ';
		}

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Artists query VA count: $sql_va / " . Data::Dump::dump($p_va) );
		}

		my $total_sth = $dbh->prepare_cached( $sql_va );

		$total_sth->execute( @{$p_va} );
		($count_va) = $total_sth->fetchrow_array();
		$total_sth->finish;
	}

	my $indexList;
	if ($tags =~ /Z/) {
		$indexList = _createIndexList(sprintf($sql, "SUBSTR(contributors.namesort,1,1)") . " GROUP BY contributors.id ORDER BY contributors.namesort $collate", $p);

		unshift @$indexList, ['#' => 1] if $indexList && $count_va;

		if ($tags =~ /ZZ/) {
			$request->addResult('indexList', $indexList) if $indexList;
			$request->setStatusDone();
			return
		}
	}

	$sql = sprintf($sql, 'contributors.id, contributors.name, contributors.namesort' . ($tags =~ /E/ ? ', contributors.extid' : ''))
			. 'GROUP BY contributors.id ';

	$sql .= "ORDER BY $sort " unless $tags eq 'CC';

	my $stillScanning = Slim::Music::Import->stillScanning();

	# Get count of all results, the count is cached until the next rescan done event
	$cacheKey = md5_hex($sql . join( '', @{$p} ) . Slim::Music::VirtualLibraries->getLibraryIdForClient($client) . (Slim::Utils::Text::ignoreCase($search, 1) || ''));

	my $count = $cache->{$cacheKey};

	if ( !$count ) {
		my $total_sth = $dbh->prepare_cached( qq{
			SELECT COUNT(1) FROM ( $sql ) AS t1
		} );

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Artists totals query: $sql / " . Data::Dump::dump($p) );
		}

		$total_sth->execute( @{$p} );
		($count) = $total_sth->fetchrow_array();
		$total_sth->finish;
	}

	if ( !$stillScanning ) {
		$cache->{$cacheKey} = $count;
	}

	my $totalCount = $count || 0;

	if ( $count_va ) {
		# don't add the VA item on subsequent queries
		$count_va = ($count_va && !$index);

		# fix the index and counts if we have to include VA
		$totalCount = _fixCount(1, \$index, \$quantity, $count);
	}

	# now build the result

	if ($stillScanning) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	# If count is 0 but count_va is 1, set count to 1 because
	# we'll still have a VA item to add to the results
	if ( $count_va && !$count ) {
		$count = 1;
	}

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	# XXX for 'artists 0 1' with VA we need to force valid to 1
	if ( $count_va && $index == 0 && $quantity == 0 ) {
		$valid = 1;
	}

	my $loopname = 'artists_loop';
	my $chunkCount = 0;

	if ($valid && $tags ne 'CC') {
		# Limit the real query
		if ( $index =~ /^\d+$/ && $quantity =~ /^\d+$/ ) {
			$sql .= "LIMIT ?,? ";
			push @$p, $index, $quantity;
		}

		if ( main::INFOLOG && $sqllog->is_info ) {
			$sqllog->info( "Artists query: $sql / " . Data::Dump::dump($p) );
		}

		my $sth = $dbh->prepare_cached($sql);
		$sth->execute( @{$p} );

		my ($id, $name, $namesort, $extid);
		my @bind = (\$id, \$name, \$namesort);
		push @bind, \$extid if $tags =~ /E/;
		$sth->bind_columns(@bind);

		my $process = sub {
			$id += 0;

			utf8::decode($name);
			utf8::decode($namesort);

			$request->addResultLoop($loopname, $chunkCount, 'id', $id);
			$request->addResultLoop($loopname, $chunkCount, 'artist', $name);
			if ($tags =~ /s/) {
				# Bug 11070: Don't display large V at beginning of browse Artists
				my $textKey = ($count_va && $chunkCount == 0) ? ' ' : substr($namesort, 0, 1);
				$request->addResultLoop($loopname, $chunkCount, 'textkey', $textKey);
			}

			if ($tags =~ /E/ && $extid) {
				$request->addResultLoop($loopname, $chunkCount, 'extid', $extid);
			}

			$chunkCount++;

			main::idleStreams() if !($chunkCount % 10);
		};

		# Add VA item first if necessary
		if ( $count_va ) {
			my $vaObj = Slim::Schema->variousArtistsObject;

			# bug 15328 - get the VA name in the language requested by the client
			#             but only do so if the user isn't using a custom name
			my $vaName     = $vaObj->name;
			my $vaNamesort = $vaObj->namesort;
			if ( $vaName eq Slim::Utils::Strings::string('VARIOUSARTISTS') ) {
				$vaName     = $request->string('VARIOUSARTISTS');
				$vaNamesort = Slim::Utils::Text::ignoreCaseArticles($vaName);
			}

			$id       = $vaObj->id;
			$name     = $vaName;
			$namesort = $vaNamesort;

			$process->();
		}

		while ( $sth->fetch ) {
			$process->();
		}

	}

	$request->addResult('indexList', $indexList) if $indexList;

	$request->addResult('count', $totalCount);

	$request->setStatusDone();
}


sub cursonginfoQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['duration', 'artist', 'album', 'title', 'genre',
			'path', 'remote', 'current_title']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client = $request->client();

	# get the query
	my $method = $request->getRequest(0);
	my $url = Slim::Player::Playlist::url($client);

	if (defined $url) {

		if ($method eq 'path') {

			$request->addResult("_$method", $url);

		} elsif ($method eq 'remote') {

			$request->addResult("_$method",
				Slim::Music::Info::isRemoteURL($url));

		} elsif ($method eq 'current_title') {

			$request->addResult("_$method",
				Slim::Music::Info::getCurrentTitle($client, $url));

		} else {

			my $songData = _songData(
				$request,
				$url,
				'dalg',			# tags needed for our entities
			);

			if (defined $songData->{$method}) {
				$request->addResult("_$method", $songData->{$method});
			}

		}
	}

	$request->setStatusDone();
}


sub connectedQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['connected']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();

	$request->addResult('_connected', $client->connected() || 0);

	$request->setStatusDone();
}


sub debugQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['debug']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $category = $request->getParam('_debugflag');

	if ( !defined $category || !Slim::Utils::Log->isValidCategory($category) ) {

		$request->setStatusBadParams();
		return;
	}

	my $categories = Slim::Utils::Log->allCategories;

	if (defined $categories->{$category}) {

		$request->addResult('_value', $categories->{$category});

		$request->setStatusDone();

	} else {

		$request->setStatusBadParams();
	}
}


sub displayQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['display']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();

	my $parsed = $client->curLines();

	$request->addResult('_line1', $parsed->{line}[0] || '');
	$request->addResult('_line2', $parsed->{line}[1] || '');

	$request->setStatusDone();
}


sub displaynowQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['displaynow']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();

	$request->addResult('_line1', $client->prevline1());
	$request->addResult('_line2', $client->prevline2());

	$request->setStatusDone();
}


sub displaystatusQuery_filter {
	my $self = shift;
	my $request = shift;

	# we only listen to display messages
	return 0 if !$request->isCommand([['displaynotify']]);

	# retrieve the clientid, abort if not about us
	my $clientid   = $request->clientid() || return 0;
	my $myclientid = $self->clientid() || return 0;
	return 0 if $clientid ne $myclientid;

	my $subs     = $self->getParam('subscribe');
	my $type     = $request->getParam('_type');
	my $parts    = $request->getParam('_parts');
	my $duration = $request->getParam('_duration');

	# check displaynotify type against subscription ('showbriefly', 'update', 'bits', 'all')
	if ($subs eq $type || ($subs eq 'bits' && $type ne 'showbriefly') || $subs eq 'all') {

		my $pd = $self->privateData;

		# display forwarding is suppressed for this subscriber source
		return 0 if exists $parts->{ $pd->{'format'} } && !$parts->{ $pd->{'format'} };

		# don't send updates if there is no change
		return 0 if ($type eq 'update' && !$self->client->display->renderCache->{'screen1'}->{'changed'});

		# store display info in subscription request so it can be accessed by displaystatusQuery
		$pd->{'type'}     = $type;
		$pd->{'parts'}    = $parts;
		$pd->{'duration'} = $duration;

		# execute the query immediately
		$self->__autoexecute;
	}

	return 0;
}

sub displaystatusQuery {
	my $request = shift;

	main::DEBUGLOG && $log->debug("displaystatusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['displaystatus']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $subs  = $request->getParam('subscribe');

	# return any previously stored display info from displaynotify
	if (my $pd = $request->privateData) {

		my $client   = $request->client;
		my $format   = $pd->{'format'};
		my $type     = $pd->{'type'};
		my $parts    = $type eq 'showbriefly' ? $pd->{'parts'} : $client->display->renderCache;
		my $duration = $pd->{'duration'};

		$request->addResult('type', $type);

		# return screen1 info if more than one screen
		my $screen1 = $parts->{'screen1'} || $parts;

		if ($subs eq 'bits' && $screen1->{'bitsref'}) {

			# send the display bitmap if it exists (graphics display)
			use bytes;

			my $bits = ${$screen1->{'bitsref'}};
			if ($screen1->{'scroll'}) {
				$bits |= substr(${$screen1->{'scrollbitsref'}}, 0, $screen1->{'overlaystart'}[$screen1->{'scrollline'}]);
			}

			$request->addResult('bits', MIME::Base64::encode_base64($bits) );
			$request->addResult('ext', $screen1->{'extent'});

		} elsif ($format eq 'cli') {

			# format display for cli
			for my $c (keys %$screen1) {
				next unless $c =~ /^(line|center|overlay)$/;
				for my $l (0..$#{$screen1->{$c}}) {
					$request->addResult("$c$l", $screen1->{$c}[$l]) if ($screen1->{$c}[$l] ne '');
				}
			}

		} elsif ($format eq 'jive') {

			# send display to jive from one of the following components
			if (my $ref = $parts->{'jive'} && ref $parts->{'jive'}) {
				if ($ref eq 'CODE') {
					$request->addResult('display', $parts->{'jive'}->() );
				} elsif($ref eq 'ARRAY') {
					$request->addResult('display', { 'text' => $parts->{'jive'} });
				} else {
					$request->addResult('display', $parts->{'jive'} );
				}
			} else {
				my $display = {
					'text' => $screen1->{'line'} || $screen1->{'center'}
				};

				$display->{duration} = $duration if $duration;

				$request->addResult('display', $display);
			}
		}

	} elsif ($subs =~ /showbriefly|update|bits|all/) {
		# new subscription request - add subscription, assume cli or jive format for the moment
		$request->privateData({ 'format' => $request->source eq 'CLI' ? 'cli' : 'jive' });

		my $client = $request->client;

		main::DEBUGLOG && $log->debug("adding displaystatus subscription $subs");

		if ($subs eq 'bits') {

			if ($client->display->isa('Slim::Display::NoDisplay')) {
				# there is currently no display class, we need an emulated display to generate bits
				Slim::bootstrap::tryModuleLoad('Slim::Display::EmulatedSqueezebox2');
				if ($@) {
					$log->logBacktrace;
					logError("Couldn't load Slim::Display::EmulatedSqueezebox2: [$@]");

				} else {
					# swap to emulated display
					$client->display->forgetDisplay();
					$client->display( Slim::Display::EmulatedSqueezebox2->new($client) );
					$client->display->init;
					# register ourselves for execution and a cleanup function to swap the display class back
					$request->registerAutoExecute(0, \&displaystatusQuery_filter, \&_displaystatusCleanupEmulated);
				}

			} elsif ($client->display->isa('Slim::Display::EmulatedSqueezebox2')) {
				# register ourselves for execution and a cleanup function to swap the display class back
				$request->registerAutoExecute(0, \&displaystatusQuery_filter, \&_displaystatusCleanupEmulated);

			} else {
				# register ourselves for execution and a cleanup function to clear width override when subscription ends
				$request->registerAutoExecute(0, \&displaystatusQuery_filter, sub {
					$client->display->widthOverride(1, undef);
					if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
						main::INFOLOG && $log->info("last listener - suppressing display notify");
						$client->display->notifyLevel(0);
					}
					$client->update;
				});
			}

			# override width for new subscription
			$client->display->widthOverride(1, $request->getParam('width'));

		} else {
			$request->registerAutoExecute(0, \&displaystatusQuery_filter, sub {
				if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
					main::INFOLOG && $log->info("last listener - suppressing display notify");
					$client->display->notifyLevel(0);
				}
			});
		}

		if ($subs eq 'showbriefly') {
			$client->display->notifyLevel(1);
		} else {
			$client->display->notifyLevel(2);
			$client->update;
		}
	}

	$request->setStatusDone();
}

# cleanup function to disable display emulation.  This is a named sub so that it can be suppressed when resubscribing.
sub _displaystatusCleanupEmulated {
	my $request = shift;
	my $client  = $request->client;

	if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
		main::INFOLOG && $log->info("last listener - swapping back to NoDisplay class");
		$client->display->forgetDisplay();
		$client->display( Slim::Display::NoDisplay->new($client) );
		$client->display->init;
	}
}


sub genresQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['genres']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}

	my $sqllog = main::DEBUGLOG && logger('database.sql');

	# get our parameters
	my $client        = $request->client();
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $search        = $request->getParam('search');
	my $year          = $request->getParam('year');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $trackID       = $request->getParam('track_id');
	my $genreID       = $request->getParam('genre_id');
	my $libraryID     = Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id'));
	my $tags          = $request->getParam('tags') || '';

	my $sql  = 'SELECT %s FROM genres ';
	my $w    = [];
	my $p    = [];

	# Normalize and add any search parameters
	if (specified($search)) {
		my $strings = Slim::Utils::Text::searchStringSplit($search);
		if ( ref $strings->[0] eq 'ARRAY' ) {
			push @{$w}, '(' . join( ' OR ', map { 'genres.namesearch LIKE ?' } @{ $strings->[0] } ) . ')';
			push @{$p}, @{ $strings->[0] };
		}
		else {
			push @{$w}, 'genres.namesearch LIKE ?';
			push @{$p}, @{$strings};
		}
	}

	# Manage joins
	if (defined $trackID) {
		$sql .= 'JOIN genre_track ON genres.id = genre_track.genre ';
		push @{$w}, 'genre_track.track = ?';
		push @{$p}, $trackID;
	}
	elsif (defined $genreID) {
		my @genreIDs = split(/,/, $genreID);
		push @{$w}, 'genres.id IN (' . join(', ', map {'?'} @genreIDs) . ')';
		push @{$p}, @genreIDs;
	}
	else {
		# ignore those if we have a track.
		if (defined $contributorID) {

			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$sql .= 'JOIN genre_track ON genres.id = genre_track.genre ';
				$sql .= 'JOIN tracks ON genre_track.track = tracks.id ';
				$sql .= 'JOIN albums ON tracks.album = albums.id ';
				push @{$w}, 'albums.compilation = ?';
				push @{$p}, 1;
			}
			else {
				$sql .= 'JOIN genre_track ON genres.id = genre_track.genre ';
				$sql .= 'JOIN contributor_track ON genre_track.track = contributor_track.track ';
				push @{$w}, 'contributor_track.contributor = ?';
				push @{$p}, $contributorID;
			}
		}

		if ( $libraryID ) {
			$sql .= 'JOIN library_genre ON library_genre.genre = genres.id ';
			push @{$w}, 'library_genre.library = ?';
			push @{$p}, $libraryID;
		}

		if (defined $albumID || defined $year) {
			if ( $sql !~ /JOIN genre_track/ ) {
				$sql .= 'JOIN genre_track ON genres.id = genre_track.genre ';
			}
			if ( $sql !~ /JOIN tracks/ ) {
				$sql .= 'JOIN tracks ON genre_track.track = tracks.id ';
			}

			if (defined $albumID) {
				push @{$w}, 'tracks.album = ?';
				push @{$p}, $albumID;
			}
			if (defined $year) {
				push @{$w}, 'tracks.year = ?';
				push @{$p}, $year;
			}
		}
	}

	if ( @{$w} ) {
		$sql .= 'WHERE ';
		my $s = join( ' AND ', @{$w} );
		$s =~ s/\%/\%\%/g;
		$sql .= $s . ' ';
	}

	my $dbh = Slim::Schema->dbh;

	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();

	if ($tags =~ /Z/) {
		$request->addResult('indexList', _createIndexList(sprintf($sql, "SUBSTR(genres.namesort,1,1)") . " ORDER BY genres.namesort $collate", $p));

		if ($tags =~ /ZZ/) {
			$request->setStatusDone();
			return
		}
	}

	$sql = sprintf($sql, 'DISTINCT(genres.id), genres.name, genres.namesort');
	$sql .= "ORDER BY genres.namesort $collate" unless $tags eq 'CC';

	my $stillScanning = Slim::Music::Import->stillScanning();

	# Get count of all results, the count is cached until the next rescan done event
	my $cacheKey = md5_hex($sql . join( '', @{$p} ) . Slim::Music::VirtualLibraries->getLibraryIdForClient($client));

	my $count = $cache->{$cacheKey};
	if ( !$count ) {
		my $total_sth = $dbh->prepare_cached( qq{
			SELECT COUNT(1) FROM ( $sql ) AS t1
		} );

		$total_sth->execute( @{$p} );
		($count) = $total_sth->fetchrow_array();
		$total_sth->finish;
	}

	if ( !$stillScanning ) {
		$cache->{$cacheKey} = $count;
	}

	# now build the result

	if ($stillScanning) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid && $tags ne 'CC') {

		my $loopname = 'genres_loop';
		my $chunkCount = 0;

		# Limit the real query
		if ( $index =~ /^\d+$/ && $quantity =~ /^\d+$/ ) {
			$sql .= "LIMIT $index, $quantity ";
		}

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Genres query: $sql / " . Data::Dump::dump($p) );
		}

		my $sth = $dbh->prepare_cached($sql);
		$sth->execute( @{$p} );

		my ($id, $name, $namesort);
		$sth->bind_columns( \$id, \$name, \$namesort );

		while ( $sth->fetch ) {
			$id += 0;

			utf8::decode($name) if $name;
			utf8::decode($namesort) if $namesort;

			my $textKey = substr($namesort, 0, 1);

			$request->addResultLoop($loopname, $chunkCount, 'id', $id);
			$request->addResultLoop($loopname, $chunkCount, 'genre', $name);
			$tags =~ /s/ && $request->addResultLoop($loopname, $chunkCount, 'textkey', $textKey);

			$chunkCount++;

			main::idleStreams() if !($chunkCount % 5);
		}
	}

	$request->addResult('count', $count);

	$request->setStatusDone();
}


sub getStringQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['getstring']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $tokenlist = $request->getParam('_tokens');

	foreach my $token (split /,/, $tokenlist) {

		# check whether string exists or not, to prevent stack dumps if
		# client queries inexistent string
		if (Slim::Utils::Strings::stringExists($token)) {

			$request->addResult($token, $request->string($token));
		}

		else {

			$request->addResult($token, '');
		}
	}

	$request->setStatusDone();
}


sub infoTotalQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['info'], ['total'], ['genres', 'artists', 'albums', 'songs', 'duration']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}

	# get our parameters
	my $entity = $request->getRequest(2);

	my $totals = Slim::Schema->totals($request->client) if $entity ne 'duration';

	if ($entity eq 'albums') {
		$request->addResult("_$entity", $totals->{album});
	}
	elsif ($entity eq 'artists') {
		$request->addResult("_$entity", $totals->{contributor});
	}
	elsif ($entity eq 'genres') {
		$request->addResult("_$entity", $totals->{genre});
	}
	elsif ($entity eq 'songs') {
		$request->addResult("_$entity", $totals->{track});
	}
	elsif ($entity eq 'duration') {
		$request->addResult("_$entity", Slim::Schema->totalTime($request->client));
	}

	$request->setStatusDone();
}


sub irenableQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['irenable']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	$request->addResult('_irenable', $client->irenable());

	$request->setStatusDone();
}

sub librariesQuery {
	my $request = shift;

	if ($request->isNotQuery([['libraries']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if ( $request->isQuery([['libraries'], ['getid']]) && (my $client = $request->client) ) {
		my $id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client) || 0;
		$request->addResult('id', $id);
		$request->addResult('name', Slim::Music::VirtualLibraries->getNameForId($id, $client)) if $id;
	}
	else {
		my $i = 0;
		while ( my ($id, $args) = each %{ Slim::Music::VirtualLibraries->getLibraries() } ) {
			$request->addResultLoop('folder_loop', $i, 'id', $id);
			$request->addResultLoop('folder_loop', $i, 'name', $args->{name});
			$i++;
		}
	}

	$request->setStatusDone();
}

sub linesperscreenQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['linesperscreen']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();

	$request->addResult('_linesperscreen', $client->linesPerScreen());

	$request->setStatusDone();
}


sub mixerQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['mixer'], ['volume', 'muting', 'treble', 'bass', 'pitch']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);

	if ($entity eq 'muting') {
		$request->addResult("_$entity", $prefs->client($client)->get("mute"));
	}
	elsif ($entity eq 'volume') {
		$request->addResult("_$entity", $prefs->client($client)->get("volume"));
	} else {
		$request->addResult("_$entity", $client->$entity());
	}

	$request->setStatusDone();
}


sub modeQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['mode']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();

	$request->addResult('_mode', Slim::Player::Source::playmode($client));

	$request->setStatusDone();
}

sub musicfolderQuery {
	mediafolderQuery(@_);
}

sub mediafolderQuery {
	my $request = shift;

	main::INFOLOG && $log->info("mediafolderQuery()");

	# check this is the correct query.
	if ($request->isNotQuery([['mediafolder']]) && $request->isNotQuery([['musicfolder']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $folderId = $request->getParam('folder_id');
	my $want_top = $request->getParam('return_top');
	my $url      = $request->getParam('url');
	my $type     = $request->getParam('type') || '';
	my $tags     = $request->getParam('tags') || '';

	# duration is not available for anything but audio files
	$tags =~ s/d// if $type && $type ne 'audio';

	my ($sql, $volatileUrl);

	# Bug 17436, don't allow BMF if a scan is running, browse without storing tracks in database instead
	if (Slim::Music::Import->stillScanning()) {
		$volatileUrl = 1;
	}

	if (Slim::Music::Info::isVolatileURL($url)) {
		# if we're dealing with temporary items, store the real URL in $volatileUrl
		$volatileUrl = $url;
		$volatileUrl =~ s/^tmp/file/;
	}

	# url overrides any folderId
	my $params = ();
	my $mediaDirs = Slim::Utils::Misc::getMediaDirs($type || 'audio');

	$params->{recursive} = $request->getParam('recursive');

	# add "volatile" folders which are not scanned, to be browsed and played on the fly
	push @$mediaDirs, map {
		my $url = Slim::Utils::Misc::fileURLFromPath($_);
		$url =~ s/^file/tmp/;
		$url;
	} @{ Slim::Utils::Misc::getInactiveAudioDirs() } if !$type || $type eq 'audio';

	my ($topLevelObj, $items, $count, $topPath, $realName);

	my $bmfUrlForName = $cache->{bmfUrlForName} || {};

	my $highmem = $prefs->get('dbhighmem');

	my $filter = sub {
		# if a $sth is passed, we'll do a quick lookup to check existence only, not returning an actual object if possible
		my ($filename, $topPath, $sth) = @_;

		my $url = $bmfUrlForName->{$filename . $topPath};
		if (!$url) {
			$url ||= Slim::Utils::Misc::fixPath($filename, $topPath) || '';

			# keep a cache of the mapping in memory if we can afford it
			if ($highmem && $url) {
				$bmfUrlForName->{$filename . $topPath} ||= $url;
			}
		}

		# Amazingly, this just works. :)
		# Do the cheap compare for osName first - so non-windows users
		# won't take the penalty for the lookup.
		if (main::ISWINDOWS && Slim::Music::Info::isWinShortcut($url)) {
			($realName, $url) = Slim::Utils::OS::Win32->getShortcut($url);
		}

		elsif (main::ISMAC) {
			if ( my $alias = Slim::Utils::Misc::pathFromMacAlias($url) ) {
				$url = $alias;
			}
		}

		if ($sth && $url) {
			# don't create the dir objects in the first pass - we can create them later when paging through the list
			# only run a quick, relatively cheap test on the type of the URL
			$sth->execute($url);

			my $itemDetails = $sth->fetchrow_hashref;
			return 1 if $itemDetails && $itemDetails->{content_type};

			my $type = Slim::Music::Info::typeFromPath($url) || 'nada';
			return 1 if $type eq 'dir';
		}

		$url =~ s/^file/tmp/ if $volatileUrl;

		# if we have dbhighmem configured, use a memory cache to prevent slow lookups
		my $item = $bmfCache{$url} || Slim::Schema->objectForUrl({
			'url'      => $url,
			'create'   => 1,
			'readTags' => 1,
			'playlist' => Slim::Music::Info::isPlaylist($url),
		}) if $url;

		if ( (blessed($item) && $item->can('content_type')) || ($params->{typeRegEx} && $filename =~ $params->{typeRegEx}) ) {

			if ($highmem) {
				$bmfCache{$url} = $item;
			}

			# when dealing with a volatile file, read tags, as above objectForUrl() would not scan remote files
			if ( $volatileUrl ) {
				require Slim::Player::Protocols::Volatile;
				Slim::Player::Protocols::Volatile->getMetadataFor($client, $url);
			}

			return $item;
		}
	};

	if ( !defined $url && !defined $folderId && scalar(@$mediaDirs) > 1) {

		$items = $mediaDirs;
		$count = scalar(@$items);
		$topPath = '';

	}

	else {

		if ($volatileUrl && $url) {
			# We can't work with the URL for volatile objects. Make sure there is an object for it.
			my $item = Slim::Schema->objectForUrl({
				'url'      => $url,
				'create'   => 1,
			});
			$params->{'id'} = $item->id;
		}
		elsif (defined $url) {
			$params->{'url'} = $volatileUrl || $url;
		}
		elsif ($folderId) {
			$params->{'id'} = $folderId;
			$volatileUrl = 1 if $folderId < 0;
		}
		# no path given and in volatile mode - we've been called for the root during a scan
		elsif ($volatileUrl && scalar @$mediaDirs) {
			my $url = $mediaDirs->[0];

			if (!Slim::Music::Info::isURL($url)) {
				$url = Slim::Utils::Misc::fileURLFromPath($url);
			}
			$url =~ s/^file/tmp/;

			my $item = Slim::Schema->objectForUrl({
				'url'      => $url,
				'create'   => 1,
			});

			$params->{'id'} = $item->id;
		}
		elsif (scalar @$mediaDirs) {
			$params->{'url'} = $mediaDirs->[0];
		}

		if ($type) {
			$params->{typeRegEx} = Slim::Music::Info::validTypeExtensions($type);
		}

		# if this is a follow up query ($index > 0), try to read from the cache
		my $cacheKey = md5_hex(($params->{url} || $params->{id} || '') . $type . Slim::Music::VirtualLibraries->getLibraryIdForClient($client));
		if (my $cachedItem = $bmfCache{$cacheKey}) {
			$items       = $cachedItem->{items};
			$topLevelObj = $cachedItem->{topLevelObj};
			$count       = $cachedItem->{count};

			# bump the timeout on the cache
			$bmfCache{$cacheKey} = $cachedItem;
		}
		else {
			my $files;
			($topLevelObj, $files, $count) = Slim::Utils::Misc::findAndScanDirectoryTree($params);

			$topPath = blessed($topLevelObj) ? $topLevelObj->path : '';

			my $sth = (!$type || $type eq 'audio') ? Slim::Schema->dbh->prepare_cached('SELECT content_type FROM tracks WHERE url = ?') : undef;

			my $chunkCount = 0;
			$items = [ grep {
				main::idleStreams() unless ++$chunkCount % 20;
				$filter->($_, $topPath, $sth);
			} @$files ];

			$sth->finish() if $sth;

			$count = scalar @$items;

			# cache results in case the same folder is queried again shortly
			# should speed up Jive BMF, as only the first chunk needs to run the full loop above
			$bmfCache{$cacheKey} = {
				items       => $items,
				topLevelObj => $topLevelObj,
				count       => $count,
			} if scalar @$items > 10 && ($params->{url} || $params->{id});
		}

		if ($want_top) {
			$items = [ $topLevelObj->url ];
			$count = 1;
		}

		# create filtered data
		$topPath = $topLevelObj->path if blessed($topLevelObj);
	}

	# now build the result

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'folder_loop';
		my $chunkCount = 0;

		my $sth = $sql ? Slim::Schema->dbh->prepare_cached($sql) : undef;

		my $x = $start-1;
		for my $filename (@$items[$start..$end]) {

			my $id;
			$realName = '';
			my $item = $filter->($filename, $topPath) || '';

			if ( (!blessed($item) || !$item->can('content_type'))
				&& (!$params->{typeRegEx} || $filename !~ $params->{typeRegEx}) )
			{
				logError("Invalid item found in pre-filtered list - this should not happen! ($topPath -> $filename)");
				$count--;
				next;
			}
			elsif (blessed($item)) {
				$id = $item->id();
			}

			$x++;
			main::idleStreams() unless $x % 20;

			$id += 0;

			my $url = $item->url;

			# if we're dealing with temporary items, store the real URL in $volatileUrl
			if ($volatileUrl) {
				$volatileUrl = $url;
				$volatileUrl =~ s/^tmp/file/;
			}

			$realName ||= Slim::Music::Info::fileName($volatileUrl || $url);

			# volatile folder in browse root?
			my $isDir;
			if (!$realName || Slim::Music::Info::isVolatileURL($realName) && $id < 0) {
				my $url2 = $url;
				$url2 =~ s/^tmp/file/;
				$realName = '[' . Slim::Music::Info::fileName($url2) . ']';
				$isDir = Slim::Music::Info::isDir($url2);
			}

			my $textKey = uc(substr($realName, 0, 1));

			$request->addResultLoop($loopname, $chunkCount, 'id', $id);
			$request->addResultLoop($loopname, $chunkCount, 'filename', $realName);

			if ($isDir || Slim::Music::Info::isDir($volatileUrl || $item)) {
				$request->addResultLoop($loopname, $chunkCount, 'type', 'folder');
			} elsif (Slim::Music::Info::isPlaylist($volatileUrl || $item)) {
				$request->addResultLoop($loopname, $chunkCount, 'type', 'playlist');
			} elsif ($params->{typeRegEx} && $filename =~ $params->{typeRegEx}) {
				$request->addResultLoop($loopname, $chunkCount, 'type', $type);
			} elsif (Slim::Music::Info::isSong($volatileUrl || $item)) {
				$request->addResultLoop($loopname, $chunkCount, 'type', 'track');
			} elsif (-d Slim::Utils::Misc::pathFromMacAlias($volatileUrl || $url)) {
				$request->addResultLoop($loopname, $chunkCount, 'type', 'folder');
			} else {
				$request->addResultLoop($loopname, $chunkCount, 'type', 'unknown');
			}

			$tags =~ /c/ && $request->addResultLoop($loopname, $chunkCount, 'coverid', $item->coverid);
			$tags =~ /d/ && $request->addResultLoop($loopname, $chunkCount, 'duration', $item->duration);
			$tags =~ /s/ && $request->addResultLoop($loopname, $chunkCount, 'textkey', $textKey);
			$tags =~ /u/ && $request->addResultLoop($loopname, $chunkCount, 'url', $url);
			$tags =~ /t/ && $request->addResultLoop($loopname, $chunkCount, 'title', $realName);

			# XXX - This is not in line with other queries requesting the content type,
			#       where the latter would be returned as the "type" value. But I don't
			#       want to break backwards compatibility, therefore returning 'ct' instead.
			$tags =~ /o/ && $request->addResultLoop($loopname, $chunkCount, 'ct', $item->content_type);

			$chunkCount++;
		}

		$sth->finish() if $sth;
	}

	$request->addResult('count', $count);

	if (!$volatileUrl) {
		# we might have changed - flush to the db to be in sync.
		$topLevelObj->update if blessed($topLevelObj);

		# this is not always needed, but if only single tracks were added through BMF,
		# the caches would get out of sync
		Slim::Schema->wipeCaches;
		Slim::Music::Import->setLastScanTime();
	}

	if ( $highmem ) {
		# don't grow infinitely - reset after 512 entries
		if ( scalar keys %$bmfUrlForName > 512 ) {
			$bmfUrlForName = {};
		}

		$cache->{bmfUrlForName} = $bmfUrlForName;
	}

	$request->setStatusDone();
}


sub nameQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['name']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();

	$request->addResult("_value", $client->name());

	$request->setStatusDone();
}


sub playerXQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['player'], ['count', 'name', 'address', 'ip', 'id', 'model', 'displaytype', 'isplayer', 'canpoweroff', 'uuid']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $entity;
	$entity      = $request->getRequest(1);
	# if element 1 is 'player', that means next element is the entity
	$entity      = $request->getRequest(2) if $entity eq 'player';
	my $clientparam = $request->getParam('_IDorIndex');

	if ($entity eq 'count') {
		$request->addResult("_$entity", Slim::Player::Client::clientCount());

	} else {
		my $client;

		# were we passed an ID?
		if (defined $clientparam && Slim::Utils::Misc::validMacAddress($clientparam)) {

			$client = Slim::Player::Client::getClient($clientparam);

		} else {

			# otherwise, try for an index
			my @clients = Slim::Player::Client::clients();

			if (defined $clientparam && defined $clients[$clientparam]) {
				$client = $clients[$clientparam];
			}
		}

		# brute force attempt using eg. player's IP address (web clients)
		if (!defined $client) {
			$client = Slim::Player::Client::getClient($clientparam);
		}

		if (defined $client) {

			if ($entity eq "name") {
				$request->addResult("_$entity", $client->name());
			} elsif ($entity eq "address" || $entity eq "id") {
				$request->addResult("_$entity", $client->id());
			} elsif ($entity eq "ip") {
				$request->addResult("_$entity", $client->ipport());
			} elsif ($entity eq "model") {
				$request->addResult("_$entity", $client->model());
			} elsif ($entity eq "isplayer") {
				$request->addResult("_$entity", $client->isPlayer());
			} elsif ($entity eq "displaytype") {
				$request->addResult("_$entity", $client->vfdmodel());
			} elsif ($entity eq "canpoweroff") {
				$request->addResult("_$entity", $client->canPowerOff());
			} elsif ($entity eq "uuid") {
                                $request->addResult("_$entity", $client->uuid());
                        }
		}
	}

	$request->setStatusDone();
}

sub playersQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['players']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');

	my @prefs;

	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		@prefs = split(/,/, $pref_list);
	}

	my $count = Slim::Player::Client::clientCount();
	$count += 0;

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);
	$request->addResult('count', $count);

	if ($valid) {
		_addPlayersLoop($request, $start, $end, \@prefs);
	}

	$request->setStatusDone();
}

sub _addPlayersLoop {
	my ($request, $start, $end, $savePrefs) = @_;

	my $idx = $start;
	my $cnt = 0;
	my @players = Slim::Player::Client::clients();

	if (scalar(@players) > 0) {

		for my $eachclient (@players[$start..$end]) {
			$request->addResultLoop('players_loop', $cnt,
				'playerindex', $idx);
 			$request->addResultLoop('players_loop', $cnt,
				'playerid', $eachclient->id());
			$request->addResultLoop('players_loop', $cnt,
				'uuid', $eachclient->uuid());
			$request->addResultLoop('players_loop', $cnt,
				'ip', $eachclient->ipport());
			$request->addResultLoop('players_loop', $cnt,
				'name', $eachclient->name());
			if (defined $eachclient->sequenceNumber()) {
				$request->addResultLoop('players_loop', $cnt,
					'seq_no', $eachclient->sequenceNumber());
			}
			$request->addResultLoop('players_loop', $cnt,
				'model', $eachclient->model(1));
			$request->addResultLoop('players_loop', $cnt,
				'modelname', $eachclient->modelName());
			$request->addResultLoop('players_loop', $cnt,
				'power', $eachclient->power() ? 1 : 0);
			$request->addResultLoop('players_loop', $cnt,
				'isplaying', $eachclient->isPlaying() ? 1 : 0);
			$request->addResultLoop('players_loop', $cnt,
				'displaytype', $eachclient->vfdmodel())
				unless ($eachclient->model() eq 'http');
			$request->addResultLoop('players_loop', $cnt,
				'isplayer', $eachclient->isPlayer() || 0);
			$request->addResultLoop('players_loop', $cnt,
				'canpoweroff', $eachclient->canPowerOff());
			$request->addResultLoop('players_loop', $cnt,
				'connected', ($eachclient->connected() || 0));
			$request->addResultLoop('players_loop', $cnt,
				'firmware', $eachclient->revision());
			$request->addResultLoop('players_loop', $cnt,
				'player_needs_upgrade', 1)
				if ($eachclient->needsUpgrade());
			$request->addResultLoop('players_loop', $cnt,
				'player_is_upgrading', 1)
				if ($eachclient->isUpgrading());

			for my $pref (@$savePrefs) {
				if (defined(my $value = $prefs->client($eachclient)->get($pref))) {
					$request->addResultLoop('players_loop', $cnt,
						$pref, $value);
				}
			}

			$idx++;
			$cnt++;
		}
	}
}

sub playlistPlaylistsinfoQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['playlistsinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	my $playlistObj = $client->currentPlaylist();

	if (blessed($playlistObj)) {
		if ($playlistObj->can('id')) {
			$request->addResult("id", $playlistObj->id());
		}

		$request->addResult("name", $playlistObj->title());

		$request->addResult("modified", $client->currentPlaylistModified());

		$request->addResult("url", $playlistObj->url());
	}

	$request->setStatusDone();
}


sub playlistXQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['name', 'url', 'modified',
			'tracks', 'duration', 'artist', 'album', 'title', 'genre', 'path',
			'repeat', 'shuffle', 'index', 'jump', 'remote']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);
	my $index  = $request->getParam('_index');

	if ($entity eq 'repeat') {
		$request->addResult("_$entity", Slim::Player::Playlist::repeat($client));

	} elsif ($entity eq 'shuffle') {
		$request->addResult("_$entity", Slim::Player::Playlist::shuffle($client));

	} elsif ($entity eq 'index' || $entity eq 'jump') {
		$request->addResult("_$entity", Slim::Player::Source::playingSongIndex($client));

	} elsif ($entity eq 'name' && defined(my $playlistObj = $client->currentPlaylist())) {
		$request->addResult("_$entity", Slim::Music::Info::standardTitle($client, $playlistObj));

	} elsif ($entity eq 'url') {
		my $result = $client->currentPlaylist();
		$request->addResult("_$entity", $result);

	} elsif ($entity eq 'modified') {
		$request->addResult("_$entity", $client->currentPlaylistModified());

	} elsif ($entity eq 'tracks') {
		$request->addResult("_$entity", Slim::Player::Playlist::count($client));

	} elsif ($entity eq 'path') {
		my $result = Slim::Player::Playlist::url($client, $index);
		$request->addResult("_$entity",  $result || 0);

	} elsif ($entity eq 'remote') {
		if (defined (my $url = Slim::Player::Playlist::url($client, $index))) {
			$request->addResult("_$entity", Slim::Music::Info::isRemoteURL($url));
		}

	} elsif ($entity =~ /(duration|artist|album|title|genre|name)/) {

		my $songData = _songData(
			$request,
			Slim::Player::Playlist::track($client, $index),
			'dalgN',			# tags needed for our entities
		);

		if (defined $songData->{$entity}) {
			$request->addResult("_$entity", $songData->{$entity});
		}
		elsif ($entity eq 'name' && defined $songData->{remote_title}) {
			$request->addResult("_$entity", $songData->{remote_title});
		}
	}

	$request->setStatusDone();
}

# XXX TODO: merge SQL-based code from 7.6/trunk
# Can't use _getTagDataForTracks as is, as we have to deal with remote URLs, too
sub playlistsTracksQuery {
	my $request = shift;

	# check this is the correct query.
	# "playlisttracks" is deprecated (July 06).
	if ($request->isNotQuery([['playlisttracks']]) &&
		$request->isNotQuery([['playlists'], ['tracks']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $tags       = 'gald';
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	my $tagsprm    = $request->getParam('tags');
	my $playlistID = $request->getParam('playlist_id');
	my $libraryId  = Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id'));

	if (!defined $playlistID) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	my $iterator;
	my @tracks;

	my $playlistObj = Slim::Schema->find('Playlist', $playlistID);

	if (blessed($playlistObj) && $playlistObj->can('tracks')) {
		$iterator = $playlistObj->tracks($libraryId);
		$request->addResult("__playlistTitle", $playlistObj->name) if $playlistObj->name;
	}

	# now build the result

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (defined $iterator) {

		my $count = $iterator->count();
		$count += 0;

		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		if ($valid || $start == $end) {


			my $cur = $start;
			my $loopname = 'playlisttracks_loop';
			my $chunkCount = 0;

			my $list_index = 0;
			for my $eachitem ($iterator->slice($start, $end)) {

				_addSong($request, $loopname, $chunkCount, $eachitem, $tags, "playlist index", $cur);

				$cur++;
				$chunkCount++;

				main::idleStreams();
			}
		}
		$request->addResult("count", $count);

	} else {

		$request->addResult("count", 0);
	}

	$request->setStatusDone();
}


sub playlistsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['playlists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search   = $request->getParam('search');
	my $tags     = $request->getParam('tags') || '';
	my $libraryId= Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id'));

	# Normalize any search parameters
	if (defined $search && !Slim::Schema->canFulltextSearch) {
		$search = Slim::Utils::Text::searchStringSplit($search);
	}

	my $rs = Slim::Schema->rs('Playlist')->getPlaylists('all', $search, $libraryId);

	# now build the result
	my $count = $rs->count;

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (defined $rs) {

		$count += 0;

		my ($valid, $start, $end) = $request->normalize(
			scalar($index), scalar($quantity), $count);

		if ($valid) {

			my $loopname = 'playlists_loop';
			my $chunkCount = 0;

			for my $eachitem ($rs->slice($start, $end)) {

				my $id = $eachitem->id();
				$id += 0;

				my $textKey = substr($eachitem->namesort, 0, 1);

				$request->addResultLoop($loopname, $chunkCount, "id", $id);
				$request->addResultLoop($loopname, $chunkCount, "playlist", $eachitem->title);
				$tags =~ /u/ && $request->addResultLoop($loopname, $chunkCount, "url", $eachitem->url);
				$tags =~ /s/ && $request->addResultLoop($loopname, $chunkCount, 'textkey', $textKey);
				$tags =~ /E/ && $request->addResultLoop($loopname, $chunkCount, 'extid', $eachitem->extid);
				$tags =~ /x/ && $request->addResultLoop($loopname, $chunkCount, 'remote', $eachitem->remote ? 1 : 0);

				$chunkCount++;

				main::idleStreams() if !($chunkCount % 5);
			}
		}

		$request->addResult("count", $count);

	} else {
		$request->addResult("count", 0);
	}
	$request->setStatusDone();
}


sub powerQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['power']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	$request->addResult('_power', $client->power());

	$request->setStatusDone();
}


sub prefQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['pref']]) && $request->isNotQuery([['playerpref']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client;

	if ($request->isQuery([['playerpref']])) {

		$client = $request->client();

		unless ($client) {
			$request->setStatusBadDispatch();
			return;
		}
	}

	# get the parameters
	my $prefName = $request->getParam('_prefname');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*?):(.+)$/) {
		$namespace = $1;
		$prefName = $2;
	}

	if (!defined $prefName || !defined $namespace) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('_p2', $client
		? preferences($namespace)->client($client)->get($prefName)
		: preferences($namespace)->get($prefName)
	);

	$request->setStatusDone();
}


sub prefValidateQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['pref'], ['validate']]) && $request->isNotQuery([['playerpref'], ['validate']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client = $request->client();

	# get our parameters
	my $prefName = $request->getParam('_prefname');
	my $newValue = $request->getParam('_newvalue');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*?):(.+)$/) {
		$namespace = $1;
		$prefName = $2;
	}

	if (!defined $prefName || !defined $namespace || !defined $newValue) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('valid',
		($client
			? preferences($namespace)->client($client)->validate($prefName, $newValue)
			: preferences($namespace)->validate($prefName, $newValue)
		)
		? 1 : 0
	);

	$request->setStatusDone();
}


sub readDirectoryQuery {
	my $request = shift;

	main::INFOLOG && $log->info("readDirectoryQuery");

	# check this is the correct query.
	if ($request->isNotQuery([['readdirectory']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	my $folder     = $request->getParam('folder');
	my $filter     = $request->getParam('filter');

	use File::Spec::Functions qw(catdir);
	my @fsitems;		# raw list of items
	my %fsitems;		# meta data cache

	if (main::ISWINDOWS && $folder eq '/') {
		@fsitems = sort map {
			$fsitems{"$_"} = {
				d => 1,
				f => 0
			};
			"$_";
		} Slim::Utils::OS::Win32->getDrives();
		$folder = '';
	}
	else {
		$filter ||= '';

		my $filterRE = qr/./ unless ($filter eq 'musicfiles');

		# get file system items in $folder
		@fsitems = Slim::Utils::Misc::readDirectory($folder, $filterRE);
		my $transformFn = main::ISWINDOWS ? sub { Slim::Utils::Unicode::encode_locale($_[0]) } : sub { $_[0] };
		map {
			Slim::Utils::Unicode::utf8on($_) if !main::ISWINDOWS && Slim::Utils::Unicode::looks_like_utf8($_);
			$fsitems{$_} = {
				d => -d $transformFn->(catdir($folder, $_)),
				f => -f _
			}
		} @fsitems;
	}

	if ($filter eq 'foldersonly') {
		@fsitems = grep { $fsitems{$_}->{d} } @fsitems;
	}

	elsif ($filter eq 'filesonly') {
		@fsitems = grep { $fsitems{$_}->{f} } @fsitems;
	}

	# return all folders plus files of type
	elsif ($filter =~ /^filetype:(.*)/) {
		my $filterRE = qr/(?:\.$1)$/i;
		@fsitems = grep { $fsitems{$_}->{d} || $_ =~ $filterRE } @fsitems;
	}

	# search anywhere within path/filename
	elsif ($filter && $filter !~ /^(?:filename|filetype):/) {
		@fsitems = grep { catdir($folder, $_) =~ /$filter/i } @fsitems;
	}

	my $count = @fsitems;
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		my $idx = $start;
		my $cnt = 0;

		if (scalar(@fsitems)) {
			# sort folders < files
			@fsitems = sort {
				if ($fsitems{$a}->{d}) {
					if ($fsitems{$b}->{d}) { 0 }
					else { -1 }
				}
				else {
					if ($fsitems{$b}->{d}) { 1 }
					else { 0 }
				}
			} @fsitems;

			my $path;
			for my $item (@fsitems[$start..$end]) {
				my $name = $item;

				$item = Slim::Utils::Unicode::utf8decode_locale($item);

				$path = ($folder ? catdir($folder, $item) : $item);

				my $decodedName;

				# display full name if we got a Windows 8.3 file name
				if (main::ISWINDOWS && $name =~ /~\d/) {
					$decodedName = basename(Slim::Music::Info::fileName($path));
				} else {
					$decodedName = Slim::Utils::Unicode::utf8decode_locale($name);
				}

				$request->addResultLoop('fsitems_loop', $cnt, 'path', Slim::Utils::Unicode::utf8decode_locale($path));
				$request->addResultLoop('fsitems_loop', $cnt, 'name', $decodedName);

				$request->addResultLoop('fsitems_loop', $cnt, 'isfolder', $fsitems{$item}->{d});

				$idx++;
				$cnt++;
			}
		}
	}

	$request->setStatusDone();
}


sub rescanQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['rescan']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescan query

	$request->addResult('_rescan', Slim::Music::Import->stillScanning() ? 1 : 0);

	$request->setStatusDone();
}


sub rescanprogressQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['rescanprogress']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescanprogress query

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);

		# get progress from DB
		my $args = {
			'type' => 'importer',
		};

		my @progress = Slim::Schema->rs('Progress')->search( $args, { 'order_by' => 'start,id' } )->all;

		# calculate total elapsed time
		# and indicate % completion for all importers
		my $total_time = 0;
		my @steps;

		for my $p (@progress) {

			my $name = $p->name;
			if ($name =~ /(.*)\|(.*)/) {
				$request->addResult('fullname', $request->string($2 . '_PROGRESS') . $request->string('COLON') . ' ' . $1);
				$name = $2;
			}

			my $percComplete = $p->finish ? 100 : $p->total ? $p->done / $p->total * 100 : -1;
			$request->addResult($name, int($percComplete));

			push @steps, $name;

			$total_time += ($p->finish || time()) - $p->start;

			if ($p->active && $p->info) {

				$request->addResult('info', $p->info);

			}
		}

		$request->addResult('steps', join(',', @steps)) if @steps;

		# report it
		my $hrs  = int($total_time / 3600);
		my $mins = int(($total_time - $hrs * 3600)/60);
		my $sec  = $total_time - (3600 * $hrs) - (60 * $mins);
		$request->addResult('totaltime', sprintf("%02d:%02d:%02d", $hrs, $mins, $sec));

	# if we're not scanning, just say so...
	} else {
		$request->addResult('rescan', 0);

		if (Slim::Schema::hasLibrary()) {
			# inform if the scan has failed
			if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'name' => 'failure' })->first) {
				_scanFailed($request, $p->info);
			}
		}
	}

	$request->setStatusDone();
}


sub searchQuery {
	my $request = shift;
	# check this is the correct query
	if ($request->isNotQuery([['search']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client   = $request->client;
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $query    = $request->getParam('term');
	my $extended = $request->getParam('extended');
	my $libraryID= Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id')) || Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	# transliterate umlauts and accented characters
	# http://bugs.slimdevices.com/show_bug.cgi?id=8585
	$query = Slim::Utils::Text::matchCase($query);

	if (!defined $query || $query eq '') {
		$request->setStatusBadParams();
		return;
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);
	}

	my $totalCount = 0;
	my $search = Slim::Schema->canFulltextSearch ? $query : Slim::Utils::Text::searchStringSplit($query);

	my $dbh = Slim::Schema->dbh;

	my $total = 0;

	my $doSearch = sub {
		my ($type, $name, $w, $p, $c) = @_;

		# contributors first
		my $cols = "me.id, me.$name";
		$cols    = join(', ', $cols, @$c) if $extended && $c && @$c;
		
		my $sql;

		# we don't have a full text index for genres
		my $canFulltextSearch = $type ne 'genre' && Slim::Schema->canFulltextSearch;

		if ( $canFulltextSearch ) {
			Slim::Plugin::FullTextSearch::Plugin->createHelperTable({
				name   => 'quickSearch',
				search => $search,
				type   => $type,
				checkLargeResultset => sub {
					my $isLarge = shift;
					return ($isLarge && $isLarge > ($index + $quantity)) ? ('ORDER BY fulltextweight DESC LIMIT ' . $isLarge) : '';
				},
			});

			$sql = "SELECT $cols, quickSearch.fulltextweight FROM quickSearch, ${type}s me ";
			unshift @{$w}, "me.id = quickSearch.id";
		}
		else {
			$sql = "SELECT $cols FROM ${type}s me ";
		}

		if ( $libraryID ) {
			if ( $type eq 'contributor') {
				$sql .= 'JOIN contributor_track ON contributor_track.contributor = me.id ';
				$sql .= 'JOIN library_track ON library_track.track = contributor_track.track ';
			}
			elsif ( $type eq 'work') {
				$sql .= 'JOIN tracks ON tracks.work = me.id ';
				$sql .= 'JOIN library_track ON library_track.track = tracks.id ';
			}

			elsif ( $type eq 'album' ) {
				$sql .= 'JOIN tracks ON tracks.album = me.id ';
				$sql .= 'JOIN library_track ON library_track.track = tracks.id ';
			}
			elsif ( $type eq 'genre' ) {
				$sql .= 'JOIN genre_track ON genre_track.genre = me.id ';
				$sql .= 'JOIN library_track ON library_track.track = genre_track.track ';
			}
			elsif ( $type eq 'track' ) {
				$sql .= 'JOIN library_track ON library_track.track = me.id ';
			}

			push @{$w}, 'library_track.library = ?';
			push @{$p}, $libraryID;
		}

		if ( !$canFulltextSearch ) {
			my $s = ref $search ? $search : [ $search ];

			if ( ref $s->[0] eq 'ARRAY' ) {
				push @{$w}, '(' . join( ' OR ', map { "me.${name}search LIKE ?" } @{ $s->[0] } ) . ')';
				push @{$p}, @{ $s->[0] };
			}
			else {
				push @{$w}, "me.${name}search LIKE ?";
				push @{$p}, @{$s};
			}
		}

		if ( $w && @{$w} ) {
			$sql .= 'WHERE ';
			my $s = join( ' AND ', @{$w} );
			$s =~ s/\%/\%\%/g;
			$sql .= $s . ' ';
		}

		$sql .= "GROUP BY me.id " if $libraryID;

		my $sth = $dbh->prepare_cached( qq{SELECT COUNT(1) FROM ($sql) AS t1} );
		$sth->execute(@$p);
		my ($count) = $sth->fetchrow_array;
		$sth->finish;

		$count += 0;
		$total += $count;

		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		if ($valid) {
			$request->addResult("${type}s_count", $count);

			$sql .= "ORDER BY quickSearch.fulltextweight DESC " if $canFulltextSearch;

			# Limit the real query
			$sql .= "LIMIT ?,?";

			my $sth = $dbh->prepare_cached($sql);
			$sth->execute( @{$p}, $index, $quantity );

			my ($id, $title, %additionalCols);
			$sth->bind_col(1, \$id);
			$sth->bind_col(2, \$title);

			if ($extended && $c) {
				my $i = 2;
				foreach (@$c) {
					$sth->bind_col(++$i, \$additionalCols{$_});
				}
			}

			my $chunkCount = 0;
			my $loopname   = "${type}s_loop";
			while ( $sth->fetch ) {

				last if $chunkCount >= $quantity;

				$request->addResultLoop($loopname, $chunkCount, "${type}_id", $id+0);

				utf8::decode($title);
				$request->addResultLoop($loopname, $chunkCount, "${type}", $title);

				# any additional column
				if ($extended && $c) {
					foreach (@$c) {
						my $col = $_;

						my $value = $additionalCols{$_};
						utf8::decode($value);

						$col =~ s/me\.//;
						$request->addResultLoop($loopname, $chunkCount, $col, $value);
					}
				}

				$chunkCount++;

				main::idleStreams() if !($chunkCount % 10);
			}

			$sth->finish;
		}
	};

	$doSearch->('contributor', 'name');
	$doSearch->('album', 'title', undef, undef, ['me.artwork']);
	$doSearch->('work', 'title');
	$doSearch->('genre', 'name');
	$doSearch->('track', 'title', ['me.audio = ?'], ['1'], ['me.coverid', 'me.audio']);

	# XXX - should we search for playlists, too?

	$request->addResult('count', $total);
	$request->setStatusDone();
}


# the filter function decides, based on a notified request, if the serverstatus
# query must be re-executed.
sub serverstatusQuery_filter {
	my $self = shift;
	my $request = shift;

	# we want to know about clients going away as soon as possible
	if ($request->isCommand([['client'], ['forget']]) || $request->isCommand([['connect']])) {
		return 1;
	}

	# we want to know about rescan and all client notifs, as well as power on/off
	# FIXME: wipecache and rescan are synonyms...
	if ($request->isCommand([['wipecache', 'rescan', 'client', 'power']])) {
		return 1.3;
	}

	# FIXME: prefset???
	# we want to know about any pref in our array
	if (defined(my $prefsPtr = $self->privateData()->{'server'})) {
		if ($request->isCommand([['pref']])) {
			if (defined(my $reqpref = $request->getParam('_prefname'))) {
				if (grep($reqpref, @{$prefsPtr})) {
					return 1.3;
				}
			}
		}
	}
	if (defined(my $prefsPtr = $self->privateData()->{'player'})) {
		if ($request->isCommand([['playerpref']])) {
			if (defined(my $reqpref = $request->getParam('_prefname'))) {
				if (grep($reqpref, @{$prefsPtr})) {
					return 1.3;
				}
			}
		}
	}
	if ($request->isCommand([['name']])) {
		return 1.3;
	}

	return 0;
}


sub serverstatusQuery {
	my $request = shift;

	main::INFOLOG && $log->debug("serverstatusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['serverstatus']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (Slim::Schema::hasLibrary()) {
		if (Slim::Music::Import->stillScanning()) {
			$request->addResult('rescan', "1");
			if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'active' => 1 })->first) {

				# remove leading path information from the progress name
				my $name = $p->name;
				$name =~ s/(.*)\|//;

				$request->addResult('progressname', $request->string($name . '_PROGRESS'));
				$request->addResult('progressdone', $p->done);
				$request->addResult('progresstotal', $p->total);
			}
		}
		else {
			$request->addResult( lastscan => Slim::Music::Import->lastScanTime() );

			# XXX This needs to be fixed, failures are not reported
			#if ($p[-1]->name eq 'failure') {
			#	_scanFailed($request, $p[-1]->info);
			#}
		}
	}

	# add version
	if ($request->source && $request->source !~ /-lms8/ && $request->source =~ /serverstatus\|.*?\|.*?\|.*?\|(SqueezePlay-(?:baby|fab4|jive|squeezeplay)\b.+)$/) {
		my $ua = $1;
		my ($model, $version) = $ua =~ m{SqueezePlay-(baby|fab4|jive|squeezeplay)/(\d+\.\d+\.\d+)};
		if (Slim::Utils::Versions->compareVersions($version, '7.8.0') < 0) {
			$model = {
				baby => 'Radio',
				fab4 => 'Touch',
				jive => 'Controller',
				squeezeplay => 'SqueezePlay'
			}->{$model} || $model;

			main::DEBUGLOG && logger('network.protocol')->debug("Found outdated SB $model, need to return compatible version string: $ua");
			$request->addResult('version', Slim::Networking::Discovery::getFakeVersion($model));
		}
		else {
			$request->addResult('version', $::VERSION);
		}
	}
	else {
		$request->addResult('version', $::VERSION);
	}

	$request->addResult('newversion', $::newVersion) if $::newVersion;
	$request->addResult('needsrestart', 1) if Slim::Utils::PluginManager->needsRestart;
	$request->addResult('pluginsdownloading', 1) if Slim::Utils::PluginDownloader->downloading;
	if (my $newPlugins = Slim::Utils::PluginManager->message) {
		$request->addResult('newplugins', $newPlugins);
	}


	# add server_uuid
	$request->addResult('uuid', $prefs->get('server_uuid'));

	if ( my $mac = Slim::Utils::OSDetect->getOS()->getMACAddress() ) {
		$request->addResult('mac', $mac);
	}

	$request->addResult('ip', Slim::Utils::Network::serverAddr());
	$request->addResult('httpport', $prefs->get('httpport'));

	if (Slim::Schema::hasLibrary()) {
		# add totals
		my $totals = Slim::Schema->totals($request->client);

		$request->addResult("info total albums", $totals->{album});
		$request->addResult("info total artists", $totals->{contributor});
		$request->addResult("info total genres", $totals->{genre});
		$request->addResult("info total songs", $totals->{track});
		$request->addResult("info total duration", Slim::Schema->totalTime());
	}

	my %savePrefs;
	if (defined(my $pref_list = $request->getParam('prefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'server'} = \@prefs;

		for my $pref (@{$savePrefs{'server'}}) {
			if (defined(my $value = $prefs->get($pref))) {
				$request->addResult($pref, $value);
			}
		}
	}
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'player'} = \@prefs;

	}


	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');

	my $count = Slim::Player::Client::clientCount();
	$count += 0;

	$request->addResult('player count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		_addPlayersLoop($request, $start, $end, $savePrefs{'player'});
	}

	# return list of players connected to other servers
	my $other_players = Slim::Networking::Discovery::Players::getPlayerList();

	$count = scalar keys %{$other_players} || 0;

	$request->addResult('other player count', $count);

	($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $other_cnt = 0;

		for my $player ( keys %{$other_players} ) {
			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'playerid', $player
			);

			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'name', $other_players->{$player}->{name}
			);

			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'model', $other_players->{$player}->{model}
			);

			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'server', $other_players->{$player}->{server}
			);

			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'serverurl',
					Slim::Networking::Discovery::Server::getWebHostAddress($other_players->{$player}->{server})
			);

			$other_cnt++;
		}
	}

	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {

		# store the prefs array as private data so our filter above can find it back
		$request->privateData(\%savePrefs);

		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&serverstatusQuery_filter);
	}

	$request->setStatusDone();
}


sub signalstrengthQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['signalstrength']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	$request->addResult('_signalstrength', $client->signalStrength() || 0);

	$request->setStatusDone();
}


sub sleepQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['sleep']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	my $isValue = $client->sleepTime() - Time::HiRes::time();
	if ($isValue < 0) {
		$isValue = 0;
	}

	$request->addResult('_sleep', $isValue);

	$request->setStatusDone();
}


# the filter function decides, based on a notified request, if the status
# query must be re-executed.
sub statusQuery_filter {
	my $self = shift;
	my $request = shift;

	# retrieve the clientid, abort if not about us
	my $clientid   = $request->clientid() || return 0;
	my $myclientid = $self->clientid() || return 0;

	# Bug 10064: playlist notifications get sent to everyone in the sync-group
	if ($request->isCommand([['playlist', 'newmetadata']]) && (my $client = $request->client)) {
		return 0 if !grep($_->id eq $myclientid, $client->syncGroupActiveMembers());
	} elsif ($request->isCommand([['sync']])) {
		# Don't filter out notifications for sync commands. All players are notified
		# of the change in sync state regardless of whether they are "on" or "off".
	} else {
		return 0 if $clientid ne $myclientid;
	}

	# ignore most prefset commands, but e.g. alarmSnoozeSeconds needs to generate a playerstatus update
	if ( $request->isCommand( [['prefset', 'playerpref']] ) ) {
		my $prefname = $request->getParam('_prefname');
		if ( defined($prefname) && ( $prefname =~ /^(?:alarmSnoozeSeconds|digitalVolumeControl|libraryId)$/ ) ) {
			# this needs to pass through the filter
		}
		else {
			return 0;
		}
	}

	# commands we ignore
	return 0 if $request->isCommand([['ir', 'button', 'debug', 'pref', 'display']]);

	# special case: the client is gone!
	if ($request->isCommand([['client'], ['forget']])) {

		# pretend we do not need a client, otherwise execute() fails
		# and validate() deletes the client info!
		$self->needClient(0);

		# we'll unsubscribe above if there is no client
		return 1;
	}

	# suppress frequent updates during volume changes
	if ($request->isCommand([['mixer'], ['volume']])) {

		return 3;
	}

	# give it a tad more time for muting to leave room for the fade to finish
	# see bug 5255
	if ($request->isCommand([['mixer'], ['muting']])) {

		return 1.4;
	}

	# give it more time for stop as this is often followed by a new play
	# command (for example, with track skip), and the new status may be delayed
	if ($request->isCommand([['playlist'],['stop']])) {
		return 2.0;
	}

	# This is quite likely about to be followed by a 'playlist newsong' so
	# we only want to generate this if the newsong is delayed, as can be
	# the case with remote tracks.
	# Note that the 1.5s here and the 1s from 'playlist stop' above could
	# accumulate in the worst case.
	if ($request->isCommand([['playlist'], ['open', 'jump']])) {
		return 2.5;
	}

	# send every other notif with a small delay to accomodate
	# bursts of commands
	return 1.3;
}


sub statusQuery {
	my $request = shift;

	my $isDebug = main::DEBUGLOG && $log->is_debug;

	main::DEBUGLOG && $isDebug && $log->debug("statusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['status']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the initial parameters
	my $client = $request->client();
	my $menu = $request->getParam('menu');

	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $useContextMenu = $request->getParam('useContextMenu');

	# accomodate the fact we can be called automatically when the client is gone
	if (!defined($client)) {
		$request->addResult('error', "invalid player");
		# Still need to (re)register the autoexec if this is a subscription so
		# that the subscription does not dissappear while a Comet client thinks
		# that it is still valid.
		goto do_it_again;
	}

	my $connected    = $client->connected() || 0;
	my $power        = $client->power();
	my $repeat       = Slim::Player::Playlist::repeat($client);
	my $shuffle      = Slim::Player::Playlist::shuffle($client);
	my $songCount    = Slim::Player::Playlist::count($client);

	my $idx = 0;


	# now add the data...

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', "1");
	}

	if ($client->needsUpgrade()) {
		$request->addResult('player_needs_upgrade', "1");
	}

	if ($client->isUpgrading()) {
		$request->addResult('player_is_upgrading', "1");
	}

	# add player info...
	if (my $name = $client->name()) {
		$request->addResult("player_name", $name);
	}
	$request->addResult("player_connected", $connected);
	$request->addResult("player_ip", $client->ipport()) if $connected;

	if (my $library_id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client)) {
		$request->addResult("library_id", $library_id);
		$request->addResult("library_name", Slim::Music::VirtualLibraries->getNameForId($library_id, $client));
	}

	# add showBriefly info
	if ($client->display->renderCache->{showBriefly}
		&& $client->display->renderCache->{showBriefly}->{line}
		&& $client->display->renderCache->{showBriefly}->{ttl} > time()) {
		$request->addResult('showBriefly', $client->display->renderCache->{showBriefly}->{line});
	}

	if ($client->isPlayer()) {
		$power += 0;
		$request->addResult("power", $power);
	}

	if ($client->isa('Slim::Player::Squeezebox')) {
		$request->addResult("signalstrength", ($client->signalStrength() || 0));
	}

	my $playlist_cur_index;

	$request->addResult('mode', Slim::Player::Source::playmode($client));
	if ($client->isPlaying() && !$client->isPlaying('really')) {
		$request->addResult('waitingToPlay', 1);
	}

	if (my $song = $client->playingSong()) {

		if ($song->isRemote()) {
			$request->addResult('remote', 1);
			$request->addResult('current_title',
				Slim::Music::Info::getCurrentTitle($client, $song->currentTrack()->url));
		}

		$request->addResult('time',
			Slim::Player::Source::songTime($client));

		# This is just here for backward compatibility with older SBC firmware
		$request->addResult('rate', 1);

		if (my $dur = $song->duration()) {
			$dur += 0;
			$request->addResult('duration', $dur);
		}

		my $canSeek = Slim::Music::Info::canSeek($client, $song);
		if ($canSeek) {
			$request->addResult('can_seek', 1);
		}

		my $trackGain = Slim::Player::ReplayGain->fetchGainMode($client, $song);
		if (defined $trackGain) {
			$request->addResult('replay_gain', $trackGain);
		}
	}

	if ($client->currentSleepTime()) {

		my $sleep = $client->sleepTime() - Time::HiRes::time();
		$request->addResult('sleep', $client->currentSleepTime() * 60);
		$request->addResult('will_sleep_in', ($sleep < 0 ? 0 : $sleep));
	}

	if ($client->isSynced()) {

		my $master = $client->master();

		$request->addResult('sync_master', $master->id());

		my @slaves = Slim::Player::Sync::slaves($master);
		my @sync_slaves = map { $_->id } @slaves;

		$request->addResult('sync_slaves', join(",", @sync_slaves));
	}

	if ($client->hasVolumeControl()) {
		# undefined for remote streams
		my $vol = $prefs->client($client)->get('volume');
		$vol += 0;
		$request->addResult("mixer volume", $vol);
	}

	if ($client->maxBass() - $client->minBass() > 0) {
		$request->addResult("mixer bass", $client->bass());
	}

	if ($client->maxTreble() - $client->minTreble() > 0) {
		$request->addResult("mixer treble", $client->treble());
	}

	if ($client->maxPitch() - $client->minPitch()) {
		$request->addResult("mixer pitch", $client->pitch());
	}

	$repeat += 0;
	$request->addResult("playlist repeat", $repeat);
	$shuffle += 0;
	$request->addResult("playlist shuffle", $shuffle);

	# Backwards compatibility - now obsolete
	$request->addResult("playlist mode", 'off');

	if (defined $client->sequenceNumber()) {
		$request->addResult("seq_no", $client->sequenceNumber());
	}

	if (defined (my $playlistObj = $client->currentPlaylist())) {
		$request->addResult("playlist_id", $playlistObj->id());
		$request->addResult("playlist_name", $playlistObj->title());
		$request->addResult("playlist_modified", $client->currentPlaylistModified());
	}

	if ($songCount > 0) {
		$playlist_cur_index = Slim::Player::Source::playingSongIndex($client);
		$request->addResult(
			"playlist_cur_index",
			$playlist_cur_index
		);
		$request->addResult("playlist_timestamp", $client->currentPlaylistUpdateTime());
	}

	$request->addResult("playlist_tracks", $songCount);

	# send client pref for digital volume control
	my $digitalVolumeControl = $prefs->client($client)->get('digitalVolumeControl');
	if ( defined($digitalVolumeControl) ) {
		$request->addResult('digital_volume_control', $digitalVolumeControl + 0);
	}

	if ($menuMode || $request->getParam('alarmData')) {
		# send information about the alarm state to SP
		my $alarmNext    = Slim::Utils::Alarm->alarmInNextDay($client);
		my $alarmComing  = $alarmNext ? 'set' : 'none';
		my $alarmCurrent = Slim::Utils::Alarm->getCurrentAlarm($client);
		# alarm_state
		# 'active': means alarm currently going off
		# 'set':    alarm set to go off in next 24h on this player
		# 'none':   no alarm set to go off in next 24h on this player
		# 'snooze': alarm is active but currently snoozing
		if (defined($alarmCurrent)) {
			my $snoozing     = $alarmCurrent->snoozeActive();
			if ($snoozing) {
				$request->addResult('alarm_state', 'snooze');
				$request->addResult('alarm_next', 0);
			} else {
				$request->addResult('alarm_state', 'active');
				$request->addResult('alarm_next', 0);
			}
		} else {
			$request->addResult('alarm_state', $alarmComing);
			$request->addResult('alarm_next', defined $alarmNext ? $alarmNext + 0 : 0);
		}

		# NEW ALARM CODE
		# Add alarm version so a player can do the right thing
		$request->addResult('alarm_version', 2);

		# The alarm_state and alarm_next are only good for an alarm in the next 24 hours
		#  but we need the next alarm (which could be further away than 24 hours)
		my $alarmNextAlarm = Slim::Utils::Alarm->getNextAlarm($client);

		if($alarmNextAlarm and $alarmNextAlarm->enabled()) {
			# Get epoch seconds
			my $alarmNext2 = $alarmNextAlarm->nextDue();
			$request->addResult('alarm_next2', $alarmNext2);
			# Get repeat status
			my $alarmRepeat = $alarmNextAlarm->repeat();
			$request->addResult('alarm_repeat', $alarmRepeat);
			# Get days alarm is active
			my $alarmDays = "";
			for my $i (0..6) {
				$alarmDays .= $alarmNextAlarm->day($i) ? "1" : "0";
			}
			$request->addResult('alarm_days', $alarmDays);
		}

		# send client pref for alarm snooze
		my $alarm_snooze_seconds = $prefs->client($client)->get('alarmSnoozeSeconds');
		$request->addResult('alarm_snooze_seconds', defined $alarm_snooze_seconds ? $alarm_snooze_seconds + 0 : 540);

		# send client pref for alarm timeout
		my $alarm_timeout_seconds = $prefs->client($client)->get('alarmTimeoutSeconds');
		$request->addResult('alarm_timeout_seconds', defined $alarm_timeout_seconds ? $alarm_timeout_seconds + 0 : 300);
	}

	if ($menuMode) {
		# send which presets are defined
		my $presets = $prefs->client($client)->get('presets');
		my $presetLoop;
		my $presetData; # send detailed preset data in a separate loop so we don't break backwards compatibility
		for my $i (0..9) {
			if ( ref($presets) eq 'ARRAY' && defined $presets->[$i] ) {
				if ( ref($presets->[$i]) eq 'HASH') {
				$presetLoop->[$i] = 1;
					for my $key (keys %{$presets->[$i]}) {
						if (defined $presets->[$i]->{$key}) {
							$presetData->[$i]->{$key} = $presets->[$i]->{$key};
						}
					}
			} else {
				$presetLoop->[$i] = 0;
					$presetData->[$i] = {};
			}
			} else {
				$presetLoop->[$i] = 0;
				$presetData->[$i] = {};
		}
		}
		$request->addResult('preset_loop', $presetLoop);
		$request->addResult('preset_data', $presetData);

		main::DEBUGLOG && $isDebug && $log->debug("statusQuery(): setup base for jive");
		$songCount += 0;
		# add two for playlist save/clear to the count if the playlist is non-empty
		my $menuCount = $songCount?$songCount+2:0;

		$request->addResult("count", $menuCount);

		my $base;
		if ( $useContextMenu ) {
			# context menu for 'more' action
			$base->{'actions'}{'more'} = _contextMenuBase('track');
			# this is the current playlist, so tell SC the context of this menu
			$base->{'actions'}{'more'}{'params'}{'context'} = 'playlist';
		} else {
			$base = {
				actions => {
					go => {
						cmd => ['trackinfo', 'items'],
						params => {
							menu => 'nowhere',
							useContextMenu => 1,
							context => 'playlist',
						},
						itemsParams => 'params',
					},
				},
			};
		}
		$request->addResult('base', $base);
	}

	if ($songCount > 0) {

		main::DEBUGLOG && $isDebug && $log->debug("statusQuery(): setup non-zero player response");
		# get the other parameters
		my $tags     = $request->getParam('tags') || '';
		my $index    = $request->getParam('_index');
		my $quantity = $request->getParam('_quantity');

		my $loop = $menuMode ? 'item_loop' : 'playlist_loop';
		my $totalOnly;

		if ( $menuMode ) {
			# Set required tags for menuMode
			$tags = 'aAlKNcxJ';
		}
		# DD - total playtime for the current playlist, nothing else returned
		elsif ( $tags =~ /DD/ ) {
			$totalOnly = 1;
			$tags = 'd';
			$index = 0;
			$quantity = $songCount;
		}
		else {
			$tags = 'gald' if !defined $tags;
		}

		# we can return playlist data.
		# which mode are we in?
		my $modecurrent = 0;

		if (defined($index) && ($index eq "-")) {
			$modecurrent = 1;
		}

		# bug 9132: rating might have changed
		# we need to be sure we have the latest data from the DB if ratings are requested
		my $refreshTrack = $tags =~ /R/;

		my $track;

		if (!$totalOnly) {
			$track = Slim::Player::Playlist::track($client, $playlist_cur_index, $refreshTrack);

			if ($track->remote) {
				$tags .= "B" unless $totalOnly; # include button remapping
				my $metadata = _songData($request, $track, $tags);
				$request->addResult('remoteMeta', $metadata);
			}
		}

		# if repeat is 1 (song) and modecurrent, then show the current song
		if ($modecurrent && ($repeat == 1) && $quantity && !$totalOnly) {

			$request->addResult('offset', $playlist_cur_index) if $menuMode;

			if ($menuMode) {
				_addJiveSong($request, $loop, 0, $playlist_cur_index, $track);
			}
			else {
				_addSong($request, $loop, 0,
					$track, $tags,
					'playlist index', $playlist_cur_index
				);
			}

		} else {

			my ($valid, $start, $end);

			if ($modecurrent) {
				($valid, $start, $end) = $request->normalize($playlist_cur_index, scalar($quantity), $songCount);
			} else {
				($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $songCount);
			}

			if ($valid) {
				my $count = 0;
				$start += 0;
				$request->addResult('offset', $request->getParam('_index')) if $menuMode;

				my (@tracks, @trackIds);
				foreach my $track ( Slim::Player::Playlist::songs($client, $start, $end) ) {
					next unless defined $track;

					if ( $track->remote ) {
						push @tracks, $track;
					}
					else {
						push @tracks, $track->id;
						push @trackIds, $tracks[-1];
					}
				}

				# get hash of tagged data for all tracks
				my $songData = _getTagDataForTracks( $tags, {
					trackIds => \@trackIds,
				} ) if scalar @trackIds;

				# no need to use Tie::IxHash to preserve order when we return JSON Data
				my $fast = ($totalOnly || ($request->source && $request->source =~ m{/slim/request\b|JSONRPC|internal})) ? 1 : 0;

				# Slice and map playlist to get only the requested IDs
				$idx = $start;
				my $totalDuration = 0;

				foreach( @tracks ) {
					# Use songData for track, if remote use the object directly
					my $data = ref $_ ? $_ : $songData->{$_};

					# 17352 - when the db is not fully populated yet, and a stored player playlist
					# references a track not in the db yet, we can fail
					next if !$data;

					if ($totalOnly) {
						my $trackData = _songData($request, $data, $tags, $fast);
						$totalDuration += $trackData->{duration};
					}
					elsif ($menuMode) {
						_addJiveSong($request, $loop, $count, $idx, $data);
						# add clear and save playlist items at the bottom
						if ( ($idx+1)  == $songCount) {
							_addJivePlaylistControls($request, $loop, $count);
						}
					}
					else {
						_addSong(	$request, $loop, $count,
									$data, $tags,
									'playlist index', $idx, $fast
								);
					}

					$count++;
					$idx++;

					# give peace a chance...
					# This is need much less now that the DB query is done ahead of time
					main::idleStreams() if ! ($count % 20);
				}

				if ($totalOnly) {
					$request->addResult('playlist duration', $totalDuration || 0);
				}

				# we don't do that in menu mode!
				if (!$menuMode && !$totalOnly) {

					my $repShuffle = $prefs->get('reshuffleOnRepeat');
					my $canPredictFuture = ($repeat == 2)  			# we're repeating all
											&& 						# and
											(	($shuffle == 0)		# either we're not shuffling
												||					# or
												(!$repShuffle));	# we don't reshuffle

					if ($modecurrent && $canPredictFuture && ($count < scalar($quantity))) {

						# XXX: port this to use _getTagDataForTracks

						# wrap around the playlist...
						($valid, $start, $end) = $request->normalize(0, (scalar($quantity) - $count), $songCount);

						if ($valid) {

							for ($idx = $start; $idx <= $end; $idx++){

								_addSong($request, $loop, $count,
									Slim::Player::Playlist::track($client, $idx, $refreshTrack), $tags,
									'playlist index', $idx
								);

								$count++;
								main::idleStreams();
							}
						}
					}

				}
			}
		}
	}

do_it_again:
	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
		main::DEBUGLOG && $isDebug && $log->debug("statusQuery(): setting up subscription");

		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&statusQuery_filter);
	}

	$request->setStatusDone();
}

sub songinfoQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['songinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $tags  = 'abcdefghijJklmnopqrstvwxyzBCDEFHIJKLMNOQRTUVWXY'; # all letter EXCEPT u, A & S, G & P, Z
	my $track;

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $url	     = $request->getParam('url');
	my $trackID  = $request->getParam('track_id');
	my $tagsprm  = $request->getParam('tags');

	if (!defined $trackID && !defined $url) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	# find the track
	if (defined $trackID){

		$track = Slim::Schema->find('Track', $trackID);

	} else {

		if ( defined $url ){

			$track = Slim::Schema->objectForUrl($url);
		}
	}

	# now build the result

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (blessed($track) && $track->can('id')) {

		my $trackId = $track->id();
		$trackId += 0;

		my $hashRef = _songData($request, $track, $tags);
		my $count = scalar (keys %{$hashRef});

		$count += 0;

		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		my $loopname = 'songinfo_loop';
		my $chunkCount = 0;

		if ($valid) {

			# this is where we construct the nowplaying menu
			my $idx = 0;

			while (my ($key, $val) = each %{$hashRef}) {
				if ($idx >= $start && $idx <= $end) {

					$request->addResultLoop($loopname, $chunkCount, $key, $val);

					$chunkCount++;
				}
				$idx++;
			}
		}
	}

	$request->setStatusDone();
}


sub syncQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['sync']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	if ($client->isSynced()) {

		my @sync_buddies = map { $_->id() } $client->syncedWith();

		$request->addResult('_sync', join(",", @sync_buddies));
	} else {

		$request->addResult('_sync', '-');
	}

	$request->setStatusDone();
}


sub syncGroupsQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['syncgroups']])) {
		$request->setStatusBadDispatch();
		return;
	}


	my $cnt      = 0;
	my @players  = Slim::Player::Client::clients();
	my $loopname = 'syncgroups_loop';

	if (scalar(@players) > 0) {

		for my $eachclient (@players) {

			# create a group if $eachclient is a master
			if ($eachclient->isSynced() && Slim::Player::Sync::isMaster($eachclient)) {
				my @sync_buddies = map { $_->id() } $eachclient->syncedWith();
				my @sync_names   = map { $_->name() } $eachclient->syncedWith();

				$request->addResultLoop($loopname, $cnt, 'sync_members', join(",", $eachclient->id, @sync_buddies));
				$request->addResultLoop($loopname, $cnt, 'sync_member_names', join(",", $eachclient->name, @sync_names));

				$cnt++;
			}
		}
	}

	$request->setStatusDone();
}


sub timeQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['time', 'gototime']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	$request->addResult('_time', Slim::Player::Source::songTime($client));

	$request->setStatusDone();
}

# this query is to provide a list of tracks for a given artist/album etc.

sub titlesQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['titles', 'tracks', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $tags = 'gald';

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tagsprm       = $request->getParam('tags');
	my $sort          = $request->getParam('sort') || 'title';
	my $search        = $request->getParam('search');
	my $genreID       = $request->getParam('genre_id');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $trackID       = $request->getParam('track_id');
	my $roleID        = $request->getParam('role_id');
	my $libraryID     = Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id'));
	my $year          = $request->getParam('year');
	my $menuStyle     = $request->getParam('menuStyle') || 'item';
	my $releaseType   = $request->getParam('release_type');
	my $workID        = $request->getParam('work_id');
	my $ignoreWorkTracks = $request->getParam('ignore_work_tracks');
	my $grouping      = $request->getParam('grouping');

	# did we have override on the defaults?
	# note that this is not equivalent to
	# $val = $param || $default;
	# since when $default eq '' -> $val eq $param
	$tags = $tagsprm if defined $tagsprm;

	my $collate  = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	my $where    = '(tracks.content_type != "cpl" AND tracks.content_type != "src" AND tracks.content_type != "ssp" AND tracks.content_type != "dir" ';
	$where .= $ignoreWorkTracks ? 'AND tracks.work IS NULL)' : ')';
	my $order_by = "tracks.titlesort $collate";

	if ($sort) {
		if ($sort eq 'tracknum') {
			$tags .= 't';
			$order_by = "tracks.disc, tracks.tracknum, tracks.titlesort $collate"; # XXX titlesort had prepended 0
		}
		elsif ( $sort =~ /^sql=(.+)/ ) {
			$order_by = $1;
			$order_by =~ s/;//g; # strip out any attempt at combining SQL statements
		}
		elsif ($sort eq 'albumtrack') {
			$tags .= 'tl';
			$order_by = "albums.titlesort, tracks.disc, tracks.tracknum, tracks.titlesort $collate"; # XXX titlesort had prepended 0
		}
		# when sorting by title and we're including albums and all that, sort by album, artist etc. too
		elsif ($sort eq 'title' && $tags =~ /[as]/ && $tags =~ /[el]/) {
			$order_by = "tracks.titlesort, contributors.namesort, albums.titlesort, tracks.year $collate";
		}
	}

	$tags .= 'R' if $search && $search =~ /tracks_persistent\.rating/ && $tags !~ /R/;
	$tags .= 'O' if $search && $search =~ /tracks_persistent\.playcount/ && $tags !~ /O/;

	my $stillScanning = Slim::Music::Import->stillScanning();

	my $count;
	my $start;
	my $end;

	my ($items, $itemOrder, $totalCount) = _getTagDataForTracks( $tags, {
		where         => $where,
		sort          => $order_by,
		search        => $search,
		albumId       => $albumID,
		year          => $year,
		genreId       => $genreID,
		contributorId => $contributorID,
		trackId       => $trackID,
		roleId        => $roleID,
		releaseType   => $releaseType,
		workId	      => $workID,
		libraryId     => $libraryID,
		grouping      => $grouping,
		limit         => sub {
			$count = shift;

			my $valid;

			($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

			return ($valid, $index, $quantity);
		},
	} );

	if ($stillScanning) {
		$request->addResult("rescan", 1);
	}

	$count += 0;

	my $loopname = 'titles_loop';
	# this is the count of items in this part of the request (e.g., menu 100 200)
	# not to be confused with $count, which is the count of the entire list
	my $chunkCount = 0;

	if ( scalar @{$itemOrder} ) {

		for my $trackId ( @{$itemOrder} ) {
			my $item = $items->{$trackId};

			_addSong($request, $loopname, $chunkCount, $item, $tags);

			$chunkCount++;
		}

	}

	$request->addResult('count', $totalCount);

	$request->setStatusDone();
}


sub versionQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['version']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the version query

	$request->addResult('_version', $::VERSION);

	$request->setStatusDone();
}


sub yearsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['years']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}

	my $sqllog = main::DEBUGLOG && logger('database.sql');

	# get our parameters
	my $client        = $request->client();
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $year          = $request->getParam('year');
	my $libraryID     = Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id'));
	my $hasAlbums     = $request->getParam('hasAlbums');

	# get them all by default
	my $where = {};

	my ($key, $table) = ($hasAlbums || $libraryID) ? ('albums.year', 'albums') : ('id', 'years');

	my $sql = "SELECT DISTINCT $key FROM $table ";
	my $w   = ["$key != '0'"];
	my $p   = [];

	if (defined $year) {
		push @{$w}, "$key = ?";
		push @{$p}, $year;
	}

	if (defined $libraryID) {
		$sql .= 'JOIN tracks ON tracks.album = albums.id ';
		$sql .= 'JOIN library_track ON library_track.track = tracks.id ';
		push @{$w}, 'library_track.library = ?';
		push @{$p}, $libraryID;
	}

	if ( @{$w} ) {
		$sql .= 'WHERE ';
		$sql .= join( ' AND ', @{$w} );
		$sql .= ' ';
	}

	my $dbh = Slim::Schema->dbh;

	# Get count of all results, the count is cached until the next rescan done event
	my $cacheKey = md5_hex($sql . join( '', @{$p} ) . Slim::Music::VirtualLibraries->getLibraryIdForClient($client));

	my $count = $cache->{$cacheKey};
	if ( !$count ) {
		my $total_sth = $dbh->prepare_cached( qq{
			SELECT COUNT(1) FROM ( $sql ) AS t1
		} );

		$total_sth->execute( @{$p} );
		($count) = $total_sth->fetchrow_array();
		$total_sth->finish;
	}

	$sql .= "ORDER BY $key DESC";

	# now build the result

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'years_loop';
		my $chunkCount = 0;


		# Limit the real query
		if ( $index =~ /^\d+$/ && $quantity =~ /^\d+$/ ) {
			$sql .= " LIMIT $index, $quantity ";
		}

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Years query: $sql / " . Data::Dump::dump($p) );
		}

		my $sth = $dbh->prepare_cached($sql);
		$sth->execute( @{$p} );

		my $id;
		$sth->bind_columns(\$id);

		while ( $sth->fetch ) {
			$id += 0;

			$request->addResultLoop($loopname, $chunkCount, 'year', $id);

			$chunkCount++;
		}
	}

	$request->addResult('count', $count);

	$request->setStatusDone();
}

sub worksQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['works']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}

	my $sqllog = main::DEBUGLOG && logger('database.sql');

	# get our parameters
	my $client        = $request->client();
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tags          = $request->getParam('tags');
	my $search        = $request->getParam('search');
	my $libraryID     = Slim::Music::VirtualLibraries->getRealId($request->getParam('library_id'));
	my $artistID      = $request->getParam('artist_id');
	my $workID        = $request->getParam('work_id');
	my $roleID        = $request->getParam('role_id');

	# get them all by default
	my $where = {};
	my $w   = ["tracks.work IS NOT NULL"];
	my $p   = [];

	my $columns = "works.title, works.id, composer.name, composer.id, composer.namesort, works.titlesort";

	my $sql = 'SELECT %s FROM tracks
		JOIN contributor_track composer_track ON composer_track.track = tracks.id AND composer_track.role = 2 
		JOIN contributors composer ON composer.id = composer_track.contributor 
		JOIN contributor_track ON contributor_track.track = tracks.id 
		JOIN contributors ON contributors.id = contributor_track.contributor 
		JOIN works ON works.id = tracks.work AND works.composer = composer.id ';

	my $page_key = "SUBSTR(composer.namesort,1,1)";

	if (specified($search)) {
		if ( Slim::Schema->canFulltextSearch ) {
			Slim::Plugin::FullTextSearch::Plugin->createHelperTable({
				name   => 'worksSearch',
				search => $search,
				type   => 'work',
			});
			$sql .= "JOIN worksSearch ON works.id = worksSearch.id ";
		} else {
			my $strings = Slim::Utils::Text::searchStringSplit($search);
			if ( ref $strings->[0] eq 'ARRAY' ) {
				push @{$w}, '(' . join( ' OR ', map { 'works.titlesearch LIKE ?' } @{ $strings->[0] } ) . ')';
				push @{$p}, @{ $strings->[0] };
			}
			else {
				push @{$w}, 'works.titlesearch LIKE ?';
				push @{$p}, @{$strings};
			}
		}
	}

	if ( defined $roleID ) {
		my @roles = split(',', $roleID);
		if (scalar @roles) {
			push @{$p}, map { Slim::Schema::Contributor->typeToRole($_) } @roles;
			push @{$w}, 'contributor_track.role IN (' . join(', ', map {'?'} @roles) . ')';
		}
	}

	if (defined $workID) {
		push @{$w}, "works.id = ?";
		push @{$p}, $workID;
	}

	if (defined $artistID) {
		push @{$w}, "contributors.id = ?";
		push @{$p}, $artistID;
	}

	if (defined $libraryID) {
		$sql .= 'JOIN library_track ON library_track.track = tracks.id ';
		push @{$w}, 'library_track.library = ?';
		push @{$p}, $libraryID;
	}

	if ( @{$w} ) {
		$sql .= 'WHERE ';
		$sql .= join( ' AND ', @{$w} );
		$sql .= ' ';
	}

	$sql .= " GROUP BY $columns ";

	my $order_by = "ORDER BY composer.namesort, works.titlesort";

	my $dbh = Slim::Schema->dbh;

	if ($page_key && $tags =~ /Z/) {
		$request->addResult('indexList', _createIndexList(sprintf($sql, "$page_key AS n") . " $order_by", $p));

		if ($tags =~ /ZZ/) {
			$request->setStatusDone();
			return
		}
	}

	$sql = sprintf($sql, $columns);

	# Get count of all results, the count is cached until the next rescan done event
	my $cacheKey = md5_hex($sql . join( '', @{$p} ) . Slim::Music::VirtualLibraries->getLibraryIdForClient($client));

	my $count = $cache->{$cacheKey};
	if ( !$count ) {
		my $total_sth = $dbh->prepare_cached( qq{
			SELECT COUNT(1) FROM ( $sql ) AS t1
		} );

		$total_sth->execute( @{$p} );
		($count) = $total_sth->fetchrow_array();
		$total_sth->finish;
	}

#	$sql .= $artistID ?  "ORDER BY composer.namesort, works.titlesort" : "ORDER BY works.titlesort, composer.namesort";
	$sql .= $order_by;

	# now build the result

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'works_loop';
		my $chunkCount = 0;


		# Limit the real query
		if ( $index =~ /^\d+$/ && $quantity =~ /^\d+$/ ) {
			$sql .= " LIMIT $index, $quantity ";
		}

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Works query: $sql / " . Data::Dump::dump($p) );
		}

		my $sth = $dbh->prepare_cached($sql);
		$sth->execute( @{$p} );

		my ($work, $workId, $composer, $composerId, $nameSort, $titleSort );
		$sth->bind_columns(\$work, \$workId, \$composer, \$composerId, \$nameSort, \$titleSort);

		while ( $sth->fetch ) {
			#$id += 0;
			utf8::decode($work) if $work;
			utf8::decode($composer) if $composer;
			$request->addResultLoop($loopname, $chunkCount, 'work', $work);
			$request->addResultLoop($loopname, $chunkCount, 'work_id', $workId);
			$request->addResultLoop($loopname, $chunkCount, 'composer', $composer);
			$request->addResultLoop($loopname, $chunkCount, 'composer_id', $composerId);
#			$request->addResultLoop($loopname, $chunkCount, 'year', $year);
#			$request->addResultLoop($loopname, $chunkCount, 'from_search', $search) if $search;

			my $textKey;
			utf8::decode( $nameSort ) if $nameSort;
			$textKey = substr $nameSort, 0, 1;
			$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'textkey', $textKey);

			$chunkCount++;

		}
	}

	$request->addResult('count', $count);

	$request->setStatusDone();
}

################################################################################
# Special queries
################################################################################

=head2 dynamicAutoQuery( $request, $query, $funcptr, $data )

 This function is a helper function for any query that needs to poll enabled
 plugins. In particular, this is used to implement the CLI radios query,
 that returns all enabled radios plugins. This function is best understood
 by looking as well in the code used in the plugins.

 Each plugins does in initPlugin (edited for clarity):

    $funcptr = addDispatch(['radios'], [0, 1, 1, \&cli_radiosQuery]);

 For the first plugin, $funcptr will be undef. For all the subsequent ones
 $funcptr will point to the preceding plugin cli_radiosQuery() function.

 The cli_radiosQuery function looks like:

    sub cli_radiosQuery {
      my $request = shift;

      my $data = {
         #...
      };

      dynamicAutoQuery($request, 'radios', $funcptr, $data);
    }

 The plugin only defines a hash with its own data and calls dynamicAutoQuery.

 dynamicAutoQuery will call each plugin function recursively and add the
 data to the request results. It checks $funcptr for undefined to know if
 more plugins are to be called or not.

=cut

sub dynamicAutoQuery {
	my $request = shift;                       # the request we're handling
	my $query   = shift || return;             # query name
	my $funcptr = shift;                       # data returned by addDispatch
	my $data    = shift || return;             # data to add to results

	# check this is the correct query.
	if ($request->isNotQuery([[$query]])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity') || 0;
	my $sort     = $request->getParam('sort');
	my $menu     = $request->getParam('menu');

	my $menuMode = defined $menu;

	# we have multiple times the same resultset, so we need a loop, named
	# after the query name (this is never printed, it's just used to distinguish
	# loops in the same request results.
	my $loop = $menuMode?'item_loop':$query . 's_loop';

	# if the caller asked for results in the query ("radios 0 0" returns
	# immediately)
	if ($quantity) {

		# add the data to the results
		my $cnt = $request->getResultLoopCount($loop) || 0;

		if ( ref $data eq 'HASH' && scalar keys %{$data} ) {
			$data->{weight} = $data->{weight} || 1000;
			$request->setResultLoopHash($loop, $cnt, $data);
		}

		# more to jump to?
		# note we carefully check $funcptr is not a lemon
		if (defined $funcptr && ref($funcptr) eq 'CODE') {

			eval { &{$funcptr}($request) };

			# arrange for some useful logging if we fail
			if ($@) {

				logError("While trying to run function coderef: [$@]");
				$request->setStatusBadDispatch();
				$request->dump('Request');

			}
		}

		# $funcptr is undefined, we have everybody, now slice & count
		else {

			# sort if requested to do so
			if ($sort) {
				$request->sortResultLoop($loop, $sort);
			}

			# slice as needed
			my $count = $request->getResultLoopCount($loop);
			$request->sliceResultLoop($loop, $index, $quantity);
			$request->addResult('offset', $request->getParam('_index')) if $menuMode;
			$count += 0;
			$request->setResultFirst('count', $count);

			# don't forget to call that to trigger notifications, if any
			$request->setStatusDone();
		}
	}
	else {
		$request->setStatusDone();
	}
}

################################################################################
# Helper functions
################################################################################

sub _addSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $index     = shift; # loop index
	my $pathOrObj = shift; # song path or object, or hash from titlesQuery
	my $tags      = shift; # tags to use
	my $prefixKey = shift; # prefix key, if any
	my $prefixVal = shift; # prefix value, if any
	my $fast      = shift;

	# get the hash with the data
	my $hashRef = _songData($request, $pathOrObj, $tags, $fast);

	# add the prefix in the first position, use a fancy feature of
	# Tie::LLHash
	if (defined $prefixKey && defined $hashRef) {
		if ($fast) {
			$hashRef->{$prefixKey} = $prefixVal;
		}
		else {
			(tied %{$hashRef})->Unshift($prefixKey => $prefixVal);
		}
	}

	# add it directly to the result loop
	$request->setResultLoopHash($loop, $index, $hashRef);
}

sub _addJivePlaylistControls {

	my ($request, $loop, $count) = @_;

	my $client = $request->client || return;

	# clear playlist
	my $text = $client->string('CLEAR_PLAYLIST');
	# add clear playlist and save playlist menu items
	$count++;
	my @clear_playlist = (
		{
			text    => $client->string('CANCEL'),
			actions => {
				go => {
					player => 0,
					cmd    => [ 'jiveblankcommand' ],
				},
			},
			nextWindow => 'parent',
		},
		{
			text    => $client->string('CLEAR_PLAYLIST'),
			actions => {
				do => {
					player => 0,
					cmd    => ['playlist', 'clear'],
				},
			},
			nextWindow => 'home',
		},
	);

	$request->addResultLoop($loop, $count, 'text', $text);
	$request->addResultLoop($loop, $count, 'icon-id', '/html/images/playlistclear.png');
	$request->addResultLoop($loop, $count, 'offset', 0);
	$request->addResultLoop($loop, $count, 'count', 2);
	$request->addResultLoop($loop, $count, 'item_loop', \@clear_playlist);

	# save playlist
	my $input = {
		len          => 1,
		allowedChars => $client->string('JIVE_ALLOWEDCHARS_WITHCAPS'),
		help         => {
			text => $client->string('JIVE_SAVEPLAYLIST_HELP'),
		},
	};
	my $actions = {
		do => {
			player => 0,
			cmd    => ['playlist', 'save'],
			params => {
				playlistName => '__INPUT__',
			},
			itemsParams => 'params',
		},
	};
	$count++;

	# Save Playlist item
	$text = $client->string('SAVE_PLAYLIST');
	$request->addResultLoop($loop, $count, 'text', $text);
	$request->addResultLoop($loop, $count, 'icon-id', '/html/images/playlistsave.png');
	$request->addResultLoop($loop, $count, 'input', $input);
	$request->addResultLoop($loop, $count, 'actions', $actions);
}

# **********************************************************************
# *** This is a performance-critical method ***
# Take cake to understand the performance implications of any changes.

sub _addJiveSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $count     = shift; # loop index
	my $index     = shift; # playlist index
	my $track     = shift || return;

	my $songData  = _songData(
		$request,
		$track,
		'aAlKNcxJ',			# tags needed for our entities
	);

	my $isRemote = $songData->{remote};

	$request->addResultLoop($loop, $count, 'trackType', $isRemote ? 'radio' : 'local');

	my $text   = $songData->{title};
	my $title  = $text;
	my $album  = $songData->{album};
	my $artist = $songData->{artist};

	# Bug 15779, include other role data
	# XXX may want to include all contributor roles here?
	my (%artists, @artists);
	foreach ('albumartist', 'trackartist', 'artist') {

		next if !$songData->{$_};

		foreach my $a ( split (/, /, $songData->{$_}) ) {
			if ( $a && !$artists{$a} ) {
				push @artists, $a;
				$artists{$a} = 1;
			}
		}
	}
	$artist = join(', ', @artists);

	if ( $isRemote && $text && $album && $artist ) {
		$request->addResult('current_title');
	}

	my @secondLine;
	if (defined $artist) {
		push @secondLine, $artist;
	}
	if (defined $album) {
		push @secondLine, $album;
	}

	# Special case for Internet Radio streams, if the track is remote, has no duration,
	# has title metadata, and has no album metadata, display the station title as line 1 of the text
	if ( $songData->{remote_title} && $songData->{remote_title} ne $title && !$album && $isRemote && !$track->secs ) {
		push @secondLine, $songData->{remote_title};
		$album = $songData->{remote_title};
		$request->addResult('current_title');
	}

	my $secondLine = join(' - ', @secondLine);
	$text .= "\n" . $secondLine;

	# Bug 7443, check for a track cover before using the album cover
	my $iconId = $songData->{coverid} || $songData->{artwork_track_id};

	if ( defined($songData->{artwork_url}) ) {
		$request->addResultLoop( $loop, $count, 'icon', proxiedImage($songData->{artwork_url}) );
	}
	elsif ( defined $iconId ) {
		$request->addResultLoop($loop, $count, 'icon-id', proxiedImage($iconId));
	}
	elsif ( $isRemote ) {
		# send radio placeholder art for remote tracks with no art
		$request->addResultLoop($loop, $count, 'icon-id', '/html/images/radio.png');
	}

	# split to three discrete elements for NP screen
	if ( defined($title) ) {
		$request->addResultLoop($loop, $count, 'track', $title);
	} else {
		$request->addResultLoop($loop, $count, 'track', '');
	}
	if ( defined($album) ) {
		$request->addResultLoop($loop, $count, 'album', $album);
	} else {
		$request->addResultLoop($loop, $count, 'album', '');
	}
	if ( defined($artist) ) {
		$request->addResultLoop($loop, $count, 'artist', $artist);
	} else {
		$request->addResultLoop($loop, $count, 'artist', '');
	}
	# deliver as one formatted multi-line string for NP playlist screen
	$request->addResultLoop($loop, $count, 'text', $text);

	my $params = {
		'track_id' => ($songData->{'id'} + 0),
		'playlist_index' => $index,
	};
	$request->addResultLoop($loop, $count, 'params', $params);
	$request->addResultLoop($loop, $count, 'style', 'itemplay');
}


my %tagMap = (
	# Tag    Tag name             Token            Track method         Track field
	#------------------------------------------------------------------------------
	  'u' => ['url',              'LOCATION',      'url'],              #url
	  'o' => ['type',             'TYPE',          'content_type'],     #content_type
	                                                                    #titlesort
	                                                                    #titlesearch
	  'a' => ['artist',           'ARTIST',        'artistName'],       #->contributors
	  's' => ['artist_id',        '',              'artistid'],         #->contributors
	  'e' => ['album_id',         '',              'albumid'],          #album
	  'l' => ['album',            'ALBUM',         'albumname'],        #->album.title
	  't' => ['tracknum',         'TRACK',         'tracknum'],         #tracknum
	  'n' => ['modificationTime', 'MODTIME',       'modificationTime'], #timestamp
	  'D' => ['addedTime',        'ADDTIME',       'addedTime'],        #added_time
	  'U' => ['lastUpdated',      'UPDTIME',       'lastUpdated'],      #updated_time
	  'f' => ['filesize',         'FILELENGTH',    'filesize'],         #filesize
	                                                                    #tag
	  'i' => ['disc',             'DISC',          'disc'],             #disc
	  'j' => ['coverart',         'SHOW_ARTWORK',  'coverArtExists'],   #cover
	  'x' => ['remote',           '',              'remote'],           #remote
	                                                                    #audio
	                                                                    #audio_size
	                                                                    #audio_offset
	  'y' => ['year',             'YEAR',          'year'],             #year
	  'd' => ['duration',         'LENGTH',        'secs'],             #secs
	                                                                    #vbr_scale
	  'r' => ['bitrate',          'BITRATE',       'prettyBitRate'],    #bitrate
	  'T' => ['samplerate',       'SAMPLERATE',    'samplerate'],       #samplerate
	  'I' => ['samplesize',       'SAMPLESIZE',    'samplesize'],       #samplesize
	  'H' => ['channels',         'CHANNELS',      'channels'],         #channels
	  'F' => ['dlna_profile',     'DLNA_PROFILE',  'dlna_profile'],     #dlna_profile
	                                                                    #block_alignment
	                                                                    #endian
	  'm' => ['bpm',              'BPM',           'bpm'],              #bpm
	  'v' => ['tagversion',       'TAGVERSION',    'tagversion'],       #tagversion
	# 'z' => ['drm',              '',              'drm'],              #drm
	  'M' => ['musicmagic_mixable', '',            'musicmagic_mixable'], #musicmagic_mixable
	                                                                    #musicbrainz_id
	                                                                    #lastplayed
	  'Q' => ['lossless',         'LOSSLESS',      'lossless'],         #lossless
	  'w' => ['lyrics',           'LYRICS',        'lyrics'],           #lyrics
	  'R' => ['rating',           'RATING',        'rating'],           #rating
	  'O' => ['playcount',        'PLAYCOUNT',     'playcount'],        #playcount
	  'Y' => ['replay_gain',      'REPLAYGAIN',    'replay_gain'],      #replay_gain
	                                                                    #replay_peak

	  'c' => ['coverid',          'COVERID',       'coverid'],          # coverid
	  'K' => ['artwork_url',      '',              'coverurl'],         # artwork URL
	  'B' => ['buttons',          '',              'buttons'],          # radio stream special buttons
	  'L' => ['info_link',        '',              'info_link'],        # special trackinfo link
	  'N' => ['remote_title'],                                          # remote stream title
	  'E' => ['extid',            '',              'extid'],            # a track's external identifier (eg. on an online music service)
	  'V' => ['live_edge',        '',              'live_edge'],        # a remote live streams maximum available seek point in seconds within the current duration.

	  'g' => ['genre',            'GENRE',         'genrename'],        #->genre_track->genre.name
	  'p' => ['genre_id',         '',              'genreid'],          #->genre_track->genre.id

	# Tag    Tag name              Token              Relationship     Method          Track relationship
	#--------------------------------------------------------------------------------------------------
	  'A' => ['<role>',            '<ROLE>',          'contributors',  'name'],         #->contributors[role].name
	  'S' => ['<role>_ids',        '',                'contributors',  'id'],           #->contributors[role].id

	  'q' => ['disccount',         '',                'album',         'discc'],        #->album.discc
	  'J' => ['artwork_track_id',  'COVERART',        'album',         'artwork'],      #->album.artwork
	  'C' => ['compilation',       'COMPILATION',     'album',         'compilation'],  #->album.compilation
	  'W' => ['release_type',      'RELEASETYPE',     'album',         'release_type'], #->album.release_type
	  'X' => ['album_replay_gain', 'ALBUMREPLAYGAIN', 'album',         'replay_gain'],  #->album.replay_gain

	  'G' => ['genres',            'GENRE',           'genres',        'name'],         #->genre_track->genres.name
	  'P' => ['genre_ids',         '',                'genres',        'id'],           #->genre_track->genres.id

	  'k' => ['comment',           'COMMENT',         'comment'],                       #->comment_object

);

# Map tag -> column to avoid a huge if-else structure
my %colMap = (
	g => 'genres.name',
	G => 'genres',
	p => 'genres.id',
	P => 'genre_ids',
	a => 'contributors.name',
	's' => 'contributors.id',
	l => 'albums.title',
	e => 'tracks.album',
	d => 'tracks.secs',
	i => 'tracks.disc',
	q => 'albums.discc',
	t => 'tracks.tracknum',
	y => 'tracks.year',
	m => 'tracks.bpm',
	M => sub { $_[0]->{'tracks.musicmagic_mixable'} ? 1 : 0 },
 	Q => sub { $_[0]->{'tracks.lossless'} ? 1 : 0 },
	k => 'comment',
	o => 'tracks.content_type',
	v => 'tracks.tagversion',
	r => sub { Slim::Schema::Track->buildPrettyBitRate( $_[0]->{'tracks.bitrate'}, $_[0]->{'tracks.vbr_scale'} ) },
	f => 'tracks.filesize',
	j => sub { $_[0]->{'tracks.cover'} ? 1 : 0 },
	J => 'albums.artwork',
	n => 'tracks.timestamp',
	F => 'tracks.dlna_profile',
	D => 'tracks.added_time',
	U => 'tracks.updated_time',
	C => sub { $_[0]->{'albums.compilation'} ? 1 : 0 },
	Y => 'tracks.replay_gain',
	X => 'albums.replay_gain',
	R => 'tracks_persistent.rating',
	O => 'tracks_persistent.playcount',
	T => 'tracks.samplerate',
	I => 'tracks.samplesize',
	u => 'tracks.url',
	w => 'tracks.lyrics',
	W => 'albums.release_type',
	x => sub { $_[0]->{'tracks.remote'} ? 1 : 0 },
	c => 'tracks.coverid',
	H => 'tracks.channels',
	E => 'tracks.extid',
);

sub _songDataFromHash {
	my ( $request, $res, $tags, $fast ) = @_;

	my %returnHash;

	# define an ordered hash for our results
	tie (%returnHash, "Tie::IxHash") unless $fast;

	$returnHash{id}    = $res->{'tracks.id'};
	$returnHash{title} = $res->{'tracks.title'};
	$returnHash{work} = $res->{'works.title'};
	$returnHash{grouping} = $res->{'tracks.grouping'};

	my @contributorRoles = Slim::Schema::Contributor->contributorRoles;

	# loop so that stuff is returned in the order given...
	for my $tag (split (//, $tags)) {
		my $tagref = $tagMap{$tag} or next;

		# Special case for A/S which return multiple keys
		if ( $tag eq 'A' ) {
			# if we don't have an explicit track artist defined, we're going to assume the track's artist was the track artist
			if ( $res->{artist} && $res->{albumartist} && $res->{artist} ne $res->{albumartist} && !$res->{trackartist}) {
				$res->{trackartist} = $res->{artist};
				$res->{trackartist_ids} = $res->{artist_ids};
			}

			for my $role ( @contributorRoles ) {
				$role = lc $role;
				if ( defined $res->{$role} ) {
					$returnHash{$role} = $res->{$role};
				}
			}
		}
		elsif ( $tag eq 'S' ) {
			for my $role ( @contributorRoles ) {
				$role = lc $role;
				if ( defined $res->{"${role}_ids"} ) {
					$returnHash{"${role}_ids"} = $res->{"${role}_ids"};
				}
			}
		}
		# eg. the web UI is requesting some tags which are only available for remote tracks,
		# such as 'B' (custom button handler). They would return empty here - ignore them.
		elsif ( my $map = $colMap{$tag} ) {
			my $value = ref $map eq 'CODE' ? $map->($res) : $res->{$map};

			if (defined $value && $value ne '') {
				$returnHash{ $tagref->[0] } = $value;
			}
		}
	}

	return \%returnHash;
}

sub _songData {
	my $request   = shift; # current request object
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use
	my $fast      = shift; # don't use Tie::IxHash for performance

	if ( ref $pathOrObj eq 'HASH' ) {
		# Hash from direct DBI query in titlesQuery
		return _songDataFromHash($request, $pathOrObj, $tags, $fast);
	}

	# figure out the track object
	my $track = Slim::Schema->objectForUrl($pathOrObj);

	if (!blessed($track) || !$track->can('id')) {

		logError("Called with invalid object or path: $pathOrObj!");

		# For some reason, $pathOrObj may be an id... try that before giving up...
		if ($pathOrObj =~ /^\d+$/) {
			$track = Slim::Schema->find('Track', $pathOrObj);
		}

		if (!blessed($track) || !$track->can('id')) {

			logError("Can't make track from: $pathOrObj!");
			return;
		}
	}

	# If we have a remote track, check if a plugin can provide metadata
	my $remoteMeta = {};
	my $isRemote = $track->remote;
	my $url = $track->url;

	my $song;
	if ( my $client = $request->client ) {
		$song = $client->currentSongForUrl($url);
	}

	if ( $isRemote ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

		if ( $handler && $handler->can('getMetadataFor') ) {
			# Don't modify source data
			$remoteMeta = Storable::dclone(
				$handler->getMetadataFor( $request->client, $url )
			);

			$remoteMeta->{a} = $remoteMeta->{artist};
			$remoteMeta->{A} = $remoteMeta->{artist};
			$remoteMeta->{E} = $remoteMeta->{extid};
			$remoteMeta->{l} = $remoteMeta->{album};
			$remoteMeta->{i} = $remoteMeta->{disc};
			$remoteMeta->{K} = $remoteMeta->{cover};
			$remoteMeta->{d} = ( $remoteMeta->{duration} || $remoteMeta->{secs} || 0 ) + 0;
			$remoteMeta->{Y} = $remoteMeta->{replay_gain};
			$remoteMeta->{o} = $remoteMeta->{type};
			$remoteMeta->{r} = $remoteMeta->{bitrate};
			$remoteMeta->{B} = $remoteMeta->{buttons};
			$remoteMeta->{L} = $remoteMeta->{info_link};
			$remoteMeta->{t} = $remoteMeta->{tracknum};
			$remoteMeta->{y} = $remoteMeta->{year};
			$remoteMeta->{T} = $remoteMeta->{samplerate};
			$remoteMeta->{I} = $remoteMeta->{samplesize};
			$remoteMeta->{W} = $remoteMeta->{releasetype};

			# Distance from the live edge of live remote stream. -1 is not live, 0 is live at the edge, >0 is distance in seconds from the live edge.
			# $remoteMeta->{live_edge} contains distance from live edge. Will only be populated by 3rd party handlers that support dynamic adaptive live streams.
			$remoteMeta->{V} = $remoteMeta->{live_edge} // ($song && $song->isLive() ? 0 : -1);
		}
	}

	my $parentTrack;
	if ( $song ) {
		my $t = $song->currentTrack();
		if ($t->url ne $url) {
			$parentTrack = $track;
			$track = $t;
			$isRemote = $track->remote;
		}
	}

	my %returnHash;

	# define an ordered hash for our results
	tie (%returnHash, "Tie::IxHash") unless $fast;

	$returnHash{'id'}    = $track->id;
	$returnHash{'title'} = $remoteMeta->{title} || $track->title;
	my %seen;

	# loop so that stuff is returned in the order given...
	for my $tag (split (//, $tags)) {
		next if $seen{$tag}++;		# don't process tags multiple times

		my $tagref = $tagMap{$tag} or next;

		# special case, remote stream name
		if ($tag eq 'N') {
			if ($parentTrack) {
				$returnHash{$tagref->[0]} = $parentTrack->title;
			} elsif ( $isRemote && !$track->secs && $remoteMeta->{title} && !$remoteMeta->{album} ) {
				if (my $meta = $track->title) {
					$returnHash{$tagref->[0]} = $meta;
				}
			}
		}

		# special case for remote flag, since we had to evaluate it anyway
		# only include it if it is true
		elsif ($tag eq 'x' && $isRemote) {
			$returnHash{$tagref->[0]} = 1;
		}

		# special case artists (tag A and S)
		elsif ($tag eq 'A' || $tag eq 'S') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{artist} = $meta;
				next;
			}
			elsif ( $track->isa('Slim::Schema::RemoteTrack')) {
				next;
			}

			if ( defined(my $submethod = $tagref->[3]) ) {

				my $postfix = ($tag eq 'S')?"_ids":"";

				my $dbh = Slim::Schema->dbh;
				my $contributor_sth;

				if ($tag eq 'S') {
					$contributor_sth = $dbh->prepare_cached( q{
						SELECT DISTINCT contributor FROM contributor_track WHERE track = ? AND role = ?
					} );
				}
				else {
					$contributor_sth = $dbh->prepare_cached( q{
						SELECT DISTINCT contributors.name
						FROM contributor_track
							JOIN contributors ON contributors.id = contributor_track.contributor
						WHERE track = ? AND role = ?
					} );
				}

				foreach my $type (Slim::Schema::Contributor::contributorRoles()) {
					$contributor_sth->execute($returnHash{'id'}, Slim::Schema::Contributor->typeToRole($type));
					my $cons = $contributor_sth->fetchall_arrayref([0]);

					next unless scalar @$cons;

					my $value = join(', ', map { utf8::decode($_->[0]); $_->[0] } @$cons);

					if (defined $value && $value ne '') {
						my $key = lc($type) . $postfix;

						# add the tag to the result
						$returnHash{$key} = $value;
					}
				}
			}
		}

		# if we have a method/relationship for the tag
		elsif (defined(my $method = $tagref->[2])) {

			my $value;
			my $key = $tagref->[0];

			# Override with remote track metadata if available
			if ( defined $remoteMeta->{$tag} ) {
				$value = $remoteMeta->{$tag};
			}

			elsif ($method eq '' || !$track->can($method)) {
				next;
			}

			# tag with submethod
			elsif (defined(my $submethod = $tagref->[3])) {

				# call submethod
				if (defined(my $related = $track->$method)) {

					# array returned/genre
					if ( blessed($related) && $related->isa('Slim::Schema::ResultSet::Genre')) {
						$value = join(', ', map { $_ = $_->$submethod() } $related->all);
					} elsif ( $isRemote && !$related->can($submethod) ) {
						$value = $related;
					} else {
						$value = $related->$submethod();
					}
				}
			}

			# simple track method
			else {
				$value = $track->$method();
			}

			# correct values
			if ($tag eq 'R' && $value == 0) {
				$value = undef;
			}
			# we might need to proxy the image request to resize it
			elsif ($tag eq 'K' && $value) {
				$value = proxiedImage($value);
			}

			# if we have a value
			if (defined $value && $value ne '') {

				# add the tag to the result
				$returnHash{$key} = $value;
			}
		}
	}

	return \%returnHash;
}

# this is a silly little sub that allows jive cover art to be rendered in a large window
sub showArtwork {

	main::INFOLOG && $log->info("Begin showArtwork Function");
	my $request = shift;

	# get our parameters
	my $id = $request->getParam('_artworkid');

	if ($id =~ /:\/\//) {
		$request->addResult('artworkUrl'  => proxiedImage($id));
	} else {
		$request->addResult('artworkId'  => $id);
	}

	$request->addResult('offset', 0);
	$request->setStatusDone();

}

# Wipe cached data, called after a rescan
sub wipeCaches {
	my $bmfCacheObject = tied %bmfCache;
	tie %bmfCache, 'Tie::Cache::LRU::Expires', EXPIRES => $bmfCacheObject->{EXPIRES}, ENTRIES => $bmfCacheObject->{ENTRIES};

	$cache = {};
}

# fix the count in case we're adding additional items
# (VA etc.) to the resultset
sub _fixCount {
	my $insertItem = shift;
	my $index      = shift;
	my $quantity   = shift;
	my $count      = shift;

	my $totalCount = $count || 0;

	if ($insertItem) {
		$totalCount++;

		# return one less result as we only add the additional item in the first chunk
		if ( !$$index ) {
			$$quantity--;
		}

		# decrease the index in subsequent queries
		else {
			$$index--;
		}
	}

	return $totalCount;
}

# contextMenuQuery is a wrapper for producing context menus for various objects
sub contextMenuQuery {

	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['contextmenu']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');

	my $client        = $request->client();
	my $menu          = $request->getParam('menu');

	# this subroutine is just a wrapper, so we prep the @requestParams array to pass on to another command
	my $params = $request->getParamsCopy();
	my @requestParams = ();
	for my $key (keys %$params) {
		next if $key eq '_index' || $key eq '_quantity';
		push @requestParams, $key . ':' . $params->{$key};
	}

	my $proxiedRequest;
	if (defined($menu)) {
		# send the command to *info, where * is the param given to the menu command
		my $command = $menu . 'info';
		$proxiedRequest = Slim::Control::Request->new( $client->id, [ $command, 'items', $index, $quantity, @requestParams ] );

		# Bug 17357, propagate the connectionID as info handlers cache sessions based on this
		$proxiedRequest->connectionID( $request->connectionID );
		$proxiedRequest->execute();

		# Bug 13744, wrap async requests
		if ( $proxiedRequest->isStatusProcessing ) {
			$proxiedRequest->callbackFunction( sub {
				$request->setRawResults( $_[0]->getResults );
				$request->setStatusDone();
			} );

			$request->setStatusProcessing();
			return;
		}

	# if we get here, we punt
	} else {
		$request->setStatusBadParams();
	}

	# now we have the response in $proxiedRequest that needs to get its output sent via $request
	$request->setRawResults( $proxiedRequest->getResults );

}

# currently this sends back a callback that is only for tracks
# to be expanded to work with artist/album/etc. later
sub _contextMenuBase {

	my $menu = shift;

	return {
		player => 0,
		cmd => ['contextmenu', ],
			'params' => {
				'menu' => $menu,
			},
		itemsParams => 'params',
		window => {
			isContextMenu => 1,
		},
	};

}

sub _scanFailed {
	my ($request, $info) = @_;

	if ($info && $info eq 'SCAN_ABORTED') {
		$info = $request->string($info);
	}
	elsif ($info) {
		$info = $request->string('FAILURE_PROGRESS', $request->string($info . '_PROGRESS') || '?');
	}

	$request->addResult('lastscanfailed', $info || '?');
}

=pod
This method is used by both titlesQuery and statusQuery, it tries to get a bunch of data
about tracks as efficiently as possible.

	$tags - String of tags, see songinfo docs
	$args - {
		where         => additional raw SQL to be used in WHERE clause
		sort          => string to be used with ORDER BY
		search        => titlesearch
		albumId       => return tracks for this album ID
		year          => return tracks for this year
		genreId       => return tracks for this genre ID
		contributorId => return tracks for this contributor ID
		trackIds      => arrayref of track IDs to fetch
		limit         => a coderef that is passed the count and returns (valid, start, end)
		                 If valid is not true, the request is aborted.
		                 This is messy but the only way to support the use of _fixCount, etc
	}

Returns arrayref of hashes.
=cut

sub _getTagDataForTracks {
	my ( $tags, $args ) = @_;

	my $sqllog = main::DEBUGLOG && logger('database.sql');

	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();

	my $sql      = 'SELECT %s FROM tracks LEFT JOIN works ON works.id = tracks.work ';
	my $c        = { 'tracks.id' => 1, 'tracks.title' => 1, 'works.title' => 1, 'works.id' => 1, 'tracks.grouping' => 1 };
	my $w        = [];
	my $p        = [];
	my $total    = 0;

	if ( $args->{where} ) {
		push @{$w}, $args->{where};
	}

	my $sort = $args->{sort};

	# return count only?
	my $count_only;
	if ($tags eq 'CC') {
		$count_only = 1;
		$tags = $sort = '';
	}

	# return IDs only
	my $ids_only;
	if ($tags eq 'II') {
		$ids_only = 1;
		$tags = $sort = '';
	}

	# Normalize any search parameters
	my $search = $args->{search};
	if ( $search && specified($search) ) {
		if ( $search =~ s/^sql=// ) {
			# Raw SQL search query
			$search =~ s/;//g; # strip out any attempt at combining SQL statements
			unshift @{$w}, $search;
		}
		# we need to adjust SQL when using fulltext search
		elsif ( Slim::Schema->canFulltextSearch ) {
			Slim::Plugin::FullTextSearch::Plugin->createHelperTable({
				name   => 'tracksSearch',
				search => $search,
				type   => 'track',
				checkLargeResultset => sub {
					my $isLarge = shift;
					return $isLarge ? "LIMIT $isLarge" : 'ORDER BY fulltextweight'
				},
			});

			$sql = 'SELECT %s FROM tracksSearch JOIN tracks ON tracks.id = tracksSearch.id LEFT JOIN works on tracks.work = works.id ';

			if (!$count_only) {
				$sort = "tracksSearch.fulltextweight DESC" . ($sort ? ", $sort" : '');
			}
		}
		else {
			my $strings = Slim::Utils::Text::searchStringSplit($search);
			if ( ref $strings->[0] eq 'ARRAY' ) {
				unshift @{$w}, '(' . join( ' OR ', map { 'tracks.titlesearch LIKE ?' } @{ $strings->[0] } ) . ')';
				unshift @{$p}, @{ $strings->[0] };
			}
			else {
				unshift @{$w}, 'tracks.titlesearch LIKE ?';
				unshift @{$p}, @{$strings};
			}
		}
	}

	if ( my $albumId = $args->{albumId} ) {
		my @albumIds = split(',', $albumId);
		push @{$w}, 'tracks.album IN (' . join(',', map {'?'} @albumIds) . ')';
		push @{$p}, @albumIds;
		delete $args->{releaseType};
	}

	if ( my $trackId = $args->{trackId} ) {
		push @{$w}, 'tracks.id = ?';
		push @{$p}, $trackId;
	}

	if ( my $year = $args->{year} ) {
		push @{$w}, 'tracks.year = ?';
		push @{$p}, $year;
	}

	if ( my $workId = $args->{workId} ) {
		push @{$w}, 'tracks.work = ?';
		push @{$p}, $workId;
		if ( my $grouping = $args->{grouping} ) {
			push @{$w}, 'tracks.grouping = ?';
			push @{$p}, $grouping;
		} elsif ( exists $args->{grouping} ) {
			push @{$w}, 'tracks.grouping IS NULL';
		}
	}

	if ( my $libraryId = $args->{libraryId} ) {
		$sql .= 'JOIN library_track ON library_track.track = tracks.id ';
		push @{$w}, 'library_track.library = ?';
		push @{$p}, $libraryId;
	}

	# Some helper functions to setup joins with less code
	my $join_genre_track = sub {
		if ( $sql !~ /JOIN genre_track/ ) {
			$sql .= 'LEFT JOIN genre_track ON genre_track.track = tracks.id ';
		}
	};

	my $join_genres = sub {
		$join_genre_track->();

		if ( $sql !~ /JOIN genres/ ) {
			$sql .= 'LEFT JOIN genres ON genres.id = genre_track.genre ';
		}
	};

	my $join_contributor_tracks = sub {
		if ( $sql !~ /JOIN contributor_track/ ) {
			$sql .= 'LEFT JOIN contributor_track ON contributor_track.track = tracks.id ';
		}
	};

	my $join_contributors = sub {
		$join_contributor_tracks->();

		if ( $sql !~ /JOIN contributors/ ) {
			$sql .= 'LEFT JOIN contributors ON contributors.id = contributor_track.contributor ';
		}
	};

	my $join_albums = sub {
		if ( $sql !~ /JOIN albums/ ) {
			$sql .= 'LEFT JOIN albums ON albums.id = tracks.album ';
		}
	};

	if ( my $releaseType = $args->{releaseType} ) {
		$join_albums->();
		my @releaseTypes = map { uc($_) } split(',', $releaseType);
		push @{$w}, 'albums.release_type IN (' . join(', ', map {'?'} @releaseTypes) . ')';
		push @{$p}, @releaseTypes;
	}

	my $join_tracks_persistent = sub {
		if ( main::STATISTICS && $sql !~ /JOIN tracks_persistent/ ) {
			$sql .= 'LEFT JOIN tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5 ';
		}
	};

	if ( my $genreId = $args->{genreId} ) {
		$join_genre_track->();

		my @genreIDs = split(/,/, $genreId);

		push @{$w}, 'genre_track.genre IN (' . join(', ', map {'?'} @genreIDs) . ')';
		push @{$p}, @genreIDs;
	}

	if ( my $contributorId = $args->{contributorId} ) {
		# handle the case where we're asked for the VA id => return compilations
		if ($contributorId == Slim::Schema->variousArtistsObject->id) {
			$join_albums->();
			push @{$w}, 'albums.compilation = 1';
		}
		else {
			$join_contributor_tracks->();
			push @{$w}, 'contributor_track.contributor = ?';
			push @{$p}, $contributorId;
		}
	}

	if ( my $trackIds = $args->{trackIds} ) {
		# Filter out negative tracks (remote tracks)
		push @{$w}, 'tracks.id IN (' . join( ',', grep { $_ > 0 } @{$trackIds} ) . ')';
	}

	# Process tags and add columns/joins as needed
	$tags =~ /e/ && do { $c->{'tracks.album'} = 1 };
	$tags =~ /E/ && do { $c->{'tracks.extid'} = 1 };
	$tags =~ /d/ && do { $c->{'tracks.secs'} = 1 };
	$tags =~ /t/ && do { $c->{'tracks.tracknum'} = 1 };
	$tags =~ /y/ && do { $c->{'tracks.year'} = 1 };
	$tags =~ /m/ && do { $c->{'tracks.bpm'} = 1 };
	$tags =~ /M/ && do { $c->{'tracks.musicmagic_mixable'} = 1 };
 	$tags =~ /Q/ && do { $c->{'tracks.lossless'} = 1 };
	$tags =~ /o/ && do { $c->{'tracks.content_type'} = 1 };
	$tags =~ /v/ && do { $c->{'tracks.tagversion'} = 1 };
	$tags =~ /r/ && do { $c->{'tracks.bitrate'} = 1; $c->{'tracks.vbr_scale'} = 1 };
	$tags =~ /f/ && do { $c->{'tracks.filesize'} = 1 };
	$tags =~ /j/ && do { $c->{'tracks.cover'} = 1 };
	$tags =~ /n/ && do { $c->{'tracks.timestamp'} = 1 };
	$tags =~ /F/ && do { $c->{'tracks.dlna_profile'} = 1 };
	$tags =~ /D/ && do { $c->{'tracks.added_time'} = 1 };
	$tags =~ /U/ && do { $c->{'tracks.updated_time'} = 1 };
	$tags =~ /T/ && do { $c->{'tracks.samplerate'} = 1 };
	$tags =~ /H/ && do { $c->{'tracks.channels'} = 1 };
	$tags =~ /I/ && do { $c->{'tracks.samplesize'} = 1 };
	$tags =~ /u/ && do { $c->{'tracks.url'} = 1 };
	$tags =~ /w/ && do { $c->{'tracks.lyrics'} = 1 };
	$tags =~ /x/ && do { $c->{'tracks.remote'} = 1 };
	$tags =~ /c/ && do { $c->{'tracks.coverid'} = 1 };
	$tags =~ /Y/ && do { $c->{'tracks.replay_gain'} = 1 };
	$tags =~ /i/ && do { $c->{'tracks.disc'} = 1 };
	$tags =~ /g/ && do {
		$join_genres->();
		$c->{'genres.name'} = 1;

		# XXX there is a bug here if a track has multiple genres, the genre
		# returned will be a random genre, not sure how to solve this -Andy
	};

	$tags =~ /p/ && do {
		$join_genres->();
		$c->{'genres.id'} = 1;
	};

	$tags =~ /[as]/ && do {
		$join_contributors->();
		$c->{'contributors.name'} = 1 if $tags =~ /a/;

		# only albums on which the contributor has a specific role?
		my @roles;
		if ($args->{roleId}) {
			@roles = split /,/, $args->{roleId};
			push @roles, 'ARTIST' if $args->{roleId} eq 'ALBUMARTIST' && !$prefs->get('useUnifiedArtistsList');
		}
		elsif ($prefs->get('useUnifiedArtistsList')) {
			# Tag 'a' returns either ARTIST or TRACKARTIST role
			# Bug 16791: Need to include ALBUMARTIST too
			@roles = ( 'ARTIST', 'TRACKARTIST', 'ALBUMARTIST' );

			# Loop through each pref to see if the user wants to show that contributor role.
			foreach (Slim::Schema::Contributor->contributorRoles) {
				if ($prefs->get(lc($_) . 'InArtists')) {
					push @roles, $_;
				}
			}
		}
		else {
			@roles = Slim::Schema::Contributor->contributorRoles();
		}

		push @{$p}, map { Slim::Schema::Contributor->typeToRole($_) } @roles;
		push @{$w}, '(contributors.id = tracks.primary_artist OR tracks.primary_artist IS NULL)' if $args->{trackIds};
		push @{$w}, 'contributor_track.role IN (' . join(', ', map {'?'} @roles) . ')';
	};

	$tags =~ /s/ && do {
		$join_contributors->();
		$c->{'contributors.id'} = 1;
	};

	$tags =~ /l/ && do {
		$join_albums->();
		$c->{'albums.title'} = 1;
	};

	$tags =~ /q/ && do {
		$join_albums->();
		$c->{'albums.discc'} = 1;
	};

	$tags =~ /J/ && do {
		$join_albums->();
		$c->{'albums.artwork'} = 1;
	};

	$tags =~ /C/ && do {
		$join_albums->();
		$c->{'albums.compilation'} = 1;
	};

	$tags =~ /W/ && do {
		$join_albums->();
		$c->{'albums.release_type'} = 1;
	};

	$tags =~ /X/ && do {
		$join_albums->();
		$c->{'albums.replay_gain'} = 1;
	};

	$tags =~ /R/ && do {
		if ( main::STATISTICS ) {
			$join_tracks_persistent->();
			$c->{'tracks_persistent.rating'} = 1;
		}
	};

	$tags =~ /O/ && do {
		if ( main::STATISTICS ) {
			$join_tracks_persistent->();
			$c->{'tracks_persistent.playcount'} = 1;
		}
	};

	if ( scalar @{$w} ) {
		$sql .= 'WHERE ';
		my $s = join( ' AND ', @{$w} );
		$s =~ s/\%/\%\%/g;
		$sql .= $s . ' ';
	}
	$sql .= 'GROUP BY tracks.id ' if $sql =~ /JOIN /;

	if ( $sort ) {
		$sql .= "ORDER BY $sort ";
	}

	$ids_only && do { $c->{'tracks.primary_artist'} = 1 };

	# Add selected columns
	# Bug 15997, AS mapping needed for MySQL
	my @cols = sort keys %{$c};
	$sql = sprintf $sql, join( ', ', map { $_ . " AS '" . $_ . "'" } @cols );

	my $dbh = Slim::Schema->dbh;

	if ( $count_only || (my $limit = $args->{limit}) ) {
		# Let the caller worry about the limit values

		my $cacheKey = md5_hex($sql . join( '', @{$p}, @$w ) . (Slim::Utils::Text::ignoreCase($search, 1) || ''));

		# use short lived cache, as we might be dealing with changing data (eg. playcount)
		if ( my $cached = $bmfCache{$cacheKey} ) {
			$total = $cached;
		}
		else {
			my $total_sth = $dbh->prepare_cached( qq{
				SELECT COUNT(1) FROM ( $sql ) AS t1
			} );

			if ( main::DEBUGLOG && $sqllog->is_debug ) {
				$sqllog->debug( "Titles totals query: SELECT COUNT(1) FROM ($sql) / " . Data::Dump::dump($p) );
			}

			$total_sth->execute( @{$p} );
			($total) = $total_sth->fetchrow_array();
			$total_sth->finish;

			$bmfCache{$cacheKey} = $total;
		}

		my ($valid, $start, $end);
		($valid, $start, $end) = $limit->($total) unless $count_only;

		if ( $count_only || !$valid ) {
			return wantarray ? ( {}, [], $total ) : {};
		}

		# Limit the real query
		if ( $start =~ /^\d+$/ && defined $end && $end =~ /^\d+$/ ) {
			$sql .= "LIMIT $start, $end ";
		}
	}

	if ( main::DEBUGLOG && $sqllog->is_debug ) {
		$sqllog->debug( "_getTagDataForTracks query: $sql / " . Data::Dump::dump($p) );
	}

	my $sth = $dbh->prepare_cached($sql);
	$sth->execute( @{$p} );

	# Bind selected columns in order
	my $i = 1;
	for my $col ( @cols ) {
		# Adjust column names that are sub-queries to be stored using the AS value
		if ( $col =~ /SELECT/ ) {
			my ($newcol) = $col =~ /AS (\w+)/;
			$c->{$newcol} = 1;
			$col = $newcol;
		}

		$sth->bind_col( $i++, \$c->{$col} );
	}

	# Results are stored in a hash keyed by track ID, and we
	# also store the order the data is returned in, titlesQuery
	# needs this to provide correctly sorted results, and I don't
	# want to make %results an IxHash.
	my %results;
	my @resultOrder;

	my $ignoreReleaseTypes = $tags =~ /W/ && $prefs->get('ignoreReleaseTypes');

	while ( $sth->fetch ) {
		if (!$ids_only) {
			utf8::decode( $c->{'tracks.title'} ) if exists $c->{'tracks.title'};
			utf8::decode( $c->{'tracks.grouping'} ) if exists $c->{'tracks.grouping'};
			utf8::decode( $c->{'works.title'} ) if exists $c->{'works.title'};
			utf8::decode( $c->{'tracks.lyrics'} ) if exists $c->{'tracks.lyrics'};
			utf8::decode( $c->{'albums.title'} ) if exists $c->{'albums.title'};
			utf8::decode( $c->{'contributors.name'} ) if exists $c->{'contributors.name'};
			utf8::decode( $c->{'genres.name'} ) if exists $c->{'genres.name'};
			utf8::decode( $c->{'comments.value'} ) if exists $c->{'comments.value'};
		}

		my $id = $c->{'tracks.id'};

		$results{ $id } = { map { $_ => $c->{$_} } keys %{$c} };

		# if user doesn't want to distinguish release types, just return ALBUMS for all of them
		if ($ignoreReleaseTypes) {
			$results{ $id }->{'albums.release_type'} = 'ALBUM';
		}

		push @resultOrder, $id;
	}

	# For tag A/S we have to run 1 additional query
	if ( $tags =~ /[AS]/ ) {
		my $sql = sprintf qq{
			SELECT contributors.id, contributors.name, contributor_track.track, contributor_track.role
			FROM contributor_track
			JOIN contributors ON contributors.id = contributor_track.contributor
			WHERE contributor_track.track IN (%s)
			ORDER BY contributor_track.role DESC
		}, join( ',', @resultOrder );

		my $contrib_sth = $dbh->prepare($sql);

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Tag A/S (contributor) query: $sql" );
		}

		$contrib_sth->execute;

		my %values;
		my $separator = $tags =~ /AA/ ? ',' : ', ';
		while ( my ($id, $name, $track, $role) = $contrib_sth->fetchrow_array ) {
			$values{$track} ||= {};
			my $role_info = $values{$track}->{$role} ||= {};

			# XXX: what if name has ", " in it?
			utf8::decode($name);
			$role_info->{ids}   .= $role_info->{ids} ? ',' . $id : $id;
			$role_info->{names} .= $role_info->{names} ? $separator . $name : $name;
		}

		my $want_names = $tags =~ /A/;
		my $want_ids   = $tags =~ /S/;

		while ( my ($id, $role) = each %values ) {
			my $track = $results{$id};

			while ( my ($role_id, $role_info) = each %{$role} ) {
				my $role = lc( Slim::Schema::Contributor->roleToType($role_id) );

				$track->{"${role}_ids"} = $role_info->{ids}   if $want_ids;
				$track->{$role}         = $role_info->{names} if $want_names;
			}
		}
	}

	# Same thing for G/P, multiple genres requires another query
	if ( $tags =~ /[GP]/ ) {
		my $sql = sprintf qq{
			SELECT genres.id, genres.name, genre_track.track
			FROM genre_track
			JOIN genres ON genres.id = genre_track.genre
			WHERE genre_track.track IN (%s)
			ORDER BY genres.namesort $collate
		}, join( ',', @resultOrder );

		my $genre_sth = $dbh->prepare($sql);

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Tag G/P (genre) query: $sql" );
		}

		$genre_sth->execute;

		my %values;
		while ( my ($id, $name, $track) = $genre_sth->fetchrow_array ) {
			my $genre_info = $values{$track} ||= {};

			utf8::decode($name);
			$genre_info->{ids}   .= $genre_info->{ids} ? ',' . $id : $id;
			$genre_info->{names} .= $genre_info->{names} ? ', ' . $name : $name;
		}

		my $want_names = $tags =~ /G/;
		my $want_ids   = $tags =~ /P/;

		while ( my ($id, $genre_info) = each %values ) {
			my $track = $results{$id};
			$track->{genre_ids} = $genre_info->{ids}   if $want_ids;
			$track->{genres}    = $genre_info->{names} if $want_names;
		}
	}

	# And same for comments
	if ( $tags =~ /k/ ) {
		my $sql = sprintf qq{
			SELECT track, value
			FROM comments
			WHERE track IN (%s)
			ORDER BY id
		}, join( ',', @resultOrder );

		my $comment_sth = $dbh->prepare($sql);

		if ( main::DEBUGLOG && $sqllog->is_debug ) {
			$sqllog->debug( "Tag k (comment) query: $sql" );
		}

		$comment_sth->execute();

		my %values;
		while ( my ($track, $value) = $comment_sth->fetchrow_array ) {
			$values{$track} .= $values{$track} ? ' / ' . $value : $value;
		}

		while ( my ($id, $comment) = each %values ) {
			utf8::decode($comment);
			$results{$id}->{comment} = $comment;
		}
	}

	# If the query wasn't limited, get total from results
	if ( !$total ) {
		$total = scalar @resultOrder;
	}

	# delete the temporary table, as it's stored in memory and can be rather large
	Slim::Plugin::FullTextSearch::Plugin->dropHelperTable('tracksSearch') if $search && Slim::Schema->canFulltextSearch;

	return wantarray ? ( \%results, \@resultOrder, $total ) : \%results;
}

# SQLite would not sort single characters the same way as the same characters at
# the beginning of the word. Thus sorting the list of initial characters fails:
# https://www.mail-archive.com/sqlite-users@mailinglists.sqlite.org/msg113837.html
# Therefore we can't use SQLite's GROUP statement, but must group items ourselves.
# If we have an index item which we already had in the list, merge all items after
# the previous index and the current item into one. Eg. "U Ü U" -> "U" only.
# https://github.com/LMS-Community/slimserver/issues/388
sub _createIndexList {
	my ($pageSql, $p) = @_;

	my $sqllog = main::DEBUGLOG && logger('database.sql');
	if ( $sqllog && $sqllog->is_debug ) {
		$sqllog->debug( "indexList query: $pageSql / " . Data::Dump::dump($p) );
	}

	my $indexData = Slim::Schema->dbh->selectall_arrayref($pageSql, undef, @{$p});

	my @indexList;

	foreach (@$indexData) {
		my $char = $_->[0];
		utf8::decode($char);

		my $i = first { @indexList[$_]->[0] eq $char } 0..$#indexList;

		if (defined($i)) {
			# Some sort orders are tricking us: eg. in Danish Å would be considered the same as AA,
			# but still sorted to the end. Thus Aaron would end up in the end, too. Therefore hide
			# A at the end, by not grouping it if there's been an ASCII character larger than A already.
			if ($char =~ /[A-Z]/ && grep {
				$_->[0] =~ /[A-Z]/ && $char lt $_->[0];
			} @indexList) {
				$i = $#indexList;
			}

			while ($i < $#indexList) {
				my $toMerge = pop @indexList;
				$indexList[$i]->[1] += $toMerge->[1];
			}

			$indexList[-1]->[1]++;
		}
		else {
			push @indexList, [$char, 1];
		}
	}

	return \@indexList;
}

=head1 SEE ALSO

L<Slim::Control::Request.pm>

=cut

1;

__END__
