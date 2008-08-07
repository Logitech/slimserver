package Slim::Utils::Alarm;
use strict;

# Max Spicer, May 2008
# This code is derived from code with the following copyright message:
#
# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.


################################################################################
=head1 NAME

Slim::Utils::Alarm;

=head1 SYNOPSIS

	# Create a new alarm for 11:30am
	my $alarm = Slim::Utils::Alarm->new($client, 11 * 3600 + 30 * 60);

	# Set it to sound only on Sunday and Saturday
	$alarm->day(0,0);
	$alarm->day(6,0);

	# Set the volume to 80 (don't do this if you just want to use the default volume for all alarms)
	$alarm->volume(80);

	# Enable it
	$alarm->enabled(1);

	# Save and activate it
	$alarm->save;

=head1 DESCRIPTION

This class implements SqueezeCenter alarms (alarm clock functionality) and provides methods for manipulating them.

Two types of alarm are implemented - daily alarms and calendar alarms.  Daily alarms have a time component and a specified subset of weekdays on which to sound e.g. 09:00 on Monday, Saturday and Sunday.  Calendar alarms have a time specified as an epoch value, representing an absolute date and time on which they sound e.g. 09:30 on 21/4/2008.

=cut

#use Data::Dumper;
use Time::HiRes;

use Slim::Player::Client;
use Slim::Utils::DateTime;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $log = logger('player.alarmclock');
my $prefs = preferences('server');

# Period over which to fade volume changes
my $FADE_SECONDS = 20;

# Duration for showBriefly
my $SHOW_BRIEFLY_DUR = 3;

# Screensaver used during alarms
my $DEF_ALARM_SCREENSAVER = 'SCREENSAVER.datetime';
my $alarmScreensaver = $DEF_ALARM_SCREENSAVER; 

# Hash storing the playlists that alarms can use.  Keys are playlist URLs.  Values are the string descriptions for each URL.
# Values that should be passed through client->string are surrounded with curly braces.
# e.g. 
# {
#	'randomplay://albums' => '{PLUGIN_RANDOM_ALBUMS}',
# }
my %alarmPlaylists = (); 

# Playlist types that have been registered using addPlaylist.  Keys are the playlist type, values
# are the playlists datastructure.  See docs for addPlaylist.
my %extraPlaylistTypes; 


################################################################################
=head1 INSTANCE METHODS

=head2 new( $client, $time )

Creates a new alarm object to sound at the specified time.

$time should be an epoch value to specify a calendar alarm, or the number of seconds since midnight to specify a daily alarm.
Values for $time should be rounded down to the nearest minute - any second values will be ignored.  Daily alarms will default
to sounding every day.

If time is not specified it will be set to undef.  However, the time must be set before the alarm can be saved or scheduled.

=cut

sub new {
	my $class  = shift;	# class to construct
	my $client = shift;	# client to which the alarm applies
	my $time = shift;	# optional time at which alarm should sound

	return unless defined $client;

	# External users: use the accessors!
	my $self = {
		_clientId => $client->id,
		_time => $time, 	
		# For daily alarms, _days is an array of booleans indicating days for which alarm should sound.
		# 0=Sun 6=Sat. undef indicates a calendar alarm
		_days => (! defined $time || $time < 86400) ? [(1) x 7] : undef,
		_enabled => 0,
		_repeat => 1,
		_playlist => undef,
		_volume => undef, # Use default volume
		_active => 0,
		_snoozeActive => 0,
		_nextDue => undef,
		_timeoutTimer => undef, # Timer ref to the alarm timeout timer
		_createTime => Time::HiRes::time,
	};

	bless $self, $class;
	
	return $self;
}

################################################################################
=head2 Accessors

=head3 calendarAlarm( )

Returns whether this is a calendar alarm (i.e. set for a specific date) or a daily alarm.

=cut

sub calendarAlarm {
	my $self = shift;

	return ! defined $self->{_days};
}

=head3 client( [ $client ] )

Sets/returns the client to which this alarm applies.

=cut

sub client {
	my $self = shift;
	my $newValue = shift;
	
	$self->{_clientId} = $newValue->id if defined $newValue;
	
	return Slim::Player::Client::getClient($self->{_clientId});
}

=head3 comment( [ $text ] )

Sets/returns the optional text associated with this alarm.  Comments should be brief and I<may> be displayed on a player's or
controller's screen when the alarm sounds.

=cut

sub comment {
	my $self = shift;
	my $newValue = shift;

	$self->{_comment} = $newValue if defined $newValue;

	return $self->{_comment};
}

=head3 day( $dayNum , [ 0/1 ] ) 

Sets/returns whether the alarm is active on a particular day (0=Sun .. 6=Sat).

=cut

sub day {
	my $self = shift;
	my $day = shift;
	my $newValue = shift;
	
	$self->{_days}->[$day] = $newValue if defined $newValue;
	
	return $self->{_days}->[$day];
}

=head3 everyDay( [0/1] )

Sets/returns whether this alarm is active every day.  This is a convenience method to avoid repeated calls to day().

=cut

sub everyDay {
	my $self = shift;
	my $all = shift;

	if (defined $all) {
		foreach my $day (@{$self->{_days}}) {
			$day = $all;
		}
	} else {
		# Look for a day that isn't enabled
		$all = 1;
		foreach my $day (@{$self->{_days}}) {
			if (! $day) {
				$all = 0;
				last;
			}
		}
	}
	return $all;
}

=head3 enabled( [ 0/1 ] )

Sets/returns whether this alarm is enabled.  Disabled alarms will never sound.

=cut

sub enabled {
	my $self = shift;
	my $newValue = shift;
	
	$self->{_enabled} = $newValue if defined $newValue;
	
	return $self->{_enabled};
}

=head3 repeat ( [0/1] )

Sets/returns whether this alarm repeats.  Non-repeating alarms will be automatically disabled once they have sounded.

Non-repeating alarms that are set to sound on multiple days, will be disabled after they sound for the first time and so will
not then sound on the other days unless they are then re-enabled manually.

=cut

sub repeat {
	my $self = shift;
	my $newValue = shift;

	$self->{_repeat} = $newValue if defined $newValue;
	
	return $self->{_repeat};
}

