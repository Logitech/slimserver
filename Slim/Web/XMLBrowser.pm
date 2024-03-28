package Slim::Web::XMLBrowser;


# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# This class displays a generic web interface for XML feeds

use strict;

use URI::Escape qw(uri_unescape uri_escape_utf8);
use List::Util qw(min);
use Tie::RegexpHash;

use Slim::Control::XMLBrowser;
use Slim::Formats::XML;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Favorites;
use Slim::Utils::Prefs;
use Slim::Music::TitleFormatter;
use Slim::Web::HTTP;
use Slim::Web::ImageProxy qw(proxiedImage);
use Slim::Web::Pages;

use constant CACHE_TIME => 3600; # how long to cache browse sessions

my $log = logger('formats.xml');
my $prefs = preferences('server');

# use a timestamp to let cached pages expire on certain events
my $cacheTimestamp;
if ( !main::SCANNER ) {
	# Wipe cached data after rescan or library change
	Slim::Control::Request::subscribe( \&wipeCaches, [['library','rescan','favorites'], ['changed','done','changed']] );

	$prefs->setChange( \&wipeCaches, qw(itemsPerPage thumbSize showArtist showYear additionalPlaylistButtons noGenreFilter noRoleFilter searchSubString browseagelimit
		composerInArtists conductorInArtists bandInArtists variousArtistAutoIdentification titleFormat titleFormatWeb language useUnifiedArtistsList
		groupArtistAlbumsByReleaseType ignoreReleaseTypes releaseTypesToIgnore showComposerReleasesbyAlbum showComposerReleasesbyAlbumGenres) );
}

tie my %cacheables, 'Tie::RegexpHash';

sub handleWebIndex {
	my ( $class, $args ) = @_;

	my $client    = $args->{'client'};
	my $feed      = $args->{'feed'};
	my $type      = $args->{'type'} || 'link';
	my $path      = $args->{'path'} || 'index.html';
	my $title     = $args->{'title'};
	my $expires   = $args->{'expires'};
	my $timeout   = $args->{'timeout'};
	my $asyncArgs = $args->{'args'};
	my $item      = $args->{'item'} || {};
	my $pageicon  = $Slim::Web::Pages::additionalLinks{icons}{$title};

	main::DEBUGLOG && $log->is_debug && $log->debug( "feed is :" . Data::Dump::dump($feed) );

	if ($title eq uc($title)) {
		$title = string($title);
	}

	# If the feed is already XML data (Podcast List), send it to handleFeed
	if ( ref $feed eq 'HASH' ) {

		handleFeed( $feed, {
			'url'     => $feed->{'url'},
			'path'    => $path,
			'title'   => $title,
			'expires' => $expires,
			'args'    => $asyncArgs,
			'pageicon'=> $pageicon
		} );

		return;
	}

	my $params = {
		'client'  => $client,
		'url'     => $feed,
		'type'    => $type,
		'path'    => $path,
		'title'   => $title,
		'expires' => $expires,
		'timeout' => $timeout,
		'args'    => $asyncArgs,
		'pageicon'=> $pageicon,
	};

	# Handle plugins that want to use callbacks to fetch their own URLs
	if ( ref $feed eq 'CODE' ) {
		my $callback = sub {
			my $data = shift;
			my $opml;

			if ( ref $data eq 'HASH' ) {
				$opml = $data;
				$opml->{'type'}  ||= 'opml';
				$opml->{'title'} ||= $title;
			} else {
				$opml = {
					type  => 'opml',
					title =>  $title,
					items => (ref $data ne 'ARRAY' ? [$data] : $data),
				};
			}

			handleFeed( $opml, $params );
		};

		# get passthrough params if supplied
		my $pt = $item->{'passthrough'} || [];

		if ( main::DEBUGLOG && $log->is_debug ) {
			my $cbname = Slim::Utils::PerlRunTime::realNameForCodeRef($feed);
			$log->debug( "Fetching OPML from coderef $cbname" );
			$log->debug($asyncArgs->[1]->{url_query});
		}

		# XXX: maybe need to pass orderBy through

		return $feed->( $client, $callback, {isWeb => 1, wantMetadata => 1, wantIndex => 1, params => $asyncArgs->[1]}, @{$pt});
	}

	# Handle type = search at the top level, i.e. Radio Search
	if ( $type eq 'search' ) {
		my $query = $asyncArgs->[1]->{q};

		if ( !$query ) {
			my $index = $asyncArgs->[1]->{index};
			($query) = $index =~ m/^(?:[a-f0-9]{8})?_([^.]+)/;
			$query = uri_unescape( $query ) if $query;
		}

		if ( $query ) {
			$params->{url} =~ s/{QUERY}/$query/g;
		}
		else {
			my $opml = {
				type  => 'opml',
				title => Slim::Utils::Strings::getString($title),
				items => [{
					type => 'search',
					name => Slim::Utils::Strings::getString($title),
					url  => $params->{url},
				}],
			};
			handleFeed( $opml, $params );
			return;
		}
	}

	# Lookup this browse session in cache if user is browsing below top-level
	# This avoids repated lookups to drill down the menu
	my $index = $params->{args}->[1]->{index};
	if ( $index && $index =~ /^([a-f0-9]{8})/ ) {
		my $sid = $1;

		# Do not use cache if this is a search query
		if ( $asyncArgs->[1]->{q} ) {
			# Generate a new sid
			my $newsid = Slim::Utils::Misc::createUUID();

			$params->{args}->[1]->{index} =~ s/^$sid/$newsid/;
		}
		else {
			my $cache = Slim::Utils::Cache->new;
			if ( my $cached = $cache->get("xmlbrowser_$sid") ) {
				main::DEBUGLOG && $log->is_debug && $log->debug( "Using cached session $sid" );

				handleFeed( $cached, $params );
				return;
			}
		}
	}

	# fetch the remote content
	Slim::Formats::XML->getFeedAsync(
		\&handleFeed,
		\&handleError,
		$params,
	);

	return;
}

