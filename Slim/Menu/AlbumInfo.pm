package Slim::Menu::AlbumInfo;

# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# Provides OPML-based extensible menu for album info
=head1 NAME

Slim::Menu::AlbumInfo

=head1 DESCRIPTION

Provides a dynamic OPML-based album info menu to all UIs and allows
plugins to register additional menu items.

=cut

use strict;

use base qw(Slim::Menu::Base);

use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

my $log = logger('menu.albuminfo');
my $prefs = preferences('server');

sub init {
	my $class = shift;
	$class->SUPER::init();

	Slim::Control::Request::addDispatch(
		[ 'albuminfo', 'items', '_index', '_quantity' ],
		[ 0, 1, 1, \&cliQuery ]
	);

	Slim::Control::Request::addDispatch(
		[ 'albuminfo', 'playlist', '_method' ],
		[ 1, 1, 1, \&cliQuery ]
	);
}

sub name {
	return 'ALBUM_INFO';
}

##
# Register all the information providers that we provide.
# This order is defined at http://wiki.slimdevices.com/index.php/UserInterfaceHierarchy
#
sub registerDefaultInfoProviders {
	my $class = shift;

	$class->SUPER::registerDefaultInfoProviders();

	$class->registerInfoProvider( addalbum => (
		after    => 'top',
		func      => \&addAlbumEnd,
	) );

	$class->registerInfoProvider( addalbumnext => (
		after    => 'addalbum',
		func      => \&addAlbumNext,
	) );

	$class->registerInfoProvider( playitem => (
		after    => 'addalbumnext',
		func      => \&playAlbum,
	) );

#	$class->registerInfoProvider( artwork => (
#		menuMode  => 1,
#		after     => 'addalbum',
#		func      => \&showArtwork,
#	) );

	$class->registerInfoProvider( contributors => (
		after => 'top',
		func  => \&infoContributors,
	) );

	$class->registerInfoProvider( year => (
		after => 'top',
		func  => \&infoYear,
	) );

	$class->registerInfoProvider( fullalbum => (
		after => 'top',
		func  => \&infoAlbum,
	) );

	$class->registerInfoProvider( duration => (
		after    => 'year',
		func     => \&infoDuration,
	) );

	$class->registerInfoProvider( replaygain => (
		after    => 'year',
		func     => \&infoReplayGain,
	) );

	$class->registerInfoProvider( disc => (
		after => 'year',
		func  => \&infoDisc,
	) );

	$class->registerInfoProvider( compilation => (
		after => 'year',
		func  => \&infoCompilation,
	) );

	$class->registerInfoProvider( extid => (
		after => 'compilation',
		func  => \&infoExternalId,
	) );
}

sub menu {
	my ( $class, $client, $url, $album, $tags, $filter ) = @_;
	$tags ||= {};

	# If we don't have an ordering, generate one.
	# This will be triggered every time a change is made to the
	# registered information providers, but only then. After
	# that, we will have our ordering and only need to step
	# through it.
	my $infoOrdering = $class->getInfoOrdering;

	# $remoteMeta is an empty set right now. adding to allow for parallel construction with trackinfo
	my $remoteMeta = {};

	# Get album object if necessary
	if ( !blessed($album) ) {
		$album = Slim::Schema->rs('Album')->objectForUrl( {
			url => $url,
		} );
		if ( !blessed($album) ) {
			$log->error( "No album object found for $url" );
			return;
		}
	}

	# Function to add menu items
	my $addItem = sub {
		my ( $ref, $items ) = @_;

		if ( defined $ref->{func} ) {

			my $item = eval { $ref->{func}->( $client, $url, $album, $remoteMeta, $tags, $filter ) };
			if ( $@ ) {
				$log->error( 'Album menu item "' . $ref->{name} . '" failed: ' . $@ );
				return;
			}

			return unless defined $item;

			# skip jive-only items for non-jive UIs
			return if $ref->{menuMode} && !$tags->{menuMode};

			# show artwork item to jive only if artwork exists
			return if $ref->{menuMode} && $tags->{menuMode} && $ref->{name} eq 'artwork' && !$album->coverArtExists;

			if ( ref $item eq 'ARRAY' ) {
				if ( scalar @{$item} ) {
					push @{$items}, @{$item};
				}
			}
			elsif ( ref $item eq 'HASH' ) {
				return if $ref->{menuMode} && !$tags->{menuMode};
				if ( scalar keys %{$item} ) {
					push @{$items}, $item;
				}
			}
			else {
				$log->error( 'AlbumInfo menu item "' . $ref->{name} . '" failed: not an arrayref or hashref' );
			}
		}
	};

	# Now run the order, which generates all the items we need
	my $items = [];

	for my $ref ( @{ $infoOrdering } ) {
		# Skip items with a defined parent, they are handled
		# as children below
		next if $ref->{parent};

		# Add the item
		$addItem->( $ref, $items );

		# Look for children of this item
		my @children = grep {
			$_->{parent} && $_->{parent} eq $ref->{name}
		} @{ $infoOrdering };

		if ( @children ) {
			my $subitems = $items->[-1]->{items} = [];

			for my $child ( @children ) {
				$addItem->( $child, $subitems );
			}
		}
	}

	return {
		name  => $album->title || Slim::Music::Info::getCurrentTitle( $client, $url, 1 ),
		type  => 'opml',
		items => $items,
		cover => '/music/' . ($album->artwork || 0) . '/cover.jpg',
	};
}