=head3 time( [ $time ] )

Sets/returns the time for this alarm.  If a new time is specified the alarm will be converted to/from calendar type as appropriate.

Warning: for calendar alarms, this time will also include a date component.  Editors should take care not to destroy this when changing just the time.

=cut

sub time {
	my $self = shift;
	my $time = shift;
	
	if (defined $time) {
		$self->{_time} = $time;
		if ($time >= 86400) {
			$self->{_days} = undef;
		}
	}
	
	return $self->{_time};
}

=head3 id( )

Returns the unique id for this alarm.

Alarms that have not have been saved will not have an id defined - this method will return undef in this case.

=cut

sub id {
	my $self = shift;
	
	return $self->{_id};
}

=head3 volume( [ $volume ] )

Sets/returns the volume at which this alarm will sound.

N.B.  This feature is not exposed in the default interfaces.  Alarms all use the default volume.

=cut

sub volume {
	my $self = shift;

	my $client = $self->client;
	my $class = ref $self;

	if (@_) {
		my $newValue = shift;
	
		$self->{_volume} = $newValue;

		# Update the RTC volume if needed
	        if ($client->alarmData->{nextAlarm} == $self) {
			$class->setRTCAlarm($client);
		};

	}

	if (defined $self->{_volume}) {
		return $self->{_volume};
	} else {
		# No explicit volume defined so alarm uses default volume
		return ref($self)->defaultVolume($self->client);
	}
}

=head3 usesDefaultVolume( [ 1 ] )

Sets/returns whether this alarm uses the default volume or has it's own volume setting.  Set to 1 to use the default.

To stop an alarm using the default volume, set its volume to something.

N.B.  This feature is not exposed in the default interfaces.  Alarms all use the default volume.

=cut

sub usesDefaultVolume {
	my $self = shift;
	my $default = shift;

	if ($default) {
		$self->{_volume} = undef;
	}

	return ! defined $self->{_volume};
}

=head3 playlist( $playlistUrl )

Sets/returns the url for the alarm playlist.  If url is undef, the current playlist will be used.

=cut

sub playlist {
	my $self = shift;

	if (@_) {
		my $newValue = shift;
		
		$self->{_playlist} = $newValue;
	}
	
	return $self->{_playlist};
}

=head3 nextDue( )

Returns the epoch value for when this alarm is next due.

=cut

sub nextDue {
	my $self = shift;

	return $self->{_nextDue};
}


################################################################################
=head2 Methods

=head3 findNextTime( $baseTime )

Returns as an epoch value, the time when this alarm should next sound or undef if no time was found.  Also stores this value
within the alarm object.

$baseTime must be an epoch value for the start time from which the next alarm should be considered and should be the current
time rounded down to the nearest minute.  Any alarm with a time equal to or after this will be considered a candidate for being
next.  This allows multiple alarms to be considered against a common, non-increasing base point.

=cut

sub findNextTime {
	my $self = shift;
	my $baseTime = shift;
	
	if (! $self->{_enabled}) {
		return undef;
	}
	
	my $client = $self->client;

	if (defined $self->{_days}) {
		# Convert base time into a weekday number and time
		my ($sec, $min, $hour, $mday, $mon, $year, $wday)  = localtime($baseTime);
		
		if ( main::SLIM_SERVICE ) {
			# Adjust for the user's timezone
			my $timezone = $prefs->client($client)->get('timezone') 
				|| $client->playerData->userid->timezone 
				|| 'America/Los_Angeles';

			my $dt = DateTime->now( 
				time_zone => $timezone
			);
			
			$wday = $dt->day_of_week;
			$min  = $dt->min;
			$hour = $dt->hour;
			
			$log->debug( "SN time adjusted for $timezone to wday $wday $hour:$min:$sec" );
		}

		# Find the first enabled alarm starting at baseTime's day num 
		my $day = $wday;
		for (my $i = 0; $i < 7; $i++) {
			if ($self->{_days}[$day]) {
				# alarm is enabled for this day, which is $day days away from $baseTime

				# work out how far $baseTime is from midnight on that day
				my $baseTimeSecs = $min * 60 + $hour * 3600;
				# alarm is next if it's not in the same day as base time or is >= basetime
				if ($i > 0 || $baseTimeSecs <= $self->{_time}) {
					# alarm time in seconds since midnight on base time's day
					my $relAlarmTime = $self->{_time} + $i * 86400;
					my $absAlarmTime = $baseTime - $baseTimeSecs + $relAlarmTime;

					$log->debug(sub {'Potential next time found: ' . _timeStr($absAlarmTime)});

					# Make sure this isn't the alarm that's just sounded or another alarm with the
					# same time.
					my $lastAlarmTime = $client->alarmData->{lastAlarmTime};
					defined $lastAlarmTime && $log->debug(sub {'Last alarm due: ' . _timeStr($lastAlarmTime)});
					if (! defined $lastAlarmTime || $absAlarmTime != $lastAlarmTime) {
						$self->{_nextDue} = $absAlarmTime;
						return $absAlarmTime;
					} else {
						$log->debug('Skipping..');
					}

				}
			}
			# Move on to the next day, wrapping round to the start of the week as necessary
			$day = ($day + 1) % 7;
		}

		$log->debug('Alarm has no days enabled');
		return undef;
	} else {
		# This is a calendar alarm so _time is already absolute
		$self->{_nextDue} = $self->{_time};
		return $self->{_time}
	}
}

=head3 sound( )

Sound this alarm by starting its playlist on its client, adjusting the volume, displaying notifications etc etc.

This method is generally called by a Timer callback that has been set using scheduleNext();

=cut