sub handleFeed {
	my ( $feed, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };

	my $cache = Slim::Utils::Cache->new;

	$feed->{'title'} ||= Slim::Utils::Strings::getString($params->{'title'});
	$stash->{'pageicon'}  = $params->{pageicon};

	if ($feed->{'query'}) {
		$stash->{'mquery'} = join('&amp;', map {$_ . '=' . $feed->{'query'}->{$_}} keys(%{$feed->{'query'}}));
	}

	my $template = 'xmlbrowser.html';

	# Session ID for this browse session
	my $sid;

	# select the proper list of items
	my @index = ();

	if ( defined $stash->{'index'} && length( $stash->{'index'} ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("item_id: ", $stash->{'index'});

		@index = split (/\./, $stash->{'index'});

		if ( length( $index[0] ) >= 8 && $index[0] =~ /^[a-f0-9]{8}/ ) {
			# Session ID is first element in index
			$sid = shift @index;
		}
	}
	else {
		# Create a new session ID, unless the list has coderefs
		my $refs = scalar grep { ref $_->{url} } @{ $feed->{items} };

		if ( !$refs ) {
			$sid = Slim::Utils::Misc::createUUID();
		}
	}

	# breadcrumb
	my @crumb = ( {
		'name'  => $feed->{'title'},
		'index' => $sid,
	} );

	# Persist search query from top level item
	if ( $params->{type} && $params->{type} eq 'search' && !scalar @index ) {
		$crumb[0]->{index} = ($sid || '') . '_' . uri_escape_utf8( $stash->{q}, "^A-Za-z0-9" );
	};

	# favorites class to allow add/del of urls to favorites, but not when browsing favorites list itself
	my $favs = Slim::Utils::Favorites->new($client) unless $feed->{'favorites'};
	my $favsItem;

	# action is add/delete favorite: pop the last item off the index as we want to display the whole page not the item
	# keep item id in $favsItem so we can process it later
	if ($stash->{'action'} && $stash->{'action'} =~ /^(favadd|favdel)$/ && @index) {
		$favsItem = pop @index;
	}

	if ( $sid ) {
		# Cache the feed structure for this session

		# cachetime is only set by parsers which known the content is dynamic and so can't be cached
		# for all other cases we always cache for CACHE_TIME to ensure the menu stays the same throughout the session
		my $cachetime = defined $feed->{'cachetime'} ? $feed->{'cachetime'} : CACHE_TIME;
		main::DEBUGLOG && $log->is_debug && $log->debug( "Caching session $sid for $cachetime" );
		eval { $cache->set( "xmlbrowser_$sid", $feed, $cachetime ) };
		if ( $@ && $log->is_warn ) {
			$log->warn("Session not cached: $@");
		}
	}

	if ( my $levels = scalar @index ) {

		# index links for each crumb item
		my @crumbIndex = $sid ? ( $sid ) : ();

		# descend to the selected item
		my $depth = 0;

		my $subFeed = $feed;
		my $superFeed;

		for my $i ( @index ) {
			$depth++;

			my ($in) = $i =~ /^(\d+)/;
			$superFeed = $subFeed;
			$subFeed = $subFeed->{'items'}->[$in - ($subFeed->{'offset'} || 0)];

			push @crumbIndex, $i;
			my $crumbText = join '.', @crumbIndex;

			$superFeed->{offset} ||= 0;
			main::DEBUGLOG && $log->is_debug && $log->debug("Considering $i=$in ($crumbText) from ", $stash->{'index'}, ' offset=', $superFeed->{'offset'});

			my $crumbName = Slim::Control::XMLBrowser::getTitle($subFeed->{name}, $subFeed);

			# Add search query to crumb list
			my $searchQuery;

			if ( $subFeed->{'type'} && $subFeed->{'type'} eq 'search' && defined $stash->{'q'} ) {
				# bug 17373 - remove period from search expression, as it breaks our index (and is ignored during the search anyway)
				$stash->{q} =~ s/\./ /g;

				$crumbText .= '_' . uri_escape_utf8( $stash->{q}, "^A-Za-z0-9" );
				$searchQuery = $stash->{'q'};
			}
			elsif ( $i =~ /(?:\d+)?_(.+)/ ) {
				$searchQuery = Slim::Utils::Unicode::utf8on(uri_unescape($1));
			}

			# Add search query to crumbName
			if ( defined $searchQuery ) {
				$crumbName .= ' (' . $searchQuery . ')';
			}

			push @crumb, {
				'name'  => $crumbName,
				'index' => $crumbText,
			};

			if ( $subFeed->{type} && $subFeed->{type} eq 'slideshow' ) {
				$stash->{slideshow} = 1;
			}

			# Change type to audio if it's an action request and we have a play attribute
			# and it's the last item
			if (
				   $subFeed->{'play'}
				&& $depth == $levels
				&& $stash->{'action'}
				&& $stash->{'action'} =~ /^(?:play|add|insert)$/
			) {
				$subFeed->{'type'} = 'audio';
				$subFeed->{'url'}  = $subFeed->{'play'};
			}

			# Change URL if there is a playlist attribute and it's the last item
			if (
			       $subFeed->{'playlist'}
				&& $depth == $levels
				&& $stash->{'action'}
				&& $stash->{'action'} =~ /^(?:playall|addall|insert|remove)$/
			) {
				$subFeed->{'type'} = 'playlist';
				$subFeed->{'url'}  = $subFeed->{'playlist'};
			}

			# Bug 15343, if we are at the lowest menu level, and we have already
			# fetched and cached this menu level, check if we should always
			# re-fetch this menu. This is used to ensure things like the Pandora
			# station list are always up to date. The reason we check depth==levels
			# is so that when you are browsing at a lower level we don't allow
			# the parent menu to be refreshed out from under the user
			if ( $depth == $levels && $subFeed->{fetched} && $subFeed->{forceRefresh} && !$params->{fromSubFeed} ) {
				main::DEBUGLOG && $log->is_debug && $log->debug("  Forcing refresh of menu");
				delete $subFeed->{fetched};
			}

			# short-circuit fetch if possible
			# If we have an action and we have an equivalent superFeed action
			# and we are about to fetch the last level then we can just use the feed-defined action.
			my ($feedAction, $feedActions);
			if ($depth == $levels
				&& $stash->{'action'} && $stash->{'action'} =~ /^((?:play|add|insert)(?:all)?)$/
				)
			{
				($feedAction, $feedActions) = Slim::Control::XMLBrowser::findAction($superFeed, $subFeed, $1);
			}

			if ($feedAction) {
				my @params = @{$feedAction->{'command'}};
				if (my $params = $feedAction->{'fixedParams'}) {
					push @params, map { $_ . ':' . $params->{$_}} keys %{$params};
				}
				my @vars = exists $feedAction->{'variables'} ? @{$feedAction->{'variables'}} : @{$feedActions->{'commonVariables'} || []};
				for (my $i = 0; $i < scalar @vars; $i += 2) {
					push @params, $vars[$i] . ':' . $subFeed->{$vars[$i+1]} if defined $subFeed->{$vars[$i+1]};
				}

				main::INFOLOG && $log->is_info && $log->info('CLI action (', $stash->{'action'}, '): ', join(' ', @params));

				Slim::Control::Request::executeRequest( $client, \@params );

				my $webroot = $stash->{'webroot'};
				$webroot =~ s/(.*?)plugins.*$/$1/;
				$template = 'xmlbrowser_redirect.html';

				my $output = processTemplate($template, $stash);

				# done, send output back to Web module for display
				$callback->( $client, $stash, $output, $httpClient, $response );

				return;
			}

			# If the feed is another URL, fetch it and insert it into the
			# current cached feed
			$subFeed->{'type'} ||= '';
			if ( defined $subFeed->{'url'} && !$subFeed->{'fetched'} ) {

				# Rewrite the URL if it was a search request
				if ( $subFeed->{'type'} eq 'search' && defined ( $stash->{'q'} || $searchQuery ) ) {
					my $search = URI::Escape::uri_escape_utf8($stash->{'q'} || $searchQuery);
					$subFeed->{'url'} =~ s/{QUERY}/$search/g;
				}

				# Setup passthrough args
				my $args = {
					'client'       => $client,
					'item'         => $subFeed,
					'url'          => $subFeed->{'url'},
					'path'         => $params->{'path'},
					'feedTitle'    => $subFeed->{'name'} || $subFeed->{'title'},
					'parser'       => $subFeed->{'parser'},
					'expires'      => $params->{'expires'},
					'timeout'      => $params->{'timeout'},
					'parent'       => $feed,
					'parentURL'    => $params->{'parentURL'} || $params->{'url'},
					'currentIndex' => \@crumbIndex,
					'args'         => [ $client, $stash, $callback, $httpClient, $response ],
					'pageicon'     => $subFeed->{'icon'} || $params->{'pageicon'},
				};


				my ($feedAction, $feedActions) = Slim::Control::XMLBrowser::findAction( $superFeed, $subFeed,
					($subFeed->{'type'} eq 'audio') ? 'info' : 'items' );
				if ($feedAction && !($depth == $levels && $stash->{'action'})) {
					my @params = @{$feedAction->{'command'}};

					# All items requests take _index and _quantity parameters
					if ($depth < $levels) {
						push @params, ($index[$depth], 1);
					} else {
						push @params, (($stash->{'start'} || 0), ($args->{'itemsPerPage'} || $prefs->get('itemsPerPage')));
					}

					if (my $params = $feedAction->{'fixedParams'}) {
						push @params, map { $_ . ':' . $params->{$_}} keys %{$params};
					}
					my @vars = exists $feedAction->{'variables'} ? @{$feedAction->{'variables'}} : @{$feedActions->{'commonVariables'} || []};
					for (my $i = 0; $i < scalar @vars; $i += 2) {
						push @params, $vars[$i] . ':' . $subFeed->{$vars[$i+1]} if defined $subFeed->{$vars[$i+1]};
					}

				    push @params, 'feedMode:1';
				    push @params, 'wantMetadata:1';
				    push @params, 'wantIndex:1';

					push @params, 'orderBy:' . $stash->{'orderBy'} if $stash->{'orderBy'};

					main::INFOLOG && $log->is_info && $log->info('CLI browse: ', join(' ', @params));

					my $callback = sub {
						my $opml = shift;

						$opml->{'type'}  ||= 'opml';
						$opml->{'title'} ||= $args->{feedTitle};

						handleSubFeed( $opml, $args );
					};

					my $proxiedRequest = Slim::Control::Request::executeRequest( $client, \@params );

					# wrap async requests
					if ( $proxiedRequest->isStatusProcessing ) {
						$proxiedRequest->callbackFunction( sub { $callback->($_[0]->getResults); } );
					} else {
						$callback->($proxiedRequest->getResults);
					}

					return;
				}

				elsif ( ref $subFeed->{'url'} eq 'CODE' ) {
					my $callback = sub {
						my $data = shift;
						my $opml;

						if ( ref $data eq 'HASH' ) {
							$opml = $data;
							$opml->{'type'}  ||= 'opml';
							$opml->{'title'} = $args->{feedTitle};
						} else {
							$opml = {
								type  => 'opml',
								title => $args->{feedTitle},
								items => (ref $data ne 'ARRAY' ? [$data] : $data),
							};
						}

						handleSubFeed( $opml, $args );
					};

					# get passthrough params if supplied
					my $pt = $subFeed->{'passthrough'} || [undef];

					my $search;
					if (defined $searchQuery && $searchQuery ne '' && $subFeed->{type} && $subFeed->{type} eq 'search') {
						$search = $searchQuery;
					}

					if ( main::DEBUGLOG && $log->is_debug ) {
						my $cbname = Slim::Utils::PerlRunTime::realNameForCodeRef( $subFeed->{url} );
						$log->debug( "Fetching OPML from coderef $cbname" );
					}

					my %args = (isWeb => 1, wantMetadata => 1, wantIndex => 1, search => $search, params => $stash->{'query'}, library_id => $stash->{library_id}, orderBy => $stash->{'orderBy'});
					my $index = $stash->{'start'};

					if ($depth == $levels) {
						$args{'index'} = $index;
						$args{'quantity'} = $stash->{'itemsPerPage'} || ($stash->{action} && $stash->{action} =~ /^(?:play|add)all$/i && $prefs->get('maxPlaylistLength')) || $prefs->get('itemsPerPage');
					} elsif ($depth < $levels) {
						$args{'index'} = $index[$depth];
						$args{'quantity'} = 1;
					}

					# first param is a $client object, but undef from webpages
					$subFeed->{url}->( $client, $callback, \%args, @{$pt} );

					return;
				}

				# No need to check for a cached version of this subfeed URL as getFeedAsync() will do that

				elsif ($subFeed->{'type'} ne 'audio') {
					# We need to fetch the URL
					main::INFOLOG && $log->info( "Fetching OPML from:", $subFeed->{'url'} );
					Slim::Formats::XML->getFeedAsync(
						\&handleSubFeed,
						\&handleError,
						$args,
					);

					return;
				}
			}
		}

		# If the feed contains no sub-items, display item details
		if ( (!$subFeed->{'items'}
				 ||
				 ( ref $subFeed->{'items'} eq 'ARRAY' && !scalar @{ $subFeed->{'items'} })
			 && !($subFeed->{type} && $subFeed->{type} eq 'search')
			 && !(ref $subFeed->{'url'}) )
		) {
			$subFeed->{'image'} ||= $subFeed->{'cover'} || $subFeed->{'icon'} || Slim::Player::ProtocolHandlers->iconForURL($subFeed->{'play'} || $subFeed->{'url'}, $client);
			$subFeed->{'image'} = proxiedImage($subFeed->{'image'});

			$stash->{'streaminfo'} = {
				'item'  => $subFeed,
				'index' => $sid ? join( '.', $sid, @index ) : join( '.', @index ),
			};
		}

		# Construct index param for each item in the list
		my $itemIndex = $sid ? join( '.', $sid, @index ) : join( '.', @index );
		if ( $stash->{'q'} ) {
			$itemIndex .= '_' . uri_escape_utf8( $stash->{'q'}, "^A-Za-z0-9" );
		}
		$itemIndex .= '.';

		$stash->{'pagetitle'} = Slim::Control::XMLBrowser::getTitle($subFeed->{'name'}, $subFeed);
		$stash->{'index'}     = $itemIndex;
		$stash->{'icon'}      = $subFeed->{'icon'};
		$stash->{'playUrl'}   = $subFeed->{'play'}
								|| ($subFeed->{'type'} && $subFeed->{'type'} eq 'audio'
									? $subFeed->{'url'}
									: undef);

		$feed = $subFeed;
	}
	else {
		$stash->{'pagetitle'} = $feed->{'name'} || $feed->{'title'};
		$stash->{'playUrl'}   = $feed->{'play'};

		if ( $sid ) {
			$stash->{index} = $sid;
		}

		# Persist search term from top-level item (i.e. Search Radio)
		if ( $stash->{q} ) {
			$stash->{index} .= '_' . uri_escape_utf8( $stash->{'q'}, "^A-Za-z0-9" );
		}

		if ( $stash->{index} ) {
			$stash->{index} .= '.';
		}

		if (defined $favsItem) {
			$stash->{'index'} = undef;
		}
	}

	$stash->{'crumb'}     = \@crumb;
	$stash->{'image'}     = proxiedImage($feed->{'image'} || $feed->{'cover'} || $stash->{'image'});

	foreach (qw(items type orderByList playlist_id playlistTitle total)) {
		$stash->{$_} = $feed->{$_} if defined $feed->{$_};
	}

	# Only want plain URLs as play-URL
	if ($stash->{'playUrl'} && ref $stash->{'playUrl'}) {
		delete $stash->{'playUrl'};
	}

	my $action      = $stash->{'action'};
	my $streamItem  = $stash->{'streaminfo'}->{'item'} if $stash->{'streaminfo'};

	# Play of a playlist should be playall
	if ($action
		&& ($streamItem && $streamItem->{'type'} ? $streamItem->{'type'} eq 'playlist'
						: $stash->{'type'} && $stash->{'type'} eq 'playlist')
		&& $action =~ /^(?:play|add)$/
	) {
		$action .= 'all';
	}

	# play/add stream
	if ( $client && $action && $action =~ /^(play|add)$/ ) {
		my $url   = $streamItem->{'url'};
		my $title = $streamItem->{'name'} || $streamItem->{'title'};

		# Podcast enclosures
		if ( my $enc = $streamItem->{'enclosure'} ) {
			$url = $enc->{'url'};
		}

		# Items with a 'play' attribute will use this for playback
		if ( my $play = $streamItem->{'play'} ) {
			$url = $play;
		}

		if ( $url ) {

			main::INFOLOG && $log->info("Playing/adding $url");
			main::DEBUGLOG && $log->is_debug && $log->debug("streamItem is " . Data::Dump::dump($streamItem));

			# Set metadata about this URL
			Slim::Music::Info::setRemoteMetadata( $url, {
				title   => $title,
				ct      => $streamItem->{'mime'},
				secs    => $streamItem->{'duration'},
				bitrate => $streamItem->{'bitrate'},
				cover   => $streamItem->{'cover'} || $streamItem->{'image'} || $streamItem->{'icon'},
				year	=> $streamItem->{'year'},
			} );

			$client->execute([ 'playlist', $action, $url ]);

			my $webroot = $stash->{'webroot'};
			$webroot =~ s/(.*?)plugins.*$/$1/;
			$template = 'xmlbrowser_redirect.html';
		}
		else {
			main::INFOLOG && $log->info('No URL to play');
		}
	}
	# play all/add all
	elsif ( $client && $action && $action =~ /^(playall|addall|insert|remove)$/ ) {
		$action =~ s/all$//;

		my (@urls, @itemActions);
		# XXX: Why is $stash->{streaminfo}->{item} added on here, it seems to be undef?
		for my $item ( @{ $stash->{'items'} }, $streamItem ) {
			my $url;
			if ( $item->{'type'} && $item->{'type'} eq 'audio' && $item->{'url'} ) {
				$url = $item->{'url'};
			}
			elsif ( $item->{'enclosure'} && $item->{'enclosure'}->{'url'} ) {
				$url = $item->{'enclosure'}->{'url'};
			}
			elsif ( $item->{'play'} ) {
				$url = $item->{'play'};
			}
			elsif ( my $itemAction = Slim::Control::XMLBrowser::findAction(undef, $item, $action) ) {
				push @itemActions, $itemAction if $itemAction->{command} && $itemAction->{fixedParams};
			}

			next if !$url;

			main::INFOLOG && $log->info("Playing/adding $url");
			main::DEBUGLOG && $log->is_debug && $log->debug("item is " . Data::Dump::dump($item));

			# Set metadata about this URL
			Slim::Music::Info::setRemoteMetadata( $url, {
				title   => $item->{'name'} || $item->{'title'},
				ct      => $item->{'mime'},
				secs    => $item->{'duration'},
				bitrate => $item->{'bitrate'},
				cover   => $item->{'cover'} || $item->{'image'} || $item->{'icon'},
				year	=> $item->{'year'},
			} );

			main::idleStreams();

			push @urls, $url;
		}

		if ( @urls || @itemActions ) {

			if ( main::INFOLOG && $log->is_info ) {
				$log->info(sprintf("Playing/adding all items:\n%s", Data::Dump::dump(@urls, @itemActions)));
			}

			if ( @itemActions ) {
				my $i;
				foreach my $actionItem (@itemActions) {
					# if this isn't the first item, then we'll have to add the rest to the end of the list
					if ($i++ && $actionItem->{fixedParams}->{cmd} =~ /load/i) {
						$actionItem->{fixedParams}->{cmd} = 'add';
					}

					my $command = $actionItem->{command};
					push @$command, map {
						"$_:" . $actionItem->{fixedParams}->{$_}
					} keys %{ $actionItem->{fixedParams} };

					main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($command));
					$client->execute($command);
				}
			} elsif ($action eq 'insert') {
				$client->execute([ 'playlist', 'inserttracks', 'listRef', \@urls ]);
			} elsif ($action eq 'remove') {
				$client->execute([ 'playlist', 'deletetracks', 'listRef', \@urls ]);
			} else {
				$client->execute([ 'playlist', $action, \@urls ]);
			}

			my $webroot = $stash->{'webroot'};
			$webroot =~ s/(.*?)plugins.*$/$1/;
			$template = 'xmlbrowser_redirect.html';
		}
		else {
			main::INFOLOG && $log->info('No URLs to play');
		}
	}
	else {

		# Not in use because it messes up title breadcrumbs
#		if ($feed->{'actions'} && $feed->{'actions'}->{'items'}) {
#			my $action = $feed->{'actions'}->{'items'};
#
#			my $base = 'clixmlbrowser/clicmd=' . join('+', @{$action->{'command'}});
#			if (my $params = $action->{'fixedParams'}) {
#				$base .= '&' . join('&', map { $_ . '=' . $params->{$_}} keys %{$params});
#			}
#
#			main::INFOLOG && $log->is_info && $log->info($base);
#
#			my @vars = @{$action->{'variables'} || []};
#			foreach my $item (@{ $stash->{'items'} }) {
#				my $link = $base;
#				for (my $i = 0; $i < scalar @vars; $i += 2) {
#					$link .= '&' . $vars[$i] . '=' . $item->{$vars[$i+1]};
#				}
#				$item->{'web'}->{'url'} = $link . '/';
#			}
#		}

		main::INFOLOG && $log->info('Item details or list');

		# Check if any of our items contain audio as well as a duration value, so we can display an
		# 'All Songs' link.  Lists with no duration values are lists of radio stations where it doesn't
		# make sense to have an All Songs link. (bug 6531)
		for my $item ( @{ $stash->{'items'} } ) {
			next unless ( $item->{'type'} && $item->{'type'} eq 'audio' ) || $item->{'enclosure'} || $item->{'play'};
			next unless defined $item->{'duration'} || $item->{'playall'};

			$stash->{'itemsHaveAudio'} = 1;
			$stash->{'currentIndex'}   = $crumb[-1]->{index};
			last;
		}

		my $itemCount = $feed->{'total'} || scalar @{ $stash->{'items'} };

		my $clientId = ( $client ) ? $client->id : '';
		my $crumbIndex = $crumb[-1]->{index};
		$crumbIndex = '' if !defined $crumbIndex;

		my $otherParams = '&index=' . $crumbIndex . '&player=' . $clientId;
		if ( $stash->{'query'} ) {
			$otherParams = '&query=' . $stash->{'query'} . $otherParams;
		}

		$stash->{'pageinfo'} = Slim::Web::Pages::Common->pageInfo({
				'itemCount'   => $itemCount,
				'indexList'   => $feed->{'indexList'},
				'path'        => $params->{'path'} || 'index.html',
				'otherParams' => $otherParams,
				'start'       => $stash->{'start'},
				'perPage'     => $stash->{'itemsPerPage'},
		});

		$stash->{'path'} = $params->{'path'} || 'index.html';

		my $offset = $feed->{'offset'} || 0;
		my $start  = $stash->{'pageinfo'}{'startitem'} || 0;
		$start = $offset if ($start < $offset);
		$stash->{'start'} = $start;

		if ($offset || $stash->{'pageinfo'}{'totalpages'} > 1) {
			my $count = scalar @{ $stash->{'items'} };

			# the following ensures the original array is not altered by creating a slice to show this page only
			my $finish = $stash->{'pageinfo'}{'enditem'} + 1 - $offset;
			$finish = $count if ($count < $finish);

			if ($start > $offset || $finish < $count) {
				main::DEBUGLOG && $log->is_debug && $log->info("start=$start, offset=$offset, count=$count: cutting slice ", $start - $offset, "..$finish");
				my @items = @{ $stash->{'items'} };
				my @slice = @items [ $start - $offset .. $finish - 1 ];
				$stash->{'items'} = \@slice;
			}
			else {
				main::DEBUGLOG && $log->is_debug && $log->info("start=$start, offset=$offset, count=$count: no slice needed");
			}
		}

		my $item_index = $start;
		my $format = $stash->{ajaxSearch} || ($stash->{type} || '') eq 'search'
			? 'TRACKNUM. TITLE - ALBUM - ARTIST'
			: $prefs->get('titleFormat')->[ $prefs->get('titleFormatWeb') ];

		foreach (@{ $stash->{'items'} }) {
			if ( !defined $stash->{'index'} ) {
				$_->{'index'} = $item_index++;
			} else {
				$_->{'index'} = $stash->{'index'} . $item_index++;
			}

			if (my $hasMetadata = $_->{'hasMetadata'}) {
				if ($hasMetadata eq 'track') {
					$_->{'name'} = Slim::Music::TitleFormatter::infoFormat(undef, $format, 'TITLE', $_);
				} elsif ($hasMetadata eq 'album') {
					$_->{'showYear'}   = 1 if ($prefs->get('showYear')   && $_->{'year'});
					$_->{'showArtist'} = 1 if ($prefs->get('showArtist') && $_->{'artist'});
				}
			}

			# keep track of station icons
			if ( $_->{url} && !ref $_->{url}
				&& ( $_->{play} || $_->{playlist} || ($_->{type} && ($_->{type} eq 'audio' || $_->{type} eq 'playlist')) )
				&& $_->{url} =~ /^http/
				&& $_->{url} !~ m|\.com/api/\w+/v1/opml|
				&& ( my $cover = $_->{image} || $_->{cover} )
				&& !Slim::Utils::Cache->new->get("remote_image_" . $_->{url})
			) {
				$cache->set("remote_image_" . $_->{url}, $cover, 86400);
			}
		}

		# Find special stuff that we either want to pull up into the metadata for the
		# songinfo header block or which needs unfolding.

		{
			my $details = {};
			my $i = 0;

			my $roles = join ('|', Slim::Schema::Contributor->contributorRoles());
			my $allLabels = join ('|', $roles, qw(ALBUM GENRE YEAR ALBUMREPLAYGAIN ALBUMLENGTH COMPILATION WORK));

			foreach my $item ( @{ $feed->{'albumData'} || $stash->{'items'} } ) {

				my $label = $item->{'label'} || '';
				if ($label =~ /^($allLabels)$/) {

					if ($label =~ /^($roles)$/) {

						$details->{'contributors'} ||= {};
						$details->{'contributors'}->{$label} ||= [];

						push @{ $details->{'contributors'}->{ $label } }, {
							name => $item->{'name'},
							index=> $item->{'index'},
							link => _makeWebLink(undef, $item, 'items', sprintf('%s (%s)', string('ARTIST'), $item->{'name'})),
						};

						$item->{'ignore'} = 1;
					}

					elsif ($label eq 'GENRE') {
						$details->{'genres'} ||= [];

						push @{ $details->{'genres'} }, {
							name => $item->{'name'},
							link => _makeWebLink(undef, $item, 'items', sprintf('%s (%s)', string($label), $item->{'name'})),
						};
						$item->{'ignore'} = 1;
						$item->{'type'} = 'redirect';
					}

					else {
						my $tag = lc $label;
						$details->{$tag} = {
							name => $item->{'name'},
						};
						if ($item->{'type'} ne 'text') {
							$details->{$tag}->{'link'} = _makeWebLink(undef, $item, 'items', sprintf('%s (%s)', string($label), $item->{'name'}));
						}
						$item->{'ignore'} = 1;
						$item->{'type'} = 'redirect';

						# if this is a compilation, provide a link to the album with all artists
						if ($label eq 'COMPILATION' && $stash->{artist_id}) {
							$details->{album} = {
								id   => $feed->{id},
								title  => $feed->{name},
							};
						}
					}
				}

				# unfold items which are folded for smaller UIs;
				elsif ( $item->{'items'} && ($item->{'unfold'} || $item->{'web'}->{'unfold'}) ) {

					$details->{'unfold'} ||= [];

					my $new_index = 0;
					foreach my $moreItem ( @{ $item->{'items'} } ) {
						$moreItem->{'index'} = $item->{'index'} . '.' . $new_index;
						$new_index++;

						my $label = $moreItem->{'label'} || '';
						if ($label =~ /^($allLabels)$/) {
							my $tag = lc $label;
							$details->{$tag} = {
								name => $moreItem->{'name'},
							};
							if ($moreItem->{'type'} ne 'text') {
								$details->{$tag}->{'link'} = _makeWebLink(undef, $moreItem, 'items', sprintf('%s (%s)', string($label), $moreItem->{'name'}));
							}
							$moreItem->{'ignore'} = 1;
							$moreItem->{'type'} = 'redirect';
						}
					}

					push @{ $details->{'unfold'} }, {
						items => $item->{'items'},
						start => $i,
					};
				}

				$i++;
			}

			if (my $c = $details->{'contributors'}) {
				if ($c->{'TRACKARTIST'} && $c->{'ALBUMARTIST'}) {
					my $t = join(' ', (sort (map {$_->{'name'}} @{$c->{'TRACKARTIST'}})));
					my $a = join(' ', (sort (map {$_->{'name'}} @{$c->{'ALBUMARTIST'}})));
					delete $c->{'TRACKARTIST'} if $t eq $a;
				}
			}

			if ($details->{'unfold'}) {
				# unfold nested groups of additional items
				my $new_index = 0;
				foreach my $group (@{ $details->{'unfold'} }) {

					splice @{ $stash->{'items'} }, ($group->{'start'} + $new_index), 1, @{ $group->{'items'} };
					$new_index = $#{ $group->{'items'} };
				}
				delete $details->{'unfold'};
			}

			$feed->{'favorites_url'} ||= $stash->{'playUrl'};

			if ($feed->{'hasMetadata'} && $feed->{'hasMetadata'} eq 'album' && $feed->{'albumInfo'}) {

				my $morelink = _makeWebLink({ actions => $feed->{'albumInfo'} }, $feed, 'info',
											sprintf('%s (%s)', string('INFORMATION'), ($feed->{'album'} || '')));

				$details->{'mixersLink'} = $morelink if $morelink;
			}

			if (scalar keys %$details) {
				# This is really just for Trackinfo
				if ($stash->{'playUrl'}) {
					$details->{'playLink'} = 'anyurl?p0=playlist&p1=play&p2=' .
						Slim::Utils::Misc::escape($stash->{'playUrl'});
					$details->{'addLink'} = 'anyurl?p0=playlist&p1=add&p2=' .
						Slim::Utils::Misc::escape($stash->{'playUrl'});
					$details->{'insertLink'} = 'anyurl?p0=playlist&p1=insert&p2=' .
						Slim::Utils::Misc::escape($stash->{'playUrl'});
					$details->{'removeLink'} = 'anyurl?p0=playlist&p1=deleteitem&p2=' .
						Slim::Utils::Misc::escape($stash->{'playUrl'});
				}

				if ($feed->{'favorites_url'} && $favs) {
					$details->{'favorites_icon'} = $feed->{'favorites_icon'} || $feed->{'icon'} || $feed->{'image'} || $feed->{'cover'} || Slim::Player::ProtocolHandlers->iconForURL($feed->{'favorites_url'}, $client);
					$details->{'favorites_url'} = $feed->{'favorites_url'};
					$details->{'favorites_title'} = $feed->{'favorites_title'} || $feed->{'name'} || $feed->{'title'};
					$details->{'favorites'} = $favs->hasUrl($feed->{'favorites_url'}) ? 2 : 1;
				}

				$stash->{'songinfo'} = $details;
			}
		}
	}

	if ($favs && defined $favsItem && scalar @{$stash->{'items'}}) {
		if (my $item = $stash->{'items'}->[$favsItem - ($stash->{'start'} || 0)]) {
			my $furl = _favoritesUrl($item);
			if ($stash->{'action'} eq 'favadd') {

				my $type = $item->{'favorites_type'} || $item->{'type'} || 'link';
				my $name = $item->{'favorites_title'} || $item->{'name'};
				my $icon = $item->{'favorites_icon'} || $item->{'image'} || $item->{'icon'} ||
						   Slim::Player::ProtocolHandlers->iconForURL($furl, $client) || 'html/images/favorites.png';

				if ( ($item->{'play'} && !$item->{'favorites_type'})
				    || ($type eq 'playlist' && $furl =~ /^(file|db):/)
				) {
					$type = 'audio';
				}

				$favs->add(
					$furl,
					$name,
					$type,
					$item->{'parser'},
					1,
					proxiedImage($icon)
				);
			} elsif ($stash->{'action'} eq 'favdel') {
				$favs->deleteUrl( $furl );
			}
		}
	}

	# Add play & favourites links and anchors if we can
	my $anchor = '';
	my $songinfo = $stash->{'songinfo'};
	for my $item (@{$stash->{'items'} || []}) {

		next if $item->{'ignore'};

		if ($favs) {
			my $furl = _favoritesUrl($item);
			if ($furl && !defined $item->{'favorites'}) {
				$item->{'favorites'} = $favs->hasUrl( $furl ) ? 2 : 1;
			}
		}

		my $link;

		if ($songinfo) {
			if (my $playcontrol = $item->{'playcontrol'}) {
				if ($link = _makePlayLink($feed->{'actions'}, $item, 'play')) {
					$songinfo->{$playcontrol . 'Link'} = $link;
					$item->{'ignore'} = 1;
					next;
				}
			}
		}

		$link = _makePlayLink($feed->{'actions'}, $item, 'play');
		$item->{'playLink'} = $link if $link;

		$link = _makePlayLink($feed->{'actions'}, $item, 'add');
		$item->{'addLink'} = $link if $link;

		$link = _makePlayLink($feed->{'actions'}, $item, 'insert');
		$item->{'insertLink'} = $link if $link;

		$link = _makePlayLink($feed->{'actions'}, $item, 'remove');
		$item->{'removeLink'} = $link if $link;

		$link = _makeWebLink({actions => $feed->{'actions'}}, $item, 'info', sprintf('%s (%s)', string('INFORMATION'), ($item->{'name'}|| '')));
		$item->{'mixersLink'} = $link if $link;

		my $textkey = $item->{'textkey'};
		if (defined $textkey && $textkey ne $anchor) {
			$item->{'anchor'} = $anchor = $textkey;
		}
	}

	# Ignore the All Songs link added by browse library at the end if we will add our own link.
	# This is a horrible hack really.
	if ($stash->{'items'}) {
		my $item = $stash->{'items'}->[-1];
		if ($item && $stash->{'itemsHaveAudio'} && $item->{'name'} && $item->{'name'} eq string('ALL_SONGS')) {
			$item->{'ignore'} = 1;
		}
	}



	my $output = processTemplate($template, $stash);

	# done, send output back to Web module for display
	$callback->( $client, $stash, $output, $httpClient, $response );
}

