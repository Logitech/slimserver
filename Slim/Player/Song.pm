package Slim::Player::Song;


# Logitech Media Server Copyright 2001-2020 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use bytes;
use strict;

use base qw(Slim::Utils::Accessor);

use Fcntl qw(SEEK_CUR SEEK_SET);
use Clone qw(clone);

use Slim::Utils::Log;
use Slim::Schema;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Player::SongStreamController;
use Slim::Player::CapabilitiesHelper;

BEGIN {
	if (main::TRANSCODING) {
		require Slim::Player::Pipeline;
	}
}

use Scalar::Util qw(blessed);

use constant STATUS_READY     => 0;
use constant STATUS_STREAMING => 1;
use constant STATUS_PLAYING   => 2;
use constant STATUS_FAILED    => 3;
use constant STATUS_FINISHED  => 4;

my $log = logger('player.source');
my $prefs = preferences('server');

my $_liveCount = 0;

my @_playlistCloneAttributes = qw(
	index
	_track _currentTrack _currentTrackHandler
	streamUrl
	owner
	_playlist _scanDone

	_pluginData wmaMetadataStream wmaMetaData scanData
);

{
	__PACKAGE__->mk_accessor('ro', qw(
		handler
	) );
	
	__PACKAGE__->mk_accessor('rw', 
		@_playlistCloneAttributes,

		qw(
			_status

			startOffset streamLength
			seekdata initialAudioBlock
			_canSeek _canSeekError
			stripHeader
			wantFormat

			_duration _bitrate _streambitrate _streamFormat
			_transcoded directstream

			samplerate samplesize channels totalbytes offset blockalign isLive

			retryData
		),
	);
}

sub new {
	my ($class, $owner, $index, $seekdata) = @_;

	my $client = $owner->master();

	my $objOrUrl = Slim::Player::Playlist::track($client, $index) || return undef;

	# Bug: 3390 - reload the track if it's changed.
	my $url      = blessed($objOrUrl) && $objOrUrl->can('url') ? $objOrUrl->url : $objOrUrl;

 	my $track    = Slim::Schema->objectForUrl({
		'url'      => $url,
		'readTags' => 1
	});

	if (!blessed($track) || !$track->can('url')) {
		# Try and create the track if we weren't able to fetch it.
		$track = Slim::Schema->objectForUrl({
			'url'      => $url,
			'create'   => 1,
			'readTags' => 1
		});
		if (!blessed($track) || !$track->can('url')) {
			logError("Could not find an object for [$objOrUrl]!");
			return undef;
		}
	}

	$url = $track->url;

	main::INFOLOG && $log->info("index $index -> $url");

	my $handler = Slim::Player::ProtocolHandlers->handlerForURL( $url );
	if (!$handler) {
		logError("Could not find handler for $url!");
		return undef;
	}

	my $self = $class->SUPER::new;

	$self->init_accessor(
		index           => $index,
		_status         => STATUS_READY,
		owner           => $owner,
		_playlist       => Slim::Music::Info::isPlaylist($track, $track->content_type ) ? 1 : 0,
							# 0 = simple stream, 1 = playlist, 2 = repeating stream
		startOffset     => 0,
		handler         => $handler,
		_track          => $track,
		streamUrl       => $url,	# May get updated later, either here or in handler
	);

	$self->seekdata($seekdata) if $seekdata;

	if ($handler->can('isRepeatingStream')) {
		my $type = $handler->isRepeatingStream($self);
		if ($type > 2) {
			$self->_playlist($type);
		} elsif ($type) {
			$self->_playlist(2);
		}
	}

	$_liveCount++;
	if (main::DEBUGLOG && $log->is_debug)	{
		$log->debug("live=$_liveCount");
	}

	return $self;
}

sub DESTROY {
	my $self = shift;
	$_liveCount--;
	if (main::DEBUGLOG && $log->is_debug)	{
		$log->debug(sprintf("DESTROY($self) live=$_liveCount: index=%d, url=%s", $self->index(), $self->_track()->url));
	}
}

