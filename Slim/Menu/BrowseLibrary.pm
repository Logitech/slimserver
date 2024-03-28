package Slim::Menu::BrowseLibrary;

=head1 NAME

Slim::Menu::BrowseLibrary

=head1 SYNOPSIS

	use Slim::Menu::BrowseLibrary;

	Slim::Menu::BrowseLibrary->registerNode({
		type         => 'link',
		name         => 'MYMUSIC_MENU_ITEM_TITLE',
		params       => {mode => 'myNewMode'},
		feed         => \&myFeed,
		icon         => 'html/images/someimage.png',
		homeMenuText => 'HOMEMENU_MENU_ITEM_TITLE',
		condition    => sub {my ($client, $nodeId) = @_; return 1;}
		id           => 'myNewModeId',
		weight       => 30,
	});

	Slim::Menu::BrowseLibrary->deregisterNode('someNodeId');

	Slim::Menu::BrowseLibrary->registerNodeFilter(\&nodeFilter);

	Slim::Menu::BrowseLibrary->deregisterNodeFilter(\&nodeFilter);

=head1 DESCRIPTION

Register or deregister menu items for the My Music menu.

Register or deregister filter functions used to determine if a menu
item should be included in the My Music menu, possibly for a specific client.

=head2 registerNode()

The new menu item is specified using a HASH-ref as follows (mandatory items marked with *):

=over

=item C<type>*

C<link> | C<search>

=item C<id>*

Unique identifier for the menu item

=item C<name>*

Unique string name for the menu item title when used in the My Music menu

=item C<homeMenuText>

Unique string name for the menu item title when used in the Home menu

=item C<feed>*

reference to a function that is invoked in the manner of an XMLBrowser function feed

=item C<icon>

Icon to be used with menu item

=item C<condition>

function to determine dynamically whether this menu item should be shown in the menu

=item C<weight>

Hint as to relative position of item in menu

=item C<cache>

Whether the rendered web page may be cached or not. Caching pages can considerably
speed up browsing in the web UI. But some modes (like eg. BMF) might need to be
processed on every call.

=item C<params>

HASH-ref containing:

=over

=item C<mode>

This will default to the value of the C<id> of the menu item.
If one of C<artists, albums, genres, years, tracks, playlists, playlistTracks, bmf>
is used then it will override the default method from BrowseLibrary - use with caution.

=item C<sort track_id artist_id genre_id album_id playlist_id year folder_id role_id library_id>

When browsing to a deeper level in the menu hierarchy,
then any of these values (and only these values)
will be passed in the C<params> value of the I<args> HASH-ref passed as the third parameter
to the C<feed> function as part of the (re)navigation to the sub-menu(s).

Any search-input string will also be so passed as the C<search> value.

=back

All values of this C<params> HASH will be passed in the C<params> value
of the I<args> HASH-ref passed as the third parameter to the C<feed> function
when it is invoked at the top level.

=back

Note that both C<id> and C<name> should be unique
and should not be one of the standard IDs or name strings used by BrowseLibrary.
That means that if, for example, one wants to replace the B<Artists> menu item,
one cannot use C<BROWSE_BY_ARTIST> as the C<name> string;
one must supply one's own string with a unique name,
but quite possibly using the same localized string values.

=head2 deregisterNode()

Remove a previously registered menu item specified by its C<id>.

I<Caution:> will not restore any default BrowseLibrary handlers that had been overridden
using a C<params =E<gt> mode> value of one of the default handlers.

=head2 registerNodeFilter()

Register a function to be called when a menu is being displayed to determine whether that
menu item should be included.

Passed the Slim::Player::Client for which the menu is being built, if it is a client-specific menu,
and the C<id> of the menu item.

Multiple filter functions can be registered.

If the condition associated with a menu item itself (if any),
or any of the registered filter functions,
return false then the menu item will not be included;
otherwise it will be included.

=head2 deregisterNodeFilter()

Deregister a menu-item filter.
If this method is going to be called then both registerNodeFilter() & deregisterNodeFilter()
should be passed a reference to a real sub (not an anonymous one).

=cut


use strict;
use JSON::XS::VersionOneAndTwo;

use Slim::Menu::BrowseLibrary::Releases;
use Slim::Menu::BrowseLibrary::Works;
use Slim::Music::VirtualLibraries;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

my $prefs = preferences('server');
my $log = logger('database.info');
my $cache;

use constant BROWSELIBRARY => 'browselibrary';

my $_initialized = 0;
my $_pendingChanges = 0;
my %nodes;
my @addedNodes;
my @deletedNodes;
my %extraItems;

# this can be set to a class which would give us access to remote LMS instances
my $remoteLibraryHandler;

my %browseLibraryModeMap = (
	tracks => \&_tracks,				# needs to be here because no top-level menu added via registerNode()
	playlistTracks => \&_playlistTracks,# needs to be here because no top-level menu added via registerNode()
);

my %nodeFilters;

sub registerNodeFilter {
	my ($class, $filter) = @_;

	if (!ref $filter eq 'CODE') {
		$log->error("Invalid filter: must be a CODE ref");
		return;
	}

	$nodeFilters{$filter} = $filter;
}

sub deregisterNodeFilter {
	my ($class, $filter) = @_;

	delete $nodeFilters{$filter};
}

sub registerNode {
	my ($class, $node) = @_;

	return unless $node->{'id'};

	if (!$node->{'id'} || ref $node->{'feed'} ne 'CODE') {
		logBacktrace('Invalid node specification');
		return 0;
	}

	if ($nodes{$node->{'id'}}) {
		logBacktrace('Duplicate node id: ', $node->{'id'});
		return 0;
	}

	$node->{'params'}->{'mode'} ||= $node->{'id'};
	$nodes{$node->{'id'}} = $node;
	$browseLibraryModeMap{$node->{'params'}->{'mode'}} = $node->{'feed'};

	# browse menu can contain a mix of browselibrary nodes and plugin nodes
	# ensure they are sorted consistently on all interfaces by always comparing weights
	Slim::Plugin::Base->getWeights()->{ $node->{'name'} } = $node->{'weight'};

	$class->_scheduleMenuChanges($node, undef);

	return 1;
}

sub deregisterNode {
	my ($class, $id) = @_;

	if (my $node = delete $nodes{$id}) {
		if ($browseLibraryModeMap{$node->{'params'}->{'mode'}} == $node->{'feed'}) {
			delete $browseLibraryModeMap{$node->{'params'}->{'mode'}};
		}
		delete Slim::Plugin::Base->getWeights()->{ $node->{'name'} };
		$class->_scheduleMenuChanges(undef, $node);
	}
}

sub registerExtraItem {
	my ($class, $category, $name, $handler) = @_;

	if (!$category || $category !~ /^(artist|album|track)$/) {
		$category ||= '';
		$log->error("Extra Item Registration failed: Invalid or missing category: '$category'");
	}

	if ($name && $handler && ref $handler) {
		$extraItems{$category}->{$name} = $handler;
	}
	else {
		$log->error('Extra Item Registration failed: Missing name or handler reference');
	}
}

sub getExtraItems {
	my $category = shift;

	return [ map {
		$extraItems{$category}->{$_}
	} sort keys %{$extraItems{$category}} ];
}

sub init {
	my $class = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug('init');

	$cache = Slim::Utils::Cache->new();

	{
		no strict 'refs';
		*{$class.'::'.'feed'}     = sub { \&_topLevel; };
		*{$class.'::'.'tag'}      = sub { BROWSELIBRARY };
		*{$class.'::'.'modeName'} = sub { BROWSELIBRARY };
		*{$class.'::'.'menu'}     = sub { undef };
		*{$class.'::'.'weight'}   = sub { 15 };
		*{$class.'::'.'type'}     = sub { 'link' };
	}

	$class->_registerBaseNodes();

	$class->_initCLI();

	if ( main::WEBUI ) {
		$class->_webPages;
	}

#	$class->_initSubmenus();

    $class->_initModes();

    Slim::Menu::GlobalSearch->registerInfoProvider( searchMyMusic => (
			isa  => 'top',
			func => \&_globalSearchMenu,
	) );

    Slim::Control::Request::subscribe(\&_libraryChanged, [['library'], ['changed']]);

    $_initialized = 1;
}

sub cliQuery {
 	my $request = shift;
	Slim::Control::XMLBrowser::cliQuery( BROWSELIBRARY, \&_topLevel, $request );
};

sub _initCLI {
	my ( $class ) = @_;

	# CLI support
	Slim::Control::Request::addDispatch(
		[ BROWSELIBRARY, 'items', '_index', '_quantity' ],
	    [ 0, 1, 1, \&cliQuery ]
	);

	Slim::Control::Request::addDispatch(
		[ BROWSELIBRARY, 'playlist', '_method' ],
		[ 1, 1, 1, \&cliQuery ]
	);
}