sub handleError {
	my ( $error, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };

	my $template = 'xmlbrowser.html';

	$params->{title} ||= '';
	my $title = ( $params->{title} && uc($params->{title}) eq $params->{title} ) ? Slim::Utils::Strings::getString($params->{title}) : $params->{title};

	$stash->{'pagetitle'} = $title;
	$stash->{'pageicon'}  = $params->{pageicon};
	$stash->{'msg'} = sprintf(string('WEB_XML_ERROR'), $title, $error);

	my $output = processTemplate($template, $stash);

	# done, send output back to Web module for display
	$callback->( $client, $stash, $output, $httpClient, $response );
}

# Fetch a feed URL that is referenced within another feed.
# After fetching, insert the contents into the original feed
sub handleSubFeed {
	my ( $feed, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };

	# If there's a command we need to run, run it.  This is used in various
	# places to trigger actions from an OPML result, such as to start playing
	# a new Pandora radio station
	if ( $feed->{'command'} && $client ) {
		my @p = map { uri_unescape($_) } split / /, $feed->{command};
		main::DEBUGLOG && $log->is_debug && $log->debug( "Executing command: " . Data::Dump::dump(\@p) );
		$client->execute( \@p );
	}

	# find insertion point for sub-feed data in the original feed
	my $parent = $params->{'parent'};
	my $subFeed = $parent;
	for my $i ( @{ $params->{'currentIndex'} } ) {
		# Skip sid and sid + top-level search query
		next if length($i) >= 8 && $i =~ /^[a-f0-9]{8}/;

		# If an index contains a search query, strip it out
		$i =~ s/_.+$//g;

		$subFeed = $subFeed->{'items'}->[$i - ($subFeed->{'offset'} || 0)];
	}

	if (($subFeed->{'type'} && $subFeed->{'type'} eq 'replace' || $feed->{'replaceparent'}) &&
		$feed->{'items'} && scalar @{$feed->{'items'}} == 1) {
		# if child has 1 item and requests, update previous entry to avoid new menu level
		delete $subFeed->{'url'};
		my $item = $feed->{'items'}[0];
		for my $key (keys %$item) {
			$subFeed->{ $key } = $item->{ $key };
		}
	} else {
		# otherwise insert items as subfeed
		$subFeed->{'items'} = $feed->{'items'};
	}

	# set flag to avoid fetching this url again
	$subFeed->{'fetched'} = 1;

	# Pass-through forceRefresh flag
	$subFeed->{forceRefresh} = 1 if $feed->{forceRefresh};

	foreach (qw(offset total actions albumData albumInfo orderByList indexList playlist_id playlistTitle)) {
		$subFeed->{$_} = $feed->{$_} if defined $feed->{$_};
	}

	foreach (qw(image cover)) {
		$subFeed->{$_} = proxiedImage($feed->{$_}) if defined $feed->{$_};
	}

	# Mark this as coming from subFeed, so that we know to ignore forceRefresh
	$params->{fromSubFeed} = 1;

	# cachetime will only be set by parsers which know their content is dynamic
	if (defined $feed->{'cachetime'}) {
		$parent->{'cachetime'} = min( $parent->{'cachetime'} || CACHE_TIME, $feed->{'cachetime'} );
	}

	# No caching for callback-based plugins
	# XXX: this is a bit slow as it has to re-fetch each level
	if ( ref $subFeed->{'url'} eq 'CODE' ) {

		# Clear passthrough data as it won't be needed again
		delete $subFeed->{'passthrough'};
	}

	handleFeed( $parent, $params );
}