sub clonePlaylistSong {
	my ($old) = @_;

	assert($old->isPlaylist());

	my $new = (ref $old)->SUPER::new;

	$new->init_accessor(
		_status           => STATUS_READY,
		startOffset       => 0,
	);

	foreach ('handler', @_playlistCloneAttributes) {
		$new->init_accessor($_ => clone($old->$_()));
	}

	$_liveCount++;
	if (main::DEBUGLOG && $log->is_debug)	{
		$log->debug("live=$_liveCount");
	}

	my $next = $new->_getNextPlaylistTrack();
	return undef unless $next;
	
	return $new;	
}

sub resetSeekdata {
	$_[0]->seekdata(undef);
}

sub _getNextPlaylistTrack {
	my ($self) = @_;

	if ($self->_playlist() >= 2) {
		# leave it to the protocol handler in getNextTrack()

		# Old handlers expect this
		if ($self->_playlist() == 2) {
			$self->_currentTrack($self->_track());
		}

		return $self->_track();
	}

	# Get the next good audio track
	my $playlist = Slim::Schema->objectForUrl( {url => $self->_track()->url, playlist => 1} );
	main::DEBUGLOG && $log->is_debug && $log->debug( "Getting next audio URL from playlist (after " . ($self->_currentTrack() ? $self->_currentTrack()->url : '') . ")" );	
	my $track = $playlist->getNextEntry($self->_currentTrack() ? {after => $self->_currentTrack()} : undef);
	if ($track) {
		$self->_currentTrack($track);
		$self->_currentTrackHandler(Slim::Player::ProtocolHandlers->handlerForURL($track->url));
		$self->streamUrl($track->url);
		main::INFOLOG && $log->info( "Got next URL from playlist; track is: " . $track->url );	
		
	}
	return $track;
}

sub getNextSong {
	my ($self, $successCb, $failCb, $redir) = @_;

	my $handler = $self->currentTrackHandler();

	main::INFOLOG && $log->info($self->currentTrack()->url);

	#	if (playlist and no-track and (scanned or not scannable)) {
	if (!$self->_currentTrack()
		&& $self->isPlaylist()
		&& ($self->_scanDone() || !$handler->can('scanUrl')))
	{
		if (!$self->_getNextPlaylistTrack()) {
			&$failCb('PLAYLIST_NO_ITEMS_FOUND', $self->_track()->url);
			return;
		}
		$handler = $self->currentTrackHandler();
	}

	my $track   = $self->currentTrack();
	my $url     = $redir || $track->url;
	my $client  = $self->master();

	# If we have (a) a scannable playlist track,
	# or (b) a scannable track that is not yet scanned and could be a playlist ...
	if ($handler->can('scanUrl') && !$self->_scanDone()) {
		$self->_scanDone(1);
		main::INFOLOG && $log->info("scanning URL $url");
		$handler->scanUrl($url, {
			client => $client,
			song   => $self,
			cb     => sub {
				my ( $newTrack, $error ) = @_;

				if ($newTrack) {

					if ($track != $newTrack) {

						if ($self->_track() == $track) {
							# Update of original track, by playlist or redirection
							$self->_track($newTrack);	
							$self->_currentTrackHandler($handler->currentTrackHandler($self, $newTrack)) if $handler->can('currentTrackHandler');
														
							main::INFOLOG && $log->info("Track updated by scan: $url -> " . $newTrack->url);

							# Replace the item on the playlist so it has the new track/URL
							my $i = 0;
							for my $item ( @{ Slim::Player::Playlist::playList($client) } ) {
								my $itemURL = blessed($item) ? $item->url : $item;
								if ( $itemURL eq $url ) {
									splice @{ Slim::Player::Playlist::playList($client) }, $i, 1, $newTrack;
									last;
								}
								$i++;
							}
						} elsif ($self->_currentTrack() && $self->_currentTrack() == $track) {
							# The current, playlist track got updated, maybe by redirection
							# Probably should not happen as redirection should have been
							# resolved during recursive scan of playlist.

							# Cannot update $self->_currentTrack() as would mess up playlist traversal
							$log->warn("Unexpected update of playlist track: $url -> " . $newTrack->url);
						}

						$track = $newTrack;
						# need to replace streamUrl unless scanner has changed it
						$self->streamUrl($track->url) if $self->streamUrl eq $url;
					}

					# maybe we just found or scanned a playlist
					if (!$self->_currentTrack() && !$self->_playlist()) {
						$self->_playlist(Slim::Music::Info::isPlaylist($track, $track->content_type) ? 1 : 0);
					}
					
					# if we just found a playlist					
					if (!$self->_currentTrack() && $self->isPlaylist()) {
						main::INFOLOG && $log->info("Found a playlist");
					}
					
					# always recurse either for playlist or to continue and do getNextTrack
					$self->getNextSong($successCb, $failCb);
				}
				elsif ($track->can('redir') && $track->redir && !$redir) {
					# recurse once if we failed and have been redirected
					$self->getNextSong($successCb, $failCb, $track->redir);
				}
				else {
					# Notify of failure via cant_open, this is used to pick
					# up the failure for automatic RadioTime reporting
					Slim::Control::Request::notifyFromArray( $client, [ 'playlist', 'cant_open', $url, $error ] );

					$error ||= 'PROBLEM_OPENING_REMOTE_URL';

					$failCb->($error, $url);
				}
			},
		} );
		return;
	}

	if ($handler->can('getNextTrack')) {
		$handler->getNextTrack($self, $successCb, $failCb);
		return;
	}

	# Hooks for unconverted handlers
	elsif ($handler->can('onDecoderUnderrun') || $handler->can('onJump')) {
		if ($handler->can('onJump') && 
			!($self->owner()->{'playingState'} != Slim::Player::StreamingController::STOPPED()
			&& $handler->can('onDecoderUnderrun')))
		{
			$handler->onJump(master($self), $url, $self->seekdata(), $successCb);
		} else {
			$handler->onDecoderUnderrun(master($self), $url, $successCb);
		}			
	} 
	
	else {
		# the simple case
		&$successCb();
	}

}