sub _addWebLink {
	my ($class, $node) = @_;

	# cache web pages based on the mode parameter
	if ( $node->{cache} && $node->{params} && $node->{params}->{mode} ) {
		my $regex = sprintf('\b%s\b.*?\bmode=%s\b', $class->tag, $node->{params}->{mode});
		Slim::Web::XMLBrowser->addCacheable(qr/$regex/i);
	}

	my $url = 'clixmlbrowser/clicmd=' . $class->tag() . '+items&linktitle=' . $node->{'name'};
	$url .= join('&', ('', map {$_ .'=' . $node->{'params'}->{$_}} keys %{$node->{'params'}}));
	$url .= '/';
	Slim::Web::Pages->addPageLinks("browse", { $node->{'name'} => $url });
	Slim::Web::Pages->addPageCondition($node->{'name'} => sub {
		return _conditionWrapper(shift, $node->{'id'}, $node->{'condition'})
	});
	Slim::Web::Pages->addPageLinks('icons', { $node->{'name'} => $node->{'icon'} }) if $node->{'icon'};
}

sub _webPages {
	my $class = shift;

	require Slim::Web::XMLBrowser;
	Slim::Web::XMLBrowser->init();

	Slim::Web::Pages->addPageFunction( $class->tag(), sub {
		my $client = $_[0];

		Slim::Web::XMLBrowser->handleWebIndex( {
			client  => $client,
			feed    => $class->feed( $client ),
			type    => $class->type( $client ),
			title   => $class->getDisplayName(),
			timeout => 35,
			args    => \@_
		} );
	} );

	foreach my $node (@{_getNodeList()}) {
		$class->_addWebLink($node);
	}
}

sub _addMode {
	my ($class, $node) = @_;

	Slim::Buttons::Home::addSubMenu('BROWSE_MUSIC', $node->{'name'}, {
		useMode   => $class->modeName(),
		header    => $node->{'name'},
		condition => sub {return _conditionWrapper(shift, $node->{'id'}, $node->{'condition'});},
		title     => '{' . $node->{'name'} . '}',
		%{$node->{'params'}},
	});

	if ($node->{'homeMenuText'}) {
		Slim::Buttons::Home::addMenuOption($node->{'name'}, {
			useMode   => $class->modeName(),
			header    => $node->{'homeMenuText'},
			title     => '{' . $node->{'homeMenuText'} . '}',
			%{$node->{'params'}},

		});
	}
}

sub _initModes {
	my $class = shift;

	Slim::Buttons::Common::addMode($class->modeName(), {}, sub { $class->setMode(@_) });

	foreach my $node (@{_getNodeList()}) {
		$class->_addMode($node);
	}
}

my $jiveUpdateCallback = \&Slim::Control::Jive::libraryChanged;

sub _libraryChanged {
	if ($jiveUpdateCallback) {
		$jiveUpdateCallback->();
	}
}

sub _scheduleMenuChanges {
	my $class = shift;

	my ($add, $del) = @_;

	return if !$_initialized;

	push @addedNodes, $add if $add;
	push @deletedNodes, $del if $del;

	return if $_pendingChanges;

	Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 1, \&_handleMenuChanges);

	$_pendingChanges = 1;
}

sub _handleMenuChanges {
	my $class = shift;
	# do deleted first, then added

	foreach my $node (@deletedNodes) {

		Slim::Buttons::Home::delSubMenu('BROWSE_MUSIC', $node->{'name'});
		if ($node->{'homeMenuText'}) {
			Slim::Buttons::Home::delMenuOption($node->{'name'});
		}

		if ( main::WEBUI ) {
			Slim::Web::Pages->delPageLinks("browse", $node->{'name'});
			Slim::Web::Pages->delPageLinks('icons', $node->{'name'}) if $node->{'icon'};
		}
	}

	foreach my $node (@addedNodes) {
		$class->_addMode($node);
		$class->_addWebLink($node) if main::WEBUI;
	}

	@addedNodes = ();
	@deletedNodes = ();
	$_pendingChanges = 0;

	_libraryChanged();
}

sub _conditionWrapper {
	my ($client, $id, $baseCondition) = @_;

	if ($baseCondition && !$baseCondition->($client, $id)) {
		return 0;
	}

	foreach my $filter (values %nodeFilters) {
		my $status;

		eval {
			$status = $filter->($client, $id)
		};

		if ($@) {
			$log->warn("Couldn't call menu-filter", main::DEBUGLOG ? Slim::Utils::PerlRunTime::realNameForCodeRef($filter) : 'unk', ": $@");
			# Assume true
			next;
		}

		if (!$status) {
			return 0;
		}
	}

	return 1;
}

sub _getNodeList {
	return [values %nodes];
}

sub isEnabledNode {
	my ($client, $nodeId) = @_;

	return if $client && $prefs->client($client)->get('disabled_' . $nodeId);

	return Slim::Schema::hasLibrary();
}

sub _registerBaseNodes {
	my $class = shift;

	my @topLevel = (
		# user configurable list of artists
		{
			type         => 'link',
			name         => 'BROWSE_BY_ARTIST',
			params       => {mode => 'artists'},
			feed         => \&_artists,
			icon         => 'html/images/artists.png',
			homeMenuText => 'BROWSE_ARTISTS',
			condition    => sub { isEnabledNode(@_) && $prefs->get('useUnifiedArtistsList') },
			id           => 'myMusicArtists',
			weight       => 10,
			cache        => 1,
		},
		# Album artists only
		{
			type         => 'link',
			name         => 'BROWSE_BY_ALBUMARTIST',
			params       => {
				mode => 'artists',
				role_id => 'ALBUMARTIST'
			},
			feed         => \&_artists,
			jiveIcon     => 'html/images/artists.png',
			icon         => 'html/images/artists.png',
			homeMenuText => 'BROWSE_ALBUMARTISTS',
			condition    => sub { isEnabledNode(@_) && !$prefs->get('useUnifiedArtistsList') },
			id           => 'myMusicArtistsAlbumArtists',
			weight       => 9,
			cache        => 1,
		},
		# All artists of all roles
		{
			type         => 'link',
			name         => 'BROWSE_BY_ALL_ARTISTS',
			params       => {
				mode => 'artists',
			},
			feed         => \&_artists,
			jiveIcon     => 'html/images/artists.png',
			icon         => 'html/images/artists.png',
			homeMenuText => 'ALL_ARTISTS',
			condition    => sub { isEnabledNode(@_) && !$prefs->get('useUnifiedArtistsList') },
			id           => 'myMusicArtistsAllArtists',
			weight       => 11,
			cache        => 1,
		},
		{
			type         => 'link',
			name         => 'BROWSE_BY_ALBUM',
			params       => {mode => 'albums'},
			feed         => \&_albumsOrReleases,
			icon         => 'html/images/albums.png',
			homeMenuText => 'BROWSE_ALBUMS',
			condition    => \&isEnabledNode,
			id           => 'myMusicAlbums',
			weight       => 20,
			cache        => 1,
		},
		{
			type         => 'link',
			name         => 'BROWSE_BY_GENRE',
			params       => {mode => 'genres'},
			feed         => \&_genres,
			icon         => 'html/images/genres.png',
			homeMenuText => 'BROWSE_GENRES',
			condition    => \&isEnabledNode,
			id           => 'myMusicGenres',
			weight       => 30,
			cache        => 1,
		},
		{
			type         => 'link',
			name         => 'BROWSE_BY_WORK',
			params       => {mode => 'works'},
			feed         => \&_works,
			icon         => 'html/images/playlists.png',
			homeMenuText => 'BROWSE_WORKS',
			condition    => \&isEnabledNode,
			id           => 'myMusicWorks',
			weight       => 35,
			cache        => 1,
		},
		{
			type         => 'link',
			name         => 'BROWSE_BY_YEAR',
			params       => {mode => 'years'},
			feed         => \&_years,
			icon         => 'html/images/years.png',
			homeMenuText => 'BROWSE_YEARS',
			condition    => \&isEnabledNode,
			id           => 'myMusicYears',
			weight       => 40,
			cache        => 1,
		},
		{
			type         => 'link',
			name         => 'BROWSE_NEW_MUSIC',
			icon         => 'html/images/newmusic.png',
			params       => {mode => 'albums', sort => 'new', wantMetadata => 1},
			                                                  # including wantMetadata is a hack for ip3k
			feed         => \&_albumsOrReleases,
			homeMenuText => 'BROWSE_NEW_MUSIC',
			condition    => \&isEnabledNode,
			id           => 'myMusicNewMusic',
			weight       => 50,
			cache        => 1,
		},
		{
			type         => 'link',
			name         => 'BROWSE_MUSIC_FOLDER',
			params       => {mode => 'bmf'},
			feed         => \&_bmf,
			icon         => 'html/images/musicfolder.png',
			homeMenuText => 'BROWSE_MUSIC_FOLDER',
			condition    => sub {
				return isEnabledNode(@_) && (scalar @{ Slim::Utils::Misc::getAudioDirs() } || scalar @{ Slim::Utils::Misc::getInactiveAudioDirs() });
			},
			id           => 'myMusicMusicFolder',
			weight       => 70,
			cache        => 0,		# don't cache BMF modes, as it should act on the latest disk content!
		},
		{
			type         => 'link',
			name         => 'SAVED_PLAYLISTS',
			params       => {mode => 'playlists'},
			feed         => \&_playlists,
			icon         => 'html/images/playlists.png',
			homeMenuText => 'SAVED_PLAYLISTS',
			condition    => sub {
								return unless isEnabledNode(@_);
								return 1 if Slim::Utils::Misc::getPlaylistDir();

								my $totals = Slim::Schema->totals($_[0]);
								return $totals->{playlist} if $totals;
							},
			id           => 'myMusicPlaylists',
			weight       => 80,
			cache        => 0,		# playlist pages can change as you can manipulate them without a rescan - don't cache
		},
		{
			type         => 'link',
			name         => 'SEARCH',
			params       => {mode => 'search'},
			feed         => \&_search,
			icon         => 'html/images/search.png',
			condition    => \&isEnabledNode,
			id           => 'myMusicSearch',
			weight       => 90,
		},
	);

	foreach (@topLevel) {
		$class->registerNode($_);
	}
}