sub sound {
	my $self = shift;

	my $class = ref $self;

	# Optional, high-res epoch time value for when this alarm should have been triggered.  Passed when
	# the alarm is triggered by a timer.
	my $alarmTime = shift;

	my $client = $self->client;
	
	if (! defined $client) {
		# This can happen if a client is forgotten after an alarm was scheduled for it
		$log->debug('Alarm triggered for unknown client: ' . $self->{_clientId});
		return;
	}

	$log->debug('Alarm triggered for ' . $client->name);

	# Check if this alarm is still current - we could be running really late due to hibernation or similar
	my $soundAlarm = 1;
	if (defined $alarmTime) {
		# Alarms should only ever be late.  Sound them anyway if they are early
		my $delta = CORE::time - $alarmTime;
	
		# Give a 60 second tolerance
		if ($delta > 60) {
			$log->debug("Alarm is $delta seconds late - ignoring");
			$soundAlarm = 0;
		}
	}

	# Disable alarm if it doesn't repeat
	if (! $self->{_repeat}) {
		$log->debug('Alarm does not repeat so disabling for next time');
		$self->{_enabled} = 0;
	}

	if ($soundAlarm) {
		# Sound an Alarm (HWV 63)
		$log->debug('Sounding alarm');

		# Stop any other current alarm
		if ($client->alarmData->{currentAlarm}) {
			$log->debug('Stopping other current alarm');
			$client->alarmData->{currentAlarm}->stop;
		}

		$client->alarmData->{lastAlarmTime} = $self->{_nextDue};
		$self->{_active} = 1;
		$client->alarmData->{currentAlarm} = $self;

		my $now = Time::HiRes::time(); 
		# Bug 7818, count this as user interaction, even though it isn't really
		$client->lastActivityTime($now);

		# Send out notification
		Slim::Control::Request::notifyFromArray($client, ['alarm', 'sound', $self->{_id}]);

		my $request = $client->execute(['stop']);
		$request->source('ALARM');
		$request = $client->execute(['power', 1]);
		$request->source('ALARM');

		$class->pushAlarmScreensaver($client);

		# Set analogOutMode to subwoofer to force output through main speakers even if headphones are plugged in
		# This needs doing a lot more thoroughly.  Bug 8146 
		$client->can('setAnalogOutMode') && $client->setAnalogOutMode(1);

		# Set up volume
		my $currentVolume = $client->volume;
		$log->debug("Current vol: $currentVolume Alarm vol: " . $self->volume);

		if ($currentVolume != $self->volume) {
			$log->debug("Changing volume from $currentVolume to " . $self->volume);
			$client->volume($self->volume);
		}

		# Fade volume change if requested 
		if ( $prefs->client($client)->get('alarmfadeseconds') ) {
			$log->debug('Fading volume');
			$client->fade_volume( $FADE_SECONDS );
		}

		# Play alarm playlist, falling back to the current playlist if undef
		if (defined $self->playlist) {
			$log->debug('Alarm playlist url: ' . $self->playlist);
			$request = $client->execute(['playlist', 'play', $self->playlist]);
			$request->source('ALARM');

		} else {
			$log->debug('Current playlist selected for alarm playlist');
			# Check that the current playlist isn't empty
			my $playlistLen = Slim::Player::Playlist::count($client);
			if ($playlistLen) {
				$request = $client->execute(['play']);
				$request->source('ALARM');
			} else {
				$log->debug('Current playlist is empty');

				$self->_playFallback();
			}
		}

		# Set a callback to check we managed to play something
		Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + 20, \&_checkPlaying);

		# Allow a slight delay for things to load up then tell the user what's going on
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, sub {
			# Show a long-lasting notification unless we've already pushed into an alarm screensaver
			my $showBrieflyDur = 30;
			if (Slim::Buttons::Common::mode($client) eq $class->alarmScreensaver) {
				$showBrieflyDur = $SHOW_BRIEFLY_DUR;
			}

			my $line1 = $client->string('ALARM_NOW_PLAYING');

			my $line2; 
			if (defined $self->playlist) {
				# Get the string that was given when the current playlist url was registered and stringify
				# if necessary
				my $playlistString = $alarmPlaylists{$self->playlist};
				if (defined $playlistString) {
					my ($stringKey) = $playlistString =~ /^{(.*)}$/; 

					if (defined $stringKey) {
						$line2 = $client->string($stringKey);
					} else {
						$line2 = $playlistString;
					}
				} else {
					$line2 = Slim::Music::Info::standardTitle($client, $self->playlist);
				}
			} else {
				$line2 = $client->string('CURRENT_PLAYLIST');
			}

			$client->showBriefly({
				line => [ $line1, $line2 ],
				duration => $showBrieflyDur,
			});
		} );

		# Set up subscription to end the alarm on user activity
		$class->_setAlarmSubscription($client);

		# Set up subscription to automatically end the alarm if requested
		my $timeout = $prefs->client($client)->get('alarmTimeoutSeconds');
		if ($timeout) {
			$log->debug("Scheduling time out in $timeout seconds");
			$self->{_timeoutTimer} = Slim::Utils::Timers::setTimer($self, Time::HiRes::time + $timeout, \&_timeout);
		}
	}

	$self->{_timerRef} = undef;

	$class->scheduleNext($client);
}

=head3

snooze( )

Snooze this alarm, causing it to stop sounding and re-sound after a set period.  The snooze length is determined
by the client pref, alarmSnoozeSeconds.

Does nothing unless this alarm is already active.

=cut

sub snooze {
	my $self = shift;

	$log->debug('Snooze called for alarm id ' . $self->{_id});
	
	return unless $self->{_active};

	my $client = $self->client;
	my $class = ref $self;

	# don't snooze again if we're already snoozing.
	if ($self->{_snoozeActive}) {
		$log->debug('Already snoozing');
	} else {
		my $snoozeSeconds = $prefs->client($client)->alarmSnoozeSeconds;
		$log->debug("Snoozing for $snoozeSeconds seconds");

		# Send notification
		Slim::Control::Request::notifyFromArray($client, ['alarm', 'snooze', $self->{_id}]);

		# Kill the callback to check for playback
		Slim::Utils::Timers::killTimers($self, \&_checkPlaying);

		# Reset the alarm timeout timer so the alarm will now time out in timeoutSeconds + snoozeTime
		if (defined $self->{_timeoutTimer}) {
			my $timeout = $prefs->client($client)->get('alarmTimeoutSeconds');
			Slim::Utils::Timers::killSpecific($self->{_timeoutTimer});
			$log->debug(sub {'Scheduling automatic timeout in ' . ($timeout + $snoozeSeconds) . ' seconds'});
			$self->{_timeoutTimer} =
				Slim::Utils::Timers::setTimer($self, Time::HiRes::time + $timeout + $snoozeSeconds, \&_timeout);
		}

		if (Slim::Music::Info::isRemoteURL(Slim::Player::Playlist::url($client))) {
			# Stop rather than pause for remote urls in order to keep radio in real time after a snooze
			$log->debug('Remote url being played - stopping');
			my $request = $client->execute(['stop']);
			$request->source('ALARM');
		} else {
			# Pause the music (check if it's playing first or we'll generate a 'playlist jump' command)
			if (Slim::Player::Source::playmode($client) =~ /play/) {
				my $request = $client->execute(['pause', 1]);
				$request->source('ALARM');
			}
		}

		$self->{_snoozeActive} = 1;

		# Set timer for snooze expiry 
		Slim::Utils::Timers::setTimer($self, Time::HiRes::time + $snoozeSeconds, \&stopSnooze);

		# Set up snooze subscription to end snooze on user activity
		$class->_setAlarmSubscription($client, 1);

		$client->showBriefly({
			line => [$client->string('ALARM_SNOOZE')],
			duration => $SHOW_BRIEFLY_DUR,
		});
	}

	$class->pushAlarmScreensaver($client);
}