sub infoContributors {
	my ( $client, $url, $album, $remoteMeta, $tags, $filter ) = @_;

	my $items = [];
	$filter ||= {};

	if ( $remoteMeta->{artist} ) {
		push @{$items}, {
			type =>  'text',
			name =>  $remoteMeta->{artist},
			label => 'ARTIST',
		};
	}
	else {
		my @roles = Slim::Schema::Contributor->contributorRoles;

		# Loop through each pref to see if the user wants to link to that contributor role.
		my %linkRoles = map {$_ => $prefs->get(lc($_) . 'InArtists')} @roles;
		$linkRoles{'ARTIST'} = 1;
		$linkRoles{'TRACKARTIST'} = 1;
		$linkRoles{'ALBUMARTIST'} = 1;

		my $library_id = $filter->{library_id} || Slim::Music::VirtualLibraries->getLibraryIdForClient($client);

		# Loop through the contributor types and append
		for my $role (@roles) {
			for my $contributor ( $album->artistsForRoles($role) ) {

				next unless $contributor->isInLibrary($library_id);

				if ($linkRoles{$role}) {
					my $id = $contributor->id;

					my %actions = (
						allAvailableActionsDefined => 1,
						items => {
							command     => ['browselibrary', 'items'],
							fixedParams => { mode => 'albums', artist_id => $id, library_id => $library_id },
						},
						play => {
							command     => ['playlistcontrol'],
							fixedParams => { cmd => 'load', artist_id => $id, library_id => $library_id },
						},
						add => {
							command     => ['playlistcontrol'],
							fixedParams => { cmd => 'add', artist_id => $id, library_id => $library_id },
						},
						insert => {
							command     => ['playlistcontrol'],
							fixedParams => { cmd => 'insert', artist_id => $id, library_id => $library_id },
						},
						info => {
							command     => ['artistinfo', 'items'],
							fixedParams => { artist_id => $id, library_id => $library_id },
						},
					);
					$actions{'playall'} = $actions{'play'};
					$actions{'addall'} = $actions{'add'};

					my $item = {
						type    => 'playlist',
						url     => 'blabla',
						name    => $contributor->name,
						label   => uc $role,
						itemActions => \%actions,
					};
					push @{$items}, $item;
				} else {
					my $item = {
						type    => 'text',
						name    => $contributor->name,
						label   => uc $role,
					};
					push @{$items}, $item;
				}
			}
		}
	}

	return $items;
}

sub infoYear {
	my ( $client, $url, $album ) = @_;

	my $item;

	if ( my $year = $album->year ) {

		my %actions = (
			allAvailableActionsDefined => 1,
			items => {
				command     => ['browselibrary', 'items'],
				fixedParams => { mode => 'albums', year => $year },
			},
			play => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'load', year => $year},
			},
			add => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'add', year => $year},
			},
			insert => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'insert', year => $year},
			},
			info => {
				command     => ['yearinfo', 'items'],
				fixedParams => {year => $year},
			},
		);
		$actions{'playall'} = $actions{'play'};
		$actions{'addall'} = $actions{'add'};

		$item = {
			type    => 'playlist',
			url     => 'blabla',
			name    => $year,
			label   => 'YEAR',
			itemActions => \%actions,
		};
	}

	return $item;
}