sub getJiveMenu {
	my ($client, $baseNode, $updateCallback) = @_;

	$jiveUpdateCallback = $updateCallback if $updateCallback;

	my @myMusicMenu;

	foreach my $node (@{_getNodeList()}) {
		if (!_conditionWrapper($client, $node->{'id'}, $node->{'condition'})) {
			next;
		}

		my %menu = (
			text => cstring($client, $node->{'name'}),
			id   => $node->{'id'},
			node => $baseNode,
			weight => $node->{'weight'},
			actions => {
				go => {
					cmd    => [BROWSELIBRARY, 'items'],
					params => {
						menu => 1,
						%{$node->{'params'}},
					},

				},
			}
		);

		if ($node->{'homeMenuText'}) {
			$menu{'homeMenuText'} = cstring($client, $node->{'homeMenuText'});
		}

		# Default nodes use id to automatically set iconStyle on squeezeplay clients
		# The following allow nodes to set the iconStyle or icon explicity
		if ($node->{'iconStyle'}) {
			$menu{'iconStyle'} = $node->{'iconStyle'};
		}

		if ($node->{'jiveIcon'}) {
			$menu{'icon'} = $node->{'jiveIcon'};
		}

		push @myMusicMenu, \%menu;
	}

	return \@myMusicMenu;
}

sub setMode {
	my ( $class, $client, $method, $mode, $name ) = @_;

	if ($method eq 'pop') {

		Slim::Buttons::Common::popMode($client);
		return;
	}

	my $modeName = $class->getDisplayName();
	$name ||= $modeName;
	my $title = (uc($name) eq $name) ? cstring($client,  $name ) : $name;

	my %params = (
		header   => $name,
		modeName => $modeName,
		url      => $class->feed( $client ),
		title    => $title,
		timeout  => 35,
		mode     => $mode,
		%{$client->modeParams()},
	);
	Slim::Buttons::Common::pushModeLeft( $client, 'xmlbrowser', \%params );

	# we'll handle the push in a callback
	$client->modeParam( handledTransition => 1 );
}

our @topLevelArgs = qw(track_id artist_id genre_id album_id playlist_id year folder_id role_id library_id remote_library release_type work_id composer_id from_search subtitle grouping);

sub _topLevel {
	my ($client, $callback, $args, $pt) = @_;
	my $params = $args->{'params'} || $pt;

	if ($params) {
		my %args;

		if ($params->{'query'} && $params->{'query'} =~ /C<$1>=(.*)/) {
			$params->{$1} = $2;
		}

		# check whether we have a global or per player library ID set
		$params->{'library_id'} ||= Slim::Music::VirtualLibraries->getLibraryIdForClient($client);

		my @searchTags;
		for (@topLevelArgs) {
			push (@searchTags, $_ . ':' . $params->{$_}) if $params->{$_};
		}
		$args{'searchTags'}   = \@searchTags if scalar @searchTags;
		$args{'sort'}         = 'sort:' . $params->{'sort'} if $params->{'sort'};
		$args{'orderBy'}      = 'sort:' . $params->{'orderBy'} if $params->{'orderBy'};
		$args{'search'}       = $params->{'search'} if $params->{'search'};
		$args{'wantMetadata'} = $params->{'wantMetadata'} if $params->{'wantMetadata'};
		$args{'wantIndex'}    = $params->{'wantIndex'} if $params->{'wantIndex'};
		$args{'library_id'}   = $params->{'library_id'} if $params->{'library_id'};
		$args{'remote_library'} = $params->{'remote_library'} if $params->{'remote_library'};
		$args{'noEdit'}       = $params->{'noEdit'} if $params->{'noEdit'};
		$args{'work_id'}       = $params->{'work_id'} if $params->{'work_id'};

		if ($params->{'mode'}) {
			my %entryParams;
			for (@topLevelArgs, qw(sort search mode)) {
				$entryParams{$_} = $params->{$_} if $params->{$_};
			}
			main::INFOLOG && $log->is_info && $log->info('params=>', join('&', map {$_ . '=' . $entryParams{$_}} keys(%entryParams)));

			my $func = $browseLibraryModeMap{$params->{'mode'}};

			if (ref $func ne 'CODE') {
				$log->error('No feed method for mode: ', $params->{'mode'});
				return;
			}

			&$func($client,
				sub {
					my $opml = shift;
					$opml->{'query'} = \%entryParams;
					$callback->($opml, @_);
				},
				$args, \%args);
			return;
		}
	}

	$log->error("Routing failure: node mode param");
}

sub _generic {
	my ($client,
		$callback,      # func ref:  Callback function to XMLbowser: callback(hashOrArray_ref)
		$args,          # hash ref:  Additional parameters from XMLBrowser
		$query,         # string:    CLI query, single verb or array-ref;
                        #            command takes _index, _quantity and tagged params
		$queryTags,     # array ref: tagged params to pass to CLI query
		$resultsFunc,   # func ref:  func(HASHref cliResult) returns (HASHref result, ARRAYref extraItems);
						#            function to process results loop from CLI and generate XMLBrowser items
		$tags,          # string:    (optional) the value of the 'tags'	parameter to use - added to queryTags
		$getIndexList   # boolean:   (optional)
	) = @_;

	# remote_library might be part of the @searchTags. But it's to be consumed by
	# BrowseLibrary, rather than by the CLI.
	if (!$args->{remote_library}) {
		($args->{remote_library}) = map { /remote_library:(.*)/ && $1 } grep { $_ && /remote_library/ } @$queryTags;
	}

	# library_id:-1 is supposed to clear/override the global library_id
	$queryTags = [ grep {
		$_ && $_ !~ /(?:library_id\s*:\s*-1|remote_library)/
	} @$queryTags ];

	if (!$args->{remote_library} && !Slim::Schema::hasLibrary()) {

		$log->warn('Database not fully initialized yet - return dummy placeholder');

		logBacktrace('no callback') unless $callback;

		$callback->({
			items => [ {
				type  => 'text',
				title => cstring($client, 'LIBRARY_NOT_READY'),
			} ],
			total => 1
		});

		return;
	}

	my $index = $args->{'index'} || 0;
	my $quantity = $args->{'quantity'};

	my $indexList;

	# Define a bunch of callbacks to as we might need to run this in async mode

	# callback to process the resulting data
	my $requestDone = sub {
		my $results = shift || {};

		my ($result, $extraItems) = $resultsFunc->($results);

		$result ||= {};
		$extraItems ||= [];
		$quantity ||= 0;

		$result->{'indexList'} = $indexList if defined $indexList;
		$result->{'offset'}    = $index;
		my $total = $result->{'total'} = $results->{'count'} || 0;

		# We only add the "play all" etc. extra-items if the total is 2 or more
		if ($total < 2) {
			$extraItems = [ grep { !$_->{'skipIfSingleton'} } @$extraItems ];
		}

		if ($extraItems) {
			my $n = scalar @$extraItems;
			$result->{'total'} += $n;

			my $nResults = scalar @{$result->{'items'}};

			# Work out whether this result block should have the extra items added
			if ($quantity && $index && !$nResults) {
				# Only extra items in this result
				my $usedAlready = $index - $total;
				push @{$result->{'items'}}, @$extraItems[$usedAlready..$#$extraItems];
			} elsif ($quantity && $nResults < $quantity) {
				my $spaceLeft = $quantity - $nResults;
				$spaceLeft = $n if $n < $spaceLeft;
				push @{$result->{'items'}}, @$extraItems[0..($spaceLeft-1)];
			} else {
				# just add them all
				push @{$result->{'items'}}, @$extraItems;
			}
		}

		if ( !$args->{search} && (!$result->{items} || !scalar @{ $result->{items} }) ) {
			$result->{items} = [ {
				type  => 'text',
				title => cstring($client, 'EMPTY'),
			} ];

			$result->{total} = 1;
		}

		logBacktrace('no callback') unless $callback;

		$callback->($result);
	};

	# callback to run the actual request
	my $execRequest = sub {
		push @$queryTags, 'tags:' . $tags if defined $tags;

		main::INFOLOG && $log->is_info && $log->info("$query ($index, $quantity): tags ->", join(', ', @$queryTags));

		my $requestRef = [ (ref $query ? @$query : $query), $index, $quantity, @$queryTags ];

		_doRequest($client, $requestRef, $requestDone, $args);
	};

	if ($getIndexList && $quantity && $quantity != 1) {
		# quantity == 1 is special and only used when (re)traversing the tree before getting to the desired leaf

		my $gotIndexList = sub {
			my $results = shift || {};
			$indexList = $results->{indexList};

			# find where our index starts and then where it needs to end
			if ($indexList) {
				my $total = 0;

				map { $total += $_->[1] } @$indexList;

				# don't browse beyond the end
				$index = 0 if $total <= $index;
				$total = 0;

				foreach (@$indexList) {
					$total += $_->[1];
					if ($total >= $index + $quantity) {
						$quantity = $total - $index;
						last;
					}
				}
			}

			$execRequest->();
		};

		# Get the page-bar and update quantity if necessary so that all of the last category is returned

		my @newTags = @$queryTags;
		push @newTags, 'tags:' . ($tags || '') . 'ZZ';

		main::INFOLOG && $log->is_info && $log->info("$query (0, 1): tags ->", join(', ', @newTags));

		my $requestRef = [ (ref $query ? @$query : $query), 0, 1, @newTags ];

		_doRequest($client, $requestRef, $gotIndexList, $args);
	}
	else {
		$execRequest->();
	}
}

# Wrapper function to run a query either locally using Slim::Control::Request,
# or on a remote server using JSONRPC.
sub _doRequest {
	my ($client, $requestRef, $callback, $args) = @_;

	if ( $remoteLibraryHandler && (my $remote_library = $args->{remote_library}) ) {
		$remoteLibraryHandler->remoteRequest($remote_library,
			[ '', $requestRef ],
			$callback
		);
	}
	else {
		my $request = Slim::Control::Request->new( $client ? $client->id() : undef, $requestRef );
		$request->execute();

		if ( $request->isStatusError() ) {
			$log->error($request->getStatusText());
		}

		$callback->($request->getResults());
	}
}

sub _search {
	my ($client, $callback, $args, $pt) = @_;
	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};

	my $items = searchItems($client);

	if ( !$remote_library &&  (my $library_id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client)) ) {
		foreach (@$items) {
			$_->{'passthrough'} = [
				{ 'library_id' => $library_id }
			];
		}
	}

	if ( $remote_library ) {
		foreach (@$items) {
			$_->{'passthrough'} ||= [];
			push @{$_->{'passthrough'}}, { 'remote_library' => $remote_library };
		}
	}

	$callback->( {
		name  => cstring($client, 'SEARCH'),
		icon => 'html/images/search.png',
		items => $items,
	} );
}