=head3

stopSnooze( [ $unPause = 1 ] )

Stop this alarm from snoozing.  Has no effect if the alarm isn't snoozing.

Unless $unPause is set to 0, this will cause music to be unpaused.  This is only normally desirable if this sub
is being called at the end of a snooze timer.

=cut

sub stopSnooze {
	my $self = shift;
	my $unPause = @_ ? shift : 1;

	$log->debug('Snooze expired');

	return unless $self->{_snoozeActive};

	my $class = ref $self;
	my $client = $self->client;

	$self->{_snoozeActive} = 0;
	
	if ($unPause) {
		$log->debug('unpausing music');
		my $request = $client->execute(['pause', 0]);
		$request->source('ALARM');

		# Fade volume if requested 
		if ( $prefs->client($client)->get('alarmfadeseconds') ) {
			$log->debug('Fading volume');
			$client->fade_volume( $FADE_SECONDS );
		}
	}

	$client->showBriefly({
		line     => [$client->string('ALARM_SNOOZE_ENDED')],
		duration => $SHOW_BRIEFLY_DUR,
	});
	
	# Reset the subscription to end the alarm on user activity
	$class->_setAlarmSubscription($client);

	# Send notifications
	Slim::Control::Request::notifyFromArray($client, ['alarm', 'snooze_end', $self->{_id}]);
}


=head3

stop( )

Stops this alarm.  Has no effect if the alarm is not sounding.

=cut

sub stop {
	my $self = shift;

	my $client = $self->client;

	return unless $self->{_active};

	if (defined $client->alarmData->{currentAlarm} && $client->alarmData->{currentAlarm} == $self) {
		$client->alarmData->{currentAlarm} = undef;
	}
	$self->{_active} = 0;
	$self->{_snoozeActive} = 0;

	# Kill the subscription to automatically end this alarm on user activity
	Slim::Control::Request::unsubscribe(\&_alarmEnd, $client);

	# Kill the callback to check for playback
	Slim::Utils::Timers::killTimers($self, \&_checkPlaying);

	# Kill the callback to time out the alarm
	if (defined $self->{_timeoutTimer}) {
		Slim::Utils::Timers::killSpecific($self->{_timeoutTimer});
		$self->{_timeoutTimer} = undef;
	}

	# Restore analogOutMode to previous setting
	$client->can('setAnalogOutMode') && $client->setAnalogOutMode();

	my $class = ref $self;
	$class->popAlarmScreensaver($client);

	$client->showBriefly({
		line => [$client->string('ALARM_STOPPED')],
		duration => $SHOW_BRIEFLY_DUR,
	});

	# Send notifications
	Slim::Control::Request::notifyFromArray($client, ['alarm', 'end', $self->{_id}]);
}

=head3

displayStr( )

Returns a short, single-line string describing this alarm.  e.g. 09:00 Mo Sa Sj

=cut

sub displayStr {
	my $self = shift;

	my $displayStr;
	
	if ($self->{_enabled}) {
		$displayStr = Slim::Utils::DateTime::secsToPrettyTime($self->{_time});

		if (! $self->everyDay) {
			foreach my $day (1 .. 6, 0) { 
				if ($self->day($day)) {
					$displayStr .= ' ' . $self->client->string('ALARM_SHORT_DAY_' . $day);
				}
			}
		}
	} else {
		$displayStr = $self->client->string('ALARM_OFF');
	}

	return $displayStr;
}

=head3 timeStr( )

Returns the formatted time string for this alarm.

=cut

sub timeStr {
	my $self = shift;

	my $time = Slim::Utils::DateTime::secsToPrettyTime($self->{_time});
	$time =~ s/^\s//g;
	
	return $time;
}

=head3 active( )

Returns whether this alarm is currently active.

=cut

sub active {
	my $self = shift;

	return $self->{_active};
}

=head3 snoozeActive( )

Returns whether this alarm currently has an active snooze.

A snooze can only be active if the alarm is active i.e. snoozeActive => active.

=cut

sub snoozeActive {
	my $self = shift;

	return $self->{_snoozeActive};
}

################################################################################
# Persistence management
################################################################################

=head3 save( [ $reschedule = 1 ] )

Save/update alarm.  This must be called on an alarm once changes have finished being made to it. 
Changes to existing alarms will not be persisted unless this method is called.  New alarms will
not be scheduled unless they have first been saved.

Unless $reschedule is set to 0, alarms will be rescheduled after this call.  This is almost always
what you want!

=cut

sub save {
	my $self = shift;
	my $reschedule = @_ ? shift : 1;

	my $class = ref $self;
	my $client = $self->client;

	$log->debug('Saving alarm.');

	my $alarmPref = $self->_createSaveable;

	my $prefAlarms = $prefs->client($client)->alarms;
	$prefAlarms->{$self->{_id}} = $alarmPref;
	$prefs->client($client)->alarms($prefAlarms);

	# If there are no other alarms, force alarmsEnabled to 1 to make sure
	# the new alarm sounds.  Otherwise assume that if all alarms were turned
	# off it was with good reason and leave things as they are.
	if (keys(%$prefAlarms) == 1) {
		$log->debug('Forcing alarmsEnabled to 1');
		$prefs->client($client)->alarmsEnabled(1);
	}

	# There's a new/updated alarm so reschedule
	if ($reschedule) {
		$log->debug('Alarm saved with id ' . $self->{_id} .  ' Rescheduling alarms...');
		$class->scheduleNext($client);
	}
}