# Some 'native' formats are streamed with a different format to their container
my %streamFormatMap = (
	wav => 'pcm',
);

sub open {
	my ($self, $seekdata, $redir) = @_;

	my $handler = $self->currentTrackHandler();
	my $client  = $self->master();
	my $track   = $self->currentTrack();
	assert($track);
	my $url = $redir || $track->url;

	# Reset seekOffset - handlers will set this if necessary
	$self->startOffset(0);

	# Restart direct-stream
	$self->directstream(0);

	main::INFOLOG && $log->info($url);

	$self->seekdata($seekdata) if $seekdata;

	# last chance to get the byte offset if not already provided	
	if ($self->seekdata && $self->seekdata->{'timeOffset'} && !$self->seekdata->{'sourceStreamOffset'}) {  
		my $seekdata = $self->getSeekData($self->seekdata->{'timeOffset'});
		$self->seekdata($seekdata) if $seekdata;
		main::INFOLOG && $log->info("Adding seekdata ", Data::Dump::dump($self->seekdata));
	}	

	my $sock;
	my $format = Slim::Music::Info::contentType($track);

	if ($handler->can('formatOverride')) {
		$format = $handler->formatOverride($self);
	}

	# get transcoding command & stream-mode
	# IF command == '-' AND canDirectStream THEN
	#	direct stream
	# ELSE
	#	ASSERT stream-mode == 'I'  OR command != '-'
	#
	#	IF stream-mode == 'I' OR handler-does-transcoding THEN
	#		open stream
	#	ENDIF
	#	IF command != '-' AND ! handler-does-transcoding THEN
	#		add transcoding pipeline
	#	ENDIF
	# ENDIF

	main::INFOLOG && $log->info("seek=", ($self->seekdata() ? 'true' : 'false'), ' time=', ($self->seekdata() ? $self->seekdata()->{'timeOffset'} : 0),
		 ' canSeek=', $self->canSeek());

	my $transcoder;
	my $error;

	if (main::TRANSCODING) {
		my $wantTranscoderSeek = $self->seekdata() && $self->seekdata()->{'timeOffset'} && $self->canSeek() == 2;
		my @wantOptions;
		push (@wantOptions, 'T') if ($wantTranscoderSeek);

		my @streamFormats;
		push (@streamFormats, 'I') if (! $wantTranscoderSeek);

		push @streamFormats, ($handler->isRemote && !Slim::Music::Info::isVolatile($handler) ? 'R' : 'F');
		
		my @formats = ( $format );
		push (@formats, grep { $_ ne $format} keys %{$track->processors}) if $track->can('processors');

		# we include processed formats just here because they only applies to remote + 'I' and other
		# calls to getConvertCommand2 (seek evaluation & Volatile) rule out this case before
		foreach (@formats) {
			$self->wantFormat($_);
			($transcoder, $error) = Slim::Player::TranscodingHelper::getConvertCommand2(
			$self,
			$_,
			\@streamFormats, [], \@wantOptions);
			last if $transcoder;
		}	

		if (! $transcoder) {
			logError("Couldn't create command line for $format playback for [$url]");
			return (undef, ($error || 'PROBLEM_CONVERT_FILE'), $url);
		} elsif (main::INFOLOG && $log->is_info) {
			 $log->info("Transcoder: streamMode=", $transcoder->{'streamMode'}, ", streamformat=", $transcoder->{'streamformat'});
		}

		if ($wantTranscoderSeek && (grep(/T/, @{$transcoder->{'usedCapabilities'}}))) {
			$transcoder->{'start'} = $self->startOffset($self->seekdata()->{'timeOffset'});
		}
	} else {
		require Slim::Player::CapabilitiesHelper;

		# Set the correct format for WAV playback
		$self->wantFormat($format);
		$format = $streamFormatMap{$format} || $format;

		# Is format supported by all players?
		if (!grep {$_ eq $format} Slim::Player::CapabilitiesHelper::supportedFormats($client)) {
			$error = 'PROBLEM_CONVERT_FILE';
		}
		# Is samplerate supported by all players?
		elsif (Slim::Player::CapabilitiesHelper::samplerateLimit($self)) {
			$error = 'UNSUPPORTED_SAMPLE_RATE';
		}

		if ($error) {
			logError("$error [$url]");
			return (undef, $error, $url);
		}

		$transcoder = {
			command => '-',
			streamformat => $format,
			streamMode => 'I',
			rateLimit => 0,
		};
	}
	
	# don't modify $song in getConverterCommand2 
	$self->stripHeader($transcoder->{'stripHeader'});
	
	# TODO work this out for each player in the sync-group
	my $directUrl;
	if ($transcoder->{'command'} eq '-' && ($directUrl = $client->canDirectStream($url, $self)) && (!$redir || $client->canHTTPS)) {
		main::INFOLOG && $log->info( "URL supports direct streaming [$url->$directUrl]" );
		$self->directstream(1);
		$self->streamUrl($directUrl);
	}

	else {
		my $handlerWillTranscode = $transcoder->{'command'} ne '-'
			&& $handler->can('canHandleTranscode') && $handler->canHandleTranscode($self);

		if ($transcoder->{'streamMode'} eq 'I' || $handlerWillTranscode) {
			main::INFOLOG && $log->info("Opening stream (no direct streaming) using $handler [$url]");

			$sock = $handler->new({
				url        => $url, # it is just easier if we always include the URL here
				client     => $client,
				song       => $self,
				transcoder => $transcoder,
			});

			if (!$sock) {
				
				# if we failed on a redirected track, retry once. Direct streaming will be disabled
				# as redirection from HTTP to HTTPS does not work in direct mode
				if ($track->can('redir') && $track->redir && !$redir) {
					main::INFOLOG && $log->info("failed opening, retrying non-redirected url ", $track->redir);
					$self->streamUrl($track->redir);
					return $self->open($seekdata, $track->redir);
				}

				logWarning("stream failed to open [$url].");
				$self->setStatus(STATUS_FAILED);
				return (undef, $self->isRemote() ? 'PROBLEM_CONNECTING' : 'PROBLEM_OPENING', $url);
			}

			my $contentType = Slim::Music::Info::mimeToType($sock->contentType) || $sock->contentType;

			# if it's an audio stream, try to stream,
			# either directly, or via transcoding.
			if (Slim::Music::Info::isSong($track, $contentType)) {

				main::INFOLOG && $log->info("URL is a song (audio): $url, type=$contentType");

				if ($sock->opened() && !defined(Slim::Utils::Network::blocking($sock, 0))) {
					logError("Can't set nonblocking for url: [$url]");
					return (undef, 'PROBLEM_OPENING', $url);
				}

				if ($handlerWillTranscode) {
					$self->_transcoded(1);
					$self->_streambitrate($sock->getStreamBitrate($transcoder->{'rateLimit'}) || 0);
				}

				# If the protocol handler has the bitrate set use this
				if ($sock->can('bitrate') && $sock->bitrate) {
					$self->_bitrate($sock->bitrate);
				}
			}	
			# if it's one of our playlists, parse it...
			elsif (Slim::Music::Info::isList($track, $contentType)) {

				# handle the case that we've actually
				# got a playlist in the list, rather
				# than a stream.

				# parse out the list
				my @items = Slim::Formats::Playlists->parseList($url, $sock);

				# hack to preserve the title of a song redirected through a playlist
				if (scalar(@items) == 1 && $items[0] && defined($track->title)) {
					Slim::Music::Info::setTitle($items[0], $track->title);
				}

				# close the socket
				$sock->close();
				$sock = undef;

				Slim::Player::Source::explodeSong($client, \@items);

				my $new = $self->new ($self->owner(), $self->index());
				%$self = %$new;

				# try to open the first item in the list, if there is one.
				$self->getNextSong (
					sub {return $self->open();}, # success
					sub {return(undef, @_);}    # fail
				);

			} else {
				logWarning("Don't know how to handle content for [$url] type: $contentType");

				$sock->close();
				$sock = undef;

				$self->setStatus(STATUS_FAILED);
				return (undef, $self->isRemote() ? 'PROBLEM_CONNECTING' : 'PROBLEM_OPENING', $url);
			}		
		}	

		if (main::TRANSCODING) {
			if ($transcoder->{'command'} ne '-' && ! $handlerWillTranscode) {
				# Need to transcode

				my $quality = $prefs->client($client)->get('lameQuality');

				# use a pipeline on windows when remote as we need socketwrapper to ensure we get non blocking IO
				my $usepipe = (defined $sock || (main::ISWINDOWS && $handler->isRemote)) ? 1 : undef;

				my $command = Slim::Player::TranscodingHelper::tokenizeConvertCommand2(
					$transcoder, $sock ? '-' : $track->path, $self->streamUrl(), $usepipe, $quality
				);

				if (!defined($command)) {
					logError("Couldn't create command line for $format playback for [$self->streamUrl()]");
					return (undef, 'PROBLEM_CONVERT_FILE', $url);
				}

				main::INFOLOG && $log->info('Tokenized command: ', Slim::Utils::Unicode::utf8decode_locale($command));

				my $pipeline;
				
				# Bug 10451: only use Pipeline when really necessary 
				# and indicate if local or remote source
				if ($usepipe) { 
					$pipeline = Slim::Player::Pipeline->new($sock, $command, !$handler->isRemote);
				} else {
					# Bug: 4318
					# On windows ensure a child window is not opened if $command includes transcode processes
					if (main::ISWINDOWS) {
						Win32::SetChildShowWindow(0);
						$pipeline = FileHandle->new;
						my $pid = $pipeline->open($command);

						Win32::SetChildShowWindow();
					} else {
						$pipeline = FileHandle->new($command);
					}

					if ($pipeline && $pipeline->opened() && !defined(Slim::Utils::Network::blocking($pipeline, 0))) {
						logError("Can't set nonblocking for url: [$url]");
						return (undef, 'PROBLEM_OPENING', $url);
					}
				}

				if (!defined($pipeline)) {
					logError("$!: While creating conversion pipeline for: ", $self->streamUrl());
					$sock->close() if $sock;
					return (undef, 'PROBLEM_CONVERT_STREAM', $url);
				}

				$sock = $pipeline;

				$self->_transcoded(1);

				$self->_streambitrate(guessBitrateFromFormat($transcoder->{'streamformat'}, $transcoder->{'rateLimit'}) || 0);
			}
		} # ENDIF main::TRANSCODING

		$client->remoteStreamStartTime(Time::HiRes::time());
		$client->pauseTime(0);
	}

	my $streamController;

	######################
	# make sure the filehandle was actually set
	if ($sock || $self->directstream()) {

		if ($sock && $sock->opened()) {

			# binmode() can mess with the file position but, since we cannot
			# rely on all possible protocol handlers to have set binmode,
			# we need to try to preserve the seek position if it is set.
			my $position = $sock->sysseek(0, SEEK_CUR) if $sock->can('sysseek');
			binmode($sock);
			$sock->sysseek($position, SEEK_SET) if $position;
		}

		if ( main::STATISTICS ) {
			# XXXX - this really needs to happen in the caller!
			# No database access here. - dsully
			# keep track of some stats for this track
			if ( Slim::Music::Import->stillScanning() ) {
				# bug 16003 - don't try to update the persistent DB while a scan is running
				main::DEBUGLOG && $log->is_debug && $log->debug("Don't update the persistent DB - it's locked by the scanner.");
			}
			elsif ( my $persistent = $track->retrievePersistent ) {
				$persistent->set( playcount  => ( $persistent->playcount || 0 ) + 1 );
				$persistent->set( lastplayed => time() );
				$persistent->update;
			}
		}

		$self->_streamFormat($transcoder->{'streamformat'});
		$client->streamformat($self->_streamFormat()); # XXX legacy

		$streamController = Slim::Player::SongStreamController->new($self, $sock);

	} else {
		# file or remote 'R' mode failed => no point retrying
		logError("Can't open [$url] : $!");
		return (undef, 'PROBLEM_OPENING', $url);
	}

	Slim::Control::Request::notifyFromArray($client, ['playlist', 'open', $url]);

	$self->setStatus(STATUS_STREAMING);

	$client->metaTitle(undef);

	return $streamController;
}