sub _globalSearchMenu {
	my ( $client, $tags ) = @_;

	my $items = searchItems($client);

	my $library_id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);

	foreach (@$items) {
		$_->{'type'} = 'link';
		$_->{'searchParam'} = $tags->{search};
		$_->{'passthrough'} = [
			{ 'library_id' => $library_id }
		] if $library_id;
	}

	return {
		name  => cstring($client, 'MY_MUSIC'),
		items => $items,
		type  => 'opml',
	};
}

sub searchItems {
	my $client = shift;

	return [
		{
			type => 'search',
			name => cstring($client, 'BROWSE_BY_ARTIST'),
			icon => 'html/images/search.png',
			url  => $browseLibraryModeMap{'artists'},
			cachesearch => 'ARTISTS',
		},
		{
			type => 'search',
			name => cstring($client, 'BROWSE_BY_ALBUM'),
			icon => 'html/images/search.png',
			url  => $browseLibraryModeMap{'albums'},
			cachesearch => 'ALBUMS',
		},
		{
			type => 'search',
			name => cstring($client, 'BROWSE_BY_WORK'),
			icon => 'html/images/search.png',
			url  => $browseLibraryModeMap{'works'},
			cachesearch => 'WORKS',
		},
		{
			type => 'search',
			name => cstring($client, 'BROWSE_BY_SONG'),
			icon => 'html/images/search.png',
			url  => $browseLibraryModeMap{'tracks'},
			cachesearch => 'SONGS',
		},
		{
			type => 'search',
			name => cstring($client, 'PLAYLISTS'),
			icon => 'html/images/search.png',
			url  => $browseLibraryModeMap{'playlists'},
			cachesearch => 'PLAYLISTS',
		},
	];
}

sub _tagsToParams {
	my $tags = shift;
	my %p;
	foreach (@$tags) {
		my ($k, $v) = /([^:]+):(.+)/;
		$p{$k} = $v;
	}
	return \%p;
}

sub _artists {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();
	my $search     = $pt->{'search'};
	my $library_id = $args->{'library_id'} || $pt->{'library_id'};
	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};
	my $mode = $args->{'params'}->{'mode'};
	my $roleIdParam = $args->{'params'}->{'role_id'};

	if (!$search && !scalar @searchTags && $args->{'search'}) {
		push @searchTags, 'library_id:' . $library_id if $library_id;
		$search = $args->{'search'};
	}

	my @ptSearchTags = @searchTags;
	@ptSearchTags = grep {$_ !~ /^genre_id:/} @ptSearchTags if _getPref('noGenreFilter', $remote_library);

	if ( _getPref('noRoleFilter', $remote_library) ) {
		@ptSearchTags = grep {$_ !~ /^role_id:/} @ptSearchTags if $mode && $mode eq 'artists';
	} else {

		# if single artist list, filter is the default role list _plus_ what we specifically want
		if ( _getPref('useUnifiedArtistsList', $remote_library) ) {
			my @roles = grep {$_ =~ /^role_id:/} @ptSearchTags;
			@roles = map {
				/role_id:(.*)/;
				Slim::Schema::Contributor->roleToType($1);
			} @roles  if @roles;

			if ( $mode && $mode eq 'artists' ) {
				push @roles, 'ARTIST', 'TRACKARTIST', 'ALBUMARTIST';

				# Loop through each pref to see if the user wants to show that contributor role.
				foreach (Slim::Schema::Contributor->contributorRoles) {
					if (_getPref(lc($_) . 'InArtists', $remote_library)) {
						push @roles, $_;
					}
				}

				push @ptSearchTags, 'role_id:' . join(',', @roles);
			}
		}
	}

	# only get external artists without album if no filter is set
	my $queryTags = 'Es';
	if ( ($library_id && $library_id ne (Slim::Music::VirtualLibraries->getLibraryIdForClient($client) || ''))
		|| ($search && !scalar grep { $_ !~ /^library_id:/} @searchTags)
		|| (scalar grep { $_ !~ /^role_id:.*ALBUMARTIST|^library_id:/} @searchTags)
	) {
		$queryTags = 's';
	}
	else {
		push @searchTags, 'include_online_only_artists:1'
	}

	#For use down the line in _releases
	push @ptSearchTags, 'menu_mode:' . $mode if $mode;
	push @ptSearchTags, 'menu_roles:' . $roleIdParam if $roleIdParam;

	_generic($client, $callback, $args, 'artists',
		[@searchTags, ($search ? 'search:' . $search : undef)],
		sub {
			my $results = shift;
			my $items = $results->{'artists_loop'};
			$remote_library ||= $args->{'remote_library'};

			foreach (@$items) {
				$_->{'name'}          = $_->{'artist'};
				$_->{'type'}          = 'playlist';
				$_->{'playlist'}      = \&_tracks;
				$_->{'url'}           = \&_albumsOrReleases;
				$_->{'passthrough'}   = [ { searchTags => [@ptSearchTags, "artist_id:" . $_->{'id'}], remote_library => $remote_library } ];
				$_->{'favorites_url'} = 'db:contributor.name=' .
						URI::Escape::uri_escape_utf8( $_->{'name'} );
			}
			my $extra;
			if (scalar grep { $_ !~ /role_id|remote_library/ } @searchTags) {
				my $params = _tagsToParams(\@searchTags);
				$extra = [ {
					name        => cstring($client, 'ALL_ALBUMS'),
					type        => $remote_library ? 'link' : 'playlist',
					playlist    => $remote_library ? undef : \&_tracks,
					url         => \&_albums,
					passthrough => [{ searchTags => \@searchTags }],
					skipIfSingleton => 1,
					itemActions => {
						allAvailableActionsDefined => 1,
						info => {
							command     => [],
						},
						items => {
							command     => [BROWSELIBRARY, 'items'],
							fixedParams => {
								mode       => 'albums',
								%$params,
							},
						},
						play => $remote_library ? undef : {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'load', %$params},
						},
						add => $remote_library ? undef : {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'add', %$params},
						},
						insert => $remote_library ? undef : {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'insert', %$params},
						},
						remove => $remote_library ? undef : {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'delete', %$params},
						},
					},
				} ];
			}

			elsif ($search) {
				my $strings = Slim::Utils::Text::searchStringSplit($search)->[0];

				my $sql;
				if ( ref $strings eq 'ARRAY' ) {
					$_ =~ s/'/''/g foreach @$strings;
					$sql = '(' . join( ' OR ', map { "contributors.namesearch LIKE '" . $_ . "'"} @$strings ) . ')';
				} else {
					$strings =~ s/'/''/g;
					$sql = "contributors.namesearch LIKE '" . $strings . "'";
				}

				my %params = (
					mode       => 'tracks',
					sort       => 'albumtrack',
					menuStyle  => 'menuStyle:allSongs',
					search     => 'sql=' . $sql,
				);

				my %actions = (
					allAvailableActionsDefined => 1,
					info   => {
						command => [BROWSELIBRARY, 'items'],
						fixedParams => {mode => 'artists', search => $search, item_id => $results->{'count'}},
					},
					items  => {command => [BROWSELIBRARY, 'items'],              fixedParams => \%params},
					play   => {command => [BROWSELIBRARY, 'playlist', 'play'],   fixedParams => \%params},
					add    => {command => [BROWSELIBRARY, 'playlist', 'add'],    fixedParams => \%params},
					insert => {command => [BROWSELIBRARY, 'playlist', 'insert'], fixedParams => \%params},
					remove => {command => [BROWSELIBRARY, 'playlist', 'delete'], fixedParams => \%params},
				);

				$extra = [ {
					name        => cstring($client, 'ALL_SONGS'),
					type        => 'playlist',
					playlist    => \&_tracks,
					url         => \&_tracks,
					passthrough => [{ search => 'sql=' . $sql, sort => 'sort:albumtrack', menuStyle => 'menuStyle:allSongs' }],
					itemActions => \%actions,
					skipIfSingleton => 1,
				} ];
			}

			my $params = _tagsToParams(\@ptSearchTags);
			my %actions = $remote_library ? (
				commonVariables	=> [artist_id => 'id'],
			) : (
				allAvailableActionsDefined => 1,
				commonVariables	=> [artist_id => 'id'],
				info => {
					command     => ['artistinfo', 'items'],
				},
				items => {
					command     => [BROWSELIBRARY, 'items'],
					fixedParams => {
						mode       => 'albums',
						%$params,
					},
				},
				play => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'load', %$params},
				},
				add => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'add', %$params},
				},
				insert => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'insert', %$params},
				},
				remove => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'delete', %$params},
				},
			);
			$actions{'playall'} = $actions{'play'};
			$actions{'addall'} = $actions{'add'};

			return {items => $items, actions => \%actions, sorted => 1}, $extra;
		},
		$queryTags, $pt->{'wantIndex'} || $args->{'wantIndex'},
	);
}