# Return a saveable version of the alarm and add the alarm to the client object.
# Exists solely in order to allow the alarm pref migration code to create migrated versions
# of old alarms in one batch and save them straight to the preferences.  This is necessary as
# reading prefs within the migration code causes a loop.  This sub therefore mustn't read prefs!
sub _createSaveable {
	my $self = shift;

	my $client = $self->client;

	if (! defined $self->{_time}) {
		$log->debug('Alarm hasn\'t had a time set.  Not saving.');
		return;
	}
	
	# Add alarm to client object if it hasn't been saved before
	if (! defined $self->{_id}) {
		# Create unique id for alarm
		$self->{_id} = Slim::Utils::Misc::createUUID();

		$client->alarmData->{alarms}->{$self->{_id}} = $self;
	}

	# Create a persistent version for the prefs
	return {
		_time => $self->{_time},
		_days => $self->{_days},
		_enabled => $self->{_enabled},
		_playlist => $self->{_playlist},
		_volume => $self->{_volume},
		_comment => $self->{_comment},
		_id => $self->{_id},
		_repeat => $self->{_repeat},
		_createTime => $self->{_createTime},
	};
}

=head3 delete( )

Delete alarm.  Alarm will be removed from the list of alarms for the current client and will no longer be scheduled.

=cut

sub delete {
	my $self = shift;

	my $class = ref $self;
	my $client = $self->client;

	# Only delete if alarm has actually been saved
	if (defined $self->{_id}) {
		$log->debug('Deleting alarm, id: ' . $self->{_id});

		my $prefAlarms = $prefs->client($client)->alarms;
		delete $prefAlarms->{$self->{_id}};
		$prefs->client($client)->alarms($prefAlarms);

		delete $client->alarmData->{alarms}->{$self->{_id}};

		# Alarm deleted so reschedule
		$log->debug('Rescheduling alarms...');
		$class->scheduleNext($client);
	}
};

# Check whether the alarm's client is playing something and trigger a fallback if not
sub _checkPlaying {
	my $self = shift;

	$log->debug('Checking whether client is playing for alarm ' . $self->id);

	# Do nothing if the alarm is no longer active or the user has already hit snooze (something must have woken them!)
	return if ! $self->active || $self->snoozeActive;

	my $client = $self->client;

	if (! (Slim::Player::Source::playmode($client) =~ /play/)) {
		$log->debug('Alarm active but client not playing');
		$self->_playFallback();
	}
}

# Play something as a fallback for when the alarm playlist has failed for some reason 
sub _playFallback {
	my $self = shift;

	my $client = $self->client;

	$log->debug('Starting fallback sounds');
	# Would be nice to have some alarm tones to fall back to (Bug 8499).  For now, just
	# grab 10 random tracks and play them
	$log->debug('Playing 10 random tracks');
	my @tracks = Slim::Schema->rs('track')->search({audio => 1}, {rows => 10, order_by => \'RAND()'})->all;
	my $request = $client->execute(['playlist', 'loadtracks', 'listRef', \@tracks ]);
	$request->source('ALARM');
}

# Handle the alarm timeout timer firing
sub _timeout {
	my $self = shift;

	my $client = $self->client;

	$log->debug('Alarm ' . $self->id . ' ending automatically due to timeout');

	# Pause the music.  Should we turn off?  Probably only if the player was off to start with.
	my $request = $client->execute(['pause', 1]);
	$request->source('ALARM');

	$self->stop;
}


################################################################################
=head1 CLASS METHODS

=head2 init

Initialise SqueezeCenter alarm functionality.  This must be called on server startup (probably from slimserver.pl).

=cut

sub init {
	my $class = shift;
	my $client = shift;

	$log->debug('Alarm initing...');
}

# Subscribe to commands that should stop the alarm
sub _setAlarmSubscription {
	my $class = shift;
	my $client = shift;
	my $snooze = shift;

	# Remove any subscription for this client
	Slim::Control::Request::unsubscribe(\&_alarmEnd, $client);

	my $currentAlarm = $client->alarmData->{currentAlarm};

	return unless defined $currentAlarm;

	$log->debug('Adding ' . ($snooze ? 'snooze' : 'alarm') . ' subscription');

	my $stopCommands;

	if ($snooze) {
		# The snooze should be cancelled on anything the user does that results in music playing and also on any
		# "off" action:
		# power needs to be caught on its own as the music is paused
		# pause/play when paused results in pause
		# fwd/rew and (hopefully) commands that load a new playlist result in 'playlist jump'
		$stopCommands = ['power', 'pause', 'stop', 'playlist'];
	} else {
		# The alarm should be cancelled on anything the user does that would stop the music
		# power needs to be caught on its own as the music could potentially be stopped if the alarm playlist failed
		# for some reason
		$stopCommands =  ['pause', 'stop', 'power'];
	}
	Slim::Control::Request::subscribe(\&_alarmEnd, [$stopCommands], $client);
}

=head2 getCurrentAlarm( $client )

Return the current alarm for a client.  A client only has a current alarm if an alarm is currently active for that client.  Otherwise, returns undef.

=cut

sub getCurrentAlarm {
	my $class = shift;
	my $client = shift;

	return $client->alarmData->{currentAlarm};
}

=head2 getNextAlarm( $client )

Return the next alarm that will sound for a client.  If there is no next alarm, returns undef.

=cut

sub getNextAlarm {
	my $class = shift;
	my $client = shift;

	return $client->alarmData->{nextAlarm};
}

=head2 getAlarms( $client, [ $excludeCalAlarms = 1 ] )

Return a sorted list of the alarms for a client.

Unless $excludeCalAlarms is explicitly set to false, only daily alarms will be returned. 

=cut