# Static method
sub guessBitrateFromFormat {
	my ($format, $maxRate) = @_;

	# Hack to set up stream bitrate for songTime for SliMP3/SB1
	# Also used when rebuffering, etc.
	if ($format eq 'mp3') {
		return ($maxRate || 320) * 1000;
	} elsif ($format =~ /wav|aif|pcm/) {
		# Just assume standard rate
		return 44_100 * 16 * 2;
	} elsif ($format eq 'flc') {
		# Assume 50% compression at standard rate
		return 44_100 * 16;
	}
}

sub pluginData {
	my ( $self, $key, $value ) = @_;

	my $ret;

	if ( !defined $self->_pluginData() ) {
		$self->_pluginData({});
	}

	if ( !defined $key ) {
		return $self->_pluginData();
	}

	if ( ref $key eq 'HASH' ) {
		# Assign an entire hash to pluginData
		$ret = $self->_pluginData($key);
	}
	else {
		if ( defined $value ) {
			$self->_pluginData()->{$key} = $value;
		}

		$ret = $self->_pluginData()->{$key};
	}

	return $ret;
}


sub isActive            {return $_[0]->_status() < STATUS_FAILED;}
sub master              {return $_[0]->owner()->master();}
sub track               {return $_[0]->_track();}
sub currentTrack        {return $_[0]->_currentTrack()        || $_[0]->_track();}
sub currentTrackHandler {return $_[0]->_currentTrackHandler() || $_[0]->handler();}
sub isRemote            {return $_[0]->currentTrackHandler()->isRemote();}  
sub streamformat        {return $_[0]->_streamFormat() || Slim::Music::Info::contentType($_[0]->currentTrack()->url);}
sub isPlaylist          {return $_[0]->_playlist();}
sub status              {return $_[0]->_status();}