sub _genres {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();
	my $search     = $pt->{'search'};
	my $library_id = $args->{'library_id'} || $pt->{'library_id'};
	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};

	if (!$search && !scalar @searchTags && $args->{'search'}) {
		push @searchTags, 'library_id:' . $library_id if $library_id;
		$search = $args->{'search'};
	}

	_generic($client, $callback, $args, 'genres',
		[@searchTags, ($search ? 'search:' . $search : undef)],
		sub {
			my $results = shift;
			my $items = $results->{'genres_loop'};

			$remote_library ||= $args->{'remote_library'};

			push @searchTags, "role_id:ALBUMARTIST" if !_getPref('useUnifiedArtistsList', $remote_library);

			foreach (@$items) {
				$_->{'name'}          = $_->{'genre'};
				$_->{'type'}          = 'playlist';
				$_->{'playlist'}      = \&_tracks;
				$_->{'url'}           = \&_artists;
				$_->{'passthrough'}   = [ { searchTags => [@searchTags, "genre_id:" . $_->{'id'}], remote_library => $remote_library } ];
				$_->{'favorites_url'} = 'db:genre.name=' .
						URI::Escape::uri_escape_utf8( $_->{'name'} );
			};

			my $params = _tagsToParams(\@searchTags);
			my %actions = $remote_library ? (
				commonVariables	=> [genre_id => 'id'],
			) : (
				allAvailableActionsDefined => 1,
				commonVariables	=> [genre_id => 'id'],
				info => {
					command     => ['genreinfo', 'items'],
				},
				items => {
					command     => [BROWSELIBRARY, 'items'],
					fixedParams => {mode => 'artists', %$params},
				},
				play => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'load', %$params},
				},
				add => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'add', %$params},
				},
				insert => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'insert', %$params},
				},
			);
			$actions{'playall'} = $actions{'play'};
			$actions{'addall'} = $actions{'add'};

			return {items => $items, actions => \%actions, sorted => 1}, undef;
		},
		's', $pt->{'wantIndex'} || $args->{'wantIndex'},
	);
}

sub _years {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();
	my $library_id = $args->{'library_id'} || $pt->{'library_id'};
	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};

	if ($library_id && !grep /library_id/, @searchTags) {
		push @searchTags, 'library_id:' . $library_id if $library_id;
	}

	_generic($client, $callback, $args, 'years', [ 'hasAlbums:1', @searchTags ],
		sub {
			my $results = shift;
			my $items = $results->{'years_loop'};
			$remote_library ||= $args->{'remote_library'};
			foreach (@$items) {
				$_->{'name'}          = $_->{'year'};
				$_->{'type'}          = 'playlist';
				$_->{'playlist'}      = \&_tracks;
				$_->{'url'}           = \&_albums;
				$_->{'passthrough'}   = [ { searchTags => [@searchTags, "year:" . $_->{'year'}], remote_library => $remote_library } ];
				$_->{'favorites_url'} = 'db:year.id=' . ($_->{'name'} || 0 );
			};

			my $params = _tagsToParams(\@searchTags);
			my %actions = $remote_library ? (
				commonVariables	=> [year => 'name'],
			) : (
				allAvailableActionsDefined => 1,
				commonVariables	=> [year => 'name'],
				info => {
					command     => ['yearinfo', 'items'],
				},
				items => {
					command     => [BROWSELIBRARY, 'items'],
					fixedParams => {
						mode       => 'albums',
						%$params
					},
				},
				play => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'load', %$params},
				},
				add => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'add', %$params},
				},
				insert => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'insert', %$params},
				},
			);
			$actions{'playall'} = $actions{'play'};
			$actions{'addall'} = $actions{'add'};

			return {items => $items, actions => \%actions, sorted => 1}, undef;
		},
	);
}

my %orderByList = (
	ALBUM                => 'album',
	SORT_YEARALBUM       => 'yearalbum',
	SORT_YEARARTISTALBUM => 'yearartistalbum',
	SORT_ARTISTALBUM     => 'artistalbum',
	SORT_ARTISTYEARALBUM => 'artflow',
);

my %mapArtistOrders = (
	album            => 'album',
	yearalbum        => 'yearalbum',
	yearartistalbum  => 'yearalbum',
	artistalbum      => 'album',
	artflow          => 'yearalbum'
);

sub _albumsOrReleases {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();

	# We only display the grouped albums if:
	# 1. the feature is enabled
	if (!$prefs->get('ignoreReleaseTypes') && $prefs->get('groupArtistAlbumsByReleaseType')
		# 2. a specific artist is requested or user wants release type groups always
		&& ( $prefs->get('groupArtistAlbumsByReleaseType') == 2 || grep /^artist_id:/, @searchTags )
		# 3. not from works menu:
		&& !(grep /^work_id:/, @searchTags)
		# 4. any one of the following is true:
		#    4a. we don't apply a role filter (eg. drilling down from a "Composers" menu)
		&& ($prefs->get('noRoleFilter')
			# 4b. no specific role is requested
			|| !(grep /^role_id:/, @searchTags)
			# 4c. we request the album artist or composer
			|| (grep /^role_id:.*(ALBUMARTIST|2|COMPOSER)/, @searchTags)
		)
	) {
		_releases(@_);
	}
	else {
		_albums(@_);
	}
}