sub processTemplate {
	my $page = Slim::Web::HTTP::filltemplatefile( @_ );

	Slim::Utils::Cache->new->set($_[1]->{renderCacheKey}, $page, 86400) if $page && $_[1]->{renderCacheKey};

	return $page;
}

sub init {
	my $class = shift;

	my $url   = 'clixmlbrowser/.*';

	Slim::Web::Pages->addPageFunction( $url, \&webLink);
}

sub _webLinkDone {
	my ($client, $feed, $title, $args) = @_;

	# pass CLI command as result to XMLBrowser

	__PACKAGE__->handleWebIndex( {
			client  => $client,
			feed    => $feed,
			timeout => 35,
			args    => $args,
			title   => $title,
		} );
}

sub webLink {
	my ( $client, $args, $callback, $httpClient, $response ) = @_;
	my $allArgs = \@_;
	# get parameters and construct CLI command
	# Bug 17181: Unfortunately we're un-escaping the request path parameter before we split it into separate parameters.
	# Which means any value with a & in it would be considered a distinct parameter. By using the
	# raw path value from the request object and un-escaping after the splitting, we could fix this.
	my ($params) = ($response->request->uri =~ m%clixmlbrowser/([^/]+)%);
	if (!$params) {
		($params) = ($args->{'path'} =~ m%clixmlbrowser/([^/]+)%);
	}

	my %params;

	foreach (split(/\&/, $params)) {
		if (my ($k, $v) = /([^=]+)=(.*)/) {
			$params{$k} = Slim::Utils::Misc::unescape($v);
		} else {
			$log->warn("Unrecognized parameter syntax: $_");
		}
	}

	my @verbs = split(/\+/, delete $params{'clicmd'});
	if (!scalar @verbs) {
		$log->error("Missing clicmd parameter");
		return;
	}

	my ($index, $quantity) = (($args->{'start'} || 0), ($args->{'itemsPerPage'} || $prefs->get('itemsPerPage')));
	my $itemId = $args->{'index'};
	if (defined $itemId) {
		my $i = $itemId;
		$i =~ s/^(?:[a-f0-9]{8})?\.?//;	# strip sessionid if present
		if ($i =~ /^(\d+)/) {
			$index = $1;
			$quantity = 1;
		}
	}

	push @verbs, ($index, $quantity);

	my $title = delete $params{'linktitle'};
	$title = Slim::Utils::Unicode::utf8decode(uri_unescape($title)) if $title;

	push @verbs, map { $_ . ':' . $params{$_} } keys %params;
	push @verbs, 'feedMode:1';
	push @verbs, 'wantMetadata:1';	# We always want everything we can get
	push @verbs, 'wantIndex:1';	# We always want everything we can get

	push @verbs, 'orderBy:' . $args->{'orderBy'} if $args->{'orderBy'};

	my $renderCacheKey;
	if ( !main::NOBROWSECACHE && $cacheables{ $args->{path} } && !($args->{url_query} && $args->{url_query} =~ /\baction=/) && !($args->{url_query} && $args->{url_query} =~ /\bindex=\d+\.\d+\.\d+/) && !Slim::Music::Import->stillScanning() ) {

		# let cache expire between server restarts
		$cacheTimestamp ||= time();

		# cache key needs to make sure we respect the various prefs and cookies which control the display mode...
		$renderCacheKey = join(':',
			'blweb',
			$cacheTimestamp,
			$index,
			$quantity,
			(map { $params{$_} || '' } qw(mode sort index), @Slim::Menu::BrowseLibrary::topLevelArgs),
			(map { $args->{$_} || '' } qw(artwork player sess index start systemSkin skinOverride systemLanguage webroot thumbSize serverResizesArt orderBy)),
			Slim::Music::VirtualLibraries->getLibraryIdForClient($client),
		);

		if ( my $cached = Slim::Utils::Cache->new->get($renderCacheKey) ) {
			main::DEBUGLOG && $log->debug("Returning cached copy of rendered HTML page.");
			$callback->( $client, $args, $cached, $httpClient, $response );
			return;
		}
	}

	$args->{renderCacheKey} = $renderCacheKey;

	# execute CLI command
	main::INFOLOG && $log->is_info && $log->info('Use CLI: ', join(' ', (defined $client ? $client->id : 'noClient'), @verbs));
	my $proxiedRequest = Slim::Control::Request::executeRequest( $client, \@verbs );

	# wrap async requests
	if ( $proxiedRequest->isStatusProcessing ) {
		$proxiedRequest->callbackFunction( sub { _webLinkDone($client, $_[0]->getResults, $title, $allArgs); } );
		return undef;
	} else {
		_webLinkDone($client, $proxiedRequest->getResults, $title, $allArgs);
	}
}