sub getSeekDataByPosition {
	my ($self, $bytesReceived) = @_;

	return undef if $self->_transcoded();

	my $streamLength = $self->streamLength();

	if ($streamLength && $bytesReceived >= $streamLength) {
		return {streamComplete => 1};
	}

	my $handler = $self->currentTrackHandler();

	if ($handler->can('getSeekDataByPosition')) {
		return $handler->getSeekDataByPosition($self->master(), $self, $bytesReceived);
	} else {
		return undef;
	}
}

sub getSeekData {
	my ($self, $newtime) = @_;

	my $handler = $self->currentTrackHandler();

	if ($handler->can('getSeekData')) {
		return $handler->getSeekData($self->master(), $self, $newtime);
	} else {
		return undef;
	}
}

sub bitrate {
	my $self = shift;

	if (scalar @_) {
		return $self->_bitrate($_[0]);
	}
	return $self->_bitrate() || Slim::Music::Info::getBitrate($self->currentTrack()->url);
}

sub duration {
	my $self = shift;

	if (scalar @_) {
		return $self->_duration($_[0]);
	}
	return $self->_duration() || Slim::Music::Info::getDuration($self->currentTrack()->url);
}



sub streambitrate {
	my $self = shift;
	my $sb = $self->_streambitrate();
	if (defined ($sb)) {
		return $sb ? $sb : undef;
	} else {
		return $self->bitrate()
	}
}

