package Slim::Player::StreamingController;


# Logitech Media Server Copyright 2001-2020 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use bytes;
use strict;

use Scalar::Util qw(blessed weaken);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Player::Song;
use Slim::Player::ReplayGain;

my $log = logger('player.source');
my $synclog = logger('player.sync');

my $prefs = preferences('server');

# Streaming state
use constant IDLE      => 0;
use constant STREAMING => 1;
use constant STREAMOUT => 2;
use constant TRACKWAIT => 3;	# Waiting for next track info to be ready and all players ready-to-stream
my $i = 0;
my @StreamingStateName = ('IDLE', 'STREAMING', 'STREAMOUT', 'TRACKWAIT');
my %StreamingStateNameMap = map { $_ => $i++ } @StreamingStateName;

# Playing state (audio)
use constant STOPPED         => 0;
use constant BUFFERING       => 1;
use constant WAITING_TO_SYNC => 2;
use constant PLAYING         => 3;
use constant PAUSED          => 4;
$i = 0;
my @PlayingStateName = ('STOPPED', 'BUFFERING', 'WAITING_TO_SYNC', 'PLAYING', 'PAUSED');
my %PlayingStateNameMap = map { $_ => $i++ } @PlayingStateName;

use constant FADEVOLUME       => 0.3125;

sub new {
	my ($class, $client) = @_;

	my $self = {
		masterId             => $client->id(),
		players              => [],
		allPlayers           => [$client],

		# State
		streamingState       => IDLE,
		playingState         => STOPPED,
		rebuffering          => 0,
		lastStateChange      => 0,
		
		# Streaming control
		songqueue            => [],
		songStreamController => undef,
		nextCheckSyncTime    => 0,
		resumeTime           => undef,				# elapsed time when paused
		
		# Sync management
		syncgroupid          => undef,
		frameData            => undef,              # array of (stream-byte-offset, stream-time-offset) tuples
		initialStreamBuffer  => undef,              # cache of initially-streamed data to calculate rate
		
		# Track management
		nextTrack            => undef,			    # a Song
		nextTrackCallbackId  => 0,
		consecutiveErrors    => 0,
	};
	
	if ($client->power) {
		push @{$self->{'players'}}, $client;
		weaken( $self->{players}->[0] );
	}
	
	weaken( $self->{allPlayers}->[0] );
	
	bless $self, $class;
	
	return $self;
}

# What we have here is a state table with a number of handlers, one named handler
# to cover each precondition/action/end-state combination. The handler functions
# are after the table.
#
# I am not convinced that the table is either the most efficient
# implementation of this state machine, nor the the most comprehensible.
# An alternate approach would be to evaluate the constriants and execute the
# actions & state-changes directly from the inbound-event functions. Whether it
# makes sense to change to this remains to be seen. But for the moment, use of
# the jump table gives more opportunities to find and fix unanticipated event-state
# combinations.

my @ValidStates = (
#	IDLE		STREAMING	STREAMOUT	TRACKWAIT
[	1,			0,			0,			1],		# STOPPED	
[	0,			1,			1,			0],		# BUFFERING
[	0,			1,			1,			0],		# WAITING_TO_SYNC
[	1,			1,			1,			1],		# PLAYING
[	1,			1,			1,			1],		# PAUSED
);

my %stateTable = (	# stateTable[event][playState][streamingState]
#		IDLE			STREAMING		STREAMOUT		TRACKWAIT
Stop =>
[	[	\&_NoOp,		\&_BadState,	\&_BadState,	\&_Stop],			# STOPPED	
	[	\&_BadState,	\&_Stop,		\&_Stop,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Stop,		\&_Stop,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Stop,		\&_Stop,		\&_Stop,		\&_Stop],			# PLAYING
	[	\&_Stop,		\&_Stop,		\&_Stop,		\&_Stop],			# PAUSED
],
Play =>
[	[	\&_StopGetNext,	\&_BadState,	\&_BadState,	\&_StopGetNext],	# STOPPED	
	[	\&_BadState,	\&_StopGetNext,	\&_StopGetNext,	\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_StopGetNext,	\&_StopGetNext,	\&_BadState],		# WAITING_TO_SYNC
	[	\&_StopGetNext,	\&_StopGetNext,	\&_StopGetNext,	\&_StopGetNext],	# PLAYING
	[	\&_StopGetNext,	\&_StopGetNext,	\&_StopGetNext,	\&_StopGetNext],	# PAUSED
],
ContinuePlay =>
[	[	\&_Stop,		\&_BadState,	\&_BadState,	\&_StopGetNext],	# STOPPED	
	[	\&_BadState,	\&_StopGetNext,	\&_StopGetNext,	\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_StopGetNext,	\&_StopGetNext,	\&_BadState],		# WAITING_TO_SYNC
	[	\&_Continue,	\&_Continue,	\&_Continue,	\&_PlayIfReady],	# PLAYING
	[	\&_Stop,		\&_Stop,		\&_Stop,		\&_Stop],			# PAUSED
],
Pause =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_NoOp],			# STOPPED	
	[	\&_BadState,	\&_NoOp,		\&_NoOp,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_NoOp,		\&_NoOp,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Pause,		\&_Pause,		\&_Pause,		\&_Pause],			# PLAYING
	[	\&_JumpOrResume,\&_Resume,		\&_Resume,		\&_Resume],			# PAUSED
],
Resume =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_Invalid],		# STOPPED	
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Invalid,		\&_Invalid,		\&_Invalid,		\&_Invalid],		# PLAYING
	[	\&_JumpOrResume,\&_Resume,		\&_Resume,		\&_Resume],			# PAUSED
],
Flush =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_Invalid],		# STOPPED	
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_FlushGetNext,\&_FlushGetNext,\&_FlushGetNext,\&_FlushGetNext],	# PLAYING
	[	\&_FlushGetNext,\&_FlushGetNext,\&_FlushGetNext,\&_FlushGetNext],	# PAUSED
],
Skip  => 
[	[	\&_StopGetNext,	\&_BadState,	\&_BadState,	\&_NoOp],			# STOPPED	
	[	\&_BadState,	\&_Skip,		\&_Skip,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Skip,		\&_Skip,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_StopGetNext,	\&_Skip,		\&_Skip,		\&_Skip],			# PLAYING
	[	\&_StopGetNext,	\&_Skip,		\&_Skip,		\&_Skip],			# PAUSED
],
JumpToTime =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_Invalid],		# STOPPED	
	[	\&_BadState,	\&_JumpToTime,	\&_JumpToTime,	\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_JumpToTime,	\&_JumpToTime,	\&_BadState],		# WAITING_TO_SYNC
	[	\&_JumpToTime,	\&_JumpToTime,	\&_JumpToTime,	\&_JumpToTime],		# PLAYING
	[	\&_JumpPaused,	\&_JumpPaused,	\&_JumpPaused,	\&_JumpPaused],		# PAUSED
],
NextTrackReady =>
[	[	\&_NoOp,		\&_BadState,	\&_BadState,	\&_Stream],			# STOPPED	
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Invalid,		\&_Invalid,		\&_Invalid,		\&_StreamIfReady],	# PLAYING
	[	\&_Invalid,		\&_Invalid,		\&_Invalid,		\&_StreamIfReady],	# PAUSED
],
NextTrackError =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_NextIfMore],		# STOPPED	
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Invalid,		\&_Invalid,		\&_Invalid,		\&_NextIfMore],		# PLAYING
	[	\&_Invalid,		\&_Invalid,		\&_Invalid,		\&_NextIfMore],		# PAUSED
],
LocalEndOfStream =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_Invalid],		# STOPPED	
	[	\&_BadState,	\&_Streamout,	\&_Invalid,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Streamout,	\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Invalid,		\&_Streamout,	\&_Invalid,		\&_Invalid],		# PLAYING
	[	\&_Invalid,		\&_Streamout,	\&_Invalid,		\&_Invalid],		# PAUSED
],
BufferReady =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_Invalid],		# STOPPED	
	[	\&_BadState,	\&_WaitToSync,	\&_WaitToSync,	\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_StartIfReady,\&_StartIfReady,\&_BadState],		# WAITING_TO_SYNC
	[	\&_Invalid,		\&_Invalid,		\&_Invalid,		\&_Invalid],		# PLAYING
	[	\&_Invalid,		\&_Invalid,		\&_Invalid,		\&_Invalid],		# PAUSED
],
Started =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_Invalid],		# STOPPED	
	[	\&_BadState,	\&_Playing,		\&_Playing,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_PlayAndNext,	\&_Playing,		\&_Playing,		\&_PlayAndStream],	# PLAYING
	[	\&_PlayAndNext,	\&_Playing,		\&_Playing,		\&_PlayAndStream],	# PAUSED
],
StreamingFailed =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_Invalid],		# STOPPED	
	[	\&_BadState,	\&_StopNextIfMore, \&_StopNextIfMore, \&_BadState],	# BUFFERING
	[	\&_BadState,	\&_StopNextIfMore, \&_StopNextIfMore, \&_BadState],	# WAITING_TO_SYNC
	[	\&_Invalid,		\&_SyncStopNext, \&_SyncStopNext, \&_Invalid],		# PLAYING
	[	\&_Invalid,		\&_Stop,		\&_Stop,		\&_Invalid],		# PAUSED
],
EndOfStream =>
[	[	\&_NoOp,		\&_BadState,	\&_BadState,	\&_NoOp],			# STOPPED	
	[	\&_BadState,	\&_StartStreamout,\&_Start,		\&_BadState],		# BUFFERING; _Start in Streamout to counter Bug 9125
	[	\&_BadState,	\&_StartStreamout,\&_Start,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Invalid,		\&_AutoStart,	\&_AutoStart,	\&_Invalid],		# PLAYING
	[	\&_Invalid,		\&_Streamout,	\&_NoOp,		\&_Invalid],		# PAUSED
],
ReadyToStream =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_Invalid],		# STOPPED	
	[	\&_BadState,	\&_NoOp,		\&_Invalid,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_NoOp,		\&_NextIfMore,	\&_RetryOrNext,	\&_StreamIfReady],	# PLAYING
	[	\&_NoOp,		\&_NextIfMore,	\&_NextIfMore,	\&_StreamIfReady],	# PAUSED
],
Stopped =>
[	[	\&_Invalid,		\&_BadState,	\&_BadState,	\&_NoOp],			# STOPPED	
	[	\&_BadState,	\&_NoOp,		\&_NoOp,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Stopped,		\&_Buffering,	\&_Buffering,	\&_PlayIfReady],	# PLAYING
	[	\&_Stopped,		\&_Buffering,	\&_Buffering,	\&_Stopped],		# PAUSED
],
OutputUnderrun =>
[	[	\&_NoOp,		\&_BadState,	\&_BadState,	\&_NoOp],			# STOPPED	
	[	\&_BadState,	\&_NoOp,		\&_NoOp,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_Invalid,		\&_Invalid,		\&_BadState],		# WAITING_TO_SYNC
	[	\&_Invalid,		\&_Rebuffer,	\&_Rebuffer,	\&_Invalid],		# PLAYING
	[	\&_NoOp,		\&_NoOp,		\&_NoOp,		\&_NoOp],			# PAUSED
],
StatusHeartbeat =>
[	[	\&_NoOp,		\&_BadState,	\&_BadState,	\&_NoOp],			# STOPPED	
	[	\&_BadState,	\&_NoOp,		\&_NoOp,		\&_BadState],		# BUFFERING
	[	\&_BadState,	\&_StartIfReady,\&_StartIfReady,\&_BadState],		# WAITING_TO_SYNC
	[	\&_CheckSync,	\&_CheckSync,	\&_CheckSync,	\&_CheckSync],		# PLAYING
	[	\&_NoOp,		\&_CheckPaused,	\&_CheckPaused,	\&_NoOp],			# PAUSED
],
);