sub infoAlbum {
	# if the album listing is filtered by anything such that we're not showing all tracks, include a link to the full album in the header
	my ( $client, $url, $album, $remoteMeta, $tags, $filter) = @_;

	my $item;
	my $library_id = $filter->{library_id} || Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	my $albumName = $album->title;
	my $totalAlbumTracks = $album->tracks->count;

	if ( $albumName && $totalAlbumTracks > $filter->{track_count} ) {

		my %actions = (
			allAvailableActionsDefined => 1,
			items => {
				command     => ['browselibrary', 'items'],
				fixedParams => { mode => 'tracks', album_id => $album->id, library_id => $library_id },
			},
			play => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'load', album_id => $album->id},
			},
			add => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'add', album_id => $album->id},
			},
			insert => {
				command     => ['playlistcontrol'],
				fixedParams => {cmd => 'insert', album_id => $album->id},
			},
			info => {
				command     => ['albuminfo', 'items'],
				fixedParams => {album_id => $album->id},
			},
		);
		$actions{'playall'} = $actions{'play'};
		$actions{'addall'} = $actions{'add'};

		$item = {
			type    => 'playlist',
			url     => 'blabla',
			name    => $albumName,
			label   => 'ALBUM',
			itemActions => \%actions,
		};
	}

	return $item;
}

sub infoDisc {
	my ( $client, $url, $album ) = @_;

	my $item;
	my ($disc, $discc);

	if ( blessed($album) && ($disc = $album->disc) && ($discc = $album->discc) ) {
		$item = {
			type  => 'text',
			label => 'DISC',
			name  => "$disc/$discc",
		};
	}

	return $item;
}

sub infoDuration {
	my ( $client, $url, $album ) = @_;

	my $item;

	if ( my $duration = $album->duration ) {
		$item = {
			type  => 'text',
			label => 'ALBUMLENGTH',
			name  => $duration,
		};
	}

	return $item;
}

sub infoCompilation {
	my ( $client, $url, $album ) = @_;

	my $item;

	if ( $album->compilation ) {
		$item = {
			type  => 'text',
			label => 'COMPILATION',
			name  => cstring($client,'YES'),
		};
	}

	return $item;
}

sub infoExternalId {
	my ( $client, $url, $album ) = @_;

	my $item;

	if ( $album->extid ) {
		$item = {
			type  => 'text',
			label => 'EXTERNAL_ID',
			name  => $album->extid,
		};
	}

	return $item;
}

sub showArtwork {
	my ( $client, $url, $album, $remoteMeta, $tags ) = @_;
	my $items = [];
	my $jive;
	my $actions = {
		do => {
			cmd => [ 'artwork', $album->id ],
		},
	};
	$jive->{actions} = $actions;
	$jive->{showBigArtwork} = 1;

	push @{$items}, {
		type => 'text',
		name => cstring($client, 'SHOW_ARTWORK_SINGLE'),
		jive => $jive,
	};

	return $items;
}

sub playAlbum {
	my ( $client, $url, $album, $remoteMeta, $tags, $filter) = @_;

	return undef if !blessed($client);

	my $actions = {
		items => {
			command     => [ 'playlistcontrol' ],
			fixedParams => {cmd => 'load', album_id => $album->id, %{ $filter || {} }},
		},
	};
	$actions->{'play'} = $actions->{'items'};

	return {
		itemActions => $actions,
		nextWindow  => 'nowPlaying',
		type        => $tags->{menuMode} ? 'text' : 'link',
		playcontrol => 'play',
		name        => cstring($client, 'PLAY'),
	};
}

sub addAlbumEnd {
	my ( $client, $url, $album, $remoteMeta, $tags, $filter ) = @_;
	addAlbum( $client, $url, $album, $remoteMeta, $tags, 'ADD_TO_END', 'add', $filter );
}