sub getAlarms {
	my $class = shift;
	my $client = shift;
	my $excludeCalAlarms = @_ ? shift : 1;

	my $alarmHash = $client->alarmData->{alarms};

	my @alarms;
	foreach my $alarm (sort { $alarmHash->{$a}->{_createTime} <=> $alarmHash->{$b}->{_createTime} } keys %{$alarmHash}) {
				
		$alarm = $alarmHash->{$alarm};
		
		next unless $alarm && $alarm->id;

		if ($excludeCalAlarms && $alarm->calendarAlarm) {
			next;
		}
		
		push @alarms, $alarm;
	}
	return @alarms;
}

=head2 getAlarm( $client, $id )

Returns a specific alarm for a given client, specified by alarm id.  If no such alarm exists, undef is returned.

=cut

sub getAlarm {
	my $class = shift;
	my $client = shift;
	my $id = shift;

	return $client->alarmData->{alarms}->{$id};
}

=head2 loadAlarms( $client )

Load the alarms for a given client and schedule the next alarm.  This should be called
whenever a new client is detected.

=cut

sub loadAlarms {
	my $class = shift;
	my $client = shift;	
	
	$log->debug('Loading saved alarms from prefs for ' . $client->name);
	my $prefAlarms = $prefs->client($client)->alarms;

	foreach my $prefAlarm (keys %$prefAlarms) {
		$prefAlarm = $prefAlarms->{$prefAlarm};
		my $alarm = $class->new($client, $prefAlarm->{_time});
		$alarm->{_days} = $prefAlarm->{_days};
		$alarm->{_enabled} = $prefAlarm->{_enabled};
		$alarm->{_playlist} = $prefAlarm->{_playlist};
		$alarm->{_volume} = $prefAlarm->{_volume};
		$alarm->{_comment} = $prefAlarm->{_comment};
		$alarm->{_id} = $prefAlarm->{_id};
		# Fix up createTime for alarms that pre-date its introduction
		my $needsSaving = 0;
		if (! defined $prefAlarm->{_createTime}) {
			$log->debug('Alarm has no createTime - assigning one');
			$needsSaving = 1;
			$alarm->{_createTime} = Time::HiRes::time;
		} else {
			$alarm->{_createTime} = $prefAlarm->{_createTime};
		}

		$client->alarmData->{alarms}->{$alarm->{_id}} = $alarm; 

		if ($needsSaving) {
			# Disable rescheduling after save as we'll do it soon anyway
			$alarm->save(0);
		}
	}

	$log->debug('Alarms loaded.  Rescheduling...');
	$class->scheduleNext($client);
}

=head2 scheduleNext( $client )

Set a timer to sound the next due alarm for a given client at its alarm time.

This method is called automatically when new alarms are added or re-scheduling is needed for any other reason.

=cut

sub scheduleNext {
	my $class = shift;
	my $client = shift;

	$log->debug('Asked to schedule next alarm for ' . $client->name);
	my $alarms = $client->alarmData->{alarms};

	my $nextAlarm = $client->alarmData->{nextAlarm};
	if ($nextAlarm) {
		if (defined $nextAlarm->{_timerRef}) {
			$log->debug('Previous scheduled alarm wasn\'t triggered.  Clearing nextAlarm and killing timer');
			Slim::Utils::Timers::killSpecific($nextAlarm->{_timerRef});

			# As the next alarm hasn't actually sounded, do a complete reschedule.  This allows
			# the same alarm to be scheduled again if it's still next
			$client->alarmData->{nextAlarm} = undef;
		}
	}

	if ($class->alarmsEnabled($client)) {
		# Work out current time rounded down to the nearest minute
		my $now = CORE::time;
		$now = $now - $now % 60;

		# Find the next alarm
		my $nextAlarmSecs = undef;
		my $nextAlarm = undef;

		foreach my $alarm (keys %$alarms) {
			my $secs = $alarms->{$alarm}->findNextTime($now);
			if (defined $secs && (! defined $nextAlarmSecs || $secs < $nextAlarmSecs)) {
				$nextAlarmSecs = $secs;
				$nextAlarm = $alarms->{$alarm};
			}
		}

		if (defined $nextAlarm) {
			$log->debug(sub {'Next alarm is at ' . _timeStr($nextAlarm->{'_nextDue'})});

			if ($nextAlarm->{_nextDue} == $now) {
				# The alarm is for this minute - sound it immediately
				$log->debug('Sounding alarm immediately');
				$nextAlarm->sound;
			} else {
				# TODO: schedule a bit early to allow for timers firing late.  Once this is done and the early
				# timer fires, check every second to see if the alarm should sound.  10 secs early should be more
				# than enough.  This is only really needed for SqueezeNetwork where 1000s of clients can lead
				# to timers firing a few seconds late.
				my $alarmTime = $nextAlarm->{_nextDue};
				$log->debug('Scheduling alarm');
				$nextAlarm->{_timerRef} = Slim::Utils::Timers::setTimer($nextAlarm, $alarmTime, \&sound, $alarmTime);

				$client->alarmData->{nextAlarm} = $nextAlarm;
			}
		} else {
			$log->debug('No future alarms found');
		}

	} else {
		$log->debug('Alarms are disabled');
	}

	# Set/clear the client's RTC alarm if supported
	$class->setRTCAlarm($client);
}

=head2 setRTCAlarm( $client )

Sets a given client's RTC alarm clock if the client has an alarm within the next 24 hours, otherwise clears it.  Does nothing 
if the client does not have an RTC alarm clock.  The next alarm for the client should already have been scheduled before this is called.

Once called, this sub will schedule itself to be called again in 24 hours.

=cut