sub addCacheable {
	my ( $class, $regex ) = @_;

	if ( ref $regex ne 'Regexp' ) {
		$log->error( 'addCacheable called without a regular expression' );
		return;
	}

	$cacheables{$regex} = $regex;
}

sub wipeCaches {
	$cacheTimestamp = time();
}

sub _makeWebLink {
	my ($feed, $item, $action, $title) = @_;

	my ($feedAction, $feedActions) = Slim::Control::XMLBrowser::findAction($feed, $item, $action);
	if ($feedAction) {
		my $cmd = join('+', @{$feedAction->{'command'}});
		return undef unless $cmd;

		my $link = 'clixmlbrowser/clicmd=' . $cmd;
		if (my $params = $feedAction->{'fixedParams'}) {
			$link .= join('&', '', map { $_ . '=' . $params->{$_}} keys %{$params});
		}

		my @vars = exists $feedAction->{'variables'} ? @{$feedAction->{'variables'}} : @{$feedActions->{'commonVariables'} || []};
		for (my $i = 0; $i < scalar @vars; $i += 2) {
			if (defined $item->{$vars[$i+1]}) {
				$link .= '&' . $vars[$i] . '=' . Slim::Utils::Misc::escape($item->{$vars[$i+1]});
			} elsif ($vars[$i+1] ne 'extid') {
				# XXX - why would we return here?
				return undef;
			}
		}

		$link .= '&linktitle=' . Slim::Utils::Misc::escape($title) if $title;

		$link .= '/';

#		main::DEBUGLOG && $log->debug($link);

		return $link;
	}
}