sub addAlbumNext {
	my ( $client, $url, $album, $remoteMeta, $tags, $filter ) = @_;
	addAlbum( $client, $url, $album, $remoteMeta, $tags, 'PLAY_NEXT', 'insert', $filter );
}

sub addAlbum {
	my ( $client, $url, $album, $remoteMeta, $tags, $add_string, $cmd, $filter ) = @_;

	return undef if !blessed($client);

	my $actions = {
		items => {
			command     => [ 'playlistcontrol' ],
			fixedParams => {cmd => $cmd, album_id => $album->id, %{ $filter || {} }},
		},
	};
	$actions->{'play'} = $actions->{'items'};
	$actions->{'add'}  = $actions->{'items'};

	return {
		itemActions => $actions,
		nextWindow  => 'parent',
		type        => $tags->{menuMode} ? 'text' : 'link',
		playcontrol => $cmd,
		name        => cstring($client, $add_string),
	};
}

sub infoReplayGain {
	my ( $client, $url, $album ) = @_;

	if ( blessed($album) && $album->can('replay_gain') ) {
		if ( my $albumreplaygain = $album->replay_gain ) {
			my $noclip = Slim::Player::ReplayGain::preventClipping( $albumreplaygain, $album->replay_peak );
			my %item = (
				type  => 'text',
				label => 'ALBUMREPLAYGAIN',
				name  => sprintf( "%2.2f dB", $albumreplaygain),
			);
			if ( $noclip < $albumreplaygain ) {
				# Gain was reduced to avoid clipping
				$item{'name'} .= sprintf( " (%s)",
						cstring( $client, 'REDUCED_TO_PREVENT_CLIPPING', sprintf( "%2.2f dB", $noclip ) ) );
			}
			return \%item;
		}
	}
}

# keep a very small cache of feeds to allow browsing into a artist info feed
# we will be called again without $url or $albumId when browsing into the feed
tie my %cachedFeed, 'Tie::Cache::LRU', 2;

sub cliQuery {
	main::DEBUGLOG && $log->is_debug && $log->debug('cliQuery');
	my $request = shift;

	# WebUI or newWindow param from SP side results in no
	# _index _quantity args being sent, but XML Browser actually needs them, so they need to be hacked in
	# here and the tagged params mistakenly put in _index and _quantity need to be re-added
	# to the $request params
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	if ( $index =~ /:/ ) {
		$request->addParam(split (/:/, $index));
		$index = 0;
		$request->addParam('_index', $index);
	}
	if ( $quantity =~ /:/ ) {
		$request->addParam(split(/:/, $quantity));
		$quantity = 200;
		$request->addParam('_quantity', $quantity);
	}

	my $client         = $request->client;
	my $url            = $request->getParam('url');
	my $albumId        = $request->getParam('album_id');
	my $menuMode       = $request->getParam('menu') || 0;
	my $menuContext    = $request->getParam('context') || 'normal';
	my $playlist_index = defined( $request->getParam('playlist_index') ) ?  $request->getParam('playlist_index') : undef;
	my $connectionId   = $request->connectionID || '';

	my %filter;
	foreach (qw(artist_id genre_id year library_id)) {
		if (my $arg = $request->getParam($_)) {
			$filter{$_} = $arg;
		}
	}

	my $tags = {
		menuMode      => $menuMode,
		menuContext   => $menuContext,
		playlistIndex => $playlist_index,
	};

	my $feed;

	# Default menu
	if ( $url ) {
		$feed = Slim::Menu::AlbumInfo->menu( $client, $url, undef, $tags, \%filter );
	}
	elsif ( $albumId ) {
		my $album = Slim::Schema->find( Album => $albumId );
		$feed     = Slim::Menu::AlbumInfo->menu( $client, $album->url, $album, $tags, \%filter );
	}
	elsif ( $cachedFeed{ $connectionId } ) {
		$feed = $cachedFeed{ $connectionId };
	}
	else {
		$request->setStatusBadParams();
		return;
	}

	$cachedFeed{ $connectionId } = $feed if $feed;

	Slim::Control::XMLBrowser::cliQuery( 'albuminfo', $feed, $request );
}

1;