sub setRTCAlarm {
	my $class = shift;
	my $client = shift;

	$log->debug('Asked to set rtc alarm for ' . $client->name);

	return if ! $client->hasRTCAlarm;

	# Clear any existing timer to call this sub
	my $timerRef = $client->alarmData->{_rtcTimerRef};
	if (defined $timerRef) {
		# Kill previous rtc alarm timer
		Slim::Utils::Timers::killSpecific($timerRef);
	}

	my $nextAlarm = $class->getNextAlarm($client);

	my $clearRTCAlarm = 1;
	my $now = Time::HiRes::time;

	if (defined $nextAlarm) {
		my $nextDue = $nextAlarm->nextDue;

		my $secsToAlarm = $now - $nextDue;
		if ($secsToAlarm && $secsToAlarm < 86400) {
			# Alarm due in next 24 hours

			my $alarmTime;
			if ($nextAlarm->calendarAlarm) {
				$alarmTime = $nextAlarm->time % 86400;
			} else {
				$alarmTime = $nextAlarm->time;
			}

			# Alarm times are "floating" so no need to adjust for local time
			$log->debug( "Setting RTC alarm to $alarmTime, volume " . $nextAlarm->volume );
			
			$client->setRTCAlarm($alarmTime, $nextAlarm->volume);

			$clearRTCAlarm = 0;
		}
	}

	if ($clearRTCAlarm) {
		# Next alarm not defined or not within next 24 hours
		$log->debug('Clearing RTC alarm');
		$client->setRTCAlarm(undef);
	}

	# Set a timer to check again in 24 hours
	$client->alarmData->{_rtcTimerRef} = Slim::Utils::Timers::setTimer($class, $now + 86400, \&setRTCAlarm, $client);
}

=head2 defaultVolume( [ $volume ] )

Sets/returns the volume level that is used for all alarms on a given client that don't have an explicit volume level set.

N.B.  The ability to change an individual alarm's volume is not exposed in the default interfaces, so all alarms created
using them will use the default volume.  Nevertheless, the correct way to find the volume level for an alarm is to do
$alarm->volume NOT $class->defaultVolume.  This allows plugins etc to utilise the hidden volume functionality if desired.

=cut

sub defaultVolume {
	my $class = shift;
	my $client = shift;
	my $volume = shift;

	if (defined $volume && $volume != $prefs->client($client)->alarmDefaultVolume) {
		$prefs->client($client)->alarmDefaultVolume($volume);
		# Update the RTC volume
		$class->setRTCAlarm($client);
	}

	return $prefs->client($client)->alarmDefaultVolume;
}

=head2 alarmsEnabled ( [0/1] )

Sets/returns whether alarms are enabled for a given client.

This enables all alarms to be quickly enabled/disabled, whilst still retaining their settings for the future.

=cut

sub alarmsEnabled {
	my $class = shift;
	my $client = shift;
	my $enabled = shift;

	if (defined $enabled && $enabled != $prefs->client($client)->alarmsEnabled) {
		$prefs->client($client)->alarmsEnabled($enabled);
		
		# Reschedule to enable/disable
		$log->debug('Alarms enabled state changed - rescheduling alarms...');
		$class->scheduleNext($client);
	}

	return $prefs->client($client)->alarmsEnabled;
}

=head2 addPlaylists( $type, $playlists )

Adds playlists to the list of possible playlists that alarms can play when sounding.  This method
should be called by modules that offer new playlist types and wish to register them for alarms.

$type is a string identifying the type of playlist that is being added.  It may be displayed to the
user, for example as a heading to group multiple playlists of the same type.  $type will be passed
through string().  $type is used as a key - any previous playlists registered with the same type will
be replaced!

$playlists is a reference to an array of hash references.  The array items should be presented in
the order in which they should be presented to the end-user.  Each hash represents a playlist to be
added and should contain a title key, whose value is the display name for a playlist, and an url
key, whose value is the url for the playlist.  The title values will be passed through
$client->string if they are enclosed in curly braces.

For example, the RandomPlay plugin could register its mixes as possible alarm playlists as follows
(in fact, RandomPlay is special and is registered differently, but you get the idea...):

	Slim::Utils::Alarm->addPlaylists('PLUGIN_RANDOMPLAY',
		[
			{ title => '{PLUGIN_RANDOM_TRACK}', url => 'randomplay:track' },
			{ title => '{PLUGIN_RANDOM_CONTRIBUTOR}', url => 'randomplay:contributor' },
			{ title => '{PLUGIN_RANDOM_ALBUM}', url => 'randomplay:album' },
			{ title => '{PLUGIN_RANDOM_YEAR}', url => 'randomplay:year' },
		]
	);

This could result in the user being presented with four new alarm playlists to chose from, all
grouped under the heading of PLUGIN_RANDOMPLAY.

=cut

sub addPlaylists {
	my $class = shift;
	my $type = shift;
	my $playlists = shift;

	foreach my $playlist (@$playlists) {
		# Create a mapping from the url to its display name
		$alarmPlaylists{$playlist->{url}} = $playlist->{title}; 		
	}

	# Create a mapping from the playlist type to its associated playlists
	$extraPlaylistTypes{$type} = $playlists;
}

=head2 getPlaylists( )

Return the current possible alarm playlists with names stringified for the given client.

The returned datastructure is somewhat complex and is best explained by example:
	[
		{
			type => 'Random Mix',
			items => [
				{ title => 'Song Mix', url => 'randomplay://albums' },
				{ title => 'Album Mix', url => 'randomplay://artists' },
				...
			],
		},
		{
			type => 'Favorites',
			items => [
				...
			],
		},
		{
			type => 'Use Current Playlist',
			items => [
				{ title => 'The Current Playlist', url => ... }, 
			],
			# This playlist type will only ever contain one item
			singleItem => 1,
		},
		...
	]

The outer array reference contains an ordered set of playlist types.  Each playlist type contains
an ordered list of playlists.

The singleItem key for a playlist type is effectively a rendering hint.  The player ui uses this to
present Current Playlist as a top-level item rather than as a sub-menu.

=cut