sub _albums {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();
	my $sort       = $pt->{'sort'};
	my $search     = $pt->{'search'};
	my $wantMeta   = $pt->{'wantMetadata'};
	# aa & SS will get all contributors and IDs in addition to the main contributor (albums.contributor) - slower but more accurate
	my $tags       = 'ljsaaSSKE';
	my $library_id = $args->{'library_id'} || $pt->{'library_id'};
	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};

	if (!$sort || $sort !~ /^sort:(?:random|new)$/) {
		$sort = $pt->{'orderBy'} || $args->{'orderBy'} || $sort;
	}
	$sort = 'sort:' . $sort if $sort && $sort !~ /^sort:/;

	if (!$search && !scalar @searchTags && $args->{'search'}) {
		push @searchTags, 'library_id:' . $library_id if $library_id;
		$search = $args->{'search'};
	}

	# filter out some release types if wanted, unless we are already filtering for a release type
	my %releaseTypesToIgnore = map { $_ => 1 } @{ $prefs->get('releaseTypesToIgnore') || [] };
	if ( keys %releaseTypesToIgnore && !grep /^release_type:/, @searchTags) {
		push @searchTags, 'release_type:' . join(',', grep {
			!$releaseTypesToIgnore{$_}
		} @{Slim::Schema::Album->releaseTypes});
	}

	my @artistIds = grep /artist_id:/, @searchTags;
	my $artistId;
	if (scalar @artistIds) {
		$artistIds[0] =~ /artist_id:(\d+)/;
		$artistId = $1;
	}

	$tags .= 'y' unless grep {/^year:/} @searchTags;

	# Remove artist from sort order if selection includes artist
	if ($sort && $sort =~ /sort:(.*)/) {
		my $mapped;
		if ($artistId && ($mapped = $mapArtistOrders{$1})) {
			$sort = 'sort:' . $mapped;
		}
		$sort = undef unless grep {$_ eq $1} ('new', 'random', values %orderByList);
	}

	# Under certain circumstances (random albums in web UI or with remote streams) we are only
	# to return one item. In this case pull a list of IDs from the cache, as requesting a bunch
	# of random albums would retun a different list than what we were showing the user.
	my $cacheKey = 'randomAlbumIDs_' . ($client ? $client->id : '') if $sort && $sort =~ 'random';

	# shortcut if we hit a cached list
	if ( $cacheKey && $args->{quantity} && $args->{quantity} == 1 && (my $cached = $cache->get($cacheKey)) ) {
		if ( ref $cached && ref $cached eq 'HASH' ) {
			$cached->{items} = [ map { $_->{'playlist'} = $_->{'url'} = \&_tracks; $_ } @{$cached->{items}} ];
			$callback->($cached);
			return;
		}
	}

	my $trackArtistOnly = grep /role_id:TRACKARTIST/, @searchTags;

	_generic($client, $callback, $args, 'albums',
		[@searchTags, ($sort ? $sort : ()), ($search ? 'search:' . $search : undef)],
		sub {
			my $results = shift;
			my $items = $results->{'albums_loop'};
			$remote_library ||= $args->{'remote_library'};

			foreach (@$items) {
				$_->{'name'} = $_->{'composer'} ? $_->{'composer'} . cstring($client, 'COLON') . ' ' : '';
				if ( $_->{'work_id'} ) {
					$_->{'name'} .= $_->{'work_name'} . ' (';
					$_->{'name'} .= "$_->{'grouping'} " if $_->{'grouping'};
					$_->{'name'} .= cstring($client,'FROM') . ' ';
				}
				$_->{'name'}          .= $_->{'album'};
				$_->{'name'}          .= ')' if $_->{'work_id'};
				$_->{'image'}         = 'music/' . $_->{'artwork_track_id'} . '/cover' if $_->{'artwork_track_id'};
				$_->{'image'}       ||= $_->{'artwork_url'} if $_->{'artwork_url'};
				$_->{'type'}          = 'playlist';
				$_->{'playlist'}      = \&_tracks;
				$_->{'url'}           = \&_tracks;
				$_->{'passthrough'}   = [ { searchTags => [@searchTags, "album_id:" . $_->{'id'}, "grouping:" . $_->{'grouping'}], sort => 'sort:tracknum', remote_library => $remote_library } ];
				# the favorites url is the album title and contributor name here (or extid for online albums)
				# album id would be (much) better, but that would screw up the favorite on a rescan
				# title is a really stupid thing to use, since there's no assurance it's unique
				my $favoritesUrl = $_->{'work_id'}
					? sprintf('db:album.title=%s&contributor.name=%s&work.title=%s&composer.name=%s&track.grouping=%s',
						URI::Escape::uri_escape_utf8($_->{'album'}), URI::Escape::uri_escape_utf8($_->{'artist'}),
						URI::Escape::uri_escape_utf8($_->{'work_name'}), URI::Escape::uri_escape_utf8($_->{'composer'}), URI::Escape::uri_escape_utf8($_->{'grouping'}))
					: sprintf('db:album.title=%s&contributor.name=%s', URI::Escape::uri_escape_utf8($_->{'album'}), URI::Escape::uri_escape_utf8($_->{'artist'}));
				$_->{'favorites_url'} = $_->{'extid'} || $favoritesUrl;

				if ($_->{'artist_ids'}) {
					$_->{'artists'} = $_->{'artist_ids'} =~ /,/ ? [ split /(?<!\s),(?!\s)/, $_->{'artists'} ] : [ $_->{'artists'} ];
					$_->{'artist_ids'} = [ split /,/, $_->{'artist_ids'} ];    # / syntax highlighters get easily confused...
				}
				else {
					$_->{'artists'}    = [ $_->{'artist'} ];
					$_->{'artist_ids'} = [ $_->{'id'} ];
				}

				# If an artist was not used in the selection criteria or if one was
				# used but is different to that of the primary artist, then provide
				# the primary artist name in name2.
				if (!$artistId || $artistId != $_->{'artist_id'} || $trackArtistOnly || $_->{'work_id'}) {
					$_->{'name2'} = join(', ', @{$_->{'artists'} || []}) || $_->{'artist'};
				}

				if (!$wantMeta) {
					delete $_->{'artist'};
				}

				$_->{'hasMetadata'}   = 'album';

				if ($remote_library) {
					$_->{'image'} = _proxiedImageUrl($_, $remote_library);
					delete $_->{'artwork_track_id'};
				}
			}

			my $extra;
			if ((scalar grep { $_ !~ /remote_library/ } @searchTags) && $sort !~ /:(?:new|random)/) {
				my $params = _tagsToParams(\@searchTags);

				if ($params->{artist_id}) {
					$extra = [ grep { $_ } map {
						$_->($params->{artist_id});
					} @{getExtraItems('artist')} ];
				}

				my %actions = $remote_library ? (
					commonVariables	=> [album_id => 'id', grouping => 'grouping'],
				) : (
					allAvailableActionsDefined => 1,
					info => {
						command     => [],
					},
					items => {
						command     => [BROWSELIBRARY, 'items'],
						fixedParams => {
							mode       => 'tracks',
							%{&_tagsToParams(\@searchTags)},
						},
					},
					play => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'load', %$params},
					},
					add => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'add', %$params},
					},
					insert => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'insert', %$params},
					},
					remove => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'delete', %$params},
					},
				);
				$actions{'playall'} = $actions{'play'};
				$actions{'addall'} = $actions{'add'};

				push @$extra, {
					name        => cstring($client, 'ALL_SONGS'),
					icon        => 'html/images/albums.png',
					type        => 'playlist',
					playlist    => \&_tracks,
					url         => \&_tracks,
					passthrough => [{ searchTags => \@searchTags, sort => 'sort:albumtrack', menuStyle => 'menuStyle:allSongs' }],
					itemActions => \%actions,
					skipIfSingleton => 1,
				};

			}
			elsif ($search) {
				my $strings = Slim::Utils::Text::searchStringSplit($search)->[0];

				my $sql;
				if ( ref $strings eq 'ARRAY' ) {
					$_ =~ s/'/''/g foreach @$strings;
					$sql = '(' . join( ' OR ', map { "albums.titlesearch LIKE '" . $_ . "'"} @$strings ) . ')';
				} else {
					$strings =~ s/'/''/g;
					$sql = "albums.titlesearch LIKE '" . $strings . "'";
				}

				my %params = (
					mode       => 'tracks',
					sort       => 'albumtrack',
					menuStyle  => 'menuStyle:allSongs',
					search     => 'sql=' . $sql,
				);

				my %actions = (
					allAvailableActionsDefined => 1,
					info   => {
						command => [BROWSELIBRARY, 'items'],
						fixedParams => {mode => 'albums', search => $search, item_id => $results->{'count'}},
					},
					items  => {command => [BROWSELIBRARY, 'items'],              fixedParams => \%params},
					play   => {command => [BROWSELIBRARY, 'playlist', 'play'],   fixedParams => \%params},
					add    => {command => [BROWSELIBRARY, 'playlist', 'add'],    fixedParams => \%params},
					insert => {command => [BROWSELIBRARY, 'playlist', 'insert'], fixedParams => \%params},
					remove => {command => [BROWSELIBRARY, 'playlist', 'delete'], fixedParams => \%params},
				);

				$extra = [ {
					name        => cstring($client, 'ALL_SONGS'),
					icon        => 'html/images/albums.png',
					type        => 'playlist',
					playlist    => \&_tracks,
					url         => \&_tracks,
					passthrough => [{ search => 'sql=' . $sql, sort => 'sort:albumtrack', menuStyle => 'menuStyle:allSongs' }],
					itemActions => \%actions,
					skipIfSingleton => 1
				} ];
			}

			my $params = _tagsToParams(\@searchTags);
			my %actions = $remote_library ? (
				commonVariables	=> [album_id => 'id', grouping => 'grouping'],
			) : (
				allAvailableActionsDefined => 1,
				commonVariables	=> [album_id => 'id', grouping => 'grouping'],
				info => {
					command     => ['albuminfo', 'items'],
					fixedParams => $params,
				},
				items => {
					command     => [BROWSELIBRARY, 'items'],
					fixedParams => {
						mode       => 'tracks',
						%$params,
					},
				},
				play => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'load', %$params},
				},
				add => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'add', %$params},
				},
				insert => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'insert', %$params},
				},
				remove => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'delete', %$params},
				},
			);
			$actions{'playall'} = $actions{'play'};
			$actions{'addall'} = $actions{'add'};

			my $result = {
				items       => $items,
				actions     => \%actions,
				sorted      => (($sort && $sort =~ /^sort:(?:random|new)$/) ? 0 : 1),
				orderByList => (defined($search) || ($sort && $sort =~ /^sort:(?:random|new)$/) ? undef : \%orderByList),
			};

			if ( $cacheKey && $args->{quantity} && $args->{quantity} > 1 ) {
				$cache->set($cacheKey, {
					items => [ map {
						delete $_->{'url'};
						delete $_->{'playlist'};
						$_;
					} @{$result->{items}} ],
					actions => $result->{actions},
					sorted => $result->{sorted},
					orderByList => $result->{orderByList},
				}, 86400);
			}
			return $result, $extra;
		},
		# no need for an index bar in New Music mode
		$tags, ($pt->{'wantIndex'} || $args->{'wantIndex'}) && !($sort && $sort =~ /^sort:(random|new)$/),
	);
}