sub _makePlayLink {
	my ($feedActions, $item, $action) = @_;

	return undef if $item->{type} && $item->{type} eq 'text';

	my ($feedAction, $feedActions) = Slim::Control::XMLBrowser::findAction({actions => $feedActions}, $item, $action);
	if ($feedAction) {
		my @p = @{$feedAction->{'command'}};

		if (my $params = $feedAction->{'fixedParams'}) {
			push @p, map { $_ . ':' . $params->{$_}} keys %{$params};
		}

		my @vars = exists $feedAction->{'variables'} ? @{$feedAction->{'variables'}} : @{$feedActions->{'commonVariables'} || []};
		for (my $i = 0; $i < scalar @vars; $i += 2) {
			push @p, $vars[$i] . ':' . $item->{$vars[$i+1]} if defined $item->{$vars[$i+1]};
		}

		my $link = 'anyurl?p0=' . shift @p;
		my $i = 1;

		foreach (@p) {
			$link .= "&p$i=$_";
			$i++;
		}

#		main::DEBUGLOG && $log->debug($link);

		return $link;
	}

	return undef unless $action =~ /^(add|play|insert|remove)/;

	my $playUrl = $item->{'play'}
					|| ($item->{'type'} && $item->{'type'} eq 'audio'
						? $item->{'url'}
						: undef);
	if ($playUrl && !ref $playUrl) {

		if ($action eq 'remove') {
			my $link = 'anyurl?p0=playlist&p1=deleteitem&p2=' . Slim::Utils::Misc::escape($playUrl);
			return $link;
		} else {
			my $link = 'anyurl?p0=playlist&p1=' . $action . '&p2=' . Slim::Utils::Misc::escape($playUrl);

			my $title = $item->{'title'} || $item->{'name'};

			# bug 17881: don't set the track title when we're dealing with a local file, and the title is the filename (BMF)
			$title = '' if $title && $item->{filename} && $item->{filename} eq $title;

			$link .= '&p3=' . Slim::Utils::Misc::escape($title) if $title;

			return $link;
		}
	}
}

sub _favoritesUrl {
	my $item = shift;

	my $favorites_url    = $item->{favorites_url} || $item->{play} || $item->{url};

	if ( $favorites_url && !ref $favorites_url ) {
		if ( !$item->{favorites_url} && $item->{type} && $item->{type} eq 'playlist' && $item->{playlist} ) {
			$favorites_url = $item->{playlist};
		}


		return $favorites_url;
	}
}

1;