sub getPlaylists {
	my $class = shift;
	my $client = shift;

	my @playlists;
	
	# Add the current playlist option
	push @playlists, {
			type => 'CURRENT_PLAYLIST',
			items => [ { title => '{ALARM_USE_CURRENT_PLAYLIST}', url => undef } ],
			singleItem => 1,
		};

	# Add favorites flattened out into a single level, only including audio & playlist entries
	if (my $favsObject = Slim::Utils::Favorites->new($client)) {
		push @playlists, {
				type => 'FAVORITES',
				items => $favsObject->all,
			};
	}

	if (!main::SLIM_SERVICE) {
		# Add the current saved playlists
		# XXX: This code would ideally also be elsewhere
		my @saved = Slim::Schema->rs('Playlist')->getPlaylists;
		my @savedArray;
		foreach my $playlist (@saved) {
			push @savedArray, {
					title => Slim::Music::Info::standardTitle($client, $playlist->url),
					url => $playlist->url
				};
		}
		@savedArray = sort { $a->{title} cmp $b->{title} } @savedArray; 
		push @playlists, {
				type => 'PLAYLISTS',
				items => \@savedArray,
			};

		# Add random mixes
		if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::RandomPlay::Plugin') ) {
			if ( my $mixes = Slim::Plugin::RandomPlay::Plugin->getAlarmPlaylists() ) {
				foreach my $mixType (@$mixes) {
					push @playlists, {
							type => $mixType->{type},
							items => $mixType->{items},
						};
				}
			}
		}
	}

	# Add natural sounds
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Sounds::Plugin') ) {
		if ( my $sounds = Slim::Plugin::Sounds::Plugin->getAlarmPlaylists() ) {
			foreach my $soundType (@$sounds) {
				push @playlists, {
						type => $soundType->{type},
						items => $soundType->{items},
					};
			}
		}
	}

	# Add any alarm playlists that have been registered via addPlaylists
	foreach my $playlist (keys %extraPlaylistTypes) {
		push @playlists, {
				type => "$playlist",
				items => $extraPlaylistTypes{$playlist},
			};
	}

	# Stringify keys for given client if they have been enclosed in curly braces 
	foreach my $type (@playlists) {
		if ( $type->{type} eq uc( $type->{type} ) ) {
			$type->{type} = $client->string( $type->{type} );
		}
		
		foreach my $playlist (@{$type->{items}}) {
			# Stringify keys that are enclosed in curly braces
			my ($stringTitle) = $playlist->{title} =~ /^{(.*)}$/; 
			if (defined $stringTitle) {
				$stringTitle = $client->string($stringTitle);
			} else {
				$stringTitle = $playlist->{title};
			}
			$playlist->{title} = $stringTitle;
		}
	}

	return \@playlists;
}

=head2 alarmScreensaver( $modeName )

Gets/sets the screensaver mode name that is used during an active alarm.  This mode will be pushed into at the start of an alarm
and will for the duration of the alarm override any other defined screensaver.

Setting $modeName to undef will disable the alarm screensaver.

=cut

sub alarmScreensaver {
	my $class = shift;
	
	if (@_) {
		$alarmScreensaver = shift;
	}

	return $alarmScreensaver;
}

=head2 getDefaultAlarmScreensaver( )

Returns the mode name of the default alarm screensaver.

=cut

sub getDefaultAlarmScreensaver {
	my $class = shift;

	return $DEF_ALARM_SCREENSAVER;
}

=head2 pushAlarmScreensaver( $client )

Push into the alarm screensaver (if any) on the given client.  Generally done automatically when an alarm is sounded.

=cut

sub pushAlarmScreensaver {
	my $class = shift;
	my $client = shift;

	my $currentMode = Slim::Buttons::Common::mode($client);
	my $alarmScreensaver = $class->alarmScreensaver;

	$log->debug('Attempting to push into alarm screensaver: ' . (defined $alarmScreensaver ? $alarmScreensaver : undef)
			. ". Current mode: $currentMode");
	if (defined $alarmScreensaver
		&& Slim::Buttons::Common::validMode($alarmScreensaver)
		&& $currentMode ne $alarmScreensaver) {

		$log->debug('Pushing alarm screensaver');
		Slim::Buttons::Common::pushMode($client, $alarmScreensaver);
		$client->update();
	}
}

=head2 

popAlarmScreensaver( $client )

Pop out of the alarm screensaver if it's being displayed on the given client.

=cut

sub popAlarmScreensaver {
	my $class = shift;
	my $client = shift;

	my $currentMode = Slim::Buttons::Common::mode($client);
	$log->debug("Attempting to pop alarm screensaver.  Current mode: $currentMode");
	if ($currentMode eq $class->alarmScreensaver) {
		$log->debug('Popping alarm screensaver');
		Slim::Buttons::Common::popMode($client);
	}
}


################################################################################
# PACKAGE METHODS

# Format a given time in a human readable way.  Used for debug only.
sub _timeStr {
	my $time = shift;

	if ($time < 86400) {
		my ($sec, $min, $hour, $mday, $mon, $year, $wday)  = gmtime($time);
		return "$hour:$min:$sec";
	} else {
		my ($sec, $min, $hour, $mday, $mon, $year, $wday)  = localtime($time);
		return "$hour:$min:$sec $mday/" . ($mon + 1) . '/' . ($year + 1900);
	}

}

# Callback handlers.  (These have to be package methods as can only take $request as their argument)

# Handle events that should stop the alarm/snooze.  This doesn't cover the case of the snooze timer firing.
sub _alarmEnd {
	my $request = shift;

	my $client = $request->client;

	$log->debug(sub {'_alarmEnd called with request: ' . $request->getRequestString});

	my $currentAlarm = $client->alarmData->{currentAlarm};
	if (! defined $currentAlarm) {
		$log->debug('No current alarm.  Doing nothing.');
		return;
	}

	# Don't respond to requests that we created ourselves
	my $source = $request->source;
	if ($source && ($source eq 'ALARM' || $source eq 'PLUGIN_RANDOMPLAY')) {
		$log->debug('Ignoring self-created request');
		return;
	}

	# power always ends the alarm, whether snoozing or not
	if ($currentAlarm->{_snoozeActive} && $request->getRequest(0) ne 'power') {
		# When snoozing we should end on 'playlist jump' but can only filter on playlist
		if ($request->getRequest(0) eq 'playlist' && $request->getRequest(1) ne 'jump') {
			$log->debug('Ignoring playlist command that isn\'t jump');
			return;
		}

		# Stop the snooze expiry timer and set a new alarm subscription for events that should end the alarm
		$log->debug('Stopping snooze');
		Slim::Utils::Timers::killTimers($currentAlarm, \&stopSnooze);
		$currentAlarm->stopSnooze(0);
	} else {
		$log->debug('Stopping alarm');
		$currentAlarm->stop;
	}
}

1;

__END__