sub _tracks {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();
	my $sort       = $pt->{'sort'} || 'sort:albumtrack';
	my $menuStyle  = $pt->{'menuStyle'} || 'menuStyle:album';
	my $search     = $pt->{'search'};
	my $offset     = $args->{'index'} || 0;
	my $getMetadata= $pt->{'wantMetadata'} && grep {/album_id:/} @searchTags;
	my $tags       = 'dtuxgaAsSliqyorf';
	my $library_id = $args->{'library_id'} || $pt->{'library_id'};
	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};

	if (!defined $search && !scalar @searchTags && defined $args->{'search'}) {
		push @searchTags, 'library_id:' . $library_id if $library_id;
		$search = $args->{'search'};
	}

	# when searching we don't want tracks to be sorted by album first
	if ($search && !$pt->{'sort'}) {
		$sort = undef;
	}

	# Sanity check
	if ((!defined $search || !length($search)) && !scalar @searchTags) {
		$log->error('Invalid request: no search term or album/artist/genre tags');
		$callback->({title => 'Invalid request: no search term or album/artist/genre tags'});
		return;
	}

	$tags .= 'k' if $pt->{'wantMetadata'};

	my ($addAlbumToName2, $addArtistToName2);
	if ($addAlbumToName2  = !(grep {/album_id:/} @searchTags)) {
		$addArtistToName2 = !(grep {/artist_id:/} @searchTags);
		$tags            .= 'cJK'; # artwork
	}

	_generic($client, $callback, $args, 'titles',
		["tags:$tags", $sort, $menuStyle, @searchTags, ($search ? 'search:' . $search : undef)],
		sub {
			my $results = shift;
			my $items   = $results->{'titles_loop'};
			$remote_library ||= $args->{'remote_library'};

			foreach (@$items) {
				# Map a few items that get different tags to those expected for TitleFormatter
				# Currently missing composer, conductor, band because of additional cost of 'A' tag query
				$_->{'ct'}            = $_->{'type'};
				if (my $secs = $_->{'duration'}) {
					$_->{'secs'}      = $secs;
					$_->{'duration'}  = sprintf('%d:%02d', int($secs / 60), $secs % 60);
				}
				$_->{'discc'}         = delete $_->{'disccount'} if defined $_->{'disccount'};
				$_->{'fs'}            = $_->{'filesize'};
				$_->{'hasMetadata'}   = 'track';

				$_->{'name'}          = $_->{'title'};

				$_->{'type'}          = 'audio';
				$_->{'playall'}       = 1;
				$_->{'play_index'}    = $offset++;

				# bug 17340 - in track lists we give the trackartist precedence over the artist
				if ( $_->{'trackartist'} ) {
					$_->{'artist'} = $_->{'trackartist'};
				}
				# if the track doesn't have an ARTIST or TRACKARTIST tag, use all contributors of whatever other role is defined
				elsif ( !$_->{'artist_ids'} ) {
					my $artist_id = $_->{'artist_id'};
					foreach my $role ('albumartist', 'band') {
						my $id = $role . '_ids';
						if ( $_->{$id} && $_->{$id} =~ /$artist_id/ ) {
							$_->{'artist'} = $_->{$role};
						}
					}
				}

				my $name2;
				$name2 = $_->{'artist'} if $addArtistToName2;
				if ($addAlbumToName2 && $_->{'album'}) {
					$name2 .= ' - ' if $name2;
					$name2 .= $_->{'album'};
				}
				if ($name2) {
					if ( $_->{'coverid'} ) {
						$_->{'artwork_track_id'} = $_->{'coverid'};
					}

					$_->{'name2'}     = $name2;
					$_->{'image'}     = 'music/' . $_->{'artwork_track_id'} . '/cover' if $_->{'artwork_track_id'};
					$_->{'image'}   ||= $_->{'artwork_url'} if $_->{'artwork_url'};
				}

				if ($remote_library) {
					$_->{'url'} = _proxiedStreamUrl($_, $remote_library);
					$_->{'image'} = _proxiedImageUrl($_, $remote_library) if $_->{'image'};
					delete $_->{'coverid'};
					delete $_->{'artwork_track_id'};
					$_->{'playall'} = 1;
				}
			}

			my $params = _tagsToParams(\@searchTags);

			my %actions = $remote_library ? (
				commonVariables	=> [track_id => 'id'],
			) : (
				commonVariables	=> [track_id => 'id'],
				allAvailableActionsDefined => 1,

				info => {
					command     => ['trackinfo', 'items'],
					fixedParams => $params,
				},
				play => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'load'},
				},
				add => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'add'},
				},
				insert => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'insert'},
				},
				remove => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'delete'},
				},
			);
			$actions{'items'} = $actions{'info'};	# XXX, not sure about this, probably harmless but unnecessary

			if ($search) {
				$actions{'playall'} = $actions{'play'};
				$actions{'addall'} = $actions{'all'};
			}

			my $extra;
			if ($search && $search !~ /^sql=/) {
				my $strings = Slim::Utils::Text::searchStringSplit($search)->[0];

				my $sql;
				if ( ref $strings eq 'ARRAY' ) {
					$_ =~ s/'/''/g foreach @$strings;
					$sql = '(' . join( ' OR ', map { "tracks.titlesearch LIKE '" . $_ . "'"} @$strings ) . ')';
				} else {
					$strings =~ s/'/''/g;
					$sql = "tracks.titlesearch LIKE '" . $strings . "'";
				}

				my %params = (
					mode       => 'tracks',
					sort       => 'albumtrack',
					menuStyle  => 'menuStyle:allSongs',
					search     => 'sql=' . $sql,
				);

				my %allSongsActions = (
					allAvailableActionsDefined => 1,

					# relies on side-effect of context menu, really should implement a searchTracksinfo command
					info   => {
						command => [BROWSELIBRARY, 'items'],
						fixedParams => {mode => 'tracks', search => $search, item_id => $results->{'count'}},
					},

					# no 'items' item as no need to browse into this item
					play   => {command => [BROWSELIBRARY, 'playlist', 'play'],   fixedParams => \%params},
					add    => {command => [BROWSELIBRARY, 'playlist', 'add'],    fixedParams => \%params},
					insert => {command => [BROWSELIBRARY, 'playlist', 'insert'], fixedParams => \%params},
				);

				$extra = [ {
					name        => cstring($client, 'ALL_SONGS'),
					icon        => 'html/images/albums.png',
					type        => 'playlist',
					# No url as we no not want to be able to browse this item,
					# but cannot use type=text because this would stop Slim::Control::XMLBrowser
					# adding play-control items in a context menu (see side-effect above for 'info' action)
					playlist    => \&_tracks,
					passthrough => [{ search => 'sql=' . $sql, sort => 'sort:albumtrack', menuStyle => 'menuStyle:allSongs' }],
					itemActions => \%allSongsActions,
					skipIfSingleton => 1,
				} ];

			} elsif (!$remote_library) {
				$actions{'playall'} = {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'load', %{&_tagsToParams([@searchTags, $sort])}},
					variables	=> [play_index => 'play_index'],
				};
				$actions{'addall'} = {
					command     => ['playlistcontrol'],
					variables	=> [],
					fixedParams => {cmd => 'add', %{&_tagsToParams([@searchTags, $sort])}},
				};
			}

			my $albumMetadata;
			my $albumInfo;
			my $image;
			if ($getMetadata) {
				my ($albumId) = grep {/album_id:/} @searchTags;
				$albumId =~ s/album_id:// if $albumId;
				my ($workId) = grep {/work_id:/} @searchTags;
				$workId =~ s/work_id:// if $workId;
				my $album = Slim::Schema->find( Album => $albumId );
				my $feed  = Slim::Menu::AlbumInfo->menu( $client, $album->url, $album, undef, { library_id => $library_id, work_id => $workId, track_count => scalar @$items} ) if $album;
				$albumMetadata = $feed->{'items'} if $feed;

				$image = 'music/' . $album->artwork . '/cover' if $album && $album->artwork;

				$albumInfo = {
					info => {
						command =>   ['albuminfo', 'items'],
						variables => [ 'album_id', 'id' ],
					},
				};
			}

			return {items => $items, actions => \%actions, sorted => 0, albumData => $albumMetadata, albumInfo => $albumInfo,
					cover => $image}, $extra;
		},
	);
}