sub setStatus {
	my ($self, $status) = @_;
	$self->_status($status);

	# Bug 11156 - we reset the seekability evaluation here in case we now know more after
	# parsing the actual stream headers or the background sanner has had time to finish.
	$self->_canSeek(undef);
}

sub canSeek {
	my $self = shift;

	my $canSeek = $self->canDoSeek();

	return $canSeek if $canSeek;

	return wantarray ? ( $canSeek, @{$self->_canSeekError()} ) : $canSeek;
}

sub canDoSeek {
	my $self = shift;

	return $self->_canSeek() if (defined $self->_canSeek());

	my $handler = $self->currentTrackHandler();

	if (!main::TRANSCODING) {

		if ( $handler->can('canSeek') && $handler->canSeek( $self->master(), $self )) {
			return $self->_canSeek(1);
		} else {
			$self->_canSeekError([$handler->can('canSeekError') 
						? $handler->canSeekError( $self->master(), $self  )
						: ('SEEK_ERROR_TYPE_NOT_SUPPORTED')]);
			return $self->_canSeek(0);
		}

	} 
	
	else {

		if ($handler->can('canSeek')) {
			if ($handler->canSeek( $self->master(), $self )) {
				return $self->_canSeek(2) if $handler->can('canTranscodeSeek') && $handler->canTranscodeSeek();
				return $self->_canSeek(1) if $handler->isRemote() && !Slim::Music::Info::isVolatile($handler);

				# If dealing with local file and transcoding then best let transcoder seek if it can

				# First see how we would stream without seeking question
				my $transcoder = Slim::Player::TranscodingHelper::getConvertCommand2(
					$self,
					Slim::Music::Info::contentType($self->currentTrack),
					['I', 'F'], [], []);

				if (! $transcoder) {
					$self->_canSeekError([ 'SEEK_ERROR_TRANSCODED' ]);
					return $self->_canSeek(0);
				}

				# Is this pass-through?
				if ($transcoder->{'command'} eq '-') {
					return $self->_canSeek(1); # nice simple case
				}

				# no, then could we get a seeking transcoder?
				if (Slim::Player::TranscodingHelper::getConvertCommand2(
					$self,
					Slim::Music::Info::contentType($self->currentTrack),
					['I', 'F'], ['T'], []))
				{
					return $self->_canSeek(2);
				}

				# no, then did the transcoder accept stdin?
				if ($transcoder->{'streamMode'} eq 'I') {
					return $self->_canSeek(1);
				} else {
					$self->_canSeekError([ 'SEEK_ERROR_TRANSCODED' ]);
					return $self->_canSeek(0);
				}

			} else {
				$self->_canSeekError([$handler->can('canSeekError') 
						? $handler->canSeekError( $self->master(), $self  )
						: ('SEEK_ERROR_REMOTE')]);

				# Note: this is intended to fall through to the below code
			}
		} 
		
		if (Slim::Player::TranscodingHelper::getConvertCommand2(
				$self,
				Slim::Music::Info::contentType($self->currentTrack),
				[($handler->isRemote && !Slim::Music::Info::isVolatile($handler)) ? 'R' : 'F'], ['T'], []))
		{
			return $self->_canSeek(2);
		}

		if (!$self->_canSeekError()) {
			$self->_canSeekError([ 'SEEK_ERROR_REMOTE' ]);
		}

		return $self->_canSeek(0);
	}
}

sub icon {
	my $self = shift;
	my $client = $self->master();

	my $icon = Slim::Player::ProtocolHandlers->iconForURL($self->currentTrack()->url, $client);

	$icon ||= Slim::Player::ProtocolHandlers->iconForURL($self->track()->url, $client);

	if (!$icon && $self->currentTrack()->isa('Slim::Schema::Track')) {
		$icon = '/music/' . $self->currentTrack()->coverid . '/cover.jpg'
	}

	return $icon;
}

1;