####################################################################
# Actions
sub _eventAction {
	my ($self, $event, $params) = @_;
	
	my $action = $stateTable{$event}[$self->{'playingState'}][$self->{'streamingState'}];

	if (!defined $action) {
		$log->error(sprintf("%s: %s in state %s-%s -> undefined",
			$self->{'masterId'},
			$event,
			$PlayingStateName[$self->{'playingState'}], $StreamingStateName[$self->{'streamingState'}]));
		return;
	}	
	
	my $curPlayingState;
	my $curStreamingState;
	
	if (main::DEBUGLOG && $log->is_debug) {
		$curPlayingState   = $PlayingStateName[$self->{'playingState'}];
		$curStreamingState = $StreamingStateName[$self->{'streamingState'}];
		
		$log->debug(
			sprintf("%s: %s in %s-%s -> %s",
			$self->{'masterId'},
			$event,
			$curPlayingState, $curStreamingState,
			Slim::Utils::PerlRunTime::realNameForCodeRef($action))
		);
			
		if ($params) {
			my $s = "params:";
			foreach my $p (keys %$params) {
				$s .= " $p => " . (defined $params->{$p} ? $params->{$p} : 'undef');
			}
			$log->debug($s);
		}	
	}

	my $result = $action->(@_);
	
	if (!$ValidStates[$self->{'playingState'}][$self->{'streamingState'}]) {
		$log->error(sprintf("%s:  %s with action %s resulted in invalid state %s-%s",
			$self->{'masterId'},
			$event,
			main::DEBUGLOG ? Slim::Utils::PerlRunTime::realNameForCodeRef($action) : 'unk',
			$PlayingStateName[$self->{'playingState'}], $StreamingStateName[$self->{'streamingState'}])
		);
	}
	
	elsif ( main::DEBUGLOG && $log->is_debug ) {
		my $newPlayingState   = $PlayingStateName[$self->{'playingState'}];
		my $newStreamingState =  $StreamingStateName[$self->{'streamingState'}];
		
		if ( $newPlayingState ne $curPlayingState || $newStreamingState ne $curStreamingState ) {
			$log->debug( sprintf("%s: %s - new state %s-%s",
				$self->{'masterId'},
				$event,
				$newPlayingState, $newStreamingState,
			) );
		}	
	}

	return $result;
}

sub _NoOp {}

sub _BadState {
	my ($self, $event) = @_;
	$log->error(sprintf("%s: event %s received while in invalid state %s-%s", $self->{'masterId'}, $event,
		$PlayingStateName[$self->{'playingState'}], $StreamingStateName[$self->{'streamingState'}]));
	logBacktrace('') if $log->is_warn;
}

sub _Invalid {
	my ($self, $event) = @_;
	$log->warn(sprintf("%s: event %s received while in invalid state %s-%s", $self->{'masterId'}, $event,
		$PlayingStateName[$self->{'playingState'}], $StreamingStateName[$self->{'streamingState'}]));
	logBacktrace('') if $log->is_warn;
}

sub _Buffering {_setPlayingState($_[0], BUFFERING);}

sub _Playing {
	my ($self) = @_;
	
	# need to fade-in here and not in _Stream due to potential buffering delay
	if ($self->{'fadeActive'}) {
		foreach my $player (@{$self->{'players'}}) {
			$player->fade_volume($prefs->client($self->master)->get('fadeInDuration'));
		}
	}	
	$self->{'fadeActive'} = undef;
	
	# bug 10681 - don't actually change the state if we are rebuffering
	# as there can be a race condition between output buffer underrun and
	# track-start events especially, but not exclusively when synced.
	# We still advance the track information.
	if (!$self->{'rebuffering'}) {
		_setPlayingState($self, PLAYING);
	}
	
	$self->{'consecutiveErrors'} = 0;
	
	my $queue = $self->{'songqueue'};
	my $last_song = $self->playingSong();

	while (defined($last_song) 
		&& ($last_song->status() == Slim::Player::Song::STATUS_PLAYING 
			|| $last_song->status() == Slim::Player::Song::STATUS_FAILED
			|| $last_song->status() == Slim::Player::Song::STATUS_FINISHED)
		&& scalar(@$queue) > 1)
	{
		main::INFOLOG && $log->info("Song " . $last_song->index() . " is not longer in the queue");
		pop @{$queue};
		$last_song = $queue->[-1];
	}
	
	if (defined($last_song)) {
		main::INFOLOG && $log->info("Song " . $last_song->index() . " has now started playing");
		$last_song->setStatus(Slim::Player::Song::STATUS_PLAYING);
		$last_song->retryData(undef);	# we are playing so we must be done retrying
		if ($last_song->currentTrackHandler()->can('onPlay')) {
			foreach my $player (@{$self->{'players'}}) {
				$last_song->currentTrackHandler()->onPlay($player, $last_song);
			}
		}
	}
	
	# Update a few timestamps
	# trackStartTime is used to signal the buffering status message to stop
	# currentPlaylistChangeTime signals the web to refresh the playlist
	my $time = Time::HiRes::time();
	$self->master()->trackStartTime( $time );
	$self->master()->currentPlaylistChangeTime( $time );

	Slim::Player::Playlist::refreshPlaylist($self->master());
	
	if ( $last_song ) {
		Slim::Control::Request::notifyFromArray($self->master(),
			[
				'playlist', 
				'newsong', 
				Slim::Music::Info::standardTitle(
					$self->master(), 
					$last_song->currentTrack()
				),
				$last_song->index()
			]
		);
	}
	
	if ( main::INFOLOG && $log->is_info ) {
		$log->info("Song queue is now " . join(',', map { $_->index() } @$queue));
	}
	
}

sub _Stopped {
	_setPlayingState( $_[0], STOPPED );
	_notifyStopped( $_[0] );
}

sub _notifyStopped {
	my ($self, $suppressNotifications) = @_;

	# This was previously commented out, for bug 7781, 
	# because some plugins (Alarm) don't like extra stop events.
	# This broke important notifications for Jive.
	# Other changes mean that that this can be reinstated.
	Slim::Control::Request::notifyFromArray( $self->master(), ['playlist', 'stop'] ) unless $suppressNotifications;

	foreach my $player ( @{ $self->{'players'} } ) {
		if ($player->can('onStop')) {
			$player->onStop();
		}
	}
}

sub _Streamout {_setStreamingState($_[0], STREAMOUT);}

sub _CheckPaused {	# only called when PAUSED
	my ($self, $event, $params) = @_;
	
	return if ! $self->isPaused();	# safety check

	my $song = $self->playingSong();
	if (   $song
		&& $song->currentTrackHandler()->isRemote()
		&& $self->master()->usage() > 0.98)
	{
		if ($song->canSeek() && defined $self->{'resumeTime'}) {

			# Bug 10645: stop only the streaming if there is a chance to restart
			main::INFOLOG && $log->info("Stopping remote stream upon full buffer when paused (resume time: $self->{'resumeTime'})");
				
			_pauseStreaming($self, $song);
			
		} elsif (!$song->duration()) {
			
			# Bug 7620: stop remote radio streams if they have been paused long enough for the buffer to fill.
			# Assume unknown duration means radio and so we should stop now
			main::INFOLOG && $log->info("Stopping remote stream upon full buffer when paused (no resume)");
			
			_Stop(@_);
		}
		
		# else - (bug 14230) just leave it paused and if the remote source disconnects then pick up the pieces later
	}
}

sub _pauseStreaming {
	my ($self, $playingSong) = @_;
	
	if ($self->{'streamingState'} == IDLE) {
		return;
	}
	
	foreach my $player (@{$self->{'players'}})	{
		_stopClient($player);
	}
	
	if ($self->{'songStreamController'}) {
		$self->{'songStreamController'}->close();
		$self->{'songStreamController'} = undef;
	}
	
	_setStreamingState($self, IDLE);
	$playingSong->setStatus(Slim::Player::Song::STATUS_READY);
	
	# clear streamingSong if not same as playingSong
	if ($playingSong != $self->{'songqueue'}->[0]) {
		shift @{$self->{'songqueue'}};
	}
	
}

use constant CHECK_SYNC_INTERVAL        => 0.950;
use constant MIN_DEVIATION_ADJUST       => 0.010;
use constant MAX_DEVIATION_ADJUST       => 10.000;
use constant PLAYPOINT_RECENT_THRESHOLD => 3.0;