sub _bmf {
	my ($client, $callback, $args, $pt) = @_;

	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();

	_generic($client, $callback, $args, 'musicfolder', ['tags:cdus' . ($remote_library ? 'o' : ''), @searchTags],
		sub {
			my $results = shift;
			my $gotsubfolder = 0;
			my $items = $results->{'folder_loop'};
			$remote_library ||= $args->{'remote_library'};

			my $cover;

			foreach (@$items) {
				$_->{'name'} = $_->{'filename'};
				if ($_->{'type'} eq 'folder') {
					$_->{'type'}        = 'playlist';
					$_->{'url'}         = \&_bmf;
					$_->{'passthrough'} = [ { searchTags => [ "folder_id:" . $_->{'id'} ], remote_library => $remote_library } ];
					$_->{'itemActions'} = {
						info => {
							command     => ['folderinfo', 'items'],
							fixedParams => {folder_id =>  $_->{'id'}},
						},
						play => {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'load', folder_id =>  $_->{'id'}},
						},
						add => {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'add', folder_id =>  $_->{'id'}},
						},
						insert => {
							command     => ['playlistcontrol'],
							fixedParams => {cmd => 'insert', folder_id =>  $_->{'id'}},
						},
					};
					$_->{'itemActions'}->{'playall'} = $_->{'itemActions'}->{'play'};
					$_->{'itemActions'}->{'addall'} = $_->{'itemActions'}->{'add'};
					$gotsubfolder = 1;
				}  elsif ($_->{'type'} eq 'track') {
					$_->{'type'}        = 'audio';
					$_->{'playall'}     = 1;

					$_->{'itemActions'} = {
						info => {
							command     => ['trackinfo', 'items'],
							fixedParams => {track_id =>  $_->{'id'}},
						},
					};

					if ( $_->{'coverid'} ) {
						$_->{'image'} = 'music/' . $_->{'coverid'} . '/cover';
						$_->{'artwork_track_id'} = $_->{'coverid'};
						$cover ||= $_->{'image'};
					}

					if ($remote_library) {
						$_->{'url'} = _proxiedStreamUrl($_, $remote_library);
						$cover = $_->{'image'} = _proxiedImageUrl($_, $remote_library) if $_->{'image'};
						$_->{'playall'} = 1,
					}
				}
				elsif ($_->{'type'} eq 'playlist' && Slim::Music::Info::isCUE($_->{'url'})) {
					$_->{'favorites_url'} =	$_->{'url'};
					$_->{'playlist'}	  = \&_playlistTracks;
					$_->{'url'}           = \&_playlistTracks;
					$_->{'passthrough'}   = [ {
						searchTags => [ "playlist_id:" . $_->{'id'} ],
						noEdit     => 1,
					} ];

					if ($remote_library) {
						$_->{'url'} = _proxiedStreamUrl($_, $remote_library);
						$_->{'playall'} = 1,
					}
				}
				# Playlists in BMF folders should be returned as volatile as they will most
				# likely have not been scanned and therefore not useful for browse.
				elsif ($_->{'type'} eq 'playlist') {
					$_->{'type'}          = 'audio';
					$_->{'url'}           =~ s/^file/tmp/;
					$_->{'favorites_url'} =	$_->{'url'};
					$_->{'playall'}     = 1;

					$_->{'itemActions'} = {
						info => {
							command     => ['trackinfo', 'items'],
							fixedParams => {track_id =>  $_->{'id'}},
						},
					};

					if ($remote_library) {
						$_->{'url'} = _proxiedStreamUrl($_, $remote_library);
						$_->{'playall'} = 1,
					}
				}
				else # if ($_->{'type'} eq 'unknown')
				{
					$_->{'type'}        = 'text';
				}
			}

			return {items => $items, sorted => 1, cover => $cover }, undef;
		},
	);
}

sub _playlists {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();
	my $search     = $pt->{'search'};
	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};

	if (!$search && !scalar @searchTags && $args->{'search'}) {
		push @searchTags, 'library_id:' . $args->{'library_id'} if $args->{'library_id'};
		$search = $args->{'search'};
	}

	_generic($client, $callback, $args, 'playlists',
		['tags:sux', @searchTags, ($search ? 'search:' . $search : undef)],
		sub {
			my $results = shift;
			my $items = $results->{'playlists_loop'};
			$remote_library ||= $args->{'remote_library'};
			foreach (@$items) {
				$_->{'name'}          = $_->{'playlist'};
				$_->{'type'}          = 'playlist';
				$_->{'favorites_url'} =	$_->{'url'};
				$_->{'playlist'}      = \&_playlistTracks;
				$_->{'url'}           = \&_playlistTracks;
				$_->{'passthrough'}   = [ { searchTags => [ @searchTags, 'playlist_id:' . $_->{'id'} ], remote_library => $remote_library } ];
			};

			my %actions = $remote_library ? (
				commonVariables	=> [playlist_id => 'id', noEdit => 'remote'],
			) : (
				allAvailableActionsDefined => 1,
				commonVariables	=> [playlist_id => 'id', noEdit => 'remote'],
				info => {
					command     => ['playlistinfo', 'items'],
				},
				items => {
					command     => [BROWSELIBRARY, 'items'],
					fixedParams => {
						mode       => 'playlistTracks',
						%{&_tagsToParams(\@searchTags)},
					},
				},
				play => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'load'},
				},
				add => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'add'},
				},
				insert => {
					command     => ['playlistcontrol'],
					fixedParams => {cmd => 'insert'},
				},
			);
			$actions{'playall'} = $actions{'play'};
			$actions{'addall'} = $actions{'add'};

			return {items => $items, actions => \%actions, sorted => 1}, undef;

		},
	);
}

sub _playlistTracks {
	my ($client, $callback, $args, $pt) = @_;
	my @searchTags = $pt->{'searchTags'} ? @{$pt->{'searchTags'}} : ();
	my $menuStyle  = $pt->{'menuStyle'} || 'menuStyle:album';
	my $offset     = $args->{'index'} || 0;
	my $remote_library = $args->{'remote_library'} ||= $pt->{'remote_library'};

	my $noEdit     = delete $pt->{noEdit} if defined $pt->{noEdit};

	_generic($client, $callback, $args, ['playlists', 'tracks'],
		['tags:dtuxgaliqykorfcJK', $menuStyle, @searchTags],
		sub {
			my $results = shift;
			my $items = $results->{'playlisttracks_loop'};
			$remote_library ||= $args->{'remote_library'};

			foreach (@$items) {
				# Map a few items that get different tags to those expected for TitleFormatter
				# Currently missing composer, conductor, band because of additional cost of 'A' tag query
				$_->{'ct'}            = $_->{'type'};
				if (my $secs = $_->{'duration'}) {
					$_->{'secs'}      = $secs;
					$_->{'duration'}  = sprintf('%d:%02d', int($secs / 60), $secs % 60);
				}
				$_->{'discc'}         = delete $_->{'disccount'} if defined $_->{'disccount'};
				$_->{'fs'}            = $_->{'filesize'};
				$_->{'hasMetadata'}   = 'track';

				$_->{'name'}          = $_->{'title'};
				$_->{'name2'}		  = $_->{'artist'} . ' - ' . $_->{'album'};

				if ( $_->{'coverid'} && !($_->{'remote'} && $_->{artwork_url}) ) {
					$_->{'artwork_track_id'} = $_->{'coverid'};
				}

				$_->{'image'}         = ($_->{'artwork_track_id'}
										? 'music/' . $_->{'artwork_track_id'} . '/cover'
										: $_->{'artwork_url'} ? $_->{'artwork_url'} : undef);

				$_->{'type'}          = 'audio';
				$_->{'playall'}       = 1;
				$_->{'play_index'}    = $offset++;

				if ($remote_library) {
					$_->{'url'} = _proxiedStreamUrl($_, $remote_library);
					$_->{'image'} = _proxiedImageUrl($_, $remote_library) if $_->{'image'};
					$_->{'playall'} = 1,
				}
			}

			my %actions = $remote_library ? (
					commonVariables	=> [track_id => 'id', url => 'url'],
			) : (
					commonVariables	=> [track_id => 'id', url => 'url'],
					allAvailableActionsDefined => 1,

					info => {
						command     => ['trackinfo', 'items'],
					},
					play => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'load'},
					},
					add => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'add'},
					},
					insert => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'insert'},
					},
					remove => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'delete'},
					},
					playall => {
						command     => ['playlistcontrol'],
						fixedParams => {cmd => 'load', %{&_tagsToParams(\@searchTags)}},
						variables	=> [play_index => 'play_index'],
					},
					addall => {
						command     => ['playlistcontrol'],
						variables	=> [],
						fixedParams => {cmd => 'add', %{&_tagsToParams(\@searchTags)}},
					},
				);
			$actions{'items'} = $actions{'info'};

			my %hash = (
				items       => $items,
				actions     => \%actions,
				sorted      => 0,
			);

			$hash{'playlist_id'}   = (&_tagsToParams(\@searchTags))->{'playlist_id'} unless $noEdit;
			$hash{'playlistTitle'} = $results->{'__playlistTitle'} if defined $results->{'__playlistTitle'};

			return \%hash, undef;
		}
	);
}

sub getDisplayName () {
	return 'MY_MUSIC';
}

sub playerMenu {'PLUGINS'}

=pod

Provide a hook for plugins to register a remote library helper class. This class needs to provide the following methods:

- remoteRequest: proxy a LMS/CLI command to a remote host.
- proxiedStreamUrl: return a URL LMS can deal with. This can be using a custom protocol handler.
- proxiedImageUrl: return a valid URL to a remote LMS instance's image, including resizing parameters if needed.
- getPref: get a preference from a remote server.

=cut

sub setRemoteLibraryHandler {
	my ($class, $handler) = @_;

	# a class which wants to deal with remote servers must provide a number of methods
	if ( !( $handler && $handler->can('remoteRequest') && $handler->can('proxiedStreamUrl') && $handler->can('proxiedImageUrl') && $handler->can('getPref') ) ) {
		$class ||= 'undefined';
		$log->error("Not registering '$class' as remote handler. It doesn't support all required methods.");
	}

	$remoteLibraryHandler = $handler;
}

sub _proxiedStreamUrl {
	return $remoteLibraryHandler ? $remoteLibraryHandler->proxiedStreamUrl(@_) : $_[0];
}

sub _proxiedImageUrl {
	return $remoteLibraryHandler ? $remoteLibraryHandler->proxiedImageUrl(@_) : $_[0];
}

sub _getPref {
	my ($pref, $remote_library) = @_;

	my $value;
	if ( $remote_library && $remoteLibraryHandler) {
		$value = $remoteLibraryHandler->getPref($pref, $remote_library);
	}

	$value = $prefs->get($pref) unless defined $value;

	return $value;
}

1;