sub _CheckSync {
	my ($self, $event, $params) = @_;
	
	# check to see if resynchronization is necessary

	return unless scalar @{ $self->{'players'} } > 1;
	
	my $now = Time::HiRes::time();
	return if $now < $self->{'nextCheckSyncTime'};
	$self->{'nextCheckSyncTime'} = $now + CHECK_SYNC_INTERVAL;

	# need a recent play-point from all players in the group, otherwise give up
	my $recentThreshold = $now - PLAYPOINT_RECENT_THRESHOLD;
	my @playerPlayPoints;
	foreach my $player (@{ $self->{'players'} }) {
		next unless ( $player->isPlayer()
			&& $prefs->client($player)->get('maintainSync') );
		my $playPoint = $player->playPoint();
		if ( !defined $playPoint ) {
			if ( main::DEBUGLOG && $synclog->is_debug ) {$synclog->debug( $player->id() . " bailing as no playPoint" );}
			return;
		}
		if ( $playPoint->[0] > $recentThreshold ) {
			push(@playerPlayPoints,
				[
					$player,
					$playPoint->[1] + $prefs->client($player)->get('playDelay') / 1000
				]
			);
		}
		else {
			if ( main::DEBUGLOG && $synclog->is_debug ) {
				$synclog->debug( $player->id() . " bailing as playPoint too old: "
					  . ( $now - $playPoint->[0] ) . "s" );
			}
			return;
		}
	}
	return unless scalar(@playerPlayPoints);

	if ( main::DEBUGLOG && $synclog->is_debug ) {
		my $first = $playerPlayPoints[0][1];
		my $str = sprintf( "%s: %.3f", $playerPlayPoints[0][0]->id(), $first );
		foreach ( @playerPlayPoints[ 1 .. $#playerPlayPoints ] ) {
			$str .= sprintf( ", %s: %+5d",
				$_->[0]->id(), ( $_->[1] - $first ) * 1000 );
		}
		$synclog->debug("playPoints: $str");
	}

	# sort the play-points by decreasing apparent-start-time
	@playerPlayPoints = sort { $b->[1] <=> $a->[1] } @playerPlayPoints;

 	# clean up the list of stored frame data
 	# (do this now, so that it does not delay critial timers when using pauseFor())
	main::SB1SLIMP3SYNC && Slim::Player::SB1SliMP3Sync::purgeOldFrames( $self->frameData(),
		$recentThreshold - $playerPlayPoints[0][1] );

	# find the reference player - the most-behind that does not support skipAhead
	my $reference;
	for ( $reference = 0 ; $reference < $#playerPlayPoints ; $reference++ ) {
		last unless $playerPlayPoints[$reference][0]->can('skipAhead');
	}
	my $referenceTime = $playerPlayPoints[$reference][1];

	# my $referenceMinAdjust = $prefs->client($playerPlayPoints[$reference][0])->get('minSyncAdjust')/1000;

	# tell each player that is out-of-sync with the reference to adjust
	for ( my $i = 0 ; $i < @playerPlayPoints ; $i++ ) {
		next if ( $i == $reference );
		my $player = $playerPlayPoints[$i][0];
		my $delta  = abs( $playerPlayPoints[$i][1] - $referenceTime );
		next if (
			   $delta > MAX_DEVIATION_ADJUST
			|| $delta < MIN_DEVIATION_ADJUST
			|| $delta < $prefs->client($player)->get('minSyncAdjust') / 1000

			# || $delta < $referenceMinAdjust
		  );
		if ( $i < $reference ) {
			if ( main::INFOLOG && $synclog->is_info ) {
				$synclog->info(sprintf("%s resync: skipAhead %dms",	$player->id(), $delta * 1000));
			}
			$player->skipAhead($delta);
			$self->{'nextCheckSyncTime'} += 1;
		}
		else {

 			# bug 6864: SB1s cannot reliably pause without skipping frames, so we don't try
			if ( $player->can('pauseForInterval') ) {
				if ( main::INFOLOG && $synclog->is_info ) {
					$synclog->info(sprintf("%s resync: pauseFor %dms", $player->id(), $delta * 1000));
				}
				$player->pauseForInterval($delta);
				$self->{'nextCheckSyncTime'} += $delta;
			}
		}
	}	
}

sub _Stop {					# stop -> Stopped, Idle
	my ($self, $event, $params, $suppressNotifications) = @_;
	
	# bug 10458 - try to avoding unnecessary notifications
	$suppressNotifications = 1 unless ( $self->isPlaying() || $self->isPaused() );
	
	if ( !$suppressNotifications && $self->playingSong() && ( $self->isPlaying(1) || $self->isPaused() ) ) {
		my $song = $self->playingSong();
		my $handler = $song->currentTrackHandler();
		if ($handler->can('onStop')) {
			$handler->onStop($song);
		}
	}
	
	foreach my $player (@{$self->{'players'}})	{
		_stopClient($player);
	}
	
	my $queue = $self->{'songqueue'};
	while (scalar @$queue > 1) {shift @$queue;}
	
	$queue->[0]->setStatus(Slim::Player::Song::STATUS_FINISHED) if scalar @$queue;
	
	if (main::INFOLOG && $log->is_info && scalar @$queue) {
		$log->info("Song queue is now " . join(',', map { $_->index() } @$queue));
	}
	
	if ($self->{'songStreamController'}) {
		$self->{'songStreamController'}->close();
		$self->{'songStreamController'} = undef;
	}
	
	_setPlayingState($self, STOPPED);
	_setStreamingState($self, IDLE);
	_notifyStopped($self, $suppressNotifications);
}

sub _stopClient {
	my ($client) = @_;
	$client->stop;
	@{$client->chunks} = ();
	$client->closeStream();
}

sub _getNextTrack {			# getNextTrack -> TrackWait
	my ($self, $params, $ifMoreTracks) = @_;
	
	if ($self->{'consecutiveErrors'} > Slim::Player::Playlist::count(master($self)))  {
		$log->warn("Giving up because of too many consecutive errors: " . $self->{'consecutiveErrors'});
		return;
	}
		
	my $index = $params->{'index'};
	my $song  = $params->{'song'};

	my $id = ++$self->{'nextTrackCallbackId'};
	$self->{'nextTrack'} = undef;
	
	if (!$song) {
		# If we have an existing playlist song then we ask it for the next song.
		if (!defined($index) && ($song = $self->streamingSong()) && $song->isPlaylist()) {
			$song = $song->clonePlaylistSong();	# returns undef at end of playlist		
		} else {
			$song = undef;
		}
	}
	
	if (!$song) {
		# Otherwise, we use the repeat mode to decide which playlist entry to ask for.
		
		unless (defined($index)) {
			my $oldIndex = $params->{'errorSong'}
				? $params->{'errorSong'}->index()
				: $params->{'errorIndex'};
			$index = nextsong($self, $oldIndex);
		}
			
		if (!defined($index)) {
			if ($ifMoreTracks) {
				return; # got to end of playlist & no repeat & no force play
			} else {
				$index = 0;			
			}
		}
			
		my $seekdata = $params->{'seekdata'};
		
		$song = Slim::Player::Song->new($self, $index, $seekdata);
		
		if (!$song) {
			_setStreamingState($self, TRACKWAIT);
			_nextTrackError($self, $id, $index);
			return;
		}
	}
	
	_setStreamingState($self, TRACKWAIT);
	
	# Bug 10841: Put the song on the queue now even if it might get removed again later
	# so that player displays can be correct while scanning a remote track
	my $queue = $self->{'songqueue'};
	unshift @$queue, $song unless scalar @$queue && $queue->[0] == $song;
	while (scalar @$queue && 
		   ($queue->[-1]->status() == Slim::Player::Song::STATUS_FAILED || 
			$queue->[-1]->status() == Slim::Player::Song::STATUS_FINISHED)
		  )
	{
		pop @$queue;
	}
	
	_showTrackwaitStatus($self, $song);

	$song->getNextSong (
		sub {	# success
			_nextTrackReady($self, $id, $song);
		},
		sub {	# fail
			_nextTrackError($self, $id, $song, @_);
		}
	);
	
}

sub _showTrackwaitStatus {
	my ($self, $song) = @_;
	
	# Show getting-track-info message if still in TRACKWAIT & STOPPED
	if ($self->{'playingState'} == STOPPED && $self->{'streamingState'} == TRACKWAIT) {

		my $handler = $song->currentTrackHandler();
		my $remoteMeta = $handler->can('getMetadataFor')
			? $handler->getMetadataFor($self->master(), $song->currentTrack()->url)
			: {};
		my $icon = $song->icon();
		my $message;

		if (!$song->isRemote) {
			$message = 'NOW_PLAYING';
			$remoteMeta = undef;
		} else {
			$message = $song->isPlaylist() ? 'GETTING_TRACK_DETAILS' : 'GETTING_STREAM_INFO';
		}
		
		_playersMessage($self, $song->currentTrack->url, $remoteMeta , $message, $icon, 0, 30);
	}
}

sub _nextTrackReady {
	my ($self, $id, $song, $params) = @_;
	
	if ($self->{'nextTrackCallbackId'} != $id) {
		main::INFOLOG && $log->info($self->{'masterId'} . ": discarding unexpected nextTrackCallbackId $id, expected " . 
			$self->{'nextTrackCallbackId'});
		$song->setStatus(Slim::Player::Song::STATUS_FINISHED) if (blessed $song);
		return;
	}

	$self->{'nextTrack'} = $song;
	main::INFOLOG && $log->info($self->{'masterId'} . ": nextTrack will be index ". $song->index());
	
	_eventAction($self, 'NextTrackReady', $params);
}

sub _nextTrackError {
	my ($self, $id, $songOrIndex, @error) = @_;

	if ($self->{'nextTrackCallbackId'} != $id) {return;}

	my ($song, $index);
	if (blessed $songOrIndex) {
		$song = $songOrIndex;
		$song->setStatus(Slim::Player::Song::STATUS_FAILED);
	} else {
		$index = $songOrIndex;
	}
	
	_errorOpening($self, $song ? $song->currentTrack()->url : undef, @error);
		
	_eventAction($self, 'NextTrackError', {error => \@error, errorSong => $song, errorIndex => $index});
}

sub _errorOpening {
	my ($self, $songUrl, $error, $url) = @_;
	
	$self->{'consecutiveErrors'}++;
	
	$error ||= 'PROBLEM_OPENING';
	$url   ||= $songUrl;

	_playersMessage($self, $url, {}, $error, undef, 1, 5, 'isError');
}

sub _playersMessage {
	my ($self, $url, $remoteMeta, $message, $icon, $block, $duration, $isError) = @_;
	
	$block    = 0  unless defined $block;
	$duration = 10 unless defined $duration;

	my $master = $self->master();
	
	# Check with the protocol handler to see if it wants to suppress certain messages
	if ( my $song = $self->streamingSong() || $self->playingSong() ) {
		my $handler = $song->currentTrackHandler();
		if ( $handler->can('suppressPlayersMessage') ) {
			return if $handler->suppressPlayersMessage($master, $song, $message);
		}
	}	

	my $line1 = (uc($message) eq $message) ? $master->string($message) : $message;
	
	main::INFOLOG && $log->info("$line1: $url");
	
	my $iconType = $icon && Slim::Music::Info::isRemoteURL($icon) ? 'icon' : 'icon-id';
	$icon ||= 0;

	# don't pass remoteMeta if it does not contain a title so getCurrentTitle can extract from db
	if ($remoteMeta && ref $remoteMeta eq 'HASH' && !$remoteMeta->{'title'}) {
		$remoteMeta = undef;
	}

	foreach my $client (@{$self->{'players'}}) {

		my ($lines, $overlay);

		my $line2 = Slim::Music::Info::getCurrentTitle($client, $url, 0, $remoteMeta) || $url;

		# use full now playing display if NOW_PLAYING message to get overlay
		if ($message eq 'NOW_PLAYING' && $client->can('currentSongLines')) {
			my $songLines = $client->currentSongLines();
			$lines   = $songLines->{'line'};
			$overlay = $songLines->{'overlay'};
		} else {
			$lines = [ $line1, $line2 ];
		}

		my $screen = Slim::Buttons::Common::msgOnScreen2($client) ? 'screen2' : 'screen1';
	
		# Show an error message
		$client->showBriefly( {
			$screen => { line => $lines, overlay => $overlay },
			jive => { 
				type => ($isError ? 'popupplay' : 'song'), 
				text => [ $line1, $line2 ], 
				$iconType => Slim::Web::ImageProxy::proxiedImage($icon), 
				duration => $duration * 1000
			},
		}, {
			scroll    => 1,
			firstline => 1,
			block     => $block,
			duration  => $duration,
		} );
	}
}

# nextsong is for figuring out what the next song will be.
sub nextsong {
	my ($self, $currsong) = @_;

	my $streamingSong = streamingSong($self);
	
	$currsong = $streamingSong ? $streamingSong->index() : 0 unless defined $currsong;
	
	my $client = master($self);
	my $playlistCount = Slim::Player::Playlist::count($client);

	if (!$playlistCount) {return undef;}
	
	my $repeat = Slim::Player::Playlist::repeat($client);
	
	if ($self->{'consecutiveErrors'} >= 2) {
		if ($playlistCount == 1) {
			$log->warn("Giving up because of too many consecutive errors: " . $self->{'consecutiveErrors'});
			return undef;
		} elsif ($repeat == 1) {
			$repeat = 2;	# skip this track anyway after two errors
		}
	}

	if ( $repeat == 1 ) {
		return $currsong;
	}

	# Allow one full cycle of the playlist + 1 track
	if ($self->{'consecutiveErrors'} > $playlistCount) {
		$log->warn("Giving up because of too many consecutive errors: " . $self->{'consecutiveErrors'});
		return undef;
	}
	
	my $nextsong = $currsong + 1;

	if ($nextsong >= $playlistCount) {
		# play the next song and start over if necessary
		if (Slim::Player::Playlist::shuffle($client) && 
			$repeat == 2 &&
			$prefs->get('reshuffleOnRepeat')) {
			
			Slim::Player::Playlist::reshuffle($client, 1);
			$client->currentPlaylistUpdateTime(Time::HiRes::time()); # bug 17643
		}
		$nextsong = 0;
	}
		
	main::INFOLOG && $log->info("The next song is number $nextsong, was $currsong");
	
	if (!$repeat && $nextsong == 0) {$nextsong = undef;}

	return $nextsong;
}

# FIXME - this algorithm is not safe enough. 
# (a) It may be that the Track object does not have a duration available for fixed-length stream
# better checks in place now represented by Song::isLive;
# (b) It may be that the duration is only a guess and not good enough for resuming.
#
# If we are playing a remote stream and it ends prematurely, either because it is radio
# (no specific duration) or we have played less than expected, then try to restart.
# We have to have played at least 10 seconds and there must be at least 10 seconds more expected
# in order to try to restart.
#
sub _RetryOrNext {		# -> Idle; IF [shouldretry && canretry] THEN continue
						#			ELSIF [moreTracks] AND [roomInQueue] THEN getNextTrack -> TrackWait ENDIF
	my ($self, $event, $params) = @_;
	_setStreamingState($self, IDLE);
	
	my $song        = streamingSong($self);
	my $elapsed     = playingSongElapsed($self);
	my $stillToPlay = master($self)->outputBufferFullness() / (44100 * 8);
	
	if ($song == playingSong($self)
		&& $song->isRemote()
		&& $elapsed > 10)				# have we managed to play at least 10s?
	{
		if (!$song->duration() && $song->isLive()) {	# unknown duration => assume radio
			main::INFOLOG && $log->is_info && $log->info('Attempting to re-stream ', $song->currentTrack()->url, ' after time ', $elapsed);
			$song->retryData({ count => 0, start => Time::HiRes::time()});
			_Stream($self, $event, {song => $song});
			return;
		}
	}

	# see comment on _NextIfMore
	if (scalar @{$self->{'songqueue'}} < 2) {
		_getNextTrack($self, $params, 1);
	} else {
		$log->info("streaming track not started yet, will wait until then to try next track");
	}
}

sub _Continue {
	my ($self, $event, $params) = @_;
	my $song          = $params->{'song'};
	my $bytesReceived = $params->{'bytesReceived'};
	
	my $seekdata;
	
	if ($bytesReceived) {
		$seekdata = $song->getSeekDataByPosition($bytesReceived);
	}	
	
	if ($seekdata && $seekdata->{'streamComplete'}) {
		main::INFOLOG && $log->is_info && $log->info("stream already complete at offset $bytesReceived");
		_Streamout($self);
	} elsif ($seekdata && $bytesReceived) {
		main::INFOLOG && $log->is_info && $log->info("Restarting stream at offset $bytesReceived");
		_Stream($self, $event, {song => $song, seekdata => $seekdata, reconnect => 1});
		if ($song == playingSong($self)) {
			$song->setStatus(Slim::Player::Song::STATUS_PLAYING);
		}
	} else {
		# This handles resuming after reboot with the caveat that if connection has been lost (no reboot) 
		# while playing and before reception of next song's 1st byte, we'll resume the current song
		main::INFOLOG && $log->is_info && $log->info("Restarting playback at time offset: ". $self->playingSongElapsed());
		_JumpToTime($self, $event, {newtime => $self->playingSongElapsed(), restartIfNoSeek => 1});
	}
}

sub _StopGetNext {			# stop, getNextTrack -> Stopped, TrackWait
	my ($self, $event, $params) = @_;
	_Stop(@_);
	_getNextTrack($self, $params);	
}

sub _Skip {
	my ($self, $event, $params) = @_;
	
	my $currentSong = $self->streamingSong();
	my $handler     = $currentSong->currentTrackHandler();
	my $url         = $currentSong->currentTrack()->url;
	
	if ($handler->can('canDoAction') && !$handler->canDoAction($self->master(), $url, 'stop')) {
		main::INFOLOG && $log->info("Skip for $url disallowed by protocol handler");
		return;
	}
	
	_StopGetNext(@_);
}

sub _FlushGetNext {			# flush -> Idle; IF [moreTracks] THEN getNextTrack -> TrackWait ENDIF
	my ($self, $event, $params) = @_;
	
	# flush means that we get rid of the streaming song
	shift @{$self->{'songqueue'}};

	foreach my $player (@{$self->{'players'}})	{
		$player->flush();
	}
	_setStreamingState($self, IDLE);
	_getNextTrack($self, $params, 1);
}

sub _NextIfMore {			# -> Idle; IF [moreTracks] AND [roomInQueue] THEN getNextTrack -> TrackWait ENDIF
	my ($self, $event, $params) = @_;
	_setStreamingState($self, IDLE);
	# if we already have a playing and a streaming track, then wait until the streaming 
	# one starts to play before getting the next one. That happens when player's buffer 
	# is much larger than track. 
	if (scalar @{$self->{'songqueue'}} < 2) {
		_getNextTrack($self, $params, 1);
	} else {
		$log->info("streaming track not started yet, will wait until then to try next track");
	}
	_getNextTrack($self, $params, 1);
}

# This action is only called for StreamingFailed; buffering or wait-to-sync
sub _StopNextIfMore {		# -> Stopped, Idle; IF [moreTracks] THEN getNextTrack -> TrackWait ENDIF
	my ($self, $event, $params) = @_;
	
	# bug 10165: need to force stop in case the failure that got use here did not stop all active players
	_Stop(@_);
	
	return if _willRetry($self);
	
	_getNextTrack($self, $params, 1);
}

# This action is only called for StreamingFailed, PLAYING
sub _SyncStopNext {		# -> [synced]Stopped, Idle; IF [moreTracks] THEN getNextTrack -> TrackWait ENDIF
	my ($self, $event, $params) = @_;
	
	# bug 10165: need to force stop in case the failure that got use here did not stop all active players
	if ($self->activePlayers() > 1) {
		_Stop(@_);
	} elsif ($params->{'errorDisconnect'}) {
		# we are already playing, treat like EoS & give retry a chance
		_setStreamingState($self, STREAMOUT);
		my $song = streamingSong($self);
		if ($song && !$song->retryData()) {
			return;
		}
	} else {
		_setStreamingState($self, IDLE);
	}

	return if _willRetry($self);

	_getNextTrack($self, $params, 1);
}

sub _JumpPaused {			# stream -> Idle, IF [!canSeek && restartIfNoSeek] THEN stop ENDIF
	my ($self, $event, $params) = @_;
	my $newtime = $params->{'newtime'};
	my $restartIfNoSeek = $params->{'restartIfNoSeek'};

	my $song = playingSong($self) || return;
	my $handler = $song->currentTrackHandler();

	# shortcut simple cases
	if (!$song->canSeek()) {
		if ($restartIfNoSeek) {
			_Stop($self, $event, $params);
		}
		# else ignore
		
		return;
	}

	if ($newtime !~ /^[\+\-]/ && $newtime == 0) {
		# User is trying to restart the current track
		my $url         = $song->currentTrack()->url;
		
		if ($handler->can("canDoAction") && !$handler->canDoAction($self->master(), $url, 'rew')) {
			main::DEBUGLOG && $log->debug("Restart for $url disallowed by protocol handler");
			return;
		}
		
	} elsif ($newtime =~ /^[\+\-]/) {
		my $oldtime = $self->{'resumeTime'};
		main::INFOLOG && $log->info("Relative jump $newtime from current time $oldtime");
		$newtime += $oldtime;
		
		if ($newtime < 0) {
			$newtime = 0;
		}
	}
	
	$self->{'resumeTime'} = $newtime;
	_pauseStreaming($self, $song);
}

sub _JumpToTime {			# IF [canSeek] THEN stop, stream -> Buffering, Streaming ENDIF
	my ($self, $event, $params) = @_;
	my $newtime = $params->{'newtime'};
	my $restartIfNoSeek = $params->{'restartIfNoSeek'};

	my $song = playingSong($self) || return;
	my $handler = $song->currentTrackHandler();

	if ($newtime !~ /^[\+\-]/ && $newtime == 0
		|| !$song->duration()
	) {
		# User is trying to restart the current track
		my $url         = $song->currentTrack()->url;
		
		if ($handler->can("canDoAction") && !$handler->canDoAction($self->master(), $url, 'rew')) {
			main::DEBUGLOG && $log->debug("Restart for $url disallowed by protocol handler");
			return;
		}
		
		_Stop($self, $event, $params, 'suppressNotification');
		$song->resetSeekdata();
		_Stream($self, $event, {song => $song});
		return;
	}

	if ($newtime =~ /^[\+\-]/) {
		my $oldtime = playingSongElapsed($self);
		main::INFOLOG && $log->info("Relative jump $newtime from current time $oldtime");
		$newtime += $oldtime;
		
		if ($newtime < 0) {
			$newtime = 0;
		}
	}
	
	if ($newtime > $song->duration()) {
		_Skip($self, $event);
		return;
	}
	
	my $seekdata;
	
	# get seek data from protocol handler.
	$seekdata = $song->getSeekData($newtime);
	
	return unless $seekdata || $restartIfNoSeek;

	_Stop($self, $event, $params, 'suppressNotification');
	
	_Stream($self, $event, {song => $song, seekdata => $seekdata});
}

sub _Stream {				# play -> Buffering, Streaming
	my ($self, $event, $params) = @_;

	# Get song and seekdata from params if present
	
	my $song;
	my $seekdata;
	my $reconnect;
	if ($params) {
		$seekdata  = $params->{'seekdata'};
		$song      = $params->{'song'};
		$reconnect = $params->{'reconnect'};
	}
	
	if ($song) {
		main::INFOLOG && $log->info($self->{'masterId'} . ": got song from params, song index ", $song->index());
	}
	
	unless ($song) {$song = $self->{'nextTrack'}};
	
	assert($song);
	if (!$song) {
		$log->error("No song to stream: try next");
		# TODO - show error
		_NextIfMore($self, $event);
		return;
	}

	# Allow protocol hander to update $song before streaming - used when song url contains params which may become stale 
	# updateOnStream will call either the success or fail callbacks, either immediately or later
	if ( $song->currentTrackHandler()->can('updateOnStream') && !$params->{'updateOnStreamCallback'}) {
		main::DEBUGLOG && $log->debug("Protocol Handler for ", $song->currentTrack()->url, " updateOnStream");
		
		my $id = ++$self->{'nextTrackCallbackId'};
		$self->{'nextTrack'} = undef;
		_setStreamingState($self, TRACKWAIT);
		
		$song->currentTrackHandler()->updateOnStream (
			$song,
			sub {	# success
				_nextTrackReady($self, $id, $song, {%$params, song => $song, updateOnStreamCallback => 1});
			},
			sub {	# fail
				_nextTrackError($self, $id, $song, @_);
			}
		);

		_showTrackwaitStatus($self, $song);
		
		return;
	}
	
	my $queue = $self->{'songqueue'};

	# bug 10510 - remove old songs from head of queue before adding new one
	# (Note: did not just test for STATUS_PLAYING so as not to hardwire max-queue-length == 2 too often)
	while (scalar @$queue && 
		   ($queue->[-1]->status() == Slim::Player::Song::STATUS_FAILED || 
			$queue->[-1]->status() == Slim::Player::Song::STATUS_FINISHED || 
			$queue->[-1]->status() == Slim::Player::Song::STATUS_READY)
		  ) {

		pop @$queue;
	}
	
	# bug 12653: also remove inappropriate songs from tail of queue
	while (scalar @$queue && 
		   ($queue->[0]->status() == Slim::Player::Song::STATUS_FAILED || 
			$queue->[0]->status() == Slim::Player::Song::STATUS_FINISHED || 
			$queue->[0]->status() == Slim::Player::Song::STATUS_READY)
		  ) {

		shift @$queue;
	}
	
	unshift @$queue, $song unless scalar @$queue && $queue->[0] == $song;

	# Bug 5103, the firmware can handle only 2 tracks at a time: one playing and one streaming,
	# and on very short tracks we may get multiple decoder underrun events during playback of a single
	# track. Trying to _Stream() more than 1 shoud never happen as it is blocked in the ReadyToStream
	# event (_NextIfMore and _RetryOrNext() methods)) and the _Stream() is delayed to Started event
	if (scalar @$queue > 2) {
		$log->error("we should not be here: aborting streaming because songqueue too long: ", scalar @$queue);
		shift @$queue while (scalar @$queue > 2);
		return;
	}
	
	if (main::INFOLOG && $log->is_info) {	
		$log->info("Song queue is now " . join(',', map { $_->index() } @$queue));
	}
	
	main::INFOLOG && $log->info($self->{masterId} . ": preparing to stream song index " .  $song->index());
	
	# Allow protocol handler to override playback and do something else,
	# used by Random Play, MusicIP, to provide URLs
	if ( $song->currentTrackHandler()->can('overridePlayback') ) {
		main::DEBUGLOG && $log->debug("Protocol Handler for " . $song->currentTrack()->url . " overriding playback");
		return $song->currentTrackHandler()->overridePlayback( $self->master(), $song->currentTrack()->url );
	}
	
	# close any existing source stream if necessary
	if ($self->{'songStreamController'}) {
		$self->{'songStreamController'}->close();
		$self->{'songStreamController'} = undef;
	}
	
	my ($songStreamController, @error) = $song->open($seekdata);
		
	if (!$songStreamController) {
		_errorOpening($self, $song->currentTrack()->url, @error);

		# Bug 3161: more-agressive retries
		return if _willRetry($self, $song);
		
		_NextIfMore($self, $event, {errorSong => $song});
		return;	
	}	

	Slim::Control::Request::notifyFromArray( $self->master(),
		[ 'playlist', 'open', $songStreamController->streamUrl() ] );

	my $paused = (scalar @{$self->{'players'}} > 1) && 
		($self->{'playingState'} == STOPPED || $self->{'playingState'} == BUFFERING);

	my $fadeIn = $self->{'fadeIn'} || 0;
	$paused ||= ($fadeIn > 0);
	
	# Bug 18165: master's volume might not be the right one to use
	my $masterVol;
	foreach my $player (@{$self->{'players'}}) {
		next unless $prefs->client($player)->get('syncVolume');
		$masterVol = abs($prefs->client($player)->get("volume") || 0);
		last;
	}	
	
	my $startedPlayers = 0;
	my $reportsTrackStart = 0;
		
	# bug 10438
	$self->resetFrameData();
	
	# fade-in has precedence over crossfade only player is stopped
	$self->{'fadeActive'} = $fadeIn < 1 && $self->{'playingState'} == STOPPED && $prefs->client($self->master)->get('fadeInDuration');
	
	foreach my $player (@{$self->{'players'}}) {
		if ($self->{'playingState'} == STOPPED) {
			# Bug 10310: Make sure volume is synced if necessary
			my $vol = ($prefs->client($player)->get('syncVolume'))
				? $masterVol
				: abs($prefs->client($player)->get("volume") || 0);
			$player->volume($vol);
			# can't fade_volume here as we might not be playing yet so ramp-up would be lost
			$player->volume(0,1) if $self->{'fadeActive'};
		}	
		
		my $myFadeIn = $fadeIn;
		if ($fadeIn > $player->maxTransitionDuration()) {
			$myFadeIn = 0;
		}
		
		main::INFOLOG && $log->info($player->id . ": stream");
		
		if ($song->currentTrackHandler()->can('onStream')) {
			$song->currentTrackHandler()->onStream($player, $song);
		}
		
		my %params = ( 
			'paused'      => $paused, 
			'format'      => $song->streamformat(), 
			'controller'  => $songStreamController,
			'url'         => $songStreamController->streamUrl(), 
			'reconnect'   => $reconnect,
			'replay_gain' => Slim::Player::ReplayGain->fetchGainMode($self->master(), $song),
			'seekdata'    => $seekdata,
			'fadeIn'      => $myFadeIn,
			# we never set the 'loop' parameter
		);

		$startedPlayers += $player->play( \%params );
		
		$reportsTrackStart ||= $player->reportsTrackStart();
	}	
	
	if ($startedPlayers != scalar @{$self->{'players'}}) {
		$log->warn(sprintf('%s: only %d of %d players started streaming',
			$self->{'masterId'}, $startedPlayers, scalar @{$self->{'players'}}));
		_Stop($self); 	# what else can we do?
		$self->{'consecutiveErrors'}++;
		_NextIfMore($self);
		return;
	}

	# Bug 15477: Delayed to here so that $player->play() has the opportunity to close any old stream 
	# before the new one becomes available
	$self->{'songStreamController'} = $songStreamController;

	if ( main::INFOLOG && $log->is_info ) {
		$log->info("Song queue is now " . join(',', map { $_->index() } @$queue));
	}

	Slim::Player::Playlist::refreshPlaylist($self->master());
	
	$self->{'nextTrack'} = undef;
	if ($self->{'playingState'} == STOPPED) {_setPlayingState( $self, BUFFERING );}
	_setStreamingState($self, STREAMING);
	
	if (!$reportsTrackStart) {
		_Playing($self);
	}
}

sub _PlayIfReady {		# -> Stopped; IF [trackReady] THEN play -> Buffering, Streaming ENDIF
	my ($self, $event, $params) = @_;
	
	_setPlayingState($self, STOPPED);

	if ( $self->{'nextTrack'} ) {
		_Stream(@_);
	}
	else {
		_notifyStopped($self);
	}
}

sub _PlayAndStream {		# -> PLAYING; IF [allReadyToStream] THEN play -> Streaming ENDIF
	_Playing(@_);
	_StreamIfReady(@_);		# Bug 5103
}

sub _PlayAndNext {			# -> PLAYING; IF [allReadyToStream] THEN play -> Streaming ENDIF
	# this happens because the streaming track was fully streamed before the playing one
	# was finished, so we waited for the streaming track to start playing before getting 
	# next one, but we must now get it. 
	_Playing(@_);
	main::INFOLOG && $log->info('now playing already fully streaming song => get next');
	_getNextTrack($_[0], undef, 1);
}

sub _StreamIfReady {		# IF [allReadyToStream] THEN play -> Streaming ENDIF
	my ($self, $event, $params) = @_;
	
	my $song = $self->{'nextTrack'};
	if (!$song) {return;}
	
	my $ready = 1;
	foreach my $player (@{$self->{'players'}})	{
		if (!$player->isReadyToStream( $song, $self->playingSong() )) {
			$ready = 0;
			last;
		}
	}
	
	_Stream(@_) unless (!$ready);
}

sub _Start {		# start -> Playing
	my ($self, $event, $params) = @_;
	
	if (!$self->{'rebuffering'}) {
		
		if ($self->{'fadeIn'}) {
			for (@{ $self->{'players'} }) {
				if ($self->{'fadeIn'} > $_->maxTransitionDuration()) {
					$_->fade_volume($self->{'fadeIn'});
				}
			}
		}
		$self->{'fadeIn'} = undef;

		if ( scalar @{ $self->{'players'} } > 1 ) {
			_syncStart($self);
		} else {
			$self->master()->resume();
		}

		_Playing(@_);
	} else {
		_Resume(@_);
	}
}

my @retryIntervals = (5, 10, 15, 30);
use constant RETRY_LIMIT          => 5 * 60;
use constant RETRY_LIMIT_PLAYLIST => 30;

# Bug 3161: more retries
sub _willRetry {
	my ($self, $song) = @_;
	
	$song ||= streamingSong($self);
	return 0 if !$song;
	
	my $retry = $song->retryData();
	if (!$retry) {
		$log->info('no retry data');
		return 0;
	}
	
	my $limit;
	my $next = nextsong($self);
	if (defined $next && $next != $song->index) {
		$limit = RETRY_LIMIT_PLAYLIST;
	} else {
		$limit = RETRY_LIMIT;
	}
	
	my $interval = $retryIntervals[$retry->{'count'} > $#retryIntervals ? -1 : $retry->{'count'}];
	my $retryTime = time() + $interval;

	if ($retry->{'start'} + $limit < $retryTime) {
		# too late, give up
		$song->retryData(undef);
		_errorOpening($self, $song->currentTrack()->url, 'RETRY_LIMIT_EXCEEDED');
		_Stop($self);
		$self->{'consecutiveErrors'} = 1;	# the failed retry counts as one error
		return 0;
	}
	
	$retry->{'count'} += 1;
	my $id = ++$self->{'nextTrackCallbackId'};
	$self->{'nextTrack'} = undef;
	_setStreamingState($self, TRACKWAIT);
	
	Slim::Utils::Timers::setTimer(
		$self,
		$retryTime,
		sub {
			$song->setStatus(Slim::Player::Song::STATUS_READY);
			$self->{'consecutiveErrors'} = 0;
			_nextTrackReady($self, $id, $song);
		},
		undef
	);
	
	_playersMessage($self, $song->currentTrack()->url, undef, 'RETRYING', undef, 0, $interval + 1);

	return 1;
}

sub _syncStart {
	my ($self) = @_;

	my $playerStartDelay = 0;    # ms

	my $player;
	
	foreach $player ( @{ $self->{'players'} } ) {
		my $delay;               # ms
		if ((
				$delay = $prefs->client($player)->get('startDelay') +
				$prefs->client($player)->get('playDelay')
			) > $playerStartDelay
		  )
		{
			$playerStartDelay = $delay;
		}
	}

	my $startAt =
	  Time::HiRes::time() +
	  ( $playerStartDelay + ( $prefs->get('syncStartDelay') || 200 ) ) / 1000;

	foreach $player ( @{ $self->{'players'} } ) {
		$player->startAt(
			$startAt - (
				$prefs->client($player)->get('startDelay') +
				  $prefs->client($player)->get('playDelay') ) / 1000
		);
	}
}

sub _StartIfReady {			# IF [allReadyToStart] THEN 
							#	IF [rebuffering] THEN resume ELSE start ENDIF 
							#	-> Playing
							# ENDIF
	my ($self, $event, $params) = @_;
		
	my $ready = 1;
	foreach my $player (@{$self->{'players'}})	{
		if (!$player->isBufferReady()) {
			$ready = 0;
			last;
		}
	}
	
	_Start(@_) unless (!$ready);
}

sub _StartStreamout {		# start -> Playing, Streamout
	my ($self, $event, $params) = @_;
	_setStreamingState($self, STREAMOUT);
	_Start(@_);
}

sub _WaitToSync {			# IF [allReadyToStart] THEN start -> Playing ELSE -> WaitToSync ENDIF
	my ($self, $event, $params) = @_;
	_setPlayingState($self, WAITING_TO_SYNC);
	
	# Could have become the only player in the sync-group since we started (unlikely, but ...)
	# Let's just see if we can move on straight away
	return _StartIfReady(@_);
}


sub _Pause {				# pause -> Paused
	my ($self, $event, $params) = @_;

	$self->{'resumeTime'} = playingSongElapsed($self);
	_setPlayingState($self, PAUSED);
	
	# since we can't count on the accuracy of the fade
	# timers, we fade-out them all, but the master calls
	# back to pause everybody
	foreach my $player (@{$self->{'players'}})	{
		if (_isMaster($self, $player)) {
			$player->fade_volume(
				-(FADEVOLUME),
				sub {
					# Actually pause the players when the fade-out is complete.
					
					# Bug 9752: check that we are still paused
					return if !$self->isPaused();
					
					# Reevaluate player-set here in case sync-group membership
					# changed during fade-out, although this will fail if we
					# have a new master.
					foreach my $player (@{$self->{'players'}})	{
						$player->pause();
					}
				}
			);
		} else {
			$player->fade_volume(-(FADEVOLUME));
		}
		
	}
	
	Slim::Control::Request::notifyFromArray( $self->master(), ['playlist', 'pause', 1] );
}

# Bug 8861
# Force a start in case a track was too short to trigger autostart
# This code should not be necessary if bug 9125 is fixed in firmware
sub _AutoStart {			# [streaming-track-not-playing] start -> Streamout
	my ($self, $event, $params) = @_;
	
	_setStreamingState($self, STREAMOUT);
	
	if ($self->streamingSong && $self->streamingSong->status() != Slim::Player::Song::STATUS_PLAYING) {
		main::INFOLOG && $log->info('autostart possibly short track');
		foreach my $player (@{$self->{'players'}})	{
			$player->resume();
		}
		# we still rely on a track-start-event from the player
	}
}

sub _JumpOrResume {			# resume -> Streaming, Playing
	my ($self, $event, $params) = @_;

	if (defined $self->{'resumeTime'}) {
		$self->{'fadeIn'} = FADEVOLUME;
		
		_JumpToTime($self, $event, {newtime => $self->{'resumeTime'}, restartIfNoSeek => 1});

		$self->{'resumeTime'} = undef;
		$self->{'fadeIn'} = undef;
	} else {
		_Resume(@_);
	}
}

sub _Resume {				# resume -> Playing
	my ($self, $event, $params) = @_;
	
	my $song        = playingSong($self);
	my $pausedAt    = ($self->{'resumeTime'} || 0) - ($song ? ($song->startOffset() || 0) : 0);
	my $startAtBase = Time::HiRes::time() + ($prefs->get('syncStartDelay') || 200) / 1000;
	
	$self->{fadeIn} ||= $prefs->client($self->master)->get('fadeInDuration');
																							
	_setPlayingState($self, PLAYING);
	foreach my $player (@{$self->{'players'}})	{
		# set volume to 0 to make sure fade works properly
		$player->volume(0,1);
		if (@{$self->{'players'}} > 1 ) {
			my ($playPoint, $delay);
			my $startAt = $startAtBase;
			if ( ($playPoint = $player->playPoint)
				&& defined $playPoint->[2]
				&& ($delay = ($playPoint->[2] - $pausedAt)) >= 0)
			{
				$startAt += $delay;
			}
			main::INFOLOG && $synclog->is_info && $synclog->info($player->id, ": startAt=$startAt");
			$player->resume($startAt);
		} else {
			$player->resume();
		}
		$player->fade_volume($self->{'fadeIn'} ? $self->{'fadeIn'} : FADEVOLUME);
	}
	
	$self->{'nextCheckSyncTime'} = $startAtBase + 2;

	Slim::Control::Request::notifyFromArray( $self->master(), ['playlist', 'pause', 0] );
	
	$self->{'resumeTime'} = undef;
	$self->{'fadeIn'} = undef;
}


sub _Rebuffer {				# pause(noFadeOut) -> Buffering(rebuffering)
	my ($self, $event, $params) = @_;
	
	_setPlayingState($self, BUFFERING);
	$self->{'rebuffering'} = 1;
	foreach my $player (@{$self->{'players'}})	{
		$player->pause();
		$player->rebuffer();
	}
	
	# Bug 17877: need to save resumeTime here so that synchronized-resume works after the rebuffer
	$self->{'resumeTime'} = playingSongElapsed($self);
}

####################################################################
# Incoming queries - <<interface>> PlayStatus

sub isPlaying {
	my ($self, $really) = @_;
	return $really ? $self->{'playingState'} == PLAYING : (!isStopped($self) && !isPaused($self)); 
}

sub isStopped {
	return $_[0]->{'playingState'} == STOPPED && $_[0]->{'streamingState'} == IDLE;
}

sub isStreaming {
	return $_[0]->{'streamingState'} == STREAMING;
}

sub isStreamout {
	return $_[0]->{'streamingState'} == STREAMOUT;
}

sub isPaused {
	return $_[0]->{'playingState'} == PAUSED;
}

# returns 1 for normal buffering, 2 for rebuffering
sub buffering {
	return ($_[0]->{'playingState'} == BUFFERING || $_[0]->{'playingState'} == WAITING_TO_SYNC)
		? ($_[0]->{'rebuffering'} ? 2 : 1)
		: 0;
}

sub isWaitingToSync {
	return $_[0]->{'playingState'} == WAITING_TO_SYNC;
}

sub isRetrying {
	my $self = shift;
	my $song = streamingSong($self);
	return $song && $song->retryData();
}

sub playingSongDuration {
	my $song = playingSong($_[0]) || return;
	return $song->duration();
}

sub playingSongElapsed {
	my $self = shift;
	
	if ($self->isPaused()) {
		return $self->{'resumeTime'};
	}
	
	my $client      = master($self);
	my $songtime    = $client->songElapsedSeconds();
	my $song     	= playingSong($self) || return 0;
	my $startStream = $song->startOffset() || 0;
	my $duration	= $song->duration();
	
	if (defined($songtime)) {
		$songtime = $startStream + $songtime;
		
		# limit check
		if ($songtime < 0) {
			$songtime = 0;
		} elsif ($duration && $songtime > $duration) {
			$songtime = $duration;
		}
		
		return $songtime;
	}
	
	#######
	# All the remaining code is to deal with players which do not report songElapsedSeconds,
	# specifically SliMP3s and SB1s; maybe also web clients?

	my $byterate	  	= ($song->streambitrate() || 0)/8 || ($duration ? ($song->totalbytes() / $duration) : 0);
	my $bytesReceived 	= ($client->bytesReceived() || 0) - $client->bytesReceivedOffset();
	my $fullness	  	= $client->bufferFullness() || 0;
		
	# If $fullness > $bytesReceived, then we are playing out previous song
	my $bytesPlayed = $bytesReceived - $fullness;
	
	# If negative, then we are playing out previous song
	if ($bytesPlayed < 0) {
		if ($duration && $byterate) {
			$songtime = $duration + $bytesPlayed / $byterate;
		} else {
			# not likley to happen as it would mean that we are streaming one song after another
			# without knowing the duration and bitrate of the previous song
			$songtime = 0;
		}
	} else {
		
		$songtime = $byterate ? ($bytesPlayed / $byterate + $startStream) : 0;
	}
	
	# This assumes that remote streaming is real-time - not always true but, for the common
	# cases when it is, it will be better than nothing.
	if ($songtime == 0) {

		my $startTime = $client->remoteStreamStartTime();
		
		$songtime = ($startTime ? Time::HiRes::time() - $startTime : 0);
	}

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug("songtime=$songtime from byterate=$byterate, duration=$duration, bytesReceived=$bytesReceived, fullness=$fullness, startStream=$startStream");
	}

	# limit check
	if ($songtime < 0) {
		$songtime = 0;
	} elsif ($duration && $songtime > $duration) {
		$songtime = $duration;
	}

	return $songtime;
}

sub master {
	return Slim::Player::Client::getClient($_[0]->{'masterId'});
}

sub songStreamController {
	return $_[0]->{'songStreamController'};
}

sub setSongStreamController {
	$_[0]->{'songStreamController'} = $_[1];
}

sub playingSong {
	return $_[0]->{'songqueue'}->[-1] if scalar $_[0]->{'songqueue'};
}

sub streamingSong {
	return $_[0]->{'songqueue'}->[0] if scalar $_[0]->{'songqueue'};
}

sub songqueue {
	return $_[0]->{'songqueue'};
}

sub resetSongqueue {
	my ($self, $index) = @_;

	my $queue = $self->{'songqueue'};

	$#{$queue} = -1;

	if (defined($index)) {
		my $song  = Slim::Player::Song->new($self, $index);
		push(@{$queue}, $song) unless (!$song);
	}

	if ( main::INFOLOG && $log->is_info ) {
		$log->info("Song queue is now " . join(',', map { $_->index() } @$queue));
	}
		
	return $index || 0;	
}

sub currentSongForUrl {
	my ($self, $url) = @_;
	
	my $song;
	for $song (reverse @{$self->songqueue()}) {
		if ($song->currentTrack()->url eq $url || $song->track()->url eq $url) {
			return $song;
		}
	}
}

sub streamingSongForUrl {
	my ($self, $url) = @_;
	
	my $song;
	for $song (@{$self->songqueue()}) {
		if ($song->currentTrack()->url eq $url || $song->track()->url eq $url) {
			return $song;
		}
	}
}

sub onlyActivePlayer {
	my ($self, $client) = @_;
	
	my @activePlayers = $self->activePlayers();
	
	return (scalar @activePlayers == 1 && $client == $activePlayers[0]);	
}

sub frameData {
	my $self = shift;
	if (@_) {
		$self->{'frameData'} = shift;
	}
	return $self->{'frameData'};
}

sub initialStreamBuffer {
	my $self = shift;
	if (@_) {
		$self->{'initialStreamBuffer'} = shift;
	}
	return $self->{'initialStreamBuffer'};
}

sub resetFrameData {
	my $self = shift;

	$self->initialStreamBuffer(undef);
	$self->frameData(undef);
}


####################################################################
# Incoming events - miscellaneous

sub localEndOfStream {
	
	closeStream($_[0]);

	_eventAction($_[0], 'LocalEndOfStream');
}

sub sync {
	my ($self, $player, $noRestart) = @_;

	if ($player->controller() == $self) {
		main::INFOLOG && $synclog->info($self->{'masterId'} . " sync-group already contains: " . $player->id());
		if ($player->power && $player->connected) {
			$self->playerActive($player);
		}
		return;
	}
	
	my $other = $player->controller();
	if (@{$other->{'allPlayers'}} > 1) {
		$other->unsync($player);	# will also stop it, if necessary
		$noRestart = 0;	
	} elsif (!$noRestart && !$other->isStopped()) {
		_stopClient($player);
	}

	main::INFOLOG && $synclog->info($self->{'masterId'} . " adding to syncGroup: " . $player->id());
	
	assert (@{$player->controller()->{'allPlayers'}} == 1); # can only add un-synced player
	
	foreach (@{$self->{'allPlayers'}}) {
		if ($_ == $player) {
			$synclog->error($player->id . " already in this syncgroup but has different controller");
			return;
		}
	}
	
	# setup and save syncgroup
	my $id = $self->{'syncgroupid'};
	if (!$id) {
		$id = $prefs->client(master($self))->get('syncgroupid') || int(rand 999999999);
		$self->{'syncgroupid'} = $id;
		$prefs->client(master($self))->set('syncgroupid', $id);
	}
	$prefs->client($player)->set('syncgroupid', $id);

	# make it one of ours
	$player->controller($self);	# discards old controller -> safe, as not synced
	push @{$self->{'allPlayers'}}, $player;
	
	if (@{$self->{'allPlayers'}} == 1) {
		_newMaster($self);
	}
	
	# TODO - reevaluate master in general

	if ($player->power && $player->connected) {
		push @{$self->{'players'}}, $player;
		
		if (!$self->master->power()) {
			_newMaster($self);
		}
		
		if (isPaused($self)) {
			_pauseStreaming($self, playingSong($self));
		} elsif (!$noRestart && !isStopped($self)) {
			_JumpToTime($self, undef, {newtime => playingSongElapsed($self), restartIfNoSeek => 1});
		}
	} else {
		if (main::INFOLOG && $synclog->is_info) {
			$synclog->info(sprintf("New player inactive: power=%d, connected=%d", $player->power, $player->connected));
		}
	}
	
	$player->currentPlaylistUpdateTime(Time::HiRes::time());
	Slim::Control::Request::notifyFromArray($self->master(), ['playlist', 'sync']);
	
	if (main::INFOLOG && $synclog->is_info) {
		$synclog->info($self->{'masterId'} . " sync group now has: " . join(',', map { $_->id } @{$self->{'allPlayers'}}));
		$synclog->info($self->{'masterId'} . " active players are: " . join(',', map { $_->id } @{$self->{'players'}}));
	}
}

sub unsync {
	my ($self, $player, $keepSyncGroupId) = @_;
	
	assert ($player->controller() == $self);
	
	if (@{$self->{'allPlayers'}} < 2) {return;}
	
	main::INFOLOG && $synclog->info($self->{'masterId'} . " unsync " . $player->id());
		
	# remove player from the lists
	my $i = 0;
	foreach my $c (@{$self->{'players'}}) {
		if ($c == $player) {
		
			if (!isStopped($self)) {
				if (@{$self->{'players'}} == 1) {
					# If player is our last active player, then stop
					_Stop($self);
				} else {
					# Otherwise just stop the one we are unsyncing
					_stopClient($player);
				}
			} else {
				# Force stop anyway in case it was paused, off
				_stopClient($player);
			}
				
			splice @{$self->{'players'}}, $i, 1;
			last;
		}
		$i++;
	}

	$i = 0;
	foreach my $c (@{$self->{'allPlayers'}}) {
		if ($c == $player) {
			splice @{$self->{'allPlayers'}}, $i, 1;
			last;
		}
		$i++;
	}
	
	# Choose new master
	if (@{$self->{'allPlayers'}}) {
		_newMaster($self);
	}
	
	# Every player must have a controller
	$player->controller(Slim::Player::StreamingController->new($player));
	Slim::Player::Playlist::copyPlaylist($player, $self->master());
	
	$prefs->client($player)->remove('syncgroupid') unless $keepSyncGroupId;

	$player->currentPlaylistUpdateTime(Time::HiRes::time());

	Slim::Control::Request::notifyFromArray($player, ['playlist', 'stop']);	
	Slim::Control::Request::notifyFromArray($player, ['playlist', 'sync']);
	
	Slim::Control::Request::notifyFromArray($self->master(), ['playlist', 'sync']);
	
	if (main::INFOLOG && $synclog->is_info) {
		$synclog->info($self->{'masterId'} . " sync group now has: " . join(',', map { $_->id } @{$self->{'allPlayers'}}));
		$synclog->info($self->{'masterId'} . " active players are: " . join(',', map { $_->id } @{$self->{'players'}}));
	}
}

sub playerActive {
	my ($self, $player) = @_;
	
	foreach my $c (@{$self->{'players'}}) {
		if ($c == $player) {
			main::INFOLOG && $log->info($self->{'masterId'} . " player already active: " . $player->id());
			return;
		}
	}

	# make sure that the streaming is disconnected, so that any unpause will be by _JumpToTime
	_pauseStreaming($self, $self->playingSong()) if $self->isPaused() && $self->playingSong();
	
	# It is possible for us to be paused with all the "active" players actually (logically) powered off.
	# bug 10406: In fact, the last active player in a group to be powered off may anyway be left active and off.
	# In this case it could be that another player in the sync group, which is not part of the off-active
	# set, is made active. So we first need to test for this situation
	if (!master($self)->power()) {
		# This means that the existing 'active' players were paused-on-powerOff (dealt with above),
		# or the last player left active. This is probably an invalid state.
		# We need to stop them and make them inactive - otherwise they will auto-magically power-on.
		if (!$self->isStopped() && !$self->isPaused()) {
			_Stop($self) ;
		}
		
		$self->{'players'} = [];       
	}
	
	push @{$self->{'players'}}, $player;
	
	# Choose new master
	_newMaster($self);
	
	if (main::INFOLOG && $synclog->is_info) {
		$synclog->info($self->{'masterId'} . " sync group now has: " . join(',', map { $_->id } @{$self->{'allPlayers'}}));
		$synclog->info($self->{'masterId'} . " active players are: " . join(',', map { $_->id } @{$self->{'players'}}));
	}
	
	if (isPlaying($self)) {
		main::INFOLOG && $synclog->info($self->{'masterId'} . " restart play");
		_JumpToTime($self, undef, {newtime => playingSongElapsed($self), restartIfNoSeek => 1});
	}
}

sub playerInactive {
	my ($self, $player) = @_;
	
	# remove player from the list
	my $i = 0;
	foreach my $c (@{$self->{'players'}}) {
		if ($c == $player) {

			if (!isStopped($self)) {
				if (@{$self->{'players'}} == 1) {
					# If player is our last active player, then stop
					_Stop($self);
				} else {
					# Otherwise just stop the one we are unsyncing
					_stopClient($player);
					# We do not send a 'playlist stop' notification so as not to notify the 
					# whole sync-group
				}
			}
	
			splice @{$self->{'players'}}, $i, 1;
			last;
		}
		$i++;
	}
	
	# Choose new master
	# TODO - in all cases
	if ($player->id() eq $self->{'masterId'} && @{$self->{'players'}}) {
		_newMaster($self);
	}

	if (main::INFOLOG && $synclog->is_info) {
		$synclog->info($self->{'masterId'} . " sync group now has: " . join(',', map { $_->id } @{$self->{'allPlayers'}}));
		$synclog->info($self->{'masterId'} . " active players are: " . join(',', map { $_->id } @{$self->{'players'}}));	
	}
}

sub playerReconnect {
	my ($self, $bytesReceived) = @_;
	main::INFOLOG && $log->info($self->{'masterId'});
	
	my $song = $self->streamingSong();
	
	if ($song) {
		_eventAction($self, 'ContinuePlay', {bytesReceived => $bytesReceived, song => $song});
	}
	
}

sub activePlayers {
	return @{$_[0]->{'players'}};
}

sub allPlayers {
	return @{$_[0]->{'allPlayers'}};
}

sub closeStream {
	$_[0]->{'songStreamController'}->close() if $_[0]->{'songStreamController'};
}

sub nextIfStreamed {
	my ($self) = @_;

	# this is called when we are adding/moving another track after last one
	# or moving it upper in the list. If it has been fully streamed and we 
	# are playing/buffering/waiting, then we need to grab next track. If we 
	# are paused then we'll restart the process later upon resume
	if ($self->{'streamingState'} == IDLE && 
		$self->{'playingState'} != STOPPED && 
		$self->{'playingState'} != PAUSED) {
		main::INFOLOG && $log->info("getting next track to re-launch streaming process");
		_getNextTrack($self, undef, 1);
	}
}	

####################################################################
# Incoming events - <<interface>> PlayControl

sub stop       {$log->info($_[0]->{'masterId'}); _eventAction($_[0], 'Stop');}

sub play       {
	main::INFOLOG && $log->info($_[0]->{'masterId'});
	$_[0]->{'consecutiveErrors'} = 0;
	$_[0]->{'fadeIn'} = $_[4] if ($_[4] && $_[4] > 0);
	_eventAction($_[0], 'Play', {index => $_[1], seekdata => $_[2]});
}

sub skip       {
	main::INFOLOG && $log->info($_[0]->{'masterId'});
	$_[0]->{'consecutiveErrors'} = 0;
	_eventAction($_[0], 'Skip');
}


sub pause      {
	my ($self) = @_;
	
	main::INFOLOG && $log->info($self->{'masterId'});
	
	# Some protocol handlers don't allow pausing of active streams.
	# We check if that's the case before continuing.
	my $song = playingSong($self) || {};
	my $handler = $song->currentTrackHandler();

	if ($handler && $handler->can("canDoAction") &&
		!$handler->canDoAction(master($self), $song->currentTrack()->url, 'pause'))
	{
		$log->warn("Protocol handler doesn't allow pausing. Let's try stopping.");
		stop(@_);
	}
		
	_eventAction($_[0], 'Pause');
}


sub resume     {
	$_[0]->{'fadeIn'} = $_[1] if ($_[1] && $_[1] > 0);
	main::INFOLOG && $log->info($_[0]->{'masterId'}, 'fadein=', ($_[1] ? $_[1] : 'undef'));
	_eventAction($_[0], 'Resume');
}

sub flush      {
	main::INFOLOG && $log->info($_[0]->{'masterId'});
	_eventAction($_[0], 'Flush');
}

sub jumpToTime {
	main::INFOLOG && $log->info($_[0]->{'masterId'});
	_eventAction($_[0], 'JumpToTime', {newtime => $_[1], restartIfNoSeek => $_[2]});
}


####################################################################
# Incoming events - <<interface>> PlayerNotificationHandler

sub playerStopped {
	my ($self, $client) = @_;
		
	main::INFOLOG && $log->info($client->id);

	# TODO - handler hook
	
	unless (_isMaster($self, $client)) {return;}
	
	my $queue = $self->{'songqueue'};
	
	if (@{$queue} > 1) {
		pop @{$queue};
	} else {
		my $song = playingSong($self);
		if ($song && $song->status() == Slim::Player::Song::STATUS_PLAYING) {
			$song->setStatus(Slim::Player::Song::STATUS_FINISHED);
		}
	}
	
	_eventAction($self, 'Stopped');
}

sub playerTrackStarted {
	my ($self, $client) = @_;

	main::INFOLOG && $log->info($client->id);

	unless (_isMaster($self, $client)) {return;}
	
	# Hack - we can still get track-started events after abandoning the previous track
	# Mostly these duplicates do no harm, but when synced they can really mess things up.
	# So if we are synced then the first track will be 'started' via unpause
	if (scalar @{$self->songqueue()} == 1 && scalar $self->activePlayers() > 1) {return;}

	_eventAction($self, 'Started');

	# sync the button mode periodic update to the track time
	Slim::Buttons::Common::syncPeriodicUpdates($client, Time::HiRes::time() + 0.1);
}

sub playerReadyToStream {
	my ($self, $client) = @_;

	main::INFOLOG && $log->info($client->id);

	if ($self->_isMaster($client)) {
		if ( my $song = $self->streamingSong() ) {
			my $handler = $song->currentTrackHandler();
			if ($handler->can('onPlayout')) {
				my $ret = $handler->onPlayout($song, $self);
				if ($ret && $ret eq 'return') { return; }
			}
		}
	}

	_eventAction($self, 'ReadyToStream');
}

sub playerOutputUnderrun {
	my ($self, $client) = @_;
	
	if ( main::INFOLOG && $log->is_info ) {
		my $decoder = $client->bufferFullness();
		my $output  = $client->outputBufferFullness() || 0;
		$log->info($client->id, ": decoder: $decoder / output: $output" );
	}

	_eventAction($self, 'OutputUnderrun');
}

sub playerStreamingFailed {
	my ($self, $client, @error) = @_;

	main::INFOLOG && $log->info($client->id);
	
	my $song = streamingSong($self);
	my $errorDisconnect;
	
	if ( $song ) {
		$song->setStatus(Slim::Player::Song::STATUS_FAILED);
	}
	
	# bug 10407: remove failed Song from song-queue unless only Song in queue.
	my $queue = $self->{'songqueue'};
	if (scalar(@$queue) > 1) {
		shift @$queue;
	}
	
	if (@error > 1 && $error[1] eq 'errorDisconnect') {
		$errorDisconnect = 1;
		splice @error, 1, 1;
	}

	if ( $song ) {
		_errorOpening($self, $song->currentTrack()->url, @error);
	}

	_eventAction($self, 'StreamingFailed', {errorDisconnect => $errorDisconnect});
}

sub playerBufferReady {
	my ($self, $client) = @_;

	main::INFOLOG && $log->info($client->id);

	_eventAction($self, 'BufferReady');
}

sub playerEndOfStream {
	my ($self, $client) = @_;

	main::INFOLOG && $log->info($client->id);

	# TODO - handler hook

	unless (_isMaster($self, $client)) {return;}

	_eventAction($self, 'EndOfStream');
}

sub playerDirectMetadata {
	my ($self, $client, $metadata, $timestamp) = @_;

	main::INFOLOG && $log->info($client->id);

	unless (_isMaster($self, $client)) {return;}

	my $song = _streamingSong($self);
	my $handler = $song->currentTrackHandler();
	if ($handler->can('directMetadata')) {
		$handler->directMetadata($song, $metadata);
		# TODO - schedule title update? 
	}
}

sub playerStatusHeartbeat {
	my ($self, $client) = @_;

	unless (_isMaster($self, $client)) {return;}

	_eventAction($self, 'StatusHeartbeat');
}

sub setState {
	my ($self, $state) = @_;
	
	my ($playing, $streaming) = split (/-/, $state);
	
	_setPlayingState( $self, $PlayingStateNameMap{ $playing } );
	_setStreamingState( $self, $StreamingStateNameMap{ $streaming } );
}

####################################################################
# Support Functions

sub _newMaster {
	my ($self) = @_;
	
	my $oldMaster = master($self);
	
	# TODO - better algorithm
	my $newMaster = $self->{'players'}->[0] || $self->{'allPlayers'}->[0];

	return if $oldMaster == $newMaster;
	
	$self->{'masterId'} = $newMaster->id();
	
	main::INFOLOG && $log->info("new master: " . $self->{'masterId'});
	
	# copy the playlist to the new master but do not reset the song queue
	Slim::Player::Playlist::copyPlaylist($newMaster, $oldMaster, 1);
			
	$newMaster->streamformat($oldMaster->streamformat);
	$oldMaster->streamformat(undef);	
	
	# do we still need to save frame data?
	if (@{$self->{'players'}} < 2) {
		initialStreamBuffer($self, undef);
		frameData($self, undef);
	} else {
		my $needFrameData = 0;
	    foreach ( @{$self->{'players'}} ) {
		    my $model = $_->model();
		    last if $needFrameData = ($model eq 'slimp3' || $model eq 'squeezebox');
	    }
		initialStreamBuffer($self, undef);
		frameData($self, undef);
	}	
}

sub _isMaster {
	my ($self, $client) = @_;
	return ($self->{'masterId'} eq $client->id());
}

sub _getPlayingState {return $_[0]->{'playingState'};}
sub _getStreamingState {return $_[0]->{'streamingState'};}

sub _setPlayingState {
	my ($self, $newState) = @_;
	$self->{'playingState'} = $newState;

	main::INFOLOG && $log->info("new playing state $PlayingStateName[$newState]");

	if ($newState != BUFFERING && $newState != WAITING_TO_SYNC) {$self->{'rebuffering'} = 0;}
}

sub _setStreamingState {
	my ($self, $newState) = @_;
	$self->{'streamingState'} = $newState;
	
	main::INFOLOG && $log->info("new streaming state $StreamingStateName[$newState]");
	
	# If we switch to IDLE then any oustanding getNextTrack callback should be discarded
	if ($newState == IDLE) {
		$self->{'nextTrackCallbackId'}++;
		$self->{'nextTrack'} = undef;
	}
}

1;
